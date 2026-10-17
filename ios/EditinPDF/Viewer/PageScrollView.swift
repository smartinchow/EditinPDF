import EditinPDFCore
import SwiftUI
import UIKit

/// The boxes of the search hit being looked at, on its page, in PDF points: one for each line the
/// hit runs across. They are drawn in another colour than the other hits' boxes.
struct ActiveHighlight: Equatable {
    let page: Int
    let rects: [CGRect]
}

/// A box on a page, in PDF points (view space: origin at the page's top-left, y down): what to bring
/// into view when a search hit is picked. `rect` is `.null` for a page with no box to show.
struct PageRect: Equatable {
    let page: Int
    let rect: CGRect
}

/// The open document's pages, one below the other, scrolling and zooming.
struct PageScrollView: UIViewControllerRepresentable {
    let model: DocumentModel
    /// A page to bring to the top of the view, set by whatever wants to jump there (the thumbnails,
    /// search). It is cleared once the jump is made.
    @Binding var scrollTarget: Int?
    /// A box to bring into view once the view is at `scrollTarget`'s page, set with it by search, for
    /// a hit that may be far down a page taller than the view. It is cleared once it has been done.
    @Binding var revealRect: PageRect?
    /// The boxes to highlight on each page, in PDF points: the hits of a search.
    var highlights: [Int: [CGRect]] = [:]
    /// The hit being looked at, which is drawn in its own colour over the others.
    var activeHighlight: ActiveHighlight?

    func makeUIViewController(context: Context) -> PageScrollViewController {
        PageScrollViewController(model: model)
    }

    func updateUIViewController(_ controller: PageScrollViewController, context: Context) {
        controller.highlightsByPage = highlights
        controller.activeHighlight = activeHighlight
        guard scrollTarget != nil || revealRect != nil else { return }
        let target = scrollTarget
        let reveal = revealRect
        // The jump changes the current page and the requests are cleared, and SwiftUI's state must not
        // change while it updates views: both happen just after the update instead.
        let targetRequest = $scrollTarget
        let revealRequest = $revealRect
        Task { @MainActor in
            if let target { controller.scroll(to: target) }
            // After the jump, so that the page is where it belongs and the box is only moved into view.
            if let reveal { controller.reveal(reveal) }
            targetRequest.wrappedValue = nil
            revealRequest.wrappedValue = nil
        }
    }
}

/// Shows the pages of `model`'s document in one column, each fitted to the width, zooming from 1 to
/// 8 times. Only the pages in view and the two either side of them have a view; the others are
/// dropped as they scroll away, with their tiles. Keeps `model.currentPage` on the page the reader
/// is on: the first or the last at either end of the document, otherwise the page at the centre of
/// the view.
final class PageScrollViewController: UIViewController, UIScrollViewDelegate {
    /// How many pages above and below those in view keep a view, so they are drawn before they
    /// scroll in.
    static let pagesKeptAround = 2

    /// How near an end of its scroll range, in points, the view counts as at that end. Offsets and
    /// sizes are rounded to device pixels along the way: a point at most, on a 1x screen.
    static let endTolerance: CGFloat = 1

    let scrollView = UIScrollView()
    /// The view that zooms. It holds the page views, laid out at zoom 1.
    let contentView = UIView()

    /// The boxes to highlight on each page, in PDF points: the hits of a search. A page view is given
    /// its page's boxes when it is made as well as when they change, so they are still there when a
    /// page scrolls out of the window of page views and back.
    var highlightsByPage: [Int: [CGRect]] = [:] {
        didSet { if highlightsByPage != oldValue { applyHighlightsToPageViews() } }
    }

    /// The hit being looked at: its boxes get the active colour, on its page.
    var activeHighlight: ActiveHighlight? {
        didSet { if activeHighlight != oldValue { applyHighlightsToPageViews() } }
    }

    private let model: DocumentModel
    /// Nil until the view has a width.
    private var layout: PageLayout?
    private var pageViews: [Int: PageView] = [:]
    /// A page asked for before there was a layout to find it in.
    private var pendingTarget: Int?
    /// A box asked for before there was a layout to find its page in.
    private var pendingReveal: PageRect?

    init(model: DocumentModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The pages that have a view, in order.
    var loadedPages: [Int] { pageViews.keys.sorted() }

    /// The view of `page`, if it has one.
    func pageView(for page: Int) -> PageView? { pageViews[page] }

    override func loadView() {
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 8
        // The pages scroll under the bars, and the insets keep the first and the last clear of them;
        // `.always` keeps the sides clear too, such as the camera's side in landscape.
        scrollView.contentInsetAdjustmentBehavior = .always
        scrollView.backgroundColor = .secondarySystemBackground
        // For UI tests; not shown or spoken.
        scrollView.accessibilityIdentifier = "pageScrollView"
        scrollView.addSubview(contentView)
        view = scrollView
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let insets = scrollView.adjustedContentInset
        let fitWidth = scrollView.bounds.width - insets.left - insets.right
        guard fitWidth > 0, fitWidth != layout?.fitWidth else { return }
        relayout(fitWidth: fitWidth)
    }

    /// Brings `page` to the top of the view, or as near as the end of the document allows. Waits
    /// for the first layout if there is none yet; a page the document does not have is ignored.
    func scroll(to page: Int) {
        guard let layout else {
            pendingTarget = page
            return
        }
        guard (0..<layout.pageCount).contains(page) else { return }
        show(layout.frame(of: page).minY)
    }

    /// Scrolls, if need be, so that `target.rect` (PDF points on its page) is wholly in the part of the
    /// view the bars leave: with the box in the middle of it when it fits, as near as the ends of the
    /// document allow, and at its top and left edges when it is larger. Zoomed in, it scrolls across
    /// as well as down. Nothing happens when the box is in view already, when there is no box to show
    /// (`.null`, or not finite), or when the document does not have its page. Waits for the first
    /// layout if there is none yet.
    ///
    /// Search uses it after `scroll(to:)`: the page's top is not where the hit is when the page is
    /// taller than the view (a phone or an iPad on its side, a page zoomed in).
    func reveal(_ target: PageRect) {
        guard let layout else {
            pendingReveal = target
            return
        }
        let rect = target.rect
        guard (0..<layout.pageCount).contains(target.page),
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else { return }
        // The box in layout points at zoom 1: the page is fitted to the width by its own scale.
        let frame = layout.frame(of: target.page)
        let scale = layout.scale(of: target.page)
        let box = CGRect(x: frame.minX + rect.minX * scale, y: frame.minY + rect.minY * scale,
                         width: rect.width * scale, height: rect.height * scale)
        guard !visibleArea().contains(box) else { return }

        let zoom = scrollView.zoomScale
        let insets = scrollView.adjustedContentInset
        let size = scrollView.bounds.size
        let offset = CGPoint(
            x: Self.offset(showing: box.minX * zoom, length: box.width * zoom, in: size.width - insets.left - insets.right, inset: insets.left),
            y: Self.offset(showing: box.minY * zoom, length: box.height * zoom, in: size.height - insets.top - insets.bottom, inset: insets.top))
        // As `show(_:)` keeps to the ends of the scroll range.
        let lowest = CGPoint(x: -insets.left, y: -insets.top)
        let highest = CGPoint(x: max(lowest.x, scrollView.contentSize.width + insets.right - size.width),
                              y: max(lowest.y, scrollView.contentSize.height + insets.bottom - size.height))
        scrollView.setContentOffset(CGPoint(x: min(max(offset.x, lowest.x), highest.x), y: min(max(offset.y, lowest.y), highest.y)),
                                    animated: false)
        update()
    }

    /// The scroll offset along one axis that puts the span of `length` starting at `low` (scroll view
    /// points) in the middle of the `viewport` that lies past `inset`, or at its start when the span is
    /// longer than the viewport.
    private static func offset(showing low: CGFloat, length: CGFloat, in viewport: CGFloat, inset: CGFloat) -> CGFloat {
        length <= viewport ? low + (length - viewport) / 2 - inset : low - inset
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        contentView
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        update()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        update()
    }

    /// The bars' insets decide where the ends of the scroll range are.
    func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        update()
    }

    // MARK: Layout

    /// Lays the pages out for a new width at zoom 1, keeping the page that was at the top of the
    /// view there (or going to a page asked for before the first layout). The page views are made
    /// again: a page view's size never changes, so its tiles never mix two sizes.
    private func relayout(fitWidth: CGFloat) {
        let anchor = layout.flatMap { readingPosition(in: $0) }
        let target = pendingTarget
        pendingTarget = nil
        let newLayout = PageLayout(pages: model.pages, fitWidth: fitWidth)
        layout = nil
        scrollView.zoomScale = 1
        for view in pageViews.values { view.removeFromSuperview() }
        pageViews.removeAll()
        contentView.frame = CGRect(origin: .zero, size: newLayout.contentSize)
        scrollView.contentSize = newLayout.contentSize
        layout = newLayout

        if let target, (0..<newLayout.pageCount).contains(target) {
            show(newLayout.frame(of: target).minY)
        } else if let anchor {
            let frame = newLayout.frame(of: anchor.page)
            show(frame.minY + anchor.fraction * frame.height)
        } else {
            show(newLayout.frame(of: model.currentPage).minY)
        }

        if let reveal = pendingReveal {
            pendingReveal = nil
            self.reveal(reveal)
        }
    }

    /// The page at the top of the visible area and how far down it that is (0 to 1); a point in a
    /// gap counts as the top of the page below it.
    private func readingPosition(in layout: PageLayout) -> (page: Int, fraction: CGFloat)? {
        guard layout.pageCount > 0 else { return nil }
        let top = visibleArea().minY
        let page = min(layout.visiblePages(in: CGRect(x: 0, y: top, width: layout.fitWidth, height: 0)).lowerBound,
                       layout.pageCount - 1)
        let frame = layout.frame(of: page)
        return (page, min(max((top - frame.minY) / frame.height, 0), 1))
    }

    /// Scrolls so that layout point `y` (at zoom 1) is at the top of the visible area, as near as
    /// the ends of the document allow, at the left edge; then brings the page views and the current
    /// page up to date, even when the offset was already there.
    private func show(_ y: CGFloat) {
        let insets = scrollView.adjustedContentInset
        let lowest = -insets.top
        let highest = max(lowest, scrollView.contentSize.height + insets.bottom - scrollView.bounds.height)
        let offsetY = min(max(y * scrollView.zoomScale - insets.top, lowest), highest)
        scrollView.setContentOffset(CGPoint(x: -insets.left, y: offsetY), animated: false)
        update()
    }

    /// The part of the content the bars do not cover, in layout points at zoom 1.
    private func visibleArea() -> CGRect {
        scrollView.convert(scrollView.bounds.inset(by: scrollView.adjustedContentInset), to: contentView)
    }

    /// Makes views for the pages in view and those kept around them, drops the others, and moves
    /// the current page to the one the reader is on.
    private func update() {
        guard let layout, let document = model.document() else { return }
        let inView = layout.visiblePages(in: scrollView.convert(scrollView.bounds, to: contentView))
        let kept = max(0, inView.lowerBound - Self.pagesKeptAround)..<min(layout.pageCount, inView.upperBound + Self.pagesKeptAround)
        for (page, view) in pageViews where !kept.contains(page) {
            view.removeFromSuperview()
            pageViews[page] = nil
        }
        for page in kept where pageViews[page] == nil && model.pages.indices.contains(page) {
            let info = model.pages[page]
            let view = PageView(page: page, document: document, pointSize: CGSize(width: info.widthPt, height: info.heightPt))
            view.frame = layout.frame(of: page)
            applyHighlights(to: view)
            contentView.addSubview(view)
            pageViews[page] = view
        }
        if let page = readerPage(in: layout), page != model.currentPage {
            model.currentPage = page
        }
    }

    private func applyHighlightsToPageViews() {
        for view in pageViews.values { applyHighlights(to: view) }
    }

    /// Gives `view` the boxes of its own page.
    private func applyHighlights(to view: PageView) {
        view.overlay.highlights = highlightsByPage[view.page] ?? []
        if let active = activeHighlight, active.page == view.page {
            view.overlay.activeHighlights = active.rects
        } else {
            view.overlay.activeHighlights = []
        }
    }

    /// The page the reader is on. At the top end of the scroll range (or past it) it is the first
    /// page, and at the bottom end the last: a first or last page shorter than half the visible area
    /// never reaches its centre. Between the ends it is the page under the centre of the visible
    /// area, or nil in a gap between two pages, where the current page stays what it was. A
    /// document that fits in the view is at both ends at once, and on its first page.
    private func readerPage(in layout: PageLayout) -> Int? {
        guard layout.pageCount > 0 else { return nil }
        let insets = scrollView.adjustedContentInset
        let offset = scrollView.contentOffset.y
        if offset <= -insets.top + Self.endTolerance { return 0 }
        if offset >= scrollView.contentSize.height + insets.bottom - scrollView.bounds.height - Self.endTolerance {
            return layout.pageCount - 1
        }
        return layout.page(at: CGPoint(x: layout.fitWidth / 2, y: visibleArea().midY))
    }
}
