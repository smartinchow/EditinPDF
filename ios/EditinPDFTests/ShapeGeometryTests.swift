import EditinPDFCore
import PDFKit
import UIKit
import XCTest
@testable import EditinPDF

/// Rectangles, ovals, lines and arrows dragged out on a page, text boxes typed on it and notes stuck
/// to it: where they go (`ShapeGeometry`), and the changes the model makes of them.
@MainActor
final class ShapeGeometryTests: XCTestCase {
    let letter = CGSize(width: 612, height: 792)

    // MARK: Where they go

    func testDragBecomesANormalisedRectInsideThePage() {
        let r = ShapeGeometry.rect(from: CGPoint(x: 300, y: 300), to: CGPoint(x: 100, y: 900), pageSize: CGSize(width: 612, height: 792))
        XCTAssertEqual(r, CGRect(x: 100, y: 300, width: 200, height: 492))
        XCTAssertNil(ShapeGeometry.rect(from: .zero, to: CGPoint(x: 4, y: 40), pageSize: CGSize(width: 612, height: 792)))
        XCTAssertNil(ShapeGeometry.line(from: .zero, to: CGPoint(x: 3, y: 3), pageSize: CGSize(width: 612, height: 792)))
    }

    /// A line keeps to the page at both ends, and is a line once it is `minimumSide` long.
    func testALineIsKeptToThePage() throws {
        let line = try XCTUnwrap(ShapeGeometry.line(from: CGPoint(x: -20, y: 100), to: CGPoint(x: 700, y: 900), pageSize: letter))
        XCTAssertEqual(line.0, CGPoint(x: 0, y: 100))
        XCTAssertEqual(line.1, CGPoint(x: 612, y: 792))
        XCTAssertNotNil(ShapeGeometry.line(from: .zero, to: CGPoint(x: 8, y: 0), pageSize: letter))
        XCTAssertNil(ShapeGeometry.line(from: .zero, to: CGPoint(x: 7.9, y: 0), pageSize: letter))
    }

    /// Each shape tool's drag is its own shape; the others draw none.
    func testEachShapeToolDrawsItsShape() {
        let a = CGPoint(x: 100, y: 100), b = CGPoint(x: 200, y: 150)
        let box = CGRect(x: 100, y: 100, width: 100, height: 50)
        XCTAssertEqual(ShapeGeometry.draft(of: .rectangle, from: a, to: b, pageSize: letter), .rect(box, oval: false))
        XCTAssertEqual(ShapeGeometry.draft(of: .oval, from: a, to: b, pageSize: letter), .rect(box, oval: true))
        XCTAssertEqual(ShapeGeometry.draft(of: .line, from: a, to: b, pageSize: letter), .line(from: a, to: b, arrow: false))
        XCTAssertEqual(ShapeGeometry.draft(of: .arrow, from: a, to: b, pageSize: letter), .line(from: a, to: b, arrow: true))
        for tool in [Tool.select, .highlight, .ink, .textBox, .note, .eraser] {
            XCTAssertNil(ShapeGeometry.draft(of: tool, from: a, to: b, pageSize: letter), "\(tool)")
            XCTAssertFalse(tool.drawsShape, "\(tool)")
        }
        XCTAssertEqual(Tool.allCases.filter(\.drawsShape), [.rectangle, .oval, .line, .arrow])
        XCTAssertEqual(Tool.allCases.filter(\.placesByTap), [.textBox, .note])
    }

    /// A text box is as wide as its longest line and 8 points more, 60 at least, and stops at the
    /// page's right edge; as tall as its lines at 1.25 times the size, and 8 points more.
    func testATextBoxIsAsBigAsItsText() {
        let font = ShapeGeometry.textFont(ofSize: 14)
        let longest = ("Hello there, world" as NSString).size(withAttributes: [.font: font]).width
        let two = ShapeGeometry.textBoxRect(at: CGPoint(x: 72, y: 100), text: "Hi\nHello there, world", fontSize: 14, pageSize: letter)
        XCTAssertEqual(two.origin, CGPoint(x: 72, y: 100))
        XCTAssertEqual(two.width, longest + 8, accuracy: 0.01)
        XCTAssertEqual(two.height, 2 * 14 * 1.25 + 8, accuracy: 0.01)

        let short = ShapeGeometry.textBoxRect(at: CGPoint(x: 72, y: 100), text: "Hi", fontSize: 14, pageSize: letter)
        XCTAssertEqual(short.width, 60, "60 points at least")
        XCTAssertEqual(short.height, 14 * 1.25 + 8, accuracy: 0.01)
        let empty = ShapeGeometry.textBoxRect(at: CGPoint(x: 72, y: 100), text: "", fontSize: 14, pageSize: letter)
        XCTAssertEqual(empty.size, short.size, "an empty box is one line")

        // Near the right edge it stops there, and the text runs onto more lines.
        let edge = ShapeGeometry.textBoxRect(at: CGPoint(x: 500, y: 100), text: "Hello there, world", fontSize: 14, pageSize: letter)
        XCTAssertEqual(edge.maxX, 612, accuracy: 0.01)
        XCTAssertGreaterThan(edge.height, 14 * 1.25 + 8, "the text wraps within the page")
    }

    /// Where a text box tapped near the page's right or bottom edge starts: far enough in for its
    /// least width and its first line.
    func testATextBoxStartsWhereItFitsOnThePage() {
        XCTAssertEqual(ShapeGeometry.textBoxOrigin(at: CGPoint(x: 72, y: 100), fontSize: 14, pageSize: letter), CGPoint(x: 72, y: 100))
        let corner = ShapeGeometry.textBoxOrigin(at: CGPoint(x: 600, y: 790), fontSize: 14, pageSize: letter)
        XCTAssertEqual(corner.x, 612 - 60, accuracy: 0.01)
        XCTAssertEqual(corner.y, 792 - (14 * 1.25 + 8), accuracy: 0.01)
        XCTAssertEqual(ShapeGeometry.textBoxOrigin(at: CGPoint(x: -5, y: -5), fontSize: 14, pageSize: letter), .zero)
    }

    /// A note's icon goes where the finger went down, its top-left there, kept wholly on the page.
    func testANoteIsKeptOnThePage() {
        XCTAssertEqual(ShapeGeometry.noteBox(at: CGPoint(x: 200, y: 300), pageSize: letter), CGPoint(x: 200, y: 300))
        XCTAssertEqual(ShapeGeometry.noteBox(at: CGPoint(x: 611, y: 791), pageSize: letter), CGPoint(x: 592, y: 772))
        XCTAssertEqual(ShapeGeometry.noteBox(at: CGPoint(x: -3, y: -3), pageSize: letter), .zero)
    }

    /// The bridge's colours have no alpha: a fill is the line's colour mixed three quarters of the way
    /// to white.
    func testAFillIsTheColourMixedTowardWhite() {
        XCTAssertEqual(ShapeGeometry.fill(for: RGBA(r: 0, g: 0.4, b: 1)), RGBA(r: 0.75, g: 0.85, b: 1))
        XCTAssertEqual(ShapeGeometry.fill(for: RGBA(r: 1, g: 1, b: 1)), RGBA(r: 1, g: 1, b: 1))
    }

    /// What the bridge takes: boxes at least a point each way, points within 57,600 points of the
    /// origin, text 4 to 144 points.
    func testTheBridgesLimits() {
        XCTAssertTrue(ShapeGeometry.isDrawable(CGRect(x: 0, y: 0, width: 1, height: 1)))
        XCTAssertFalse(ShapeGeometry.isDrawable(CGRect(x: 0, y: 0, width: 0.5, height: 10)))
        XCTAssertFalse(ShapeGeometry.isDrawable(CGRect(x: 57_590, y: 0, width: 20, height: 20)))
        XCTAssertFalse(ShapeGeometry.isDrawable(CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20)))
        XCTAssertTrue(ShapeGeometry.isInReach(CGPoint(x: -57_600, y: 57_600)))
        XCTAssertFalse(ShapeGeometry.isInReach(CGPoint(x: 57_601, y: 0)))
        XCTAssertFalse(ShapeGeometry.isInReach(CGPoint(x: 0, y: CGFloat.infinity)))
        XCTAssertTrue(ShapeGeometry.isDrawableLine(from: .zero, to: CGPoint(x: 1, y: 0)))
        XCTAssertFalse(ShapeGeometry.isDrawableLine(from: .zero, to: CGPoint(x: 0.5, y: 0)))
        XCTAssertEqual(ShapeGeometry.fontSize(2), 4)
        XCTAssertEqual(ShapeGeometry.fontSize(500), 144)
        XCTAssertEqual(ShapeGeometry.fontSize(.nan), 14)
        XCTAssertEqual(ShapeGeometry.fontSize(18), 18)
    }

    /// The arrow's head: two strokes back from the tip at 30° either side of the line, 6 points and 3
    /// times the line's width long, as the engine draws it.
    func testTheArrowHeadIsTheEnginesOpenArrow() throws {
        let (a, b) = ShapeGeometry.arrowHead(from: CGPoint(x: 0, y: 100), to: CGPoint(x: 100, y: 100), width: 2)
        let length: CGFloat = 6 + 3 * 2
        for wing in [a, b] {
            XCTAssertEqual(hypot(wing.x - 100, wing.y - 100), length, accuracy: 0.001)
            XCTAssertEqual(wing.x, 100 - length * cos(.pi / 6), accuracy: 0.001)
        }
        XCTAssertEqual(abs(a.y - 100), length * sin(.pi / 6), accuracy: 0.001)
        XCTAssertEqual(a.y + b.y, 200, accuracy: 0.001, "one either side")
    }

    // MARK: The model

    func testTextBoxIsRefusedOnTurnedPagesAndAddedOnUprightOnes() async throws {
        let (m, _) = try makeModel(fixture: "rotated")
        XCTAssertFalse(m.canAddTextBox(onPage: 0))
        let (upright, _) = try makeModel()
        let made = await upright.addTextBox(page: 0, at: CGPoint(x: 72, y: 72), text: "Hi")
        XCTAssertTrue(made)
        XCTAssertEqual(upright.annotationIndex.annotations(onPage: 0).first?.contents, "Hi")
    }

    func testNoteIsPlacedWhereTapped() async throws {
        let (m, _) = try makeModel()
        let made = await m.addNote(page: 0, at: CGPoint(x: 200, y: 300), contents: "Check")
        XCTAssertTrue(made)
        let n = try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).first)
        XCTAssertEqual(n.rect.x, 200, accuracy: 1); XCTAssertEqual(n.rect.y, 300, accuracy: 1)
    }

    /// Once the permissions are read: a text box may go on an upright page, not on a turned one, and
    /// is refused there, with the reason, before the engine is asked.
    func testATextBoxOnATurnedPageIsRefusedWithItsReason() async throws {
        let (turned, u) = try makeModel(fixture: "rotated")
        await turned.settle()
        XCTAssertEqual(turned.pages[0].rotationDegrees, 90)
        XCTAssertFalse(turned.canAddTextBox(onPage: 0))
        XCTAssertFalse(turned.canAddTextBox(onPage: 5), "a page the document does not have")
        let made = await turned.addTextBox(page: 0, at: CGPoint(x: 72, y: 72), text: "Sideways")
        XCTAssertFalse(made)
        XCTAssertEqual(turned.failure?.message, Strings.textBoxNeedsUprightPage)
        XCTAssertTrue(turned.annotationIndex.annotations(onPage: 0).isEmpty)
        XCTAssertFalse(u.canUndo)

        let (upright, _) = try makeModel()
        await upright.settle()
        XCTAssertTrue(upright.canAddTextBox(onPage: 0))
    }

    /// Even before the permissions are read, a text box is not put on a turned page.
    func testATextBoxIsNotPutOnATurnedPageBeforeThePermissionsAreRead() async throws {
        let (turned, _) = try makeModel(fixture: "rotated")
        let made = await turned.addTextBox(page: 0, at: CGPoint(x: 72, y: 72), text: "Sideways")
        XCTAssertFalse(made)
        XCTAssertEqual(turned.failure?.message, Strings.textBoxNeedsUprightPage)
        XCTAssertTrue(turned.annotationIndex.annotations(onPage: 0).isEmpty)
    }

    /// A text box is made in Text Box's colour and size, in the box `textBoxRect` gives, as one change
    /// that one undo takes back. What is typed after the last character is not kept.
    func testATextBoxIsMadeInItsToolsStyle() async throws {
        let (m, u) = try makeModel()
        m.toolStyles[.textBox] = ToolStyle(color: RGBA(r: 0, g: 0.4, b: 1), width: 2, fontSize: 18, fill: false)
        let made = await m.addTextBox(page: 0, at: CGPoint(x: 100, y: 200), text: "Two\nlines\n\n")
        XCTAssertTrue(made)
        let box = try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).first)
        XCTAssertEqual(box.kind, .textBox)
        XCTAssertEqual(box.contents, "Two\nlines")
        let expected = ShapeGeometry.textBoxRect(at: CGPoint(x: 100, y: 200), text: "Two\nlines", fontSize: 18, pageSize: letter)
        XCTAssertEqual(box.rect.x, expected.minX, accuracy: 0.5); XCTAssertEqual(box.rect.y, expected.minY, accuracy: 0.5)
        XCTAssertEqual(box.rect.width, expected.width, accuracy: 0.5); XCTAssertEqual(box.rect.height, expected.height, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(box.color).blue, 1, accuracy: 0.01)
        XCTAssertEqual(u.undoActionName, Strings.actionAddAnnotation)
        u.undo(); await m.settle()
        XCTAssertTrue(m.annotationIndex.annotations(onPage: 0).isEmpty)
    }

    /// Nothing typed, or only spaces and new lines: no text box, no change, nothing to tell.
    func testAnEmptyTextBoxIsNotAdded() async throws {
        let (m, u) = try makeModel()
        for text in ["", "   ", "\n\n", " \n "] {
            let made = await m.addTextBox(page: 0, at: CGPoint(x: 72, y: 72), text: text)
            XCTAssertFalse(made, "\(text.debugDescription)")
        }
        XCTAssertFalse(u.canUndo)
        XCTAssertNil(m.failure)
        XCTAssertTrue(m.annotationIndex.annotations(onPage: 0).isEmpty)
    }

    /// A style kept from before with a size the bridge does not take is held to one it does.
    func testATextSizeOutsideTheBridgesRangeIsHeldToIt() async throws {
        let (m, _) = try makeModel()
        m.toolStyles[.textBox] = ToolStyle(color: RGBA(r: 0, g: 0, b: 0), width: 2, fontSize: 400, fill: false)
        let made = await m.addTextBox(page: 0, at: CGPoint(x: 72, y: 72), text: "Big")
        XCTAssertTrue(made)
        let box = try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).first)
        XCTAssertEqual(box.rect.height, 144 * 1.25 + 8, accuracy: 0.5)
    }

    /// Each shape is made in its tool's colour and width where it was dragged: a rectangle or an oval
    /// with a fill when its style says so, a line, an arrow (a line with an arrow head). One undo each.
    func testShapesAreMadeInTheirToolsStyle() async throws {
        let (m, u) = try makeModel()
        m.toolStyles[.rectangle] = ToolStyle(color: RGBA(r: 0, g: 0.4, b: 1), width: 3, fontSize: 14, fill: true)
        let box = CGRect(x: 100, y: 100, width: 200, height: 100)
        let rect = await m.addShape(page: 0, draft: .rect(box, oval: false))
        let oval = await m.addShape(page: 0, draft: .rect(box.offsetBy(dx: 0, dy: 200), oval: true))
        let line = await m.addShape(page: 0, draft: .line(from: CGPoint(x: 100, y: 500), to: CGPoint(x: 300, y: 550), arrow: false))
        let arrow = await m.addShape(page: 0, draft: .line(from: CGPoint(x: 100, y: 600), to: CGPoint(x: 300, y: 650), arrow: true))
        XCTAssertEqual([rect, oval, line, arrow], [true, true, true, true])
        let made = m.annotationIndex.annotations(onPage: 0)
        XCTAssertEqual(made.map(\.kind), [.rectangle, .oval, .line, .line])
        let square = made[0]
        XCTAssertEqual(square.rect.x, 100, accuracy: 3); XCTAssertEqual(square.rect.y, 100, accuracy: 3)
        XCTAssertEqual(square.rect.width, 200, accuracy: 6); XCTAssertEqual(square.rect.height, 100, accuracy: 6)
        XCTAssertEqual(try XCTUnwrap(square.color).green, 0.4, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(made[1].color).red, 0.9, accuracy: 0.01, "the oval in its own tool's colour")
        u.undo(); await m.settle()
        XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).map(\.kind), [.rectangle, .oval, .line], "one undo, one shape")
    }

    /// The fill is written to the file: the style's colour, mixed toward white.
    func testAFilledShapesFillIsInTheFile() async throws {
        let (m, _) = try makeModel()
        m.toolStyles[.oval] = ToolStyle(color: RGBA(r: 0, g: 0.4, b: 1), width: 2, fontSize: 14, fill: true)
        let made = await m.addShape(page: 0, draft: .rect(CGRect(x: 100, y: 100, width: 100, height: 100), oval: true))
        XCTAssertTrue(made)
        let saved = try XCTUnwrap(m.document()).save(mode: .incremental)
        let interior = try XCTUnwrap(PDFDocument(data: saved)?.page(at: 0)?.annotations.first?.interiorColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        interior.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 0.75, accuracy: 0.01); XCTAssertEqual(g, 0.85, accuracy: 0.01); XCTAssertEqual(b, 1, accuracy: 0.01)
    }

    /// What the bridge would refuse is refused before it is asked: the reader is told the change was
    /// not made, and nothing is left to undo.
    func testWhatTheBridgeRefusesIsRefusedBeforeIt() async throws {
        let (m, u) = try makeModel()
        let tooSmall = await m.addShape(page: 0, draft: .rect(CGRect(x: 10, y: 10, width: 0.5, height: 40), oval: false))
        XCTAssertFalse(tooSmall)
        XCTAssertEqual(m.failure?.title, Strings.editFailed)
        m.failure = nil
        let outOfReach = await m.addShape(page: 0, draft: .line(from: .zero, to: CGPoint(x: 60_000, y: 0), arrow: true))
        XCTAssertFalse(outOfReach)
        XCTAssertNotNil(m.failure)
        m.failure = nil
        let notANumber = await m.addNote(page: 0, at: CGPoint(x: CGFloat.nan, y: 10), contents: "x")
        XCTAssertFalse(notANumber)
        XCTAssertNotNil(m.failure)
        XCTAssertFalse(u.canUndo)
        XCTAssertTrue(m.annotationIndex.annotations(onPage: 0).isEmpty)
    }

    /// A line width kept from before that the bridge does not take is held to one it does.
    func testALineWidthOutsideTheBridgesRangeIsHeldToIt() async throws {
        let (m, _) = try makeModel()
        m.toolStyles[.line] = ToolStyle(color: RGBA(r: 0, g: 0, b: 0), width: 90, fontSize: 14, fill: false)
        let made = await m.addShape(page: 0, draft: .line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100), arrow: false))
        XCTAssertTrue(made)
    }

    /// On a page turned by `/Rotate 90`, a rectangle, a line and a note come back where they were put,
    /// in view space.
    func testShapesAndNotesOnATurnedPageComeBackWhereTheyWerePut() async throws {
        let (m, _) = try makeModel(fixture: "rotated")
        await m.settle()
        XCTAssertEqual(m.pages[0].rotationDegrees, 90)
        let box = CGRect(x: 100, y: 150, width: 300, height: 120)
        let rect = await m.addShape(page: 0, draft: .rect(box, oval: false))
        let line = await m.addShape(page: 0, draft: .line(from: CGPoint(x: 500, y: 100), to: CGPoint(x: 700, y: 400), arrow: true))
        let note = await m.addNote(page: 0, at: CGPoint(x: 600, y: 500), contents: "Turned")
        XCTAssertEqual([rect, line, note], [true, true, true])
        let made = m.annotationIndex.annotations(onPage: 0)
        XCTAssertEqual(Set(made.map(\.kind)), [.rectangle, .line, .note])
        let square = try XCTUnwrap(made.first { $0.kind == .rectangle }).rect
        XCTAssertEqual(square.x, 100, accuracy: 2); XCTAssertEqual(square.y, 150, accuracy: 2)
        XCTAssertEqual(square.width, 300, accuracy: 4); XCTAssertEqual(square.height, 120, accuracy: 4)
        let span = try XCTUnwrap(made.first { $0.kind == .line }).rect
        XCTAssertLessThanOrEqual(span.x, 500); XCTAssertLessThanOrEqual(span.y, 100)
        XCTAssertGreaterThanOrEqual(span.x + span.width, 700); XCTAssertGreaterThanOrEqual(span.y + span.height, 400)
        XCTAssertLessThan(span.width, 200 + 30, "around the line, not turned"); XCTAssertLessThan(span.height, 300 + 30)
        let icon = try XCTUnwrap(made.first { $0.kind == .note }).rect
        XCTAssertEqual(icon.x, 600, accuracy: 1); XCTAssertEqual(icon.y, 500, accuracy: 1)
    }

    /// A shape is placed in view space: dragged out before a turn of its page that is still on its
    /// way, it is refused as stale, and the reader told; nothing is left to undo but the turn.
    func testAShapeDrawnBeforeATurnOfItsPageIsRefusedAsStale() async throws {
        let (m, u) = try makeModel()
        await m.settle()
        let drawnAt = m.revision
        let rotate = m.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        let made = await m.enqueueShape(page: 0, draft: .rect(CGRect(x: 10, y: 10, width: 50, height: 50), oval: false), workedOutAt: drawnAt).value
        let rotated = await rotate.value
        XCTAssertTrue(rotated); XCTAssertFalse(made)
        XCTAssertEqual(m.failure?.message, Strings.documentChangedTryAgain)
        XCTAssertTrue(m.annotationIndex.annotations(onPage: 0).isEmpty)
        u.undo(); await m.settle()
        XCTAssertFalse(u.canUndo, "the refused shape left nothing to undo")
    }

    /// A note's text is changed in place: still one note, with the new text; undo puts the old back.
    func testANotesTextIsChangedInPlace() async throws {
        let (m, u) = try makeModel()
        let added = await m.addNote(page: 0, at: CGPoint(x: 200, y: 300), contents: "Check")
        XCTAssertTrue(added)
        let note = try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).first)
        let draft = NoteDraft(page: 0, point: CGPoint(x: note.rect.x, y: note.rect.y),
                              existing: AnnotationRef(page: 0, index: note.index), text: "Check", revision: m.revision)
        let saved = await m.saveNote(draft, text: "Checked")
        XCTAssertTrue(saved)
        XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).map(\.contents), ["Checked"])
        XCTAssertEqual(u.undoActionName, Strings.actionEditAnnotation)
        u.undo(); await m.settle()
        XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).map(\.contents), ["Check"])

        // The same text again is no change.
        let unchanged = await m.saveNote(NoteDraft(page: 0, point: .zero, existing: AnnotationRef(page: 0, index: note.index),
                                                   text: "Check", revision: m.revision), text: "Check")
        XCTAssertFalse(unchanged)
    }

    /// A new note from the sheet goes where it was tapped, in Note's colour; an empty one is not added.
    func testANewNoteFromTheSheetIsAddedUnlessItIsEmpty() async throws {
        let (m, u) = try makeModel()
        let empty = await m.saveNote(NoteDraft(page: 0, point: CGPoint(x: 50, y: 60), existing: nil, text: "", revision: m.revision), text: "  \n")
        XCTAssertFalse(empty)
        XCTAssertFalse(u.canUndo)
        let saved = await m.saveNote(NoteDraft(page: 0, point: CGPoint(x: 50, y: 60), existing: nil, text: "", revision: m.revision), text: "Ask")
        XCTAssertTrue(saved)
        let note = try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).first)
        XCTAssertEqual(note.kind, .note); XCTAssertEqual(note.contents, "Ask")
        XCTAssertEqual(note.rect.x, 50, accuracy: 1); XCTAssertEqual(note.rect.y, 60, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(note.color).green, 0.8, accuracy: 0.01)
    }

    /// A note sheet opened before an annotation before it on the page was deleted names another one
    /// now: its save is refused as stale, and nothing changes.
    func testANoteEditedAcrossADeleteIsRefusedAsStale() async throws {
        let (m, _) = try makeModel()
        _ = await m.addNote(page: 0, at: CGPoint(x: 10, y: 10), contents: "First")
        _ = await m.addNote(page: 0, at: CGPoint(x: 100, y: 10), contents: "Second")
        let second = try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).last)
        let draft = NoteDraft(page: 0, point: .zero, existing: AnnotationRef(page: 0, index: second.index), text: "Second", revision: m.revision)
        let deleted = await m.perform(.deleteAnnotation(page: 0, index: 0), named: Strings.actionDeleteAnnotation, touching: [0])
        XCTAssertTrue(deleted)
        let saved = await m.saveNote(draft, text: "Changed")
        XCTAssertFalse(saved)
        XCTAssertEqual(m.failure?.message, Strings.documentChangedTryAgain)
        XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).map(\.contents), ["Second"])
    }
}
