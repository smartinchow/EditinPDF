import CoreGraphics
import EditinPDFCore
import XCTest
@testable import EditinPDF

// The geometry that picks the gap between two glyphs nearest a point, which is where a dragged
// selection handle lands. Pure values, so no main actor and no engine: the glyphs are made here.
final class GlyphLinesTests: XCTestCase {
    /// `text` as glyphs of a line, each one `width` wide and `height` tall, the first at (`x`, `y`).
    static func line(_ text: String, x: Double = 72, y: Double = 100, width: Double = 6, height: Double = 12) -> [TextGlyph] {
        text.enumerated().map { index, character in
            TextGlyph(text: String(character), rect: Rect(x: x + Double(index) * width, y: y, width: width, height: height))
        }
    }

    // MARK: The gap nearest a point, on one line

    /// "Hello world": 11 glyphs from x = 72, six wide, so glyph `k` spans 72 + 6k ... 78 + 6k.
    func testAPointInTheLeftHalfOfAGlyphIsTheGapBeforeIt() throws {
        let lines = GlyphLines(glyphs: Self.line("Hello world"))
        // Glyph 3 spans 90 ... 96, its centre is 93.
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 91, y: 106)), 3)
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 90, y: 106)), 3)
    }

    func testAPointInTheRightHalfOfAGlyphIsTheGapAfterIt() throws {
        let lines = GlyphLines(glyphs: Self.line("Hello world"))
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 95, y: 106)), 4)
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 96, y: 106)), 4)
    }

    /// The centre belongs to the right half, so a drag that ends on a glyph's centre takes the glyph in.
    func testTheCentreOfAGlyphIsTheGapAfterIt() throws {
        let lines = GlyphLines(glyphs: Self.line("Hello world"))
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 93, y: 106)), 4)
        // The last glyph (spans 132 ... 138): its centre is the gap after the end of the line.
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 135, y: 106)), 11)
    }

    /// Two glyphs meet at an edge, and a point on it is as near to one as to the other: either way
    /// the answer is the one gap between them, not a different one for each glyph.
    func testAPointOnTheEdgeBetweenTwoGlyphsIsTheGapBetweenThem() throws {
        let lines = GlyphLines(glyphs: Self.line("Hello world"))
        for k in 1..<11 {
            let edge = 72 + 6 * Double(k)
            XCTAssertEqual(lines.nearestGap(to: CGPoint(x: edge, y: 106)), k, "edge \(k)")
        }
    }

    func testAPointBeforeTheStartOfALineIsTheGapBeforeItsFirstGlyph() throws {
        let lines = GlyphLines(glyphs: Self.line("Hello world"))
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: -50, y: 106)), 0)
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 10, y: 106)), 0)
    }

    func testAPointPastTheEndOfALineIsTheGapAfterItsLastGlyph() throws {
        let lines = GlyphLines(glyphs: Self.line("Hello world"))
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 500, y: 106)), 11)
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 10_000, y: 106)), 11)
    }

    // MARK: Which line

    /// "one" on the first line (glyphs 0 ... 2), "three" on the second (3 ... 7), 4 points of space between
    /// the lines, which are 12 tall.
    func twoLines() -> GlyphLines {
        GlyphLines(glyphs: Self.line("one", y: 100) + Self.line("three", y: 116))
    }

    func testThePointPicksTheLineItIsLevelWith() throws {
        let lines = twoLines()
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 80, y: 105)), 1, "first line: glyph 1 spans 78 ... 84")
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 80, y: 122)), 4, "second line: glyph 4 spans 78 ... 84")
    }

    func testAPointBetweenTwoLinesPicksTheNearerOne() throws {
        let lines = twoLines()
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 80, y: 113)), 1, "the gap is 112 ... 116: 113 is nearer the first line")
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 80, y: 115)), 4, "and 115 the second")
    }

    func testAPointAboveOrBelowEverythingPicksTheFirstOrLastLine() throws {
        let lines = twoLines()
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 80, y: -400)), 1)
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 80, y: 9_000)), 4)
    }

    /// The point's own line comes first, whatever is nearer in the plane: right of a short line, level
    /// with it, is the end of that line, even though the long line below reaches further right.
    func testTheLineComesBeforeTheDistanceAlongIt() throws {
        let lines = GlyphLines(glyphs: Self.line("short", y: 100) + Self.line("a much longer line of text", y: 116))
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 150, y: 106)), 5, "the end of the short line")
        // The long line's glyph k (global 5 + k) spans 72 + 6k ... 78 + 6k: 150 is the edge between k = 12 and 13.
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 150, y: 122)), 5 + 13, "the gap in the long line, level with it")
    }

    /// Two runs of text level with each other and next to each other in reading order are one line, however
    /// wide the gap between them (a tab, a table's cells): the gaps are found along it as in any line.
    func testRunsAcrossAWideGapAreOneLine() throws {
        // "left" is glyphs 0 ... 3, spanning 72 ... 96; "right" is glyphs 4 ... 8, spanning 300 ... 330.
        let lines = GlyphLines(glyphs: Self.line("left", x: 72, y: 100) + Self.line("right", x: 300, y: 100))
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 10, y: 106)), 0, "left of both: the start of the left run")
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 80, y: 106)), 1, "inside the left run")
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 320, y: 106)), 7, "inside the right run: glyph 7 spans 318 ... 324")
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 500, y: 106)), 9, "right of both: the end of the right run")
    }

    /// Columns do not line up to the point: the one nearer across wins even when the other's line is a
    /// little nearer to the point's own height.
    func testAcrossComesBeforeTheMiddleOfTheLine() throws {
        // Two columns of two lines, in reading order: "left" (glyphs 0 ... 3) over "lower" (4 ... 8) at
        // x 72, then "right" (9 ... 13) over "below" (14 ... 18) at x 300, a little lower (3 points).
        // A point 107 down is level with "left" (100 ... 112, middle 106) and "right" (103 ... 115, middle
        // 109), and nearer the middle of "left"; but inside the right column's width it is the right one's.
        let lines = GlyphLines(glyphs: Self.line("left", x: 72, y: 100) + Self.line("lower", x: 72, y: 120)
                               + Self.line("right", x: 300, y: 103) + Self.line("below", x: 300, y: 123))
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 80, y: 107)), 1, "in the left column")
        // "right"'s glyph k spans 300 + 6k ... 306 + 6k: 320 is inside glyph 3 (318 ... 324), left of its middle.
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 320, y: 107)), 12, "in the right column")
    }

    /// Two lines whose boxes overlap (tight leading): a point in the overlap is level with both, and the
    /// line whose middle it is nearer to wins.
    func testInOverlappingLinesTheNearerMiddleWins() throws {
        // Boxes 100 ... 116 and 112 ... 128: the overlap is 112 ... 116. Middles at 108 and 120.
        let lines = GlyphLines(glyphs: Self.line("ab", y: 100, height: 16) + Self.line("cd", y: 112, height: 16))
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 73, y: 113)), 0, "113 is 5 from the first middle, 7 from the second")
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 73, y: 115)), 2, "115 is 7 from the first middle, 5 from the second")
    }

    /// A raised or lowered glyph (a superscript) is on its line: it does not start another.
    func testASuperscriptStaysOnItsLine() throws {
        var glyphs = Self.line("x2", y: 100)
        glyphs[1] = TextGlyph(text: "2", rect: Rect(x: 78, y: 97, width: 6, height: 8))
        glyphs += Self.line("next", y: 116)
        let lines = GlyphLines(glyphs: glyphs)
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 500, y: 106)), 2, "the end of the first line, superscript included")
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 500, y: 122)), 6, "the end of the second")
    }

    // MARK: What cannot be placed

    func testAPageWithoutGlyphsHasNoGap() throws {
        XCTAssertNil(GlyphLines(glyphs: []).nearestGap(to: CGPoint(x: 10, y: 10)))
    }

    func testAGlyphWithoutAUsableBoxKeepsItsIndexAndIsNeverPicked() throws {
        var glyphs = Self.line("abcd")
        glyphs[1] = TextGlyph(text: "b", rect: Rect(x: .nan, y: 100, width: 6, height: 12))
        glyphs[2] = TextGlyph(text: "c", rect: Rect(x: 84, y: 100, width: 6, height: 0))
        let lines = GlyphLines(glyphs: glyphs)
        XCTAssertEqual(lines.count, 4)
        // Glyph 0 spans 72 ... 78, glyph 3 spans 90 ... 96; the two between have no box to land on.
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 80, y: 106)), 1, "nearer glyph 0's right edge than glyph 3")
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 89, y: 106)), 3, "nearer glyph 3's left edge")
        XCTAssertEqual(lines.nearestGap(to: CGPoint(x: 500, y: 106)), 4)
    }

    func testAPageOfGlyphsWithNoBoxAtAllHasNoGap() throws {
        let glyphs = [TextGlyph(text: "a", rect: Rect(x: .nan, y: .nan, width: 1, height: 1)),
                      TextGlyph(text: "b", rect: Rect(x: 1, y: 1, width: -2, height: 0))]
        XCTAssertNil(GlyphLines(glyphs: glyphs).nearestGap(to: CGPoint(x: 1, y: 1)))
    }

    func testAPointThatIsNotANumberHasNoGap() throws {
        let lines = GlyphLines(glyphs: Self.line("Hello"))
        XCTAssertNil(lines.nearestGap(to: CGPoint(x: Double.nan, y: 106)))
        XCTAssertNil(lines.nearestGap(to: CGPoint(x: 80, y: Double.infinity)))
    }

    // MARK: The glyphs a drag selects

    /// A drag keeps the glyph it began on selected and runs to the gap nearest the finger.
    func testTheRangeRunsFromTheAnchorGlyphToTheGap() throws {
        XCTAssertEqual(GlyphLines.range(anchor: 2, gap: 6, count: 11), 2..<6, "forwards: up to the gap")
        XCTAssertEqual(GlyphLines.range(anchor: 2, gap: 3, count: 11), 2..<3, "one glyph: the anchor's own")
    }

    /// Past the anchor the other way, the anchor glyph is still in.
    func testTheRangeKeepsTheAnchorWhenTheGapIsBeforeIt() throws {
        XCTAssertEqual(GlyphLines.range(anchor: 6, gap: 4, count: 11), 4..<7)
        XCTAssertEqual(GlyphLines.range(anchor: 6, gap: 6, count: 11), 6..<7, "the gap just before the anchor: the anchor alone")
        XCTAssertEqual(GlyphLines.range(anchor: 6, gap: 0, count: 11), 0..<7)
    }

    func testTheRangeIsNeverEmptyAndStaysInsideTheGlyphs() throws {
        XCTAssertEqual(GlyphLines.range(anchor: 2, gap: 2, count: 11), 2..<3)
        XCTAssertEqual(GlyphLines.range(anchor: 2, gap: 99, count: 11), 2..<11)
        XCTAssertEqual(GlyphLines.range(anchor: 99, gap: 5, count: 11), 5..<11, "an anchor past the end is the last glyph")
        XCTAssertEqual(GlyphLines.range(anchor: -4, gap: 3, count: 11), 0..<3, "and one before the start is the first")
        XCTAssertEqual(GlyphLines.range(anchor: 0, gap: -2, count: 11), 0..<1)
        XCTAssertNil(GlyphLines.range(anchor: 0, gap: 0, count: 0), "no glyphs, no range")
    }
}
