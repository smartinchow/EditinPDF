import UIKit

/// What is drawn over one page, on top of its tiles: the boxes of the search hits (the hit being
/// looked at in another colour), for text selection, the selected text, signatures being placed with
/// Sign, a shape being dragged out with a Markup tool, and the outline of the annotation selected with
/// Select.
///
/// It is a subview of the page view with the same bounds, and the boxes are given in PDF points
/// (view space: origin at the top-left, y down), so it draws them `bounds.width / pointSize.width`
/// times as big: the scale the page's own tiles are drawn at. The scroll view zooms the page view
/// and everything in it by a transform, so a box stays on its text at every zoom. Each kind of box
/// is one shape layer, filled by Core Animation at the size it has on screen: sharp at the deepest
/// zoom, where a bitmap drawn with `draw(_:)` would be enlarged along with the page and go soft.
///
/// It takes no touches: they are for the scroll view and the page's gestures.
final class PageOverlayView: UIView {
    /// The page's size in PDF points, as shown (its rotation applied): the units of the boxes.
    let pointSize: CGSize

    /// The boxes of the search hits, in PDF points: yellow, at 35 % alpha.
    var highlights: [CGRect] = [] {
        didSet { if highlights != oldValue { update() } }
    }

    /// The boxes of the hit being looked at, in PDF points: orange, in place of the yellow of the same
    /// boxes in `highlights`. A hit that runs over a line break has a box on each line, and they are
    /// all the active one.
    var activeHighlights: [CGRect] = [] {
        didSet { if activeHighlights != oldValue { update() } }
    }

    /// The boxes of the selected text, in PDF points: light blue, at 30 % alpha, under the hits. The
    /// scroll view controller fills it with the page's part of the selection.
    var selection: [CGRect] = [] {
        didSet { if selection != oldValue { update() } }
    }

    /// Signatures placed with Sign and on their way into the page, their strokes in PDF points: drawn
    /// as the page will show them (black, `SignatureStore.lineWidth` wide) until it does.
    /// `MarkupInteraction` adds each, and takes it off once it is on the page or refused.
    var signatures: [SignatureDraft] = [] {
        didSet { if signatures != oldValue { update() } }
    }

    /// A shape being dragged out with a shape tool, in PDF points, drawn over everything else in
    /// `draftStyle`; nil when none is. `MarkupInteraction` sets it, and clears it once the shape is
    /// on the page or refused.
    var draft: DraftShape? {
        didSet { if draft != oldValue { update() } }
    }

    /// How `draft` is drawn: its line's colour and width (PDF points), its fill, and whether its line
    /// is dashed (while it is being dragged) or solid (while it is being added).
    var draftStyle = DraftStyle(color: .systemBlue, width: 2, fill: nil, dashed: true) {
        didSet { if draftStyle != oldValue { update() } }
    }

    /// The box of the annotation selected with Select, in PDF points, outlined just outside it with a
    /// dot at each corner, over everything else; nil when none on this page is.
    var selectedAnnotationRect: CGRect? {
        didSet { if selectedAnnotationRect != oldValue { update() } }
    }

    /// How far the selected annotation is being dragged, in PDF points (across and down the page as
    /// shown): its outline is drawn that far from its box, following the finger. Zero when it is not
    /// being dragged.
    var dragOffset: CGSize = .zero {
        didSet { if dragOffset != oldValue { update() } }
    }

    /// How far outside the selected annotation's box its outline runs, and how big the dots at its
    /// corners are (their radius), in the overlay's points.
    static let outlineMargin: CGFloat = 3
    static let outlineDotRadius: CGFloat = 4

    // Bottom to top. Internal, for tests: they read what is drawn from the layers.
    let selectionLayer = PageOverlayView.makeLayer(UIColor(red: 0, green: 0.48, blue: 1, alpha: 0.30))
    let highlightLayer = PageOverlayView.makeLayer(UIColor.yellow.withAlphaComponent(0.35))
    let activeLayer = PageOverlayView.makeLayer(UIColor.orange.withAlphaComponent(0.5))
    let signatureLayer: CAShapeLayer = {
        let layer = BoxesLayer()
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.fillColor = nil
        layer.strokeColor = SignatureStore.color.uiColor.cgColor
        return layer
    }()
    let draftLayer: CAShapeLayer = {
        let layer = BoxesLayer()
        layer.lineCap = .round
        layer.lineJoin = .round
        return layer
    }()
    let annotationOutlineLayer: CAShapeLayer = {
        let layer = BoxesLayer()
        layer.fillColor = nil
        layer.strokeColor = UIColor.systemBlue.cgColor
        layer.lineWidth = 1.5
        return layer
    }()
    let annotationDotsLayer: CAShapeLayer = {
        let layer = BoxesLayer()
        layer.fillColor = UIColor.systemBlue.cgColor
        layer.strokeColor = UIColor.white.cgColor
        layer.lineWidth = 1.5
        return layer
    }()

    /// An overlay for a page `pointSize` PDF points in size; give it the page view's bounds.
    init(pointSize: CGSize) {
        self.pointSize = pointSize
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        // Highlights run to the page's edge at most.
        clipsToBounds = true
        for layer in [selectionLayer, highlightLayer, activeLayer, signatureLayer, draftLayer, annotationOutlineLayer, annotationDotsLayer] {
            self.layer.addSublayer(layer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        update()
    }

    /// Layer points per PDF point; 0 while there is nothing to scale by: the overlay has no size yet,
    /// or the page has none the engine could give (zero, negative or not a number).
    private var scale: CGFloat {
        guard pointSize.width > 0, pointSize.width.isFinite, bounds.width > 0 else { return 0 }
        return bounds.width / pointSize.width
    }

    /// Sets each layer to the bounds and its boxes to a path at the current scale.
    private func update() {
        // Not animated: a path set from inside a view's layout would otherwise morph into the next.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let scale = scale
        // The active boxes are the hits' boxes too, but they are drawn in their own colour alone: both
        // layers over the same text would tint it twice, and leave it harder to read.
        let others = activeHighlights.isEmpty ? highlights : highlights.filter { !activeHighlights.contains($0) }
        for (layer, boxes) in [(selectionLayer, selection), (highlightLayer, others), (activeLayer, activeHighlights)] {
            layer.frame = bounds
            layer.path = Self.path(of: boxes, scale: scale)
        }
        updateSignatures(scale: scale)
        updateDraft(scale: scale)
        updateSelectedAnnotation(scale: scale)
    }

    /// Draws `signatures` at `scale`: each stroke through its points, a stroke of one point a dot.
    private func updateSignatures(scale: CGFloat) {
        signatureLayer.frame = bounds
        guard scale > 0, !signatures.isEmpty else {
            signatureLayer.path = nil
            return
        }
        let path = CGMutablePath()
        for stroke in signatures.flatMap(\.strokes) {
            guard let first = stroke.first else { continue }
            // One point is a dot: the round cap of a line of no length.
            path.addLines(between: stroke.count > 1 ? stroke : [first, first])
        }
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        signatureLayer.path = path.copy(using: &transform)
        signatureLayer.lineWidth = max(CGFloat(SignatureStore.lineWidth) * scale, 1 / max(contentScaleFactor, 1))
    }

    /// Outlines `selectedAnnotationRect`, moved by `dragOffset`, at `scale`, a dot at each corner.
    private func updateSelectedAnnotation(scale: CGFloat) {
        annotationOutlineLayer.frame = bounds
        annotationDotsLayer.frame = bounds
        let box = selectedAnnotationRect?.offsetBy(dx: dragOffset.width, dy: dragOffset.height)
        guard let box, scale > 0, [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite) else {
            annotationOutlineLayer.path = nil
            annotationDotsLayer.path = nil
            return
        }
        let shown = CGRect(x: box.minX * scale, y: box.minY * scale, width: box.width * scale, height: box.height * scale)
            .insetBy(dx: -Self.outlineMargin, dy: -Self.outlineMargin)
        annotationOutlineLayer.path = CGPath(rect: shown, transform: nil)
        let dots = CGMutablePath()
        let r = Self.outlineDotRadius
        for corner in [CGPoint(x: shown.minX, y: shown.minY), CGPoint(x: shown.maxX, y: shown.minY),
                       CGPoint(x: shown.minX, y: shown.maxY), CGPoint(x: shown.maxX, y: shown.maxY)] {
            dots.addEllipse(in: CGRect(x: corner.x - r, y: corner.y - r, width: 2 * r, height: 2 * r))
        }
        annotationDotsLayer.path = dots
    }

    /// Draws `draft` at `scale` in `draftStyle`: a rectangle's or an oval's line inside its box, as the
    /// engine draws it, and an arrow with its head.
    private func updateDraft(scale: CGFloat) {
        draftLayer.frame = bounds
        guard let draft, scale > 0 else {
            draftLayer.path = nil
            return
        }
        let style = draftStyle
        let width = max(style.width, 0)
        let path = CGMutablePath()
        switch draft {
        case .rect(let box, let oval):
            // The line lies inside the box, as the engine draws it (half its width in from each side).
            let inset = min(width / 2, box.width / 2, box.height / 2)
            let inside = box.insetBy(dx: inset, dy: inset)
            if oval { path.addEllipse(in: inside) } else { path.addRect(inside) }
        case .line(let from, let to, let arrow):
            path.move(to: from)
            path.addLine(to: to)
            if arrow {
                let (a, b) = ShapeGeometry.arrowHead(from: from, to: to, width: width)
                path.move(to: a)
                path.addLine(to: to)
                path.addLine(to: b)
            }
        }
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        draftLayer.path = path.copy(using: &transform)
        draftLayer.lineWidth = max(width * scale, 1 / max(contentScaleFactor, 1))
        draftLayer.strokeColor = style.color.cgColor
        if case .rect = draft { draftLayer.fillColor = style.fill?.cgColor } else { draftLayer.fillColor = nil }
        draftLayer.lineDashPattern = style.dashed ? [NSNumber(value: Double(max(width * scale, 1) * 3)), NSNumber(value: Double(max(width * scale, 1) * 2))] : nil
    }

    /// `boxes` scaled by `scale`, as one path, so boxes that overlap are one area and not darker
    /// where they do; nil for no boxes, or no scale.
    private static func path(of boxes: [CGRect], scale: CGFloat) -> CGPath? {
        guard scale > 0, !boxes.isEmpty else { return nil }
        let path = CGMutablePath()
        path.addRects(boxes, transform: CGAffineTransform(scaleX: scale, y: scale))
        return path
    }

    private static func makeLayer(_ color: UIColor) -> CAShapeLayer {
        let layer = BoxesLayer()
        layer.fillColor = color.cgColor
        layer.strokeColor = nil
        return layer
    }
}

/// A signature on its way into its page (`PageOverlayView.signatures`): its strokes, in PDF points.
/// Each placing is its own, though two be alike.
struct SignatureDraft: Equatable {
    let id = UUID()
    let strokes: [[CGPoint]]
}

/// How a shape being dragged out is drawn over its page (`PageOverlayView.draft`): its line's colour
/// and width in PDF points, its fill (a rectangle's or an oval's), and whether the line is dashed.
struct DraftStyle: Equatable {
    var color: UIColor
    var width: CGFloat
    var fill: UIColor?
    var dashed: Bool
}

/// A shape layer that never animates a change: a highlight that is replaced by the next must not
/// fade or morph into it, and none of the layer's properties is meant to be animated.
private final class BoxesLayer: CAShapeLayer {
    override func action(forKey event: String) -> CAAction? { NSNull() }
}
