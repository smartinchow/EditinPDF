import CoreGraphics
import UIKit

/// A shape being dragged out on a page with a shape tool, in view space (PDF points of the page,
/// origin top-left, y down, its rotation applied): a rectangle or an oval in a box, or a line, with
/// an arrow head at its end or not. What `DocumentModel.addShape` adds.
enum DraftShape: Equatable, Sendable {
    case rect(CGRect, oval: Bool)
    case line(from: CGPoint, to: CGPoint, arrow: Bool)

    /// The tool that draws it.
    var tool: Tool {
        switch self {
        case .rect(_, let oval): oval ? .oval : .rectangle
        case .line(_, _, let arrow): arrow ? .arrow : .line
        }
    }
}

/// Where the shapes, text boxes and notes made on a page go, in view space, and what the bridge takes
/// of them. Every function is pure: the pages' sizes are given, as shown (`PageInfo.widthPt` and
/// `heightPt`, the rotation applied).
enum ShapeGeometry {
    /// How long a drag has to be, in PDF points, each way for a box and end to end for a line, to be a
    /// shape: a shorter one is taken for a slip of the finger.
    static let minimumSide: CGFloat = 8

    /// The side of a note's icon, in PDF points: the engine's (`pdfcraft_annot::NOTE_SIZE`).
    static let noteSize: CGFloat = 20

    /// A text box's least width, in PDF points.
    static let textBoxMinimumWidth: CGFloat = 60
    /// What a text box has beyond its text, in PDF points, across and down: the engine sets its text
    /// `textInset` in from the box's left and top, and this leaves as much again to spare.
    static let textBoxMargin: CGFloat = 8
    /// How far in from a text box's left, right and top edges the engine sets its text, in PDF points
    /// (`pdfcraft_annot` appearance: 2 points, there being no border).
    static let textInset: CGFloat = 2
    /// How far apart the engine sets a text box's lines, in text sizes.
    static let lineSpacing: CGFloat = 1.2
    /// How tall a text box's line is, in text sizes: a little more than the engine's spacing.
    static let lineHeight: CGFloat = 1.25
    /// The text sizes the bridge takes, in points.
    static let fontSizes: ClosedRange<Double> = 4...144
    /// The text size a size that is not a number becomes: the tool's first.
    static let defaultFontSize: Double = 14

    /// How far from the page's origin, each way, a point the bridge converts may be (its
    /// `MAX_VIEW_COORD`, four times the largest page side, 14,400 points).
    static let reach: CGFloat = 57_600
    /// How long, in PDF points, the bridge has a box's sides and a line at least.
    static let bridgeMinimumSide: CGFloat = 1

    // MARK: Shapes

    /// `point` brought onto a page `pageSize` in size: each coordinate kept between 0 and the side.
    static func clamp(_ point: CGPoint, to pageSize: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), max(pageSize.width, 0)), y: min(max(point.y, 0), max(pageSize.height, 0)))
    }

    /// The box a drag from `start` to `end` spans, kept to the page, whichever way it went; nil when a
    /// side of it is shorter than `minimumSide`.
    static func rect(from start: CGPoint, to end: CGPoint, pageSize: CGSize) -> CGRect? {
        let a = clamp(start, to: pageSize), b = clamp(end, to: pageSize)
        let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        guard box.width >= minimumSide, box.height >= minimumSide else { return nil }
        return box
    }

    /// The line a drag from `start` to `end` draws, each end kept to the page; nil when it is shorter
    /// than `minimumSide`.
    static func line(from start: CGPoint, to end: CGPoint, pageSize: CGSize) -> (CGPoint, CGPoint)? {
        let a = clamp(start, to: pageSize), b = clamp(end, to: pageSize)
        guard hypot(b.x - a.x, b.y - a.y) >= minimumSide else { return nil }
        return (a, b)
    }

    /// The shape `tool` draws for a drag from `start` to `end` on a page `pageSize` in size; nil for a
    /// drag too short (`rect`, `line`) or a tool that draws no shape.
    static func draft(of tool: Tool, from start: CGPoint, to end: CGPoint, pageSize: CGSize) -> DraftShape? {
        switch tool {
        case .rectangle, .oval:
            rect(from: start, to: end, pageSize: pageSize).map { .rect($0, oval: tool == .oval) }
        case .line, .arrow:
            line(from: start, to: end, pageSize: pageSize).map { .line(from: $0.0, to: $0.1, arrow: tool == .arrow) }
        case .select, .highlight, .underline, .strikeout, .ink, .signature, .textBox, .note, .eraser:
            nil
        }
    }

    /// The two ends of an open arrow head at `to`, for a line from `from` `width` points wide: back
    /// along the line at 30° either side of it, 6 points and 3 widths long, as the engine draws it
    /// (`pdfcraft_annot` appearance, `arrow_size`). Both are `to` for a line of no length.
    static func arrowHead(from: CGPoint, to: CGPoint, width: CGFloat) -> (CGPoint, CGPoint) {
        let dx = from.x - to.x, dy = from.y - to.y
        let length = hypot(dx, dy)
        guard length > 0, length.isFinite else { return (to, to) }
        let size = 6 + 3 * max(width, 0)
        let (ux, uy) = (dx / length, dy / length)
        let (c, s) = (cos(CGFloat.pi / 6), sin(CGFloat.pi / 6))
        return (CGPoint(x: to.x + size * (ux * c - uy * s), y: to.y + size * (ux * s + uy * c)),
                CGPoint(x: to.x + size * (ux * c + uy * s), y: to.y + size * (-ux * s + uy * c)))
    }

    /// The colour a shape drawn in `color` is filled with: the bridge's colours have no alpha, so it is
    /// `color` mixed three quarters of the way to white.
    static func fill(for color: RGBA) -> RGBA {
        func lightened(_ c: Double) -> Double { c + (1 - c) * 0.75 }
        return RGBA(r: lightened(color.r), g: lightened(color.g), b: lightened(color.b))
    }

    // MARK: Text boxes

    /// A text size the bridge takes: `size` held to `fontSizes`; `defaultFontSize` for one that is not
    /// a number.
    static func fontSize(_ size: Double) -> Double {
        size.isFinite ? min(max(size, fontSizes.lowerBound), fontSizes.upperBound) : defaultFontSize
    }

    /// The face the engine sets a text box's text in, Helvetica, `size` points: what its text is
    /// measured in, and typed in.
    static func textFont(ofSize size: CGFloat) -> UIFont {
        UIFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
    }

    /// Where a text box tapped at `point` starts: there, or as far in from the page's right and bottom
    /// edges as its least width and its first line need.
    static func textBoxOrigin(at point: CGPoint, fontSize: CGFloat, pageSize: CGSize) -> CGPoint {
        let oneLine = fontSize * lineHeight + textBoxMargin
        return CGPoint(x: min(max(point.x, 0), max(pageSize.width - textBoxMinimumWidth, 0)),
                       y: min(max(point.y, 0), max(pageSize.height - oneLine, 0)))
    }

    /// The box of a text box at `point` (its top-left) showing `text` at `fontSize`: as wide as its
    /// longest line and `textBoxMargin` more, `textBoxMinimumWidth` at least, and no further than the
    /// page's right edge; as tall as its lines (a line that does not fit across runs onto more) at
    /// `lineHeight` times the size, and `textBoxMargin` more. An empty text is one line.
    static func textBoxRect(at point: CGPoint, text: String, fontSize: CGFloat, pageSize: CGSize) -> CGRect {
        let font = textFont(ofSize: fontSize)
        let lines = text.components(separatedBy: .newlines)
        let measured = lines.map { width(of: $0, in: font) }.max() ?? 0
        let width = min(max(measured + textBoxMargin, textBoxMinimumWidth), pageSize.width - point.x)
        let across = max(width - 2 * textInset, 1)
        let count = lines.reduce(0) { $0 + wrappedLineCount(of: $1, in: font, across: across) }
        return CGRect(x: point.x, y: point.y, width: width, height: CGFloat(max(count, 1)) * fontSize * lineHeight + textBoxMargin)
    }

    /// The width of `line` set in `font`, on one line.
    private static func width(of line: String, in font: UIFont) -> CGFloat {
        guard !line.isEmpty else { return 0 }
        return (line as NSString).size(withAttributes: [.font: font]).width
    }

    /// How many lines `line` (no new line in it) takes set in `font` `across` points wide, broken
    /// between words: 1 at least.
    private static func wrappedLineCount(of line: String, in font: UIFont, across: CGFloat) -> Int {
        guard width(of: line, in: font) > across else { return 1 }
        let spacing = font.pointSize * lineSpacing
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = spacing
        style.maximumLineHeight = spacing
        let height = (line as NSString).boundingRect(with: CGSize(width: across, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin],
                                                     attributes: [.font: font, .paragraphStyle: style], context: nil).height
        return max(1, Int((height / spacing).rounded()))
    }

    /// The text a text box is made with from what was typed: without the spaces and new lines after
    /// its last character. Empty when nothing but those was typed.
    static func committedText(_ typed: String) -> String {
        guard let last = typed.lastIndex(where: { !$0.isWhitespace }) else { return "" }
        return String(typed[...last])
    }

    // MARK: Notes

    /// Where a note's icon goes for a tap at `point`: its top-left there, kept wholly on the page.
    static func noteBox(at point: CGPoint, pageSize: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), max(pageSize.width - noteSize, 0)),
                y: min(max(point.y, 0), max(pageSize.height - noteSize, 0)))
    }

    // MARK: What the bridge takes

    /// Whether `value` is a coordinate the bridge converts: a number within `reach` of 0.
    static func isInReach(_ value: CGFloat) -> Bool {
        value.isFinite && abs(value) <= reach
    }

    /// Whether both of `point`'s coordinates are ones the bridge converts.
    static func isInReach(_ point: CGPoint) -> Bool {
        isInReach(point.x) && isInReach(point.y)
    }

    /// Whether the bridge draws a box in `rect`: its corners within reach, and at least
    /// `bridgeMinimumSide` wide and tall.
    static func isDrawable(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height, rect.origin.x + rect.width, rect.origin.y + rect.height]
            .allSatisfy(isInReach) && rect.width >= bridgeMinimumSide && rect.height >= bridgeMinimumSide
    }

    /// Whether the bridge draws a line from `from` to `to`: both within reach, at least
    /// `bridgeMinimumSide` apart.
    static func isDrawableLine(from: CGPoint, to: CGPoint) -> Bool {
        isInReach(from) && isInReach(to) && hypot(to.x - from.x, to.y - from.y) >= bridgeMinimumSide
    }
}
