import CoreGraphics
import EditinPDFCore

/// The document's annotations by page, as the engine listed them at one revision, and which of
/// them a touch lands on. Rebuilt by the model after every change, undo and redo: an annotation's
/// index can name another one afterwards.
struct AnnotationIndex: Sendable {
    /// The annotations of each page (counting from 0), in the engine's order (the page's `/Annots`).
    let byPage: [Int: [AnnotationInfo]]

    init(_ all: [AnnotationInfo]) {
        byPage = Dictionary(grouping: all) { Int($0.page) }
    }

    /// The annotations on `page`, in the engine's order; none for a page without any.
    func annotations(onPage page: Int) -> [AnnotationInfo] {
        byPage[page] ?? []
    }

    /// The annotation under `point` (view space, in points) on `page`: of those whose box, grown by
    /// `slop` on every side (a finger is not a pointer), holds the point, the one drawn last, which
    /// is on top: the highest index. Only those `matching` count (a note under a shape, say). Nil when
    /// the touch lands on none.
    func hit(page: Int, at point: CGPoint, slop: CGFloat = 8, matching: (AnnotationInfo) -> Bool = { _ in true }) -> AnnotationInfo? {
        annotations(onPage: page)
            .filter { matching($0) && $0.box.insetBy(dx: -slop, dy: -slop).contains(point) }
            .max { $0.index < $1.index }
    }

    /// The annotation `ref` names at this revision; nil when its page has none at that index.
    func annotation(_ ref: AnnotationRef) -> AnnotationInfo? {
        annotations(onPage: ref.page).first { $0.index == ref.index }
    }

    /// What an eraser dragged along `points` (view space, in points, on `page`) deletes: at every point
    /// along the path, the annotation on top there (`hit`) that the file does not lock (a locked one
    /// on top is passed over, for the one under it), each once, highest index first, the order their
    /// deletes must go in, since deleting one moves those after it down. The path is followed from
    /// point to point at most `slop` apart (half a point at least), so a box it crosses between two
    /// points is not missed; a single point is a tap.
    func erased(page: Int, along points: [CGPoint], slop: CGFloat) -> [AnnotationInfo] {
        let all = annotations(onPage: page)
        guard !all.isEmpty, let first = points.first else { return [] }
        let slop = slop.isFinite ? max(slop, 0) : 0
        let length = zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        // Some 20,000 looks along the path at most, however long and wiggly it is.
        let step = max(slop, 0.5, length.isFinite ? length / 20_000 : 0.5)
        var found: [UInt32: AnnotationInfo] = [:]
        func look(at point: CGPoint) {
            guard point.x.isFinite, point.y.isFinite,
                  let top = hit(page: page, at: point, slop: slop, matching: { !$0.locked }) else { return }
            found[top.index] = top
        }
        look(at: first)
        for (from, to) in zip(points, points.dropFirst()) {
            let distance = hypot(to.x - from.x, to.y - from.y)
            guard distance.isFinite else { continue }
            let count = Int((distance / step).rounded(.up))
            for i in stride(from: 1, through: max(count, 1), by: 1) {
                let t = CGFloat(i) / CGFloat(max(count, 1))
                look(at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            }
        }
        return found.values.sorted { $0.index > $1.index }
    }
}


extension AnnotationInfo {
    /// Where the annotation is on its page, in view space (points, origin top-left, y down).
    var box: CGRect { CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height) }
}
