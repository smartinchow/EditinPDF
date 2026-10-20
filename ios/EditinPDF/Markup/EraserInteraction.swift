import UIKit

/// **Eraser**: deletes whole annotations, those it touches. It belongs to the scroll view's
/// `MarkupInteraction`, which routes its one-finger pan and its tap here and hands it the tool's
/// changes and the layout's.
///
/// One finger on a page where the eraser may be used (the document allows markup) erases: the points
/// it passes over, on the page it went down on, are collected (`begin`, `move`), and when it comes up
/// everything the path touched, within `MarkupInteraction.screenHitSlop` points on screen, is deleted
/// at once (`DocumentModel.enqueueErase`: the one on top at each point, highest index first, one
/// change that one undo takes back). A tap deletes the annotation under it. In the gap between pages
/// one finger scrolls; two fingers always scroll and zoom (the pan fails on a second finger).
@MainActor
final class EraserInteraction {
    private weak var host: PageScrollViewController?
    private let model: DocumentModel

    /// A stroke of the eraser: its page, and the points it passed over there (view space; past the
    /// page's edge too).
    private struct Stroke {
        let page: Int
        var points: [CGPoint]
    }
    private var stroke: Stroke?

    init(host: PageScrollViewController, model: DocumentModel) {
        self.host = host
        self.model = model
    }

    /// Whether a stroke is going on.
    var isErasing: Bool { stroke != nil }

    /// Whether the eraser is picked and may be used on `page`: once the document's permissions are
    /// read, when they allow markup.
    private func usable(onPage page: Int) -> Bool {
        model.tool == .eraser && model.capabilities != nil && model.refusal(of: .eraser, onPage: page) == nil
    }

    /// Whether one finger going down at `point` (the content view's coordinates) erases: on a page
    /// where the eraser may be used. Elsewhere the finger scrolls.
    func takesTouch(atContentPoint point: CGPoint) -> Bool {
        guard let location = host?.pageLocation(of: point) else { return false }
        return usable(onPage: location.page)
    }

    /// Whether a tap at `point` is the eraser's: as for a finger going down (`takesTouch`).
    func takesTap(atContentPoint point: CGPoint) -> Bool {
        takesTouch(atContentPoint: point)
    }

    /// The finger went down at `point`: a stroke starts there, when the eraser may be used on the page
    /// under it. Says whether it does.
    @discardableResult
    func begin(atContentPoint point: CGPoint) -> Bool {
        guard let location = host?.pageLocation(of: point), usable(onPage: location.page) else { return false }
        stroke = Stroke(page: location.page, points: [location.point])
        return true
    }

    /// The finger is at `point`: the stroke goes on there, on the page it began on.
    func move(toContentPoint point: CGPoint) {
        guard var going = stroke, let at = host?.pagePoint(ofContentPoint: point, onPage: going.page) else { return }
        if at != going.points.last { going.points.append(at) }
        stroke = going
    }

    /// The finger came up at `point`: what the stroke touched is deleted, if the eraser is still picked
    /// and may still be used there. The task says whether anything was deleted; nil when no stroke was
    /// going on, or it was dropped.
    @discardableResult
    func end(atContentPoint point: CGPoint) -> Task<Bool, Never>? {
        move(toContentPoint: point)
        guard let done = stroke else { return nil }
        stroke = nil
        guard usable(onPage: done.page) else { return nil }
        return model.enqueueErase(page: done.page, along: done.points, slop: slop(onPage: done.page))
    }

    /// The stroke was cancelled (another tool, a new layout, the system taking the touch): nothing is
    /// deleted.
    func cancel() {
        stroke = nil
    }

    /// A tap at `point` with the eraser: the annotation under it is deleted. The task says whether it
    /// was; nil when the tap is not the eraser's.
    @discardableResult
    func tap(atContentPoint point: CGPoint) -> Task<Bool, Never>? {
        guard let location = host?.pageLocation(of: point), usable(onPage: location.page) else { return nil }
        return model.enqueueErase(page: location.page, along: [location.point], slop: slop(onPage: location.page))
    }

    /// How far outside an annotation's box the eraser on `page` still touches it: the same on screen at
    /// every zoom.
    private func slop(onPage page: Int) -> CGFloat {
        MarkupInteraction.hitSlop(screenScale: host?.screenScale(ofPage: page) ?? 0)
    }
}
