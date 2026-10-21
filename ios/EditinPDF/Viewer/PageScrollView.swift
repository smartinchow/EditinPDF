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

/// The view that zooms, holding the page views. Before it looks for the view under a finger going
/// down, it says where the finger lands (`touchWillLand`), when it is the first on the screen, so that
/// Draw's canvas can be put there first and take the finger (`MarkupInteraction.prepareToDraw`).
final class PageContentView: UIView {
    /// Told where a first finger is landing, in this view's coordinates.
    var touchWillLand: ((CGPoint) -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Only for a finger going down, not for a pointer hovering or a lookup with no event.
        if let event, event.type == .touches, self.point(inside: point, with: event),
           Self.isFirstFinger(otherTouches: (event.allTouches ?? []).map { ($0.view != nil, $0.phase) }) {
            touchWillLand?(point)
        }
        return super.hitTest(point, with: event)
    }

    /// Whether a touch being placed is the first finger on the screen: none of the event's other
    /// touches, those already placed on a view (`isPlaced`), is still down. The touch being placed is
    /// not placed yet, whether or not the event counts it already.
    nonisolated static func isFirstFinger(otherTouches: [(isPlaced: Bool, phase: UITouch.Phase)]) -> Bool {
        !otherTouches.contains { $0.isPlaced && $0.phase != .ended && $0.phase != .cancelled }
    }
}

/// The scroll view of the pages. A finger that goes down on a form field's widget (a button, in reading
/// mode) and moves scrolls the pages, as it does from anywhere else on them: by default a scroll view
/// leaves a touch that began on a control to the control.
final class PagesScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is FormWidgetButton || super.touchesShouldCancel(in: view)
    }
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
    /// The selected text: its page and its boxes there, in PDF points. Nil when nothing is selected.
    var selection: (page: Int, rects: [CGRect])?
    /// What the last change, undo or redo did to the pages (`DocumentModel.lastChange`), for the
    /// controller to lay them out again or redraw them. Passed in, not read from `model` here, so that
    /// the screen's body reads it and SwiftUI updates the controller each time it changes.
    var lastChange: PageChange?
    /// The Markup tool picked (`DocumentModel.tool`), passed in, as `lastChange` is, so that the
    /// controller hears when it changes.
    var tool: Tool?
    /// The annotation selected with Select, or picked in the Comments list: its page and its box there
    /// (`DocumentModel.selectedAnnotationPlace`), passed in for its page to outline it.
    var selectedAnnotation: PageRect?
    /// The document's form and whether it may be filled in (`DocumentModel.formIndex`, `canFillForms`),
    /// passed in, as `lastChange` is, for the form's overlays.
    var forms = FormDisplay.empty

    /// The screen is going: strokes drawn with Draw and waiting are added (the canvas goes with it).
    static func dismantleUIViewController(_ controller: PageScrollViewController, coordinator: ()) {
        controller.model.commitPendingInk()
    }

    func makeUIViewController(context: Context) -> PageScrollViewController {
        PageScrollViewController(model: model)
    }

    func updateUIViewController(_ controller: PageScrollViewController, context: Context) {
        controller.highlightsByPage = highlights
        controller.activeHighlight = activeHighlight
        controller.selection = selection
        controller.markupTool = tool
        // A change the controller has followed already is ignored, so handing the same one over with
        // every update is harmless. Followed just after the update, not in it: laying the pages out
        // again adds the strokes and text waiting, a change to the model, and SwiftUI's state must not
        // change while it updates views. Tasks on the main actor start in the order they are made, so
        // the changes are followed in the order they came (and an older one is ignored anyway).
        if let lastChange {
            Task { @MainActor in controller.apply(lastChange) }
        }
        controller.forms = forms
        controller.selectedAnnotation = selectedAnnotation
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
            // An annotation picked in the Comments list is in view now: its menu can come up over it.
            controller.markupInteraction.selecting.selectionDidChange()
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
///
/// The reader can select text on the pages: a long press, then handles to drag, then Copy or a mark. The
/// gestures and the handles are `SelectionInteraction`'s, and a Markup tool's drag `MarkupInteraction`'s; what is selected arrives as `selection`, to be drawn by
/// the page views' overlays like the search hits are. In reading mode the form's widgets on the pages
/// that have a view are buttons that fill the form in (`FormInteraction`).
final class PageScrollViewController: UIViewController, UIScrollViewDelegate {
    /// How many pages above and below those in view keep a view, so they are drawn before they
    /// scroll in.
    static let pagesKeptAround = 2

    /// How near an end of its scroll range, in points, the view counts as at that end. Offsets and
    /// sizes are rounded to device pixels along the way: a point at most, on a 1x screen.
    static let endTolerance: CGFloat = 1

    let scrollView: UIScrollView = PagesScrollView()
    /// The view that zooms. It holds the page views, laid out at zoom 1, and Draw's canvas over one.
    let contentView = PageContentView()

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

    /// The selected text: its page and its boxes there, in PDF points, drawn on that page's overlay. A
    /// page view is given its boxes when it is made as well as when they change, as the search hits
    /// are, so they are still there when the page scrolls out of the window of page views and back.
    var selection: (page: Int, rects: [CGRect])? {
        didSet {
            guard !Self.isSame(oldValue, selection) else { return }
            for view in pageViews.values { applyOverlay(to: view) }
            selectionInteraction.selectionDidChange()
        }
    }

    /// The annotation selected with Select: its page and its box there, in PDF points, outlined on
    /// that page's overlay. A page view is given it when it is made as well as when it changes, as the
    /// search hits are. Its menu comes and goes with it (`AnnotationSelectInteraction.selectionDidChange`),
    /// and a drag of the one before is over: its outline is drawn where it is again.
    var selectedAnnotation: PageRect? {
        didSet {
            guard selectedAnnotation != oldValue else { return }
            for view in pageViews.values {
                view.overlay.dragOffset = .zero
                applyOverlay(to: view)
            }
            markupInteraction.selecting.selectionDidChange()
        }
    }

    let model: DocumentModel
    /// The Markup tool picked: when it changes, the text of the pages in view is asked for, for a tool
    /// that marks text (`MarkupInteraction.prefetchText`), and the gestures are set up for it: with
    /// Draw, one finger draws and two scroll (`MarkupInteraction.toolDidChange`). The form's overlays
    /// are shown in reading mode only (`FormInteraction.toolDidChange`).
    var markupTool: Tool? {
        didSet {
            guard markupTool != oldValue else { return }
            markupInteraction.toolDidChange()
            formInteraction.toolDidChange()
            prefetchMarkupText()
        }
    }
    /// The document's form, and whether it may be filled in: the overlays over the pages' widgets are
    /// made again when it changes (`FormInteraction.formsDidChange`).
    var forms = FormDisplay.empty {
        didSet { if forms != oldValue { formInteraction.formsDidChange() } }
    }
    /// The long press, the tap, the handles and the menu of text selection.
    private(set) lazy var selectionInteraction = SelectionInteraction(host: self)
    /// What a finger does with a Markup tool picked: drags out text to highlight, underline or strike
    /// through. It decides which of its gestures and the scroll view's has a finger.
    private(set) lazy var markupInteraction = MarkupInteraction(host: self, model: model)
    /// The form's overlays in reading mode, and the field being typed in.
    private(set) lazy var formInteraction = FormInteraction(host: self, model: model)
    /// Nil until the view has a width.
    private var layout: PageLayout?
    private var pageViews: [Int: PageView] = [:]
    /// A page asked for before there was a layout to find it in.
    private var pendingTarget: Int?
    /// A box asked for before there was a layout to find its page in.
    private var pendingReveal: PageRect?
    /// Where the reader was the last time the view was at the layout's width: what a new layout keeps.
    /// It is recorded as the reader scrolls and zooms, not read when the width changes, because by then
    /// the scroll view has already pulled its offset into the range for its new size (it lays itself
    /// out before its controller does), losing the place across a zoomed page.
    private var lastPosition: ReadingPosition?
    /// The pages the layout was made for. When the document's no longer match them (in number, size or
    /// rotation), the layout is out of date.
    private var laidOutPages: [PageInfo] = []
    /// The revision of the last change followed (`apply(_:)`): the document's when the controller was
    /// made, until a change comes.
    private var followedRevision: UInt64

    init(model: DocumentModel) {
        self.model = model
        followedRevision = model.lastChange?.revision ?? model.revision
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)), name: UIWindow.didBecomeKeyNotification, object: nil)
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
        selectionInteraction.install()
        markupInteraction.install()
        formInteraction.install()
    }

    /// On screen, the window tells the markup of every finger going down, outside the pages too
    /// (`MarkupInteraction.fingerWentDown`).
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if view.window?.isKeyWindow == true { FrontDocument.shared.bringForward(model) }
        let observer = markupInteraction.fingersDown
        guard let window = view.window, observer.view !== window else { return }
        observer.view?.removeGestureRecognizer(observer)
        window.addGestureRecognizer(observer)
    }

    /// Tells the document, as UIKit keeps it (the `UIDocumentViewController` SwiftUI shows it in), that
    /// it has a change it has not saved, now: a change handed over as a finger goes down outside the
    /// pages (`MarkupInteraction.fingerWentDown`). The undo manager tells it too, but only as it closes
    /// the run loop turn's undo group, at the end of the turn. When the main thread is slow to handle
    /// the finger going down (the keyboard being put away waits on the keyboard's own process; a slow
    /// device), the finger lifting from Back is handled in the same turn: the document closes then,
    /// and a document that counts no change by then closes without saving, and the change is lost (the
    /// text left in a text box or a field, on the CI runner). A document that counts a change already
    /// is left as it is. The undo manager's count comes on top of this one: the document may count one
    /// change more than it has until it is next saved, which costs at most a save more.
    func countChangeNow() {
        var responder: UIResponder? = self
        while let current = responder, !(current is UIDocumentViewController) { responder = current.next }
        guard let document = (responder as? UIDocumentViewController)?.document, !document.hasUnsavedChanges else { return }
        document.updateChangeCount(.done)
    }

    /// A window became the key one: when it is this one, its document is in front, for the Edit menu's
    /// Undo and Redo (two documents side by side on an iPad).
    @objc private func windowBecameKey(_ notification: Notification) {
        if let window = notification.object as? UIWindow, window === viewIfLoaded?.window { FrontDocument.shared.bringForward(model) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let observer = markupInteraction.fingersDown
        observer.view?.removeGestureRecognizer(observer)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let fitWidth = currentFitWidth()
        guard fitWidth > 0, fitWidth != layout?.fitWidth else { return }
        relayout(fitWidth: fitWidth, placing: .readingPosition)
    }

    /// The width the pages fit: the view's, less the insets on either side, which need not be the same
    /// (a bar standing at one side, the camera's side, Split View).
    private func currentFitWidth() -> CGFloat {
        scrollView.bounds.inset(by: scrollView.adjustedContentInset).width
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
        let box = Self.layoutRect(of: rect, onPage: target.page, in: layout)
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

    // MARK: Following the document's changes

    /// Brings the pages up to date with `change`, a change, undo or redo of the document that the
    /// model has published. One that changed the number of pages, or a page's size or rotation, has
    /// the pages laid out again and their views made again, at the zoom the reader had, with the
    /// current page (`model.currentPage`, which the model keeps on a page the document still has) at
    /// the top; so does one after which the model has the reader on another page than the one in view
    /// (the page being read was moved). Any other has its pages redrawn where they are: `change.pages`, or every page that has
    /// a view when it does not say.
    ///
    /// A change already followed, or older, does nothing. Two changes can be published before the
    /// controller hears of the first: the layout is made again whenever it no longer matches the
    /// document's pages, whatever the change says, and when a revision has been skipped every page
    /// with a view is redrawn, since the pages of the change missed are not known.
    func apply(_ change: PageChange) {
        guard change.revision > followedRevision else { return }
        let missedOne = change.revision > followedRevision + 1
        followedRevision = change.revision
        // Before the first layout there is nothing drawn: that layout reads the pages as they are.
        guard let layout else { return }
        // The model moves the current page with its content when pages before it are deleted, moved
        // or inserted (`OrganizeMath.readerPage`): with the shapes all the same, the reader is taken
        // there too.
        let readerMoved = readerPage(in: layout).map { $0 != model.currentPage } ?? false
        if change.geometryChanged || readerMoved || !Self.sameGeometry(laidOutPages, model.pages) {
            let zoom = scrollView.zoomScale
            let across = visibleArea().minX
            relayout(fitWidth: layout.fitWidth, placing: .currentPage(zoom: zoom, across: across))
            return
        }
        let touched = missedOne ? nil : change.pages
        for (page, view) in pageViews where touched?.contains(page) ?? true {
            view.redraw()
        }
        // The text read for the old revision is dropped: read it again for the pages in view.
        prefetchMarkupText()
    }

    /// Whether `a` and `b` are as many pages, each the same size and turned the same way.
    private static func sameGeometry(_ a: [PageInfo], _ b: [PageInfo]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { old, new in
            old.widthPt == new.widthPt && old.heightPt == new.heightPt && old.rotationDegrees == new.rotationDegrees
        }
    }

    // MARK: Where things are, for the selection

    /// The page under `point` (the content view's coordinates: layout points at zoom 1) and where on it,
    /// in PDF points. Nil in a gap between pages, outside the column, or before there is a layout.
    func pageLocation(of point: CGPoint) -> (page: Int, point: CGPoint)? {
        guard let page = layout?.page(at: point), let pagePoint = pagePoint(ofContentPoint: point, onPage: page) else { return nil }
        return (page, pagePoint)
    }

    /// Where `point` (the content view's coordinates) is in PDF points of `page`, though it be off that
    /// page: what a drag that began on the page and went past its edge is at. Nil before there is a
    /// layout, or for a page the document does not have.
    func pagePoint(ofContentPoint point: CGPoint, onPage page: Int) -> CGPoint? {
        guard let layout, (0..<layout.pageCount).contains(page) else { return nil }
        let scale = layout.scale(of: page)
        guard scale > 0 else { return nil }
        let frame = layout.frame(of: page)
        return CGPoint(x: (point.x - frame.minX) / scale, y: (point.y - frame.minY) / scale)
    }

    /// `rect` (PDF points on `page`) in the scroll view's own coordinates, which is where the zoom and the
    /// scrolling are: what a view placed in the scroll view, beside the content, lines up with. Nil
    /// before there is a layout, or for a page the document does not have.
    func scrollViewRect(of rect: CGRect, onPage page: Int) -> CGRect? {
        guard let layout, (0..<layout.pageCount).contains(page) else { return nil }
        return contentView.convert(Self.layoutRect(of: rect, onPage: page, in: layout), to: scrollView)
    }

    /// `rect` (PDF points on `page`) in layout points at zoom 1, the content view's coordinates: the page is
    /// fitted to the width by its own scale, and sits where the layout puts it.
    private static func layoutRect(of rect: CGRect, onPage page: Int, in layout: PageLayout) -> CGRect {
        let frame = layout.frame(of: page)
        let scale = layout.scale(of: page)
        return CGRect(x: frame.minX + rect.minX * scale, y: frame.minY + rect.minY * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }

    /// Where `page` is in the content view's coordinates (layout points at zoom 1), and how many of
    /// them a PDF point of it is: what Draw's canvas over it covers. Nil before there is a layout, or
    /// for a page the document does not have.
    func layoutPlace(ofPage page: Int) -> (frame: CGRect, scale: CGFloat)? {
        guard let layout, (0..<layout.pageCount).contains(page), layout.scale(of: page) > 0 else { return nil }
        return (layout.frame(of: page), layout.scale(of: page))
    }

    /// How many points of the scroll view a PDF point of `page` is, at the zoom the view is at: 0
    /// before there is a layout, or for a page the document does not have.
    func screenScale(ofPage page: Int) -> CGFloat {
        (layout?.scale(of: page) ?? 0) * scrollView.zoomScale
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        contentView
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        update()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        selectionInteraction.viewportWillChange()
        markupInteraction.selecting.viewportWillChange()
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        selectionInteraction.viewportWillChange()
        markupInteraction.selecting.viewportWillChange()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        update()
    }

    /// The bars' insets decide where the ends of the scroll range are.
    func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        update()
    }

    // MARK: Layout

    /// Lays the pages out for a new width, keeping the reader where they were: the same page, as far
    /// down it, as far across the column and at the same zoom (`ReadingPosition`), or going to a page
    /// asked for before the first layout. The page views are made again, at zoom 1: a page view's size
    /// never changes, so its tiles never mix two sizes. The zoom is put back afterwards.
    ///
    /// After a change to the document's pages (`apply(_:)`), the place on the page means nothing any
    /// more (the page may be another one, or turned): the current page goes to the top instead, at the
    /// zoom and as far across the column as before.
    ///
    /// A finger on a selection handle lets go and the edit menu goes away, since both are about where
    /// the text was on screen; the handles themselves are put at the selection's new place.
    private func relayout(fitWidth: CGFloat, placing placement: Placement) {
        selectionInteraction.layoutWillChange()
        // Strokes drawn with Draw are added for the layout they were drawn on, before it goes; so is the
        // text typed in a form field.
        markupInteraction.layoutWillChange()
        formInteraction.layoutWillChange()
        let position = lastPosition
        // Read before the zoom changes, which moves the current page.
        let currentPage = model.currentPage
        let target = pendingTarget
        pendingTarget = nil
        let newLayout = PageLayout(pages: model.pages, fitWidth: fitWidth)
        laidOutPages = model.pages
        layout = nil
        scrollView.zoomScale = 1
        for view in pageViews.values { view.removeFromSuperview() }
        pageViews.removeAll()
        contentView.frame = CGRect(origin: .zero, size: newLayout.contentSize)
        scrollView.contentSize = newLayout.contentSize
        layout = newLayout

        if let target, (0..<newLayout.pageCount).contains(target) {
            show(newLayout.frame(of: target).minY)
        } else if case .currentPage(let zoom, let across) = placement {
            scrollView.zoomScale = min(max(zoom, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
            // The model keeps the current page on one the document has.
            show(CGPoint(x: across, y: newLayout.frame(of: currentPage).minY))
        } else if let position, (0..<newLayout.pageCount).contains(position.page) {
            scrollView.zoomScale = min(max(position.zoom, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
            show(position.topLeft(in: newLayout))
        } else {
            show(newLayout.frame(of: currentPage).minY)
        }

        if let reveal = pendingReveal {
            pendingReveal = nil
            self.reveal(reveal)
        }
    }

    /// Where a new layout puts the reader.
    private enum Placement {
        /// Where they were: the same page, as far down and across it, at the same zoom.
        case readingPosition
        /// At the top of the current page, at `zoom`, `across` layout points (zoom 1) from the column's
        /// left edge.
        case currentPage(zoom: CGFloat, across: CGFloat)
    }

    /// Scrolls so that layout point `y` (at zoom 1) is at the top of the visible area, as near as
    /// the ends of the document allow, at the left edge; then brings the page views and the current
    /// page up to date, even when the offset was already there.
    private func show(_ y: CGFloat) {
        show(CGPoint(x: 0, y: y))
    }

    /// Scrolls so that layout point `point` (at zoom 1) is at the top-left of the visible area, as near
    /// as the ends of the scroll range allow, at the zoom the view is at; then brings the page views and
    /// the current page up to date, even when the offset was already there. The insets need not be the
    /// same on both sides (the bars, the camera's side, a Split View divider): each end of the range
    /// keeps clear of its own.
    private func show(_ point: CGPoint) {
        let insets = scrollView.adjustedContentInset
        let zoom = scrollView.zoomScale
        let size = scrollView.bounds.size
        let lowest = CGPoint(x: -insets.left, y: -insets.top)
        let highest = CGPoint(x: max(lowest.x, scrollView.contentSize.width + insets.right - size.width),
                              y: max(lowest.y, scrollView.contentSize.height + insets.bottom - size.height))
        let offset = CGPoint(x: min(max(point.x * zoom - insets.left, lowest.x), highest.x),
                             y: min(max(point.y * zoom - insets.top, lowest.y), highest.y))
        scrollView.setContentOffset(offset, animated: false)
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
            applyOverlay(to: view)
            // Under Draw's canvas and what it shows: pages never overlap one another.
            contentView.insertSubview(view, at: 0)
            pageViews[page] = view
        }
        if let page = readerPage(in: layout), page != model.currentPage {
            model.currentPage = page
        }
        // The form's overlays follow the pages that have a view.
        formInteraction.pagesDidChange()
        if currentFitWidth() == layout.fitWidth {
            lastPosition = ReadingPosition(visibleArea: visibleArea(), zoom: scrollView.zoomScale, in: layout)
        }
        // The zoom and the layout move the selection on screen, and its handles with it; and the box a
        // text box is typed in, and a form field's editor.
        selectionInteraction.layoutHandles()
        markupInteraction.textBoxes.layoutTextEditor()
        formInteraction.layoutEditor()
        // With a text tool picked, whether a finger is on text is known before it goes down.
        markupInteraction.prefetchText(onPages: inView)
    }

    /// Asks for the text of the pages in view, for a tool that marks text: see `update()`.
    private func prefetchMarkupText() {
        guard let layout else { return }
        markupInteraction.prefetchText(onPages: layout.visiblePages(in: scrollView.convert(scrollView.bounds, to: contentView)))
    }

    private func applyHighlightsToPageViews() {
        for view in pageViews.values { applyOverlay(to: view) }
    }

    /// Gives `view` the boxes of its own page: the search hits, the selected text and the selected
    /// annotation.
    private func applyOverlay(to view: PageView) {
        view.overlay.selectedAnnotationRect = selectedAnnotation.flatMap { $0.page == view.page ? $0.rect : nil }
        view.overlay.highlights = highlightsByPage[view.page] ?? []
        if let active = activeHighlight, active.page == view.page {
            view.overlay.activeHighlights = active.rects
        } else {
            view.overlay.activeHighlights = []
        }
        if let selection, selection.page == view.page {
            view.overlay.selection = selection.rects
        } else {
            view.overlay.selection = []
        }
    }

    private static func isSame(_ a: (page: Int, rects: [CGRect])?, _ b: (page: Int, rects: [CGRect])?) -> Bool {
        a?.page == b?.page && a?.rects == b?.rects
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
