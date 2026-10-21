import EditinPDFCore
import PencilKit
import XCTest
@testable import EditinPDF

/// Freehand ink: what is drawn on the canvas becoming the strokes of an ink annotation, in page
/// points (`InkGeometry`), within what the bridge takes, and the model adding them as one change.
@MainActor
final class InkGeometryTests: XCTestCase {
    // MARK: Canvas points to page points

    /// Review Focus 4: a point on the canvas is the same point of the page however far the page is
    /// zoomed: `pagePoint = canvasPoint × pointsPerCanvasPoint + canvasOrigin`.
    func testCanvasPointsBecomePagePointsAtAnyZoom() {
        let p = InkGeometry.pagePoints([CGPoint(x: 200, y: 100)], canvasOrigin: .zero, pointsPerCanvasPoint: 0.5)   // zoomed 2×
        XCTAssertEqual(p, [CGPoint(x: 100, y: 50)])
        let q = InkGeometry.pagePoints([CGPoint(x: 10, y: 10)], canvasOrigin: CGPoint(x: -20, y: 0), pointsPerCanvasPoint: 2)
        XCTAssertEqual(q, [CGPoint(x: 0, y: 20)])                                    // canvasPoint × k + canvasOrigin
    }

    // MARK: Simplifying

    func testSimplifyKeepsShapeAndEnds() {
        let line = (0...100).map { CGPoint(x: Double($0), y: 0) }
        XCTAssertEqual(InkGeometry.simplify(line), [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
        XCTAssertEqual(InkGeometry.simplify([CGPoint(x: 1, y: 1)]), [CGPoint(x: 1, y: 1)])
        let corner = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 50)]
        XCTAssertEqual(InkGeometry.simplify(corner), corner)
    }

    /// A stroke that goes out along a line and comes back along it keeps the point where it turned:
    /// the distance is to the segment between the ends, not to the line through them.
    func testSimplifyKeepsATurnBackAlongTheSameLine() {
        let there = (0...50).map { CGPoint(x: Double($0) * 2, y: 0) }
        let back = (0...49).reversed().map { CGPoint(x: Double($0) * 2, y: 0) }
        XCTAssertEqual(InkGeometry.simplify(there + back), [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 0)])
    }

    /// A finger that went down and up in one place (within the tolerance) leaves a dot: one point.
    func testAStrokeThatStaysPutIsADot() {
        XCTAssertEqual(InkGeometry.simplify([CGPoint(x: 5, y: 5), CGPoint(x: 5.1, y: 5), CGPoint(x: 5, y: 5.2)]), [CGPoint(x: 5, y: 5)])
        XCTAssertEqual(InkGeometry.simplify([CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5)]), [CGPoint(x: 5, y: 5)])
        XCTAssertEqual(InkGeometry.simplify([]), [])
    }

    /// A hand's wobble, within the tolerance of the line drawn, goes; the corner stays.
    func testSimplifyDropsWobbleWithinTheTolerance() {
        let across = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0.3), CGPoint(x: 20, y: -0.3), CGPoint(x: 30, y: 0)]
        let down = [CGPoint(x: 30, y: 10), CGPoint(x: 30.3, y: 20), CGPoint(x: 30, y: 30)]
        XCTAssertEqual(InkGeometry.simplify(across + down), [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 0), CGPoint(x: 30, y: 30)])
    }

    /// A long scribble, every point of which is kept (the worst case for the method), is simplified
    /// in windows, without running out of stack; a long straight line keeps only its ends and the
    /// windows' ends.
    func testSimplifyCopesWithALongScribble() {
        let zigzag = (0..<12_000).map { CGPoint(x: Double($0), y: $0.isMultiple(of: 2) ? 0 : 10) }
        XCTAssertEqual(InkGeometry.simplify(zigzag), zigzag)
        let straight = (0..<12_000).map { CGPoint(x: Double($0), y: 0) }
        let simplified = InkGeometry.simplify(straight)
        XCTAssertEqual(simplified.first, straight.first)
        XCTAssertEqual(simplified.last, straight.last)
        XCTAssertEqual(simplified.count, 13, "the ends of its 12 windows")
    }

    // MARK: What the bridge takes

    /// A stroke longer than the bridge takes (10 000 points) becomes pieces that join: each one
    /// starts where the one before ended, so the line drawn has no gap.
    func testAStrokeLongerThanTheBridgeTakesIsSplitIntoPiecesThatJoin() {
        let long = (0..<25_000).map { CGPoint(x: Double($0 % 500), y: Double($0 / 500)) }
        let pieces = InkGeometry.withinLimits(long)
        XCTAssertEqual(pieces.count, 3)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= InkGeometry.maxStrokePoints })
        XCTAssertEqual(pieces[0].first, long.first)
        XCTAssertEqual(pieces[0].last, pieces[1].first)
        XCTAssertEqual(pieces[1].last, pieces[2].first)
        XCTAssertEqual(pieces[2].last, long.last)
        XCTAssertEqual(pieces.map(\.count).reduce(0, +) - (pieces.count - 1), long.count, "every point, the joins counted once")
    }

    /// Points the bridge would refuse (beyond ±57 600 points, or not finite) do not make the drawing
    /// fail: far points are brought within reach, and points that are not numbers are left out.
    func testPointsOutOfReachAreBroughtWithinIt() {
        let pieces = InkGeometry.withinLimits([CGPoint(x: -100_000, y: 10), CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 20, y: 90_000)])
        XCTAssertEqual(pieces, [[CGPoint(x: -57_600, y: 10), CGPoint(x: 20, y: 57_600)]])
        XCTAssertEqual(InkGeometry.withinLimits([CGPoint(x: CGFloat.infinity, y: 0)]), [])
    }

    /// A drawing with more strokes or points than one annotation may have (500 strokes, 100 000
    /// points) is cut into several, none over either limit, every stroke in one of them, in order.
    func testADrawingOverTheBridgesLimitsIsCutIntoSeveral() {
        let many = (0..<1_200).map { i in [CGPoint(x: Double(i), y: 0), CGPoint(x: Double(i), y: 10)] }
        let drawings = InkGeometry.drawings(many)
        XCTAssertEqual(drawings.map(\.count), [500, 500, 200])
        XCTAssertEqual(Array(drawings.joined()), many)
        let heavy = (0..<25).map { i in (0..<9_000).map { CGPoint(x: Double($0), y: Double(i)) } }
        let byPoints = InkGeometry.drawings(heavy)
        XCTAssertEqual(byPoints.map(\.count), [11, 11, 3])
        XCTAssertTrue(byPoints.allSatisfy { $0.map(\.count).reduce(0, +) <= InkGeometry.maxDrawingPoints })
        XCTAssertEqual(InkGeometry.drawings([[], []]), [], "empty strokes are left out")
    }

    /// A stroke more than one drawing may hold (only one not kept within the limits first) is a drawing
    /// of its own: no empty drawing comes before it.
    func testNoDrawingIsEmpty() {
        let huge = (0..<150_000).map { CGPoint(x: Double($0 % 1_000), y: Double($0 / 1_000)) }
        let short = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        let drawings = InkGeometry.drawings([huge, short])
        XCTAssertFalse(drawings.contains { $0.isEmpty })
        XCTAssertEqual(drawings.map(\.count), [1, 1])
        XCTAssertEqual(InkGeometry.drawings([short, huge]).map(\.count), [1, 1])
    }

    func testTheLineWidthIsOneTheBridgeTakes() {
        XCTAssertEqual(InkGeometry.lineWidth(2), 2)
        XCTAssertEqual(InkGeometry.lineWidth(0), 0.1)
        XCTAssertEqual(InkGeometry.lineWidth(80), 50)
        XCTAssertEqual(InkGeometry.lineWidth(.nan), 2, "not a number: the tools' starting width")
    }

    // MARK: A drawing's strokes

    /// A stroke drawn on a canvas comes out in page points, with the stroke's own transform applied,
    /// through its first and last points, and simplified.
    func testTheStrokesOfADrawingAreInPagePoints() throws {
        // A straight line on the canvas from (10, 20) to (110, 20), moved 5 down by its transform.
        var stroke = Self.stroke((0...100).map { CGPoint(x: 10 + Double($0), y: 20) })
        stroke.transform = CGAffineTransform(translationX: 0, y: 5)
        let strokes = InkGeometry.strokes(of: PKDrawing(strokes: [stroke]), canvasOrigin: CGPoint(x: 1, y: 2), pointsPerCanvasPoint: 2)
        XCTAssertEqual(strokes.count, 1)
        let line = try XCTUnwrap(strokes.first)
        XCTAssertEqual(line.count, 2, "a straight line is its two ends")
        let first = try XCTUnwrap(line.first), last = try XCTUnwrap(line.last)
        XCTAssertEqual(first.x, 10 * 2 + 1, accuracy: 0.5)
        XCTAssertEqual(first.y, 25 * 2 + 2, accuracy: 0.5)
        XCTAssertEqual(last.x, 110 * 2 + 1, accuracy: 0.5)
        XCTAssertEqual(last.y, 25 * 2 + 2, accuracy: 0.5)
    }

    /// A tap is a stroke of one point: a dot.
    func testATapIsADot() throws {
        let strokes = InkGeometry.strokes(of: PKDrawing(strokes: [Self.stroke([CGPoint(x: 30, y: 40)])]), canvasOrigin: .zero, pointsPerCanvasPoint: 1)
        XCTAssertEqual(strokes.count, 1)
        let dot = try XCTUnwrap(strokes.first)
        XCTAssertEqual(dot.count, 1)
        XCTAssertEqual(try XCTUnwrap(dot.first).x, 30, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(dot.first).y, 40, accuracy: 0.5)
    }

    // MARK: The model

    func testInkCommitsAsOneUndoStep() async throws {
        let (m, u) = try makeModel()
        let made = await m.addInk(page: 0, strokes: [[CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40)], [CGPoint(x: 10, y: 50), CGPoint(x: 60, y: 80)]])
        XCTAssertTrue(made)
        XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).map(\.kind), [.ink]); XCTAssertEqual(u.undoActionName, Strings.actionAddAnnotation)
    }

    /// The drawing is made in Draw's colour, where it was drawn, and one undo takes it back.
    func testInkIsMadeInDrawsStyleWhereItWasDrawn() async throws {
        let (m, u) = try makeModel()
        m.toolStyles[.ink] = ToolStyle(color: RGBA(r: 0, g: 0.4, b: 1), width: 4, fontSize: 14, fill: false)
        let made = await m.addInk(page: 0, strokes: [[CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 150)]])
        XCTAssertTrue(made)
        let ink = try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).first)
        Self.assertBox(ink.rect, isAround: CGRect(x: 100, y: 100, width: 100, height: 50), width: 4)
        let colour = try XCTUnwrap(ink.color)
        XCTAssertEqual(colour.blue, 1, accuracy: 0.01)
        XCTAssertEqual(colour.green, 0.4, accuracy: 0.01)
        u.undo(); await m.settle()
        XCTAssertTrue(m.annotationIndex.annotations(onPage: 0).isEmpty)
    }

    /// A drawing past what one annotation may hold is still made, as several annotations in one
    /// change: one undo takes it all back.
    func testADrawingOverTheBridgesLimitsIsStillOneChange() async throws {
        let (m, u) = try makeModel()
        // 700 short upright strokes, in two rows: more than the 500 one annotation may hold.
        let strokes: [[CGPoint]] = (0..<700).map { (i: Int) -> [CGPoint] in
            let x = CGFloat(50 + i % 400), top = CGFloat(50 + (i / 400) * 20)
            return [CGPoint(x: x, y: top), CGPoint(x: x, y: top + 10)]
        }
        let made = await m.addInk(page: 0, strokes: strokes)
        XCTAssertTrue(made)
        XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).map(\.kind), [.ink, .ink])
        u.undo(); await m.settle()
        XCTAssertTrue(m.annotationIndex.annotations(onPage: 0).isEmpty)
        XCTAssertFalse(u.canUndo)
    }

    func testNoStrokesMakeNoChange() async throws {
        let (m, u) = try makeModel()
        let made = await m.addInk(page: 0, strokes: [[]])
        XCTAssertFalse(made)
        XCTAssertFalse(u.canUndo)
        XCTAssertNil(m.failure)
    }

    /// Ink is placed in view space: drawn before a turn of its page that is still on its way, it is
    /// refused as stale, and the reader is told it was not added, and why; nothing is left to undo
    /// but the turn.
    func testInkDrawnBeforeATurnOfItsPageIsRefusedAsStale() async throws {
        let (m, u) = try makeModel()
        await m.settle()
        let drawnAt = m.revision
        let rotate = m.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        let made = await m.addInk(page: 0, strokes: [[CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40)]], drawnAt: drawnAt)
        let rotated = await rotate.value
        XCTAssertTrue(rotated); XCTAssertFalse(made)
        XCTAssertEqual(m.failure?.message, Strings.drawingNotAdded)
        XCTAssertTrue(m.annotationIndex.annotations(onPage: 0).isEmpty)
        u.undo(); await m.settle()
        XCTAssertFalse(u.canUndo, "the refused drawing left nothing to undo")
    }

    /// On a page turned by `/Rotate 90` the drawing comes back where it was drawn, in view space.
    func testInkOnATurnedPageComesBackWhereItWasDrawn() async throws {
        let (m, _) = try makeModel(fixture: "rotated")
        await m.settle()
        XCTAssertEqual(m.pages[0].rotationDegrees, 90)
        let made = await m.addInk(page: 0, strokes: [(0...20).map { CGPoint(x: 100 + 5 * Double($0), y: 100 + 2.5 * Double($0)) }])
        XCTAssertTrue(made)
        let ink = try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).first)
        Self.assertBox(ink.rect, isAround: CGRect(x: 100, y: 100, width: 100, height: 50), width: 2)
    }

    /// `box` (an ink annotation's) is around `span`, the box of its strokes: centred on it, within
    /// 0.5 points, and with a margin of half the line `width` and up to 2 points more on each side
    /// (the engine keeps the line from being clipped).
    static func assertBox(_ box: Rect, isAround span: CGRect, width: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let rect = CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
        XCTAssertEqual(rect.midX, span.midX, accuracy: 0.5, "\(rect)", file: file, line: line)
        XCTAssertEqual(rect.midY, span.midY, accuracy: 0.5, "\(rect)", file: file, line: line)
        for margin in [span.minX - rect.minX, span.minY - rect.minY, rect.maxX - span.maxX, rect.maxY - span.maxY] {
            XCTAssertGreaterThanOrEqual(margin, width / 2 - 0.5, "\(rect)", file: file, line: line)
            XCTAssertLessThanOrEqual(margin, width / 2 + 2.5, "\(rect)", file: file, line: line)
        }
    }

    // MARK: Helpers

    /// A stroke through `points` (canvas points), as PencilKit would record one.
    static func stroke(_ points: [CGPoint]) -> PKStroke {
        let controlPoints = points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: TimeInterval(index) / 120, size: CGSize(width: 2, height: 2),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.monoline, color: .black), path: PKStrokePath(controlPoints: controlPoints, creationDate: Date()))
    }
}
