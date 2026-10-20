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
            .filter { matching($0) && CGRect(x: $0.rect.x, y: $0.rect.y, width: $0.rect.width, height: $0.rect.height)
                .insetBy(dx: -slop, dy: -slop).contains(point) }
            .max { $0.index < $1.index }
    }
}

