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
/// - One finger that goes down on a page while Highlight, Underline or Strikethrough is picked, and may
///   be used there (`takesTouch(atContentPoint:)`), drags out text to mark: the scroll view's pan waits
///   for this one to fail, so that drag never scrolls. Anywhere else (the gap between pages, or another
///   tool, or none, or a tool that is refused) this pan takes no touch, and the scroll view has it at
///   once.
/// - Two fingers always scroll and zoom: a second finger before the drag has begun fails it
///   (`MarkupPanGestureRecognizer`), and the scroll view's pan and pinch take over. A second finger
///   after it has begun is ignored: the drag goes on with the first.
/// - The selection's long press is off while any tool that annotates is picked
///   (`SelectionInteraction.isLongPressAllowed`): the tool has the finger. With Select, or in reading
///   mode, it selects as before, and its menu offers the marks.
///
/// A drag selects from the word under where the finger went down to where it is, on the page it went
/// down on (a point past that page's edge is the text nearest it), and marks it when the finger comes
/// up. A drag that begins where there is no word selects, and marks, nothing.
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
    /// a text markup tool is picked and may be used, and the point is on a page.
    func takesTouch(atContentPoint point: CGPoint) -> Bool {
        guard let location = host?.pageLocation(of: point) else { return false }
        return textTool(onPage: location.page) != nil
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
    /// place of any selection. Nothing happens off the pages, or without a text tool that may be used.
    func begin(atContentPoint point: CGPoint) {
        guard let host, let controller = model.selection, let location = host.pageLocation(of: point),
              let found = textTool(onPage: location.page) else { return }
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
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === pan, let host else { return false }
        // A pan that takes no touch is not waited for: the scroll view scrolls at once.
        return takesTouch(atContentPoint: touch.location(in: host.contentView))
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, let host else { return false }
        let moved = pan.translation(in: host.contentView)
        let location = pan.location(in: host.contentView)
        return takesTouch(atContentPoint: CGPoint(x: location.x - moved.x, y: location.y - moved.y))
    }
}

/// A one-finger pan that fails when a second finger goes down before it has begun, so that two fingers
/// scroll and zoom however quickly the second follows the first. Once it has begun, more fingers are
/// ignored.
final class MarkupPanGestureRecognizer: UIPanGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, (event.touches(for: self)?.count ?? touches.count) > 1 {
            state = .failed
            return
        }
        super.touchesBegan(touches, with: event)
    }
}
