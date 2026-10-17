import CoreGraphics
import EditinPDFCore

/// A page's glyphs gathered into lines, to find the gap between two glyphs that is nearest a point:
/// where the end of a selection goes when its handle is dragged there.
///
/// The engine gives a page's glyphs in reading order, and a line is a run of them side by side:
/// consecutive glyphs whose boxes are level with one another. The engine knows its own lines but does
/// not send them across the bridge, so they are told from the boxes here, which is all a drag needs:
/// the line the point is level with comes first, and only then how far along it the point is. (The
/// engine's own nearest-glyph search, which `selectWord` uses, weighs the two instead, so a point far
/// right of a short line would be taken for the line below if that one reaches further.)
///
/// Everything is in PDF points, view space: the origin at the page's top-left, y down, as the engine
/// gives glyph boxes. Lines run across the page; on a page shown turned, where they run down it, a
/// glyph is a line of its own, and the nearest glyph is still found, though a gap between two of them
/// is told from how far across the point is.
struct GlyphLines: Sendable {
    /// A run of consecutive glyphs on one line.
    struct Line: Sendable, Equatable {
        /// The glyphs of the line, by their index on the page.
        let glyphs: Range<Int>
        /// The box that holds all their boxes.
        let box: CGRect
    }

    /// How far from a line's middle, in PDF points, a point may be before it counts as another line's
    /// level: two lines are level with a point that is as near one as the other, to within this.
    private static let sameLevel: CGFloat = 0.001

    /// How far left of a glyph's middle a point may be and still be on its right half: a point put
    /// on a glyph's middle by arithmetic that differs in the last digit is still on the middle.
    private static let middleTolerance: CGFloat = 1e-6

    /// The box of each glyph, `.null` for one with no box to land on: not finite, no height, or a
    /// width below nothing.
    private let boxes: [CGRect]
    /// The lines, in reading order.
    private let lines: [Line]

    /// The page's glyphs, in reading order. A glyph with no usable box keeps its index and stays on
    /// the line it is in, but is never the nearest.
    init(glyphs: [TextGlyph]) {
        var boxes: [CGRect] = []
        boxes.reserveCapacity(glyphs.count)
        var lines: [Line] = []
        var first = 0
        var lineBox = CGRect.null
        for (index, glyph) in glyphs.enumerated() {
            let box = Self.box(of: glyph)
            boxes.append(box)
            guard !box.isNull else { continue }
            if !lineBox.isNull, !Self.isOnLine(box, lineBox) {
                lines.append(Line(glyphs: first..<index, box: lineBox))
                first = index
                lineBox = .null
            }
            lineBox = Self.union(lineBox, box)
        }
        if !lineBox.isNull { lines.append(Line(glyphs: first..<glyphs.count, box: lineBox)) }
        self.boxes = boxes
        self.lines = lines
    }

    /// How many glyphs the page has.
    var count: Int { boxes.count }

    /// The gap nearest `point`, as the index of the glyph after it: 0 is the gap before the first glyph
    /// of the page and `count` the one after the last. Nil when the page has no glyph with a box, or the
    /// point is not a number.
    ///
    /// The line comes first: the one whose boxes the point is level with, or the nearest above or
    /// below it, and of lines side by side (columns) the one nearer across. On the line, the nearest
    /// glyph, and the gap on the side of its middle the point is on: a point on a glyph's middle is
    /// after it, so a drag that ends on a glyph takes the glyph in.
    func nearestGap(to point: CGPoint) -> Int? {
        guard point.x.isFinite, point.y.isFinite, let line = nearestLine(to: point) else { return nil }
        var best: (glyph: Int, across: CGFloat, middle: CGFloat)?
        for index in line.glyphs {
            let box = boxes[index]
            guard !box.isNull else { continue }
            let across = Self.distance(of: point.x, fromRange: box.minX, to: box.maxX)
            let middle = abs(point.x - Self.middle(of: box.minX, box.maxX))
            // Two glyphs that meet at an edge are as near a point on it: either gives the gap there.
            if let current = best, (across, middle) >= (current.across, current.middle) { continue }
            best = (index, across, middle)
        }
        guard let best else { return nil }
        let afterMiddle = point.x >= Self.middle(of: boxes[best.glyph].minX, boxes[best.glyph].maxX) - Self.middleTolerance
        return best.glyph + (afterMiddle ? 1 : 0)
    }

    /// The glyphs a drag selects: the one it began on, `anchor`, which stays selected, and everything
    /// from there to `gap`, the gap the finger is at. Never empty, and never outside the page's `count`
    /// glyphs: an anchor or a gap outside them is the nearest inside. Nil for a page with no glyphs.
    static func range(anchor: Int, gap: Int, count: Int) -> Range<Int>? {
        guard count > 0 else { return nil }
        let anchor = min(max(anchor, 0), count - 1)
        let gap = min(max(gap, 0), count)
        return gap > anchor ? anchor..<gap : gap..<(anchor + 1)
    }

    // MARK: Lines

    /// The line `point` is level with, or the nearest to it above or below, of those the nearer across
    /// first, then the one whose middle it is nearer to (so a point where two lines' boxes overlap
    /// belongs to the one it is nearer the middle of).
    private func nearestLine(to point: CGPoint) -> Line? {
        var level = CGFloat.infinity
        for line in lines {
            level = min(level, Self.distance(of: point.y, fromRange: line.box.minY, to: line.box.maxY))
        }
        guard level.isFinite else { return nil }
        var best: (line: Line, across: CGFloat, middle: CGFloat)?
        for line in lines {
            guard Self.distance(of: point.y, fromRange: line.box.minY, to: line.box.maxY) <= level + Self.sameLevel else { continue }
            let across = Self.distance(of: point.x, fromRange: line.box.minX, to: line.box.maxX)
            let middle = abs(point.y - Self.middle(of: line.box.minY, line.box.maxY))
            if let current = best, (across, middle) >= (current.across, current.middle) { continue }
            best = (line, across, middle)
        }
        return best?.line
    }

    /// Whether a glyph's `box` is on the line whose boxes so far fill `line`: it overlaps the line's
    /// height by at least half of its own. A raised or lowered glyph (a superscript) overlaps; the glyph
    /// of the next line, with a gap or a little overlap between the lines, does not.
    private static func isOnLine(_ box: CGRect, _ line: CGRect) -> Bool {
        min(line.maxY, box.maxY) - max(line.minY, box.minY) >= box.height / 2
    }

    // MARK: Boxes

    private static func box(of glyph: TextGlyph) -> CGRect {
        let rect = glyph.rect
        guard rect.x.isFinite, rect.y.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width >= 0, rect.height > 0 else { return .null }
        return CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    /// The box holding both. (`CGRect.union` leaves out a box with no width, which a glyph can have.)
    private static func union(_ a: CGRect, _ b: CGRect) -> CGRect {
        guard !a.isNull else { return b }
        guard !b.isNull else { return a }
        let minX = min(a.minX, b.minX), minY = min(a.minY, b.minY)
        return CGRect(x: minX, y: minY, width: max(a.maxX, b.maxX) - minX, height: max(a.maxY, b.maxY) - minY)
    }

    /// How far `value` is from the span `low` ... `high`: 0 when it is in it.
    private static func distance(of value: CGFloat, fromRange low: CGFloat, to high: CGFloat) -> CGFloat {
        value < low ? low - value : (value > high ? value - high : 0)
    }

    private static func middle(of low: CGFloat, _ high: CGFloat) -> CGFloat {
        low + (high - low) / 2
    }
}
