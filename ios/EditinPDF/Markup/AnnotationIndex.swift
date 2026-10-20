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
        var top: AnnotationInfo?
        for info in annotations(onPage: page) where info.index >= (top?.index ?? 0) && matching(info)
            && info.box.insetBy(dx: -slop, dy: -slop).contains(point) {
            top = info
        }
        return top
    }

    /// The annotation `ref` names at this revision; nil when its page has none at that index.
    func annotation(_ ref: AnnotationRef) -> AnnotationInfo? {
        annotations(onPage: ref.page).first { $0.index == ref.index }
    }

    /// About the most places `erased` looks at along a path, however long it is: the spacing grows
    /// with the path's length past it. (Each piece of the path between two of its points is looked at
    /// once at least, so a path of more points than this is looked at once for each point.)
    static let maxEraserLooks: CGFloat = 20_000

    /// What an eraser dragged along `points` (view space, in points, on `page`) deletes: at every point
    /// along the path, the annotation on top there (`hit`) that the file does not lock (a locked one
    /// on top is passed over, for the one under it), each once, in index order. The path is followed
    /// from point to point at most `slop` apart (half a point at least, more for a path so long that
    /// that would be more than `maxEraserLooks` looks), so a box it crosses between two points is not
    /// missed; a single point is a tap. A path whose length is not a finite number touches nothing.
    func erased(page: Int, along points: [CGPoint], slop: CGFloat) -> [AnnotationInfo] {
        let slop = slop.isFinite ? max(slop, 0) : 0
        let finite = points.filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = finite.first else { return [] }
        // Only those whose box, grown by the slop, meets the box around the path can be touched: found
        // once, so that each look below goes through those alone.
        var low = first, high = first
        for point in finite {
            low = CGPoint(x: min(low.x, point.x), y: min(low.y, point.y))
            high = CGPoint(x: max(high.x, point.x), y: max(high.y, point.y))
        }
        let candidates: [(info: AnnotationInfo, reach: CGRect)] = annotations(onPage: page).compactMap { info in
            let reach = info.box.insetBy(dx: -slop, dy: -slop)
            guard !info.locked, reach.minX <= high.x, reach.maxX >= low.x, reach.minY <= high.y, reach.maxY >= low.y else { return nil }
            return (info, reach)
        }
        guard !candidates.isEmpty else { return [] }
        let length = zip(finite, finite.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        guard length.isFinite else { return [] }
        let step = max(slop, 0.5, length / Self.maxEraserLooks)
        var found: [UInt32: AnnotationInfo] = [:]
        func look(at point: CGPoint) {
            var top: AnnotationInfo?
            for candidate in candidates where candidate.info.index >= (top?.index ?? 0) && candidate.reach.contains(point) {
                top = candidate.info
            }
            if let top { found[top.index] = top }
        }
        look(at: first)
        for (from, to) in zip(finite, finite.dropFirst()) {
            // Finite, since the whole length is; and at most `maxEraserLooks` steps, since `step` is at
            // least the length over that.
            let distance = hypot(to.x - from.x, to.y - from.y)
            let count = max(Int(min((distance / step).rounded(.up), Self.maxEraserLooks)), 1)
            for i in 1...count {
                let t = CGFloat(i) / CGFloat(count)
                look(at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            }
        }
        return found.values.sorted { $0.index < $1.index }
    }
}


extension AnnotationInfo {
    /// Where the annotation is on its page, in view space (points, origin top-left, y down).
    var box: CGRect { CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height) }
}
