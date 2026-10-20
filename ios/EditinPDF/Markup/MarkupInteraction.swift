import EditinPDFCore
import PencilKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// What a finger on the pages does in Markup mode, for the tools that act on the page by touch. The
/// first of them: Highlight, Underline and Strikethrough, which mark the text a finger drags across.
///
/// It belongs to a `PageScrollViewController`, like `SelectionInteraction`, and asks it where a touch
/// is on a page (`pageLocation(of:)`, `pagePoint(ofContentPoint:onPage:)`), so a touch becomes a point
/// in view space (PDF points of the page, origin top-left, y down, its rotation applied) exactly as the
/// selection's do: the content view's coordinates, which the zoom scales, through the layout's scale of
/// the page. The selecting is the model's `SelectionController`'s, and the marking `markSelection`'s.
///
/// **Which gesture has the finger** (the scroll view's pan and pinch, the selection's long press, this):
/// - One finger that goes down on text (within `screenHitSlop` points on screen of a glyph) while
///   Highlight, Underline or Strikethrough is picked, and may be used on that page
///   (`takesTouch(atContentPoint:)`), drags out text to mark: the scroll view's pan waits for this one to
///   fail, so that drag never scrolls. Anywhere else (the white of a page, the gap between pages, or
///   another tool, or none, or a tool that is refused) this pan takes no touch, or fails as it would
///   begin, and the scroll view scrolls: one finger scrolls a page from anywhere but its text.
/// - Whether a point is on text is decided at once, on the main actor, from the page's glyph boxes
///   (`isNearText`), which are read off the main actor (`PageTextBoxes`, which throttles the reading)
///   for the pages in view while a text tool is picked, and for a page a finger goes down on. Until
///   they have been read, a touch on the page is taken as on text, as if the page were all text: it
///   marks if it began on a word, and does not scroll.
/// - Two fingers always scroll and zoom: a second finger before the drag has begun fails it, wherever
///   it went down (`MarkupPanGestureRecognizer` counts every finger on the screen, and the pan takes
///   any touch while it has a finger already, so that it hears of it at once), and the scroll view's pan and
///   pinch take over. A second finger after it has begun is ignored: the drag goes on with the first.
/// - The selection's long press is off while any tool that annotates is picked
///   (`SelectionInteraction.isLongPressAllowed`): the tool has the finger. With Select, or in reading
///   mode, it selects as before, and its menu offers the marks.
///
/// A drag selects from the word under where the finger went down to where it is, on the page it went
/// down on (a point past that page's edge is the text nearest it), and marks it when the finger comes
/// up.
///
/// **Draw** (the ink tool) draws with PencilKit, on a canvas (`InkCaptureView`) over one page:
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
///   screen goes, and when a finger goes down anywhere outside the pages (`fingerWentDown`: the
///   toolbar, the palette, the back button). That last one is what keeps them when the document is
///   closed: the scene closes the file as soon as the back button is tapped, before the screen hears it
///   is going, and saves it only if a change has been registered by then. Each is worked out against
///   the revision it was drawn on: one drawn while a turn of its page was on its way is refused as
///   stale, and leaves nothing on the screen.
@MainActor
final class MarkupInteraction: NSObject {
    /// How far outside an annotation's box, in points on screen, a touch still lands on it: a finger is
    /// not a pointer.
    nonisolated static let screenHitSlop: CGFloat = 8

    let pan = MarkupPanGestureRecognizer()

    private weak var host: PageScrollViewController?
    private let model: DocumentModel
    /// The drag going on; nil between drags.
    private var stroke: Stroke?
    /// Counts drags, so that a drag's end that is still waiting for its selection does not finish the
    /// next one.
    private var strokeCount = 0

    /// The canvas Draw draws on: made when Draw is first picked, and in the content view, over its
    /// page, while Draw is picked.
    private(set) var ink: InkCaptureView?
    /// Pictures of strokes on their way into the document, over their page, each until the page has
    /// been drawn again with them (or at once when they are refused).
    private(set) var inkPreviews: [UIView] = []
    /// Hears of every finger going down in the screen's window, without taking it: see
    /// `fingerWentDown`. The scroll view's controller puts it on its window while it is on screen.
    let fingersDown = FingerDownObserver()
    /// How long a picture of strokes added stays: the page's cover while it is drawn again, and a
    /// little more for its tiles to come in.
    static let inkPreviewDuration: Duration = PageView.redrawCoverDuration + .milliseconds(250)

    /// The glyph boxes of the pages, read off the main actor: what `isNearText` looks at. A test may
    /// put another in its place, whose reader it sees.
    lazy var text: PageTextBoxes = {
        let document = model.document()
        return PageTextBoxes(revision: { [weak model] in model?.revision ?? 0 }) { page, revision in
            document.flatMap { PageTextBoxes.glyphBoxes(of: $0, page: page, at: revision) }
        }
    }()

    /// A drag of a text markup tool.
    private struct Stroke {
        let id: Int
        let tool: Tool
        let kind: MarkupKind
        let page: Int
    }

    init(host: PageScrollViewController, model: DocumentModel) {
        self.host = host
        self.model = model
        super.init()
    }

    /// Puts the pan on the content view, where touches on the pages land, and has the scroll view's pan
    /// wait for it to fail.
    func install() {
        guard let host else { return }
        pan.maximumNumberOfTouches = 1
        pan.addTarget(self, action: #selector(panned(_:)))
        pan.delegate = self
        host.contentView.addGestureRecognizer(pan)
        host.scrollView.panGestureRecognizer.require(toFail: pan)
        host.contentView.touchWillLand = { [weak self] point in self?.prepareToDraw(atContentPoint: point) }
        fingersDown.fingerWentDown = { [weak self] view in self?.fingerWentDown(on: view) }
        model.inkHolder = self
        toolDidChange()
    }

    /// Whether a drag is going on, from the finger going down until its mark is made or refused.
    var isMarking: Bool { stroke != nil }

    /// The tool picked, when it marks text and may be used on `page`. The tool may stay picked when the
    /// reader goes on to a page, or the document to a state, where it is refused: it is checked again
    /// for every touch.
    private func textTool(onPage page: Int) -> (tool: Tool, kind: MarkupKind)? {
        guard let tool = model.tool, let kind = tool.markupKind,
              model.capabilities != nil, model.refusal(of: tool, onPage: page) == nil else { return nil }
        return (tool, kind)
    }

    /// Whether a finger going down at `point` (the content view's coordinates) drags out text to mark:
    /// a text markup tool is picked and may be used, the point is on a page, and on its text (or the
    /// page's text is not read yet: see `isNearText`). Otherwise the finger scrolls.
    func takesTouch(atContentPoint point: CGPoint) -> Bool {
        guard let location = host?.pageLocation(of: point), textTool(onPage: location.page) != nil else { return false }
        return isNearText(location.point, onPage: location.page) != false
    }

    // MARK: The pages' text

    /// Whether `point` (view space, PDF points of `page`) is within `screenHitSlop` points on screen of
    /// one of the page's glyphs. Nil while the page's glyph boxes are not read yet: they are asked for
    /// before any other page's, and the next touch knows.
    func isNearText(_ point: CGPoint, onPage page: Int) -> Bool? {
        guard let boxes = text.boxes(onPage: page) else {
            text.request(page)
            return nil
        }
        let slop = hitSlop(onPage: page)
        return boxes.contains { $0.insetBy(dx: -slop, dy: -slop).contains(point) }
    }

    /// Asks for the glyph boxes of the pages in view (`pages`) ahead of a touch: those a text tool may
    /// be used on, nearest the middle of the view first, at most `PageTextBoxes.pagesKept`; in place of
    /// those asked for before, so a page scrolled past is not read. With no text tool picked, nothing
    /// is asked for, and what was asked for and not started is not read. The scroll view calls it as it
    /// scrolls, when the document changes and when the tool does.
    func prefetchText(onPages pages: Range<Int>) {
        guard model.tool?.markupKind != nil else {
            text.want([])
            return
        }
        let middle = Double(pages.lowerBound + pages.upperBound - 1) / 2
        let nearestFirst = pages.sorted { (abs(Double($0) - middle), $0) < (abs(Double($1) - middle), $1) }
        text.want(nearestFirst.filter { textTool(onPage: $0) != nil })
    }

    /// Reads the glyph boxes of `page` before any other's, and returns once nothing more is being read.
    /// For tests.
    func loadText(onPage page: Int) async {
        text.request(page)
        await text.settle()
    }

    // MARK: The drag

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard let host else { return }
        let location = recognizer.location(in: host.contentView)
        switch recognizer.state {
        case .began:
            // The pan begins once the finger has moved a little: the drag starts where it went down.
            let moved = recognizer.translation(in: host.contentView)
            begin(atContentPoint: CGPoint(x: location.x - moved.x, y: location.y - moved.y))
            move(toContentPoint: location)
        case .changed:
            move(toContentPoint: location)
        case .ended:
            Task { await self.end(atContentPoint: location) }
        case .cancelled, .failed:
            cancel()
        default:
            break
        }
    }

    /// The finger went down at `point` (the content view's coordinates): the word there is selected, in
    /// place of any selection. Nothing happens off the pages, off their text (`takesTouch`), or without a
    /// text tool that may be used.
    func begin(atContentPoint point: CGPoint) {
        guard let host, let controller = model.selection, takesTouch(atContentPoint: point),
              let location = host.pageLocation(of: point), let found = textTool(onPage: location.page) else { return }
        strokeCount += 1
        stroke = Stroke(id: strokeCount, tool: found.tool, kind: found.kind, page: location.page)
        controller.clear()
        controller.beginWord(page: location.page, at: location.point)
    }

    /// The finger is at `point`: the selection runs from the first word to there, on the drag's page.
    /// Until the first word is found the selection cannot be extended; the end does it again.
    func move(toContentPoint point: CGPoint) {
        guard let stroke, let page = host?.pagePoint(ofContentPoint: point, onPage: stroke.page) else { return }
        model.selection?.extend(to: page)
    }

    /// The finger came up at `point`: once the selection has caught up with it, the text is marked, if
    /// the tool that began the drag is still picked and may still be used. Says whether a mark was made.
    /// A drag whose mark is not made leaves no selection behind.
    @discardableResult
    func end(atContentPoint point: CGPoint) async -> Bool {
        guard let stroke, let controller = model.selection else { return false }
        defer { if self.stroke?.id == stroke.id { self.stroke = nil } }
        await controller.waitUntilSettled()
        if let page = host?.pagePoint(ofContentPoint: point, onPage: stroke.page) {
            controller.extend(to: page)
            await controller.waitUntilSettled()
        }
        // Another drag may have begun meanwhile: that one owns the selection now.
        guard self.stroke?.id == stroke.id else { return false }
        guard model.tool == stroke.tool, textTool(onPage: stroke.page) != nil,
              let selected = controller.selection, Int(selected.page) == stroke.page else {
            controller.clear()
            return false
        }
        return await model.markSelection(stroke.kind)
    }

    /// The drag was cancelled (a call coming in, the system taking the touch): nothing is marked, and
    /// the selection made on the way goes.
    func cancel() {
        guard stroke != nil else { return }
        stroke = nil
        model.selection?.clear()
    }

    // MARK: Drawing

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

    /// A finger went down on `view`: anywhere but the pages (the toolbar, the palette, the back button,
    /// a bar over the pages), the strokes waiting are added. Going back to the documents closes the
    /// file at once, saving it only if it has a change by then; the finger going down on the back
    /// button is the last moment the strokes can become one.
    func fingerWentDown(on view: UIView?) {
        guard let host, model.hasPendingInk else { return }
        if let view, view.isDescendant(of: host.scrollView) { return }
        model.commitPendingInk()
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
        return Task { [weak self] in
            let ok = await made.value
            if ok {
                Task { [weak self] in
                    try? await Task.sleep(for: Self.inkPreviewDuration)
                    self?.removePreview(preview)
                }
            } else {
                self?.removePreview(preview)
            }
            return ok
        }
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

    /// The tool changed (`PageScrollViewController.markupTool`): with Draw picked two fingers scroll
    /// (one draws), and the canvas is put over the page being read; with any other, or none, one
    /// finger scrolls again, and the canvas goes, once its strokes have been added (the model has
    /// added them as the tool changed).
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

    /// The pages are about to be laid out again (a new width, a change to their number, size or
    /// rotation): the strokes waiting are added, worked out for the layout they were drawn on, and the
    /// canvas and the pictures go with that layout.
    func layoutWillChange() {
        commitPendingInk()
        ink?.removeFromSuperview()
        for preview in inkPreviews { preview.removeFromSuperview() }
        inkPreviews.removeAll()
    }

    // MARK: Hitting annotations

    /// How far outside an annotation's box, in view space (PDF points of `page`), a touch still lands on
    /// it: `screenHitSlop` points on screen at the zoom the view is at, so it is the same under the
    /// finger zoomed in or out (`hitSlop(screenScale:)`).
    func hitSlop(onPage page: Int) -> CGFloat {
        Self.hitSlop(screenScale: host?.screenScale(ofPage: page) ?? 0)
    }

    /// `screenHitSlop` in PDF points, when a PDF point is `screenScale` points on screen (the layout's
    /// scale of the page times the zoom); the index's own 8 when there is no scale (no layout).
    nonisolated static func hitSlop(screenScale: CGFloat) -> CGFloat {
        screenScale > 0 && screenScale.isFinite ? screenHitSlop / screenScale : screenHitSlop
    }

    /// The annotation under `point` (the content view's coordinates), the one on top, with the slop
    /// on screen kept the same at every zoom; nil off the pages or on none.
    func annotation(atContentPoint point: CGPoint) -> AnnotationInfo? {
        guard let location = host?.pageLocation(of: point) else { return nil }
        return model.annotationIndex.hit(page: location.page, at: location.point, slop: hitSlop(onPage: location.page))
    }
}

// MARK: - UIGestureRecognizerDelegate

extension MarkupInteraction: UIGestureRecognizerDelegate {
    /// Whether the pan already has a finger: the touch being offered is a second one. (A first finger
    /// the pan did not take, on the white of the page, is counted by the pan itself, which sees every
    /// finger on the screen: `MarkupPanGestureRecognizer`. The scroll view's recognizers are not asked
    /// here: whether they count the touch being offered already is not said.)
    private var isAnotherFingerDown: Bool {
        pan.numberOfTouches > 0
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === pan, let host else { return false }
        // With another finger down, the pan takes the touch, wherever it is, to hear of the second finger
        // and fail (`MarkupPanGestureRecognizer`): two fingers scroll and zoom.
        if isAnotherFingerDown { return true }
        // A pan that takes no touch is not waited for: the scroll view scrolls at once.
        return takesTouch(atContentPoint: touch.location(in: host.contentView))
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, let host else { return false }
        // Asked again where the finger went down: the page's text may have been read since it did. A pan
        // that does not begin fails, and the scroll view's pan, which has been waiting, scrolls.
        let moved = pan.translation(in: host.contentView)
        let location = pan.location(in: host.contentView)
        return takesTouch(atContentPoint: CGPoint(x: location.x - moved.x, y: location.y - moved.y))
    }
}

/// A one-finger pan that fails when a second finger goes down before it has begun, so that two fingers
/// scroll and zoom however quickly the second follows the first. Every finger on the screen counts
/// (`event.allTouches`), not only those this pan was given: a second finger that went down where the
/// pan takes no touch (the white of the page, outside the pages) fails it too, at the latest when the
/// first finger moves. Once it has begun, more fingers are ignored.
final class MarkupPanGestureRecognizer: UIPanGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if failsOnSecondFinger(event) { return }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if failsOnSecondFinger(event) { return }
        super.touchesMoved(touches, with: event)
    }

    /// Fails the pan, and says so, when it has not begun and more than one finger is down.
    private func failsOnSecondFinger(_ event: UIEvent) -> Bool {
        guard state == .possible, Self.isMoreThanOneFinger((event.allTouches ?? []).map(\.phase)) else { return false }
        state = .failed
        return true
    }

    /// Whether touches in these `phases` are more than one finger down: those that have ended or been
    /// cancelled are not down.
    nonisolated static func isMoreThanOneFinger(_ phases: [UITouch.Phase]) -> Bool {
        phases.filter { $0 != .ended && $0 != .cancelled }.count > 1
    }
}

// MARK: - PKCanvasViewDelegate

extension MarkupInteraction: PKCanvasViewDelegate {
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

extension MarkupInteraction: PendingInkHolder {}

/// A gesture recognizer that only listens: it hears of each finger going down where it is attached
/// (the window), says on which view (`fingerWentDown`), and fails at once, so it never takes a touch,
/// delays one, or keeps another recognizer from recognizing.
final class FingerDownObserver: UIGestureRecognizer {
    /// Told the view each finger that goes down landed on.
    var fingerWentDown: ((UIView?) -> Void)?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { fingerWentDown?(touch.view) }
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
