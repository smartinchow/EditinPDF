import CoreGraphics
import PencilKit

/// What is drawn with Draw becoming the strokes of an ink annotation: from the canvas's points to the
/// page's (view space: PDF points of the page, origin top-left, y down, its rotation applied, like
/// every edit's), fewer of them where the line is straight, and within what the bridge takes.
///
/// The bridge refuses a drawing of more than `maxStrokes` strokes, a stroke of more than
/// `maxStrokePoints` points, more than `maxDrawingPoints` points in all, a point further than `reach`
/// from the page's origin, and a line width outside `lineWidths` (`editinpdf-core` `edit.rs`). A long
/// session with the Pencil can pass any of those: here a long stroke is cut into pieces that join
/// (`withinLimits`) and a big drawing into several (`drawings`), so nothing drawn is refused for its size.
enum InkGeometry {
    /// The most strokes one drawing may have.
    static let maxStrokes = 500
    /// The most points one stroke may have.
    static let maxStrokePoints = 10_000
    /// The most points one drawing may have, all its strokes together.
    static let maxDrawingPoints = 100_000
    /// How far from the page's origin, in points, a point may be, either way, on either axis.
    static let reach: CGFloat = 57_600
    /// The thinnest and thickest a line may be, in points.
    static let lineWidths: ClosedRange<Double> = 0.1...50
    /// The most points `simplify` looks at together.
    static let simplifyWindow = 1_024

    /// Page points (view space) of a stroke drawn on a canvas that shows the page at
    /// `pointsPerCanvasPoint` (= 1 / zoom): `pagePoint = canvasPoint × pointsPerCanvasPoint + canvasOrigin`,
    /// `canvasOrigin` being the canvas's top-left in page points.
    static func pagePoints(_ canvasPoints: [CGPoint], canvasOrigin: CGPoint, pointsPerCanvasPoint: CGFloat) -> [CGPoint] {
        canvasPoints.map {
            CGPoint(x: $0.x * pointsPerCanvasPoint + canvasOrigin.x, y: $0.y * pointsPerCanvasPoint + canvasOrigin.y)
        }
    }

    /// Ramer–Douglas–Peucker; keeps the end points; never returns fewer than 1 point for a non-empty input.
    ///
    /// A point goes when it is within `tolerance` of the segment between the points kept either side of
    /// it: the segment, not the line through it, so a stroke that turns back along itself keeps the
    /// point where it turned. A stroke that never leaves `tolerance` of where it began is a dot: its
    /// first point.
    ///
    /// Works through a list instead of recursing, so a stroke of any length is safe; and a stroke of
    /// more than `simplifyWindow` points is simplified in windows of that many that share their end
    /// points (kept), since the method takes time in the square of the points on a scribble.
    static func simplify(_ points: [CGPoint], tolerance: CGFloat = 0.5) -> [CGPoint] {
        guard let first = points.first, let last = points.last else { return [] }
        guard points.count > 1 else { return [first] }
        var kept = [Bool](repeating: false, count: points.count)
        var spans = stride(from: 0, to: points.count - 1, by: simplifyWindow - 1).map {
            ($0, min($0 + simplifyWindow - 1, points.count - 1))
        }
        for (start, end) in spans {
            kept[start] = true
            kept[end] = true
        }
        while let (start, end) = spans.popLast() {
            guard end - start > 1 else { continue }
            var farthest = start, distance: CGFloat = 0
            for index in (start + 1)..<end {
                let d = Self.distance(of: points[index], toSegmentFrom: points[start], to: points[end])
                if d > distance {
                    distance = d
                    farthest = index
                }
            }
            if distance > tolerance {
                kept[farthest] = true
                spans.append((start, farthest))
                spans.append((farthest, end))
            }
        }
        let simplified = zip(points, kept).compactMap { $1 ? $0 : nil }
        if simplified.count == 2, Self.distance(of: last, toSegmentFrom: first, to: first) <= tolerance {
            return [first]
        }
        return simplified
    }

    /// The strokes of `drawing` (on a canvas whose top-left is `canvasOrigin` in page points, one of
    /// whose points is `pointsPerCanvasPoint` page points) in page points: each stroke's path sampled
    /// every `spacing` canvas points (`path.interpolatedPoints(by: .distance(spacing))`), its transform
    /// applied, converted (`pagePoints`), simplified within `tolerance` page points, and kept within
    /// the bridge's limits (`withinLimits`): no stroke has more than `maxStrokePoints` points.
    /// `drawings` cuts them into as many annotations as the other limits need.
    static func strokes(of drawing: PKDrawing, canvasOrigin: CGPoint, pointsPerCanvasPoint: CGFloat,
                        spacing: CGFloat = 1, tolerance: CGFloat = 0.5) -> [[CGPoint]] {
        drawing.strokes.flatMap { stroke -> [[CGPoint]] in
            let path = stroke.path
            var canvasPoints = path.interpolatedPoints(by: .distance(max(spacing, 0.01))).map(\.location)
            // The sampling steps from the start: the stroke's own last point ends it.
            if let end = path.last?.location, canvasPoints.last != end { canvasPoints.append(end) }
            let placed = canvasPoints.map { $0.applying(stroke.transform) }
            let page = pagePoints(placed, canvasOrigin: canvasOrigin, pointsPerCanvasPoint: pointsPerCanvasPoint)
            return withinLimits(simplify(page.filter { $0.x.isFinite && $0.y.isFinite }, tolerance: tolerance))
        }
    }

    /// `stroke` as the bridge takes it: points that are not numbers left out, the others brought within
    /// `reach`, and cut into pieces of at most `maxStrokePoints` points, each starting where the one
    /// before ended, so the line has no gap. None for a stroke with no point left.
    static func withinLimits(_ stroke: [CGPoint]) -> [[CGPoint]] {
        let points = stroke.compactMap { point -> CGPoint? in
            guard point.x.isFinite, point.y.isFinite else { return nil }
            return CGPoint(x: min(max(point.x, -reach), reach), y: min(max(point.y, -reach), reach))
        }
        guard points.count > maxStrokePoints else { return points.isEmpty ? [] : [points] }
        return stride(from: 0, to: points.count - 1, by: maxStrokePoints - 1).map {
            Array(points[$0...min($0 + maxStrokePoints - 1, points.count - 1)])
        }
    }

    /// `strokes` (each within `maxStrokePoints`) cut, in order, into drawings of at most `maxStrokes`
    /// strokes and `maxDrawingPoints` points: one annotation each. Empty strokes are left out.
    static func drawings(_ strokes: [[CGPoint]]) -> [[[CGPoint]]] {
        var drawings: [[[CGPoint]]] = []
        var current: [[CGPoint]] = []
        var points = 0
        for stroke in strokes where !stroke.isEmpty {
            if current.count == maxStrokes || points + stroke.count > maxDrawingPoints {
                drawings.append(current)
                current = []
                points = 0
            }
            current.append(stroke)
            points += stroke.count
        }
        if !current.isEmpty { drawings.append(current) }
        return drawings
    }

    /// `width` points as a line the bridge draws: within `lineWidths`; the tools' starting width (2)
    /// for a width that is not a number.
    static func lineWidth(_ width: Double) -> Double {
        guard width.isFinite else { return ToolStyle.initial(for: .ink).width }
        return min(max(width, lineWidths.lowerBound), lineWidths.upperBound)
    }

    /// How far `point` is from the segment from `a` to `b` (from `a` itself when they are one point).
    private static func distance(of point: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared > 0 ? min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1) : 0
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}
