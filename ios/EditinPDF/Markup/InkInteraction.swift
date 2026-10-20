import PencilKit
import UIKit

/// **Draw** (the ink tool): what one finger, or the Apple Pencil, does on the pages while it is picked.
/// It belongs to the scroll view's `MarkupInteraction`, which routes the tools and hands it the first
/// finger, the tool's changes and the layout's. It draws with PencilKit, on a canvas
/// (`InkCaptureView`) over one page:
/// - The canvas covers the page the first touch lands on. The content view asks, before it finds the
///   view under a first finger (`PageContentView.touchWillLand`), and the canvas is put over that page
///   if Draw is picked and may be used there (`prepareToDraw`); the finger then lands on the canvas.
///   A second finger, while the first is down, never moves it, nor does anything while a stroke is
///   being drawn. Off the pages (the gap between two), and on a page where Draw is refused, nothing is
///   drawn.
/// - The canvas's drawing policy is `.anyInput`: the Apple Pencil draws, and so does one finger.
/// - Two fingers scroll and zoom: while Draw is picked the scroll view's pan needs two
///   (`toolDidChange`), and its pinch is two anyway; the canvas does not scroll or zoom itself. It
///   lies in the content view, so it scrolls and zooms with its page, strokes and all.
/// - The strokes wait on the canvas, off the document and its undo manager, and are added as one
///   drawing (`commitPendingInk`, the model's `addInk`) when the tool changes, when the reader taps
///   Done, when a touch starts on another page, before any other change and before Undo or Redo
///   (the model's), when the scene leaves the screen, when the pages are laid out again, when the
///   screen goes, and when a finger goes down anywhere outside the pages
///   (`MarkupInteraction.fingerWentDown`: the toolbar, the palette, the back button). That last one is
///   what keeps them when the document is closed: the scene closes the file as soon as the back button
///   is tapped, before the screen hears it is going, and saves it only if a change has been registered
///   by then. Each is worked out against the revision it was drawn on: one drawn while a turn of its
///   page was on its way is refused as stale, and leaves nothing on the screen.
@MainActor
final class InkInteraction: NSObject {
    private weak var host: PageScrollViewController?
    private let model: DocumentModel

    /// The canvas Draw draws on: made when Draw is first picked, and in the content view, over its
    /// page, while Draw is picked.
    private(set) var ink: InkCaptureView?
    /// Pictures of strokes on their way into the document, over their page, each until the page has
    /// been drawn again with them (or at once when they are refused).
    private(set) var inkPreviews: [UIView] = []

    init(host: PageScrollViewController, model: DocumentModel) {
        self.host = host
        self.model = model
        super.init()
    }

    /// Whether one finger on `page` draws: Draw is picked, the document's permissions are read, and
    /// they let it be used there.
    func drawsOn(page: Int) -> Bool {
        model.tool == .ink && model.capabilities != nil && model.refusal(of: .ink, onPage: page) == nil
    }

    /// A first finger is going down at `point` (the content view's coordinates): if it draws there
    /// (`drawsOn`), the canvas is put over the page under it, once the strokes waiting on another page,
    /// or drawn in another style, have been added. Says whether the canvas is there for the finger.
    /// While a stroke is being drawn the canvas stays where it is.
    @discardableResult
    func prepareToDraw(atContentPoint point: CGPoint) -> Bool {
        guard let host, let location = host.pageLocation(of: point), drawsOn(page: location.page) else { return false }
        let style = model.toolStyles[.ink]
        if let ink, ink.superview === host.contentView {
            if ink.isDrawing { return ink.page == location.page }
            if ink.page == location.page, ink.style == style { return true }
        }
        commitPendingInk()
        return placeCanvas(onPage: location.page, style: style)
    }

    /// Puts the canvas, empty, over `page`, drawing in `style`. False without a layout for the page.
    private func placeCanvas(onPage page: Int, style: ToolStyle) -> Bool {
        guard let host, let place = host.layoutPlace(ofPage: page) else { return false }
        let canvas = ink ?? makeCanvas(page: page)
        canvas.page = page
        canvas.frame = place.frame
        canvas.canvasOrigin = .zero
        canvas.pointsPerCanvasPoint = 1 / place.scale
        canvas.style = style
        // As wide on screen as the line will be on the page: a canvas point is a layout point.
        canvas.tool = PKInkingTool(.monoline, color: UIColor(red: style.color.r, green: style.color.g, blue: style.color.b, alpha: 1),
                                   width: InkCaptureView.toolWidth(drawingLinesOf: InkGeometry.lineWidth(style.width) * place.scale))
        if !canvas.drawing.strokes.isEmpty { canvas.drawing = PKDrawing() }
        canvas.forgetStrokeHistory()
        if canvas.superview === host.contentView {
            host.contentView.bringSubviewToFront(canvas)
        } else {
            host.contentView.addSubview(canvas)
        }
        // Laid out at once: the finger it is put there for lands on it in this same hit test. (Made and
        // put there during the hit test without this, it drew nothing for that first finger on the
        // iOS 26.5 simulator; the next stroke drew.)
        canvas.layoutIfNeeded()
        return true
    }

    private func makeCanvas(page: Int) -> InkCaptureView {
        let canvas = InkCaptureView(page: page)
        canvas.delegate = self
        ink = canvas
        return canvas
    }

    /// Adds the strokes on the canvas, if any, to the document as one drawing, handed over before this
    /// returns: in page points (`InkGeometry.strokes`, sampled about every point on screen and kept
    /// within half a point on screen, half a page point at most), in the style they were drawn in,
    /// worked out against the revision they were drawn on. The canvas is cleared for the next strokes,
    /// and a picture of these stays over the page meanwhile: once they are made, until the page has
    /// been drawn again with them; when they are refused (stale, say), it goes at once, and nothing is
    /// left that looks drawn. The task says whether they were made; nil with none waiting.
    @discardableResult
    func commitPendingInk() -> Task<Bool, Never>? {
        guard let ink, !ink.drawing.strokes.isEmpty, let host else { return nil }
        let drawing = ink.drawing
        // A canvas point is a layout point: one on screen is 1 / zoom of it. Half a point on screen is
        // half a page point over the screen scale.
        let zoom = max(host.scrollView.zoomScale, 1)
        let screenScale = host.screenScale(ofPage: ink.page)
        let halfAScreenPoint = screenScale > 0 && screenScale.isFinite ? 0.5 / screenScale : 0.5
        let strokes = InkGeometry.strokes(of: drawing, canvasOrigin: ink.canvasOrigin, pointsPerCanvasPoint: ink.pointsPerCanvasPoint,
                                          spacing: 1 / zoom, tolerance: min(0.5, halfAScreenPoint))
        let revision = ink.drawnAt ?? model.revision
        let preview = showPreview(of: drawing, on: ink)
        // The canvas is emptied before the change is handed over: handing it over adds whatever strokes
        // are waiting first (`DocumentModel.enqueue`), which must then be none, or these would be added twice.
        ink.drawing = PKDrawing()
        ink.drawnAt = nil
        ink.forgetStrokeHistory()
        model.pendingInkDidChange(false)
        let made = model.enqueueInk(page: ink.page, strokes: strokes, drawnAt: revision, style: ink.style)
        return MarkupInteraction.settlePreview(of: made) { [weak self] in self?.removePreview(preview) }
    }

    /// A picture of `drawing` where it is on `canvas`, over the page, in the content view: what was
    /// drawn, while it is on its way into the page. Drawn at the zoom the view is at, up to some 8
    /// million pixels.
    private func showPreview(of drawing: PKDrawing, on canvas: InkCaptureView) -> UIView? {
        guard let host else { return nil }
        let area = drawing.bounds.intersection(canvas.bounds)
        guard !area.isNull, area.width > 0, area.height > 0 else { return nil }
        let wanted = max(canvas.traitCollection.displayScale, 1) * max(host.scrollView.zoomScale, 1)
        let scale = min(wanted, (8_000_000 / (area.width * area.height)).squareRoot())
        var image = UIImage()
        // In light colours, as on the canvas: PencilKit draws the current appearance's.
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: area, scale: scale)
        }
        let view = UIImageView(image: image)
        view.frame = canvas.convert(area, to: host.contentView)
        view.isUserInteractionEnabled = false
        host.contentView.insertSubview(view, belowSubview: canvas)
        inkPreviews.append(view)
        return view
    }

    private func removePreview(_ preview: UIView?) {
        guard let preview else { return }
        preview.removeFromSuperview()
        inkPreviews.removeAll { $0 === preview }
    }

    /// The tool changed: with Draw picked two fingers scroll (one draws), and the canvas is put over the
    /// page being read; with any other, or none, one finger scrolls again, and the canvas goes, once its
    /// strokes have been added (the model has added them as the tool changed).
    func toolDidChange() {
        guard let host else { return }
        let drawing = model.tool == .ink
        host.scrollView.panGestureRecognizer.minimumNumberOfTouches = drawing ? 2 : 1
        guard !drawing else {
            // Over the page being read from the start, ready for the first finger.
            if ink?.superview !== host.contentView, drawsOn(page: model.currentPage) {
                _ = placeCanvas(onPage: model.currentPage, style: model.toolStyles[.ink])
            }
            return
        }
        commitPendingInk()
        ink?.removeFromSuperview()
    }

    /// The pages are about to be laid out again: the strokes waiting are added, worked out for the
    /// layout they were drawn on, and the canvas and the pictures go with that layout.
    func layoutWillChange() {
        commitPendingInk()
        ink?.removeFromSuperview()
        for preview in inkPreviews { preview.removeFromSuperview() }
        inkPreviews.removeAll()
    }
}

// MARK: - PKCanvasViewDelegate

extension InkInteraction: PKCanvasViewDelegate {
    /// Strokes came or went: the model hears whether some are waiting (the palette's Done), and the
    /// first of them records the revision they are drawn on.
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? InkCaptureView, canvas === ink else { return }
        if canvas.drawing.strokes.isEmpty {
            canvas.drawnAt = nil
        } else if canvas.drawnAt == nil {
            canvas.drawnAt = model.revision
        }
        model.pendingInkDidChange(!canvas.drawing.strokes.isEmpty)
    }

    /// A stroke begins: the canvas stays where it is until it ends. The first stroke on an empty
    /// canvas is drawn on the document as it is now.
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? InkCaptureView, canvas === ink else { return }
        canvas.isDrawing = true
        if canvas.drawing.strokes.isEmpty, canvas.drawnAt == nil { canvas.drawnAt = model.revision }
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? InkCaptureView, canvas === ink else { return }
        canvas.isDrawing = false
    }
}
