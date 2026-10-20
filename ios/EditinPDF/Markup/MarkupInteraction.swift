import EditinPDFCore
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
