import UIKit

/// What is drawn over one page, on top of its tiles: the boxes of the search hits (the hit being
/// looked at in another colour) and, for text selection, the selected text.
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

    // Bottom to top. Internal, for tests: they read what is drawn from the layers.
    let selectionLayer = PageOverlayView.makeLayer(UIColor(red: 0, green: 0.48, blue: 1, alpha: 0.30))
    let highlightLayer = PageOverlayView.makeLayer(UIColor.yellow.withAlphaComponent(0.35))
    let activeLayer = PageOverlayView.makeLayer(UIColor.orange.withAlphaComponent(0.5))

    /// An overlay for a page `pointSize` PDF points in size; give it the page view's bounds.
    init(pointSize: CGSize) {
        self.pointSize = pointSize
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        // Highlights run to the page's edge at most.
        clipsToBounds = true
        for layer in [selectionLayer, highlightLayer, activeLayer] { self.layer.addSublayer(layer) }
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

/// A shape layer that never animates a change: a highlight that is replaced by the next must not
/// fade or morph into it, and none of the layer's properties is meant to be animated.
private final class BoxesLayer: CAShapeLayer {
    override func action(forKey event: String) -> CAAction? { NSNull() }
}
