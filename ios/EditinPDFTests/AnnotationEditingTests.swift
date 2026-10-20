import EditinPDFCore
import PencilKit
import UIKit
import XCTest
@testable import EditinPDF

/// Annotations already on the page: selecting one, moving it, deleting it and changing its text; the
/// eraser, which deletes what it touches; and the Comments list's rows. The model's side first, then
/// the touches (called the way the gestures call them, as in `ShapeDrawingTests`).
@MainActor
final class AnnotationEditingTests: XCTestCase {
    // MARK: The model

    /// The three rectangles one eraser stroke crosses, and not the fourth, are deleted in one step: a
    /// single `deleteAnnotations` of exactly their indexes (the bridge follows each to the annotation
    /// it is, so deleting one cannot make another index name something else), which one undo takes
    /// back whole.
    func testTheEraserDeletesExactlyWhatItTouchesInOneStep() async throws {
        let (m, u) = try makeModel()
        for x in [50.0, 150.0, 250.0] { _ = await m.addShape(page: 0, draft: .rect(CGRect(x: x, y: 100, width: 60, height: 60), oval: false)) }
        _ = await m.addShape(page: 0, draft: .rect(CGRect(x: 50, y: 400, width: 60, height: 60), oval: false))
        let path = [CGPoint(x: 60, y: 120), CGPoint(x: 260, y: 120)]
        let crossed = m.annotationIndex.annotations(onPage: 0).filter { $0.rect.y < 300 }.map(\.index).sorted()
        XCTAssertEqual(crossed.count, 3)
        XCTAssertEqual(m.eraseEdit(page: 0, along: path), .deleteAnnotations(page: 0, indices: crossed), "one edit, the three crossed")
        let erased = await m.erase(page: 0, along: path)
        XCTAssertTrue(erased)
        let left = m.annotationIndex.annotations(onPage: 0)
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left.first?.rect.y ?? 0, 400, accuracy: 0.5, "the one off the path stays")
        XCTAssertEqual(u.undoActionName, Strings.actionDeleteAnnotation)
        u.undo(); await m.settle(); XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).count, 4)   // one step
        u.undo(); await m.settle(); XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).count, 3, "then the fourth shape's add")
        XCTAssertNil(m.eraseEdit(page: 0, along: [CGPoint(x: 500, y: 700)]), "touching nothing, no edit")
    }

    func testMoveSelectedAnnotation() async throws {
        let (m, u) = try makeModel()
        _ = await m.addShape(page: 0, draft: .rect(CGRect(x: 100, y: 100, width: 50, height: 50), oval: false))
        let before = try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).first).rect
        m.selectAnnotation(page: 0, at: CGPoint(x: 120, y: 120))
        let moved = await m.moveSelectedAnnotation(by: CGSize(width: 30, height: 10))
        XCTAssertTrue(moved)
        let after = try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).first).rect
        XCTAssertEqual(after.x - before.x, 30, accuracy: 0.5); XCTAssertNil(m.selectedAnnotation)
        XCTAssertEqual(after.y - before.y, 10, accuracy: 0.5)
        XCTAssertEqual(u.undoActionName, Strings.actionMoveAnnotation)
        u.undo(); await m.settle()
        XCTAssertEqual(try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).first).rect.x, before.x, accuracy: 0.5)
    }

    func testCommentRowsAreInPageOrder() throws {
        let rows = DocumentModel.commentRows(AnnotationIndex([info(page: 1, index: 0, y: 10), info(page: 0, index: 2, y: 500), info(page: 0, index: 1, y: 20)]))
        XCTAssertEqual(rows.map(\.id), [AnnotationRef(page: 0, index: 1), AnnotationRef(page: 0, index: 2), AnnotationRef(page: 1, index: 0)])
    }

    /// A row carries at most 500 characters of an annotation's text and of its author's name: a file can
    /// hold megabytes of either.
    func testCommentRowsKeepTheStartOfALongText() throws {
        let long = String(repeating: "word ", count: 20_000)
        let note = annotation(page: 0, index: 0, kind: .note, contents: "\n  " + long, author: String(repeating: "A", count: 2_000))
        let row = try XCTUnwrap(DocumentModel.commentRows(AnnotationIndex([note])).first)
        let detail = try XCTUnwrap(row.detail)
        XCTAssertEqual(detail.count, 499, "500 characters, less the space they end on")
        XCTAssertTrue(detail.hasPrefix("word word"), "the blank before it is not counted")
        XCTAssertEqual(row.author?.count, DocumentModel.maxRowText)
    }

    /// A row is named for its kind; its text, without the blank around it, is its detail, and none
    /// when it has none. The author is the file's, shown as it is.
    func testCommentRowsNameTheKindAndShowTheText() {
        let note = annotation(page: 0, index: 0, kind: .note, contents: "  Check this\n", author: "Ann")
        let mark = annotation(page: 0, index: 1, kind: .highlight, contents: "", rect: CGRect(x: 0, y: 40, width: 10, height: 10))
        let odd = annotation(page: 0, index: 2, kind: .other(subtype: "Polygon"), rect: CGRect(x: 0, y: 80, width: 10, height: 10))
        let rows = DocumentModel.commentRows(AnnotationIndex([note, mark, odd]))
        XCTAssertEqual(rows.map(\.title), ["Note", "Highlight", "Comment"])
        XCTAssertEqual(rows.map(\.detail), ["Check this", nil, nil])
        XCTAssertEqual(rows.first?.author, "Ann")
        XCTAssertEqual(rows.first?.kind, .note)
        XCTAssertEqual(rows.first?.page, 0)
        XCTAssertEqual(rows.last?.rect, CGRect(x: 0, y: 80, width: 10, height: 10))
    }

    /// Every kind has its name in the list.
    func testEveryKindHasAName() {
        let kinds: [AnnotationKind] = [.note, .highlight, .underline, .strikeOut, .squiggly, .ink, .textBox, .rectangle, .oval, .line,
                                       .stamp, .other(subtype: "Polygon")]
        XCTAssertEqual(kinds.map(Strings.annotationKindName), ["Note", "Highlight", "Underline", "Strikethrough", "Squiggly", "Drawing",
                                                               "Text", "Rectangle", "Oval", "Line", "Stamp", "Comment"])
    }

    /// A touch selects the annotation on top under it, within the slop; one on none selects nothing.
    func testSelectingPicksTheTopmostOrNothing() async throws {
        let (m, _) = try makeModel()
        _ = await m.addShape(page: 0, draft: .rect(CGRect(x: 100, y: 100, width: 200, height: 200), oval: false))
        _ = await m.addShape(page: 0, draft: .rect(CGRect(x: 150, y: 150, width: 50, height: 50), oval: false))
        let top = try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).map(\.index).max())
        m.selectAnnotation(page: 0, at: CGPoint(x: 170, y: 170))
        XCTAssertEqual(m.selectedAnnotation, AnnotationRef(page: 0, index: top))
        XCTAssertEqual(m.selectedAnnotationPlace?.page, 0)
        m.selectAnnotation(page: 0, at: CGPoint(x: 500, y: 600))
        XCTAssertNil(m.selectedAnnotation)
        XCTAssertNil(m.selectedAnnotationPlace)
    }

    /// A move of less than a point, or with nothing selected, changes nothing and leaves nothing to undo.
    func testATinyMoveOrNoSelectionChangesNothing() async throws {
        let (m, u) = try makeModel()
        _ = await m.addShape(page: 0, draft: .rect(CGRect(x: 100, y: 100, width: 50, height: 50), oval: false))
        let unselected = await m.moveSelectedAnnotation(by: CGSize(width: 30, height: 10))
        XCTAssertFalse(unselected)
        m.selectAnnotation(page: 0, at: CGPoint(x: 120, y: 120))
        let tiny = await m.moveSelectedAnnotation(by: CGSize(width: 0.5, height: 0.5))
        XCTAssertFalse(tiny)
        XCTAssertNil(m.failure)
        XCTAssertEqual(u.undoActionName, Strings.actionAddAnnotation)
    }

    /// A move is a distance in view space: one handed over behind a turn of its page is refused as
    /// stale instead of moving the annotation the wrong way, and leaves nothing to undo.
    func testAMoveQueuedBehindATurnOfItsPageIsRefusedAsStale() async throws {
        let (m, u) = try makeModel()
        _ = await m.addShape(page: 0, draft: .rect(CGRect(x: 100, y: 100, width: 50, height: 50), oval: false))
        let before = try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).first).rect
        m.selectAnnotation(page: 0, at: CGPoint(x: 120, y: 120))
        let rotate = m.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        let moved = await m.moveSelectedAnnotation(by: CGSize(width: 30, height: 10))
        let rotated = await rotate.value
        XCTAssertTrue(rotated); XCTAssertFalse(moved)
        XCTAssertEqual(m.failure?.message, Strings.documentChangedTryAgain)
        // The first undo takes back the turn (the refused move left nothing to undo): the rectangle is
        // upright where it was drawn; the second takes the rectangle back, and nothing is left.
        u.undo(); await m.settle()
        let after = try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).first).rect
        XCTAssertEqual(m.pages[0].rotationDegrees, 0)
        XCTAssertEqual(after.x, before.x, accuracy: 0.5); XCTAssertEqual(after.y, before.y, accuracy: 0.5)
        u.undo(); await m.settle()
        XCTAssertTrue(m.annotationIndex.annotations(onPage: 0).isEmpty)
        XCTAssertFalse(u.canUndo, "the refused move left nothing to undo")
    }

    /// Delete takes the selected annotation off its page, as one change that one undo takes back.
    func testDeletingTheSelectedAnnotation() async throws {
        let (m, u) = try makeModel()
        _ = await m.addShape(page: 0, draft: .rect(CGRect(x: 100, y: 100, width: 50, height: 50), oval: false))
        _ = await m.addShape(page: 0, draft: .rect(CGRect(x: 300, y: 300, width: 50, height: 50), oval: true))
        m.selectAnnotation(page: 0, at: CGPoint(x: 320, y: 320))
        let deleted = await m.deleteSelectedAnnotation()
        XCTAssertTrue(deleted)
        XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).map(\.kind), [.rectangle])
        XCTAssertNil(m.selectedAnnotation)
        XCTAssertEqual(u.undoActionName, Strings.actionDeleteAnnotation)
        let nothing = await m.deleteSelectedAnnotation()
        XCTAssertFalse(nothing)
        u.undo(); await m.settle()
        XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).count, 2)
    }

    /// A note's text is changed in place, as one change; the same text changes nothing.
    func testSetContentsChangesTheTextOfANote() async throws {
        let (m, u) = try makeModel(fixture: "annotated")
        await m.settle()
        let note = try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).first { $0.kind == .note })
        let ref = AnnotationRef(page: 0, index: note.index)
        let same = await m.setContents(of: ref, to: note.contents ?? "")
        XCTAssertFalse(same)
        XCTAssertFalse(u.canUndo)
        let changed = await m.setContents(of: ref, to: "Done")
        XCTAssertTrue(changed)
        XCTAssertEqual(m.annotationIndex.annotation(ref)?.contents, "Done")
        XCTAssertEqual(u.undoActionName, Strings.actionEditAnnotation)
        u.undo(); await m.settle()
        XCTAssertEqual(m.annotationIndex.annotation(ref)?.contents, note.contents)
    }

    /// The eraser takes, at each point along its path, the annotation on top there that may be
    /// deleted: once each however often the path crosses it, in index order, none under a locked one
    /// that is on top (the lock is the file's), and none on another page.
    func testTheEraserTakesTheTopmostAnnotationUnderItsPathOnce() {
        let big = annotation(page: 0, index: 0, kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 300, height: 300))
        let small = annotation(page: 0, index: 2, kind: .rectangle, rect: CGRect(x: 100, y: 100, width: 50, height: 50))
        let locked = annotation(page: 0, index: 5, kind: .note, rect: CGRect(x: 200, y: 100, width: 50, height: 50), locked: true)
        let elsewhere = annotation(page: 1, index: 0, kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 300, height: 300))
        let index = AnnotationIndex([big, small, locked, elsewhere])
        let zigzag = [CGPoint(x: 110, y: 120), CGPoint(x: 140, y: 120), CGPoint(x: 110, y: 125), CGPoint(x: 140, y: 125)]
        XCTAssertEqual(index.erased(page: 0, along: zigzag, slop: 0).map(\.index), [2], "crossed back and forth, the small one once")
        XCTAssertEqual(index.erased(page: 0, along: [CGPoint(x: 210, y: 120), CGPoint(x: 240, y: 120)], slop: 0).map(\.index), [0],
                       "under the locked one, the one beneath")
        XCTAssertEqual(index.erased(page: 0, along: [CGPoint(x: 50, y: 120), CGPoint(x: 240, y: 120)], slop: 0).map(\.index), [0, 2])
        XCTAssertEqual(index.erased(page: 0, along: [CGPoint(x: 120, y: 120)], slop: 0).map(\.index), [2], "a single point")
        XCTAssertEqual(index.erased(page: 0, along: [CGPoint(x: 155, y: 120)], slop: 8).map(\.index), [2], "within the slop")
        XCTAssertTrue(index.erased(page: 0, along: [CGPoint(x: 400, y: 500)], slop: 8).isEmpty)
        XCTAssertTrue(index.erased(page: 0, along: [], slop: 8).isEmpty)
        XCTAssertTrue(index.erased(page: 3, along: zigzag, slop: 8).isEmpty)
    }

    /// A path whose pieces are each a finite length but whose whole length is not (points at the edge of
    /// what a number holds) touches nothing, and does not trap working out how many looks to take.
    func testAPathTooLongToMeasureErasesNothing() {
        let big = annotation(page: 0, index: 0, kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 300, height: 300))
        let index = AnnotationIndex([big])
        let huge = CGFloat.greatestFiniteMagnitude * 0.75
        XCTAssertTrue(index.erased(page: 0, along: [CGPoint(x: 10, y: 10), CGPoint(x: huge, y: 10), CGPoint(x: 10, y: 10)], slop: 8).isEmpty)
        XCTAssertEqual(index.erased(page: 0, along: [CGPoint(x: 10, y: 10), CGPoint(x: CGFloat.nan, y: 10)], slop: 8).map(\.index), [0],
                       "a point that is not a number is left out")
    }

    /// An eraser stroke over nothing makes no change, leaves nothing to undo and says nothing.
    func testErasingNothingChangesNothing() async throws {
        let (m, u) = try makeModel()
        _ = await m.addShape(page: 0, draft: .rect(CGRect(x: 100, y: 100, width: 50, height: 50), oval: false))
        let erased = await m.erase(page: 0, along: [CGPoint(x: 400, y: 500), CGPoint(x: 500, y: 600)])
        XCTAssertFalse(erased)
        XCTAssertNil(m.failure)
        XCTAssertEqual(u.undoActionName, Strings.actionAddAnnotation)
        XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).count, 1)
    }

    /// A delete or an eraser stroke handed over behind a change that numbers the page's annotations
    /// again is refused as stale rather than deleting another one.
    func testAnEraseBehindADeleteIsRefusedAsStale() async throws {
        let (m, u) = try makeModel()
        for x in [50.0, 150.0] { _ = await m.addShape(page: 0, draft: .rect(CGRect(x: x, y: 100, width: 60, height: 60), oval: false)) }
        m.selectAnnotation(page: 0, at: CGPoint(x: 60, y: 120))
        let delete = m.enqueueDelete(try XCTUnwrap(m.selectedAnnotation))
        let erased = await m.erase(page: 0, along: [CGPoint(x: 160, y: 120)])
        let deleted = await delete.value
        XCTAssertTrue(deleted); XCTAssertFalse(erased)
        XCTAssertEqual(m.failure?.message, Strings.documentChangedTryAgain)
        XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).count, 1, "the second rectangle is still there")
        // Undo takes back the delete, then the two rectangles: the refused stroke left nothing to undo.
        u.undo(); await m.settle()
        XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).count, 2)
        u.undo(); await m.settle()
        u.undo(); await m.settle()
        XCTAssertTrue(m.annotationIndex.annotations(onPage: 0).isEmpty)
        XCTAssertFalse(u.canUndo)
    }

    /// Picking another tool lets go of the selected annotation; Select keeps it.
    func testAnotherToolLetsGoOfTheSelection() async throws {
        let (m, _) = try makeModel()
        _ = await m.addShape(page: 0, draft: .rect(CGRect(x: 100, y: 100, width: 50, height: 50), oval: false))
        m.tool = .select
        m.selectAnnotation(page: 0, at: CGPoint(x: 120, y: 120))
        XCTAssertNotNil(m.selectedAnnotation)
        m.tool = .highlight
        XCTAssertNil(m.selectedAnnotation)
    }

    // MARK: Touches

    /// `pages` US Letter pages in a 400 x 800 view, `tool` picked, with an undo manager.
    func makeController(pages: Int = 3, tool: Tool? = .select, data: Data? = nil) async -> (PageScrollViewController, DocumentModel, UndoManager) {
        let model = isolatedModel(bytes: data ?? PageScrollViewControllerTests.letterPages(pages))
        let undoManager = UndoManager()
        model.undoManager = undoManager
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(origin: .zero, size: CGSize(width: 400, height: 800))
        controller.view.layoutIfNeeded()
        await model.settle()
        pick(tool, in: model, controller)
        return (controller, model, undoManager)
    }

    /// Picks `tool`, as the palette and SwiftUI's update of the scroll view do.
    func pick(_ tool: Tool?, in model: DocumentModel, _ controller: PageScrollViewController) {
        model.tool = tool
        controller.markupTool = tool
        sync(model, controller)
    }

    /// Hands the controller the selected annotation, as SwiftUI's update of the scroll view does.
    func sync(_ model: DocumentModel, _ controller: PageScrollViewController) {
        controller.selectedAnnotation = model.selectedAnnotationPlace
    }

    /// `point` (PDF points on `page`) in the content view's coordinates.
    func contentPoint(_ point: CGPoint, page: Int = 0, in controller: PageScrollViewController) throws -> CGPoint {
        let frame = try XCTUnwrap(controller.pageView(for: page)).frame
        let scale = frame.width / CGFloat(controller.model.pages[page].widthPt)
        return CGPoint(x: frame.minX + point.x * scale, y: frame.minY + point.y * scale)
    }

    func overlay(_ controller: PageScrollViewController, page: Int = 0) throws -> PageOverlayView {
        try XCTUnwrap(controller.pageView(for: page)).overlay
    }

    /// With Select, a tap on an annotation selects it, and its page outlines it; a tap on none lets go.
    /// A tap with nothing there and nothing selected is not Select's.
    func testATapWithSelectPicksTheAnnotationAndATapElsewhereLetsGo() async throws {
        let (controller, model, _) = await makeController()
        _ = await model.addShape(page: 0, draft: .rect(CGRect(x: 100, y: 100, width: 100, height: 60), oval: false))
        let rect = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first).rect
        let markup = controller.markupInteraction
        let on = try contentPoint(CGPoint(x: 150, y: 130), in: controller)
        let off = try contentPoint(CGPoint(x: 400, y: 500), in: controller)
        XCTAssertTrue(markup.takesTap(atContentPoint: on))
        XCTAssertFalse(markup.takesTap(atContentPoint: off), "nothing there and nothing selected")
        markup.place(atContentPoint: on)
        XCTAssertNotNil(model.selectedAnnotation)
        sync(model, controller)
        XCTAssertEqual(try overlay(controller).selectedAnnotationRect, CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
        XCTAssertNil(try overlay(controller, page: 1).selectedAnnotationRect)
        XCTAssertTrue(markup.takesTap(atContentPoint: off), "a tap anywhere lets go of the selection")
        markup.place(atContentPoint: off)
        XCTAssertNil(model.selectedAnnotation)
        sync(model, controller)
        XCTAssertNil(try overlay(controller).selectedAnnotationRect)
        // Another tool's tap is not Select's.
        pick(.rectangle, in: model, controller)
        XCTAssertFalse(markup.takesTap(atContentPoint: on))
    }

    /// One finger on the selected annotation drags it: its outline follows the finger, and the move is
    /// made when the finger comes up (one change). Elsewhere one finger scrolls.
    func testDraggingTheSelectedAnnotationMovesIt() async throws {
        let (controller, model, undoManager) = await makeController()
        _ = await model.addShape(page: 0, draft: .rect(CGRect(x: 100, y: 100, width: 100, height: 60), oval: false))
        let before = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first).rect
        let markup = controller.markupInteraction
        let on = try contentPoint(CGPoint(x: 150, y: 130), in: controller)
        XCTAssertFalse(markup.takesTouch(atContentPoint: on), "nothing selected: one finger scrolls")
        markup.place(atContentPoint: on)
        sync(model, controller)
        XCTAssertTrue(markup.takesTouch(atContentPoint: on))
        XCTAssertFalse(markup.takesTouch(atContentPoint: try contentPoint(CGPoint(x: 400, y: 500), in: controller)))
        XCTAssertTrue(markup.selecting.beginMove(atContentPoint: on))
        let to = try contentPoint(CGPoint(x: 190, y: 150), in: controller)
        markup.selecting.move(toContentPoint: to)
        XCTAssertEqual(try overlay(controller).dragOffset.width, 40, accuracy: 0.5)
        XCTAssertEqual(try overlay(controller).dragOffset.height, 20, accuracy: 0.5)
        let made = try XCTUnwrap(markup.selecting.endMove(atContentPoint: to))
        let ok = await made.value
        XCTAssertTrue(ok)
        let after = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first).rect
        XCTAssertEqual(after.x - before.x, 40, accuracy: 0.5); XCTAssertEqual(after.y - before.y, 20, accuracy: 0.5)
        XCTAssertEqual(undoManager.undoActionName, Strings.actionMoveAnnotation)
        sync(model, controller)
        XCTAssertEqual(try overlay(controller).dragOffset, .zero)
        XCTAssertNil(try overlay(controller).selectedAnnotationRect)
    }

    /// A drag that stays where it began moves nothing.
    func testADragThatGoesNowhereMovesNothing() async throws {
        let (controller, model, undoManager) = await makeController()
        _ = await model.addShape(page: 0, draft: .rect(CGRect(x: 100, y: 100, width: 100, height: 60), oval: false))
        let markup = controller.markupInteraction
        let on = try contentPoint(CGPoint(x: 150, y: 130), in: controller)
        markup.place(atContentPoint: on)
        sync(model, controller)
        XCTAssertTrue(markup.selecting.beginMove(atContentPoint: on))
        let made = markup.selecting.endMove(atContentPoint: on)
        let ok = await made?.value ?? false
        XCTAssertFalse(ok)
        XCTAssertEqual(undoManager.undoActionName, Strings.actionAddAnnotation)
        XCTAssertEqual(try overlay(controller).dragOffset, .zero)
        XCTAssertNotNil(model.selectedAnnotation, "still selected")
    }

    /// A move dragged while a turn of its page was on its way is refused, and nothing of it stays on
    /// the page where it was dropped.
    func testAMoveRefusedAsStaleLeavesNoGhost() async throws {
        let (controller, model, _) = await makeController()
        _ = await model.addShape(page: 0, draft: .rect(CGRect(x: 100, y: 100, width: 100, height: 60), oval: false))
        let before = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first).rect
        let markup = controller.markupInteraction
        let on = try contentPoint(CGPoint(x: 150, y: 130), in: controller)
        markup.place(atContentPoint: on)
        sync(model, controller)
        XCTAssertTrue(markup.selecting.beginMove(atContentPoint: on))
        let rotate = model.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        let to = try contentPoint(CGPoint(x: 190, y: 150), in: controller)
        markup.selecting.move(toContentPoint: to)
        let made = try XCTUnwrap(markup.selecting.endMove(atContentPoint: to))
        let rotated = await rotate.value
        let ok = await made.value
        XCTAssertTrue(rotated); XCTAssertFalse(ok)
        XCTAssertEqual(model.failure?.message, Strings.documentChangedTryAgain)
        // Before the screen hands over the selection's going (which zeroes every offset too): the
        // refusal itself put the outline back.
        XCTAssertEqual(try overlay(controller).dragOffset, .zero, "no ghost where it was dropped")
        sync(model, controller)
        for page in controller.loadedPages {
            XCTAssertEqual(controller.pageView(for: page)?.overlay.dragOffset, .zero, "no ghost on page \(page)")
            XCTAssertNil(controller.pageView(for: page)?.overlay.selectedAnnotationRect)
        }
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).count, 1)
        _ = before
    }

    /// A move the engine refuses, with nothing else changed (the file locks the rectangle in a way the
    /// list does not read: `locked-markup.pdf`), leaves the annotation selected where it was, and its
    /// outline back on it, not where it was dropped.
    func testAMoveTheEngineRefusesKeepsTheSelectionAndLeavesNoGhost() async throws {
        let (controller, model, undoManager) = await makeController(pages: 1, data: try fixtureData("locked-markup"))
        let rectangle = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first { $0.kind == .rectangle })
        XCTAssertFalse(rectangle.locked, "listed as unlocked, so it may be dragged")
        let markup = controller.markupInteraction
        let on = try contentPoint(CGPoint(x: 150, y: 140), in: controller)
        markup.place(atContentPoint: on)
        sync(model, controller)
        XCTAssertEqual(model.selectedAnnotation, AnnotationRef(page: 0, index: rectangle.index))
        XCTAssertTrue(markup.selecting.beginMove(atContentPoint: on))
        let to = try contentPoint(CGPoint(x: 190, y: 160), in: controller)
        markup.selecting.move(toContentPoint: to)
        XCTAssertEqual(try overlay(controller).dragOffset.width, 40, accuracy: 0.5)
        let made = try XCTUnwrap(markup.selecting.endMove(atContentPoint: to))
        let ok = await made.value
        XCTAssertFalse(ok)
        XCTAssertNotNil(model.failure, "the engine's refusal is said")
        XCTAssertEqual(model.selectedAnnotation, AnnotationRef(page: 0, index: rectangle.index), "still selected")
        XCTAssertEqual(try overlay(controller).dragOffset, .zero, "no ghost where it was dropped")
        sync(model, controller)
        XCTAssertEqual(try overlay(controller).dragOffset, .zero)
        XCTAssertNotNil(try overlay(controller).selectedAnnotationRect, "the outline is on it, where it is")
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).first { $0.kind == .rectangle }?.rect, rectangle.rect)
        XCTAssertFalse(undoManager.canUndo)
    }

    /// The edit menu offers what may be done with an annotation: Edit for a note and for a text box on
    /// an upright page, Delete for any the file does not lock.
    func testTheMenuOffersWhatMayBeDone() async throws {
        let (controller, model, _) = await makeController()
        let selecting = controller.markupInteraction.selecting
        XCTAssertEqual(selecting.actions(for: annotation(page: 0, index: 0, kind: .note)), [.edit, .delete])
        XCTAssertEqual(selecting.actions(for: annotation(page: 0, index: 0, kind: .textBox)), [.edit, .delete])
        XCTAssertEqual(selecting.actions(for: annotation(page: 0, index: 0, kind: .rectangle)), [.delete])
        XCTAssertEqual(selecting.actions(for: annotation(page: 0, index: 0, kind: .note, locked: true)), [.edit],
                       "a locked note's text may still be changed, but it is not deleted")
        XCTAssertEqual(selecting.actions(for: annotation(page: 0, index: 0, kind: .rectangle, locked: true)), [])
        _ = model
        let (turned, _, _) = await makeController(pages: 1, data: try fixtureData("rotated"))
        XCTAssertEqual(turned.markupInteraction.selecting.actions(for: annotation(page: 0, index: 0, kind: .textBox)), [.delete],
                       "a text box on a turned page would be typed sideways")
    }

    /// Edit on a text box puts the box to type in over it, with its text; what is typed replaces the
    /// text, in place, as one change, when the box ends.
    func testEditingATextBoxChangesItsTextInPlace() async throws {
        let (controller, model, undoManager) = await makeController()
        _ = await model.addTextBox(page: 0, at: CGPoint(x: 100, y: 200), text: "Old")
        let box = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first)
        let ref = AnnotationRef(page: 0, index: box.index)
        let markup = controller.markupInteraction
        markup.place(atContentPoint: try contentPoint(CGPoint(x: 110, y: 205), in: controller))
        XCTAssertEqual(model.selectedAnnotation, ref)
        markup.selecting.perform(.edit, on: box)
        XCTAssertNil(model.selectedAnnotation, "the box being typed in takes the selection's place")
        let editor = try XCTUnwrap(markup.textBoxes.textEditor)
        XCTAssertEqual(editor.text, "Old")
        XCTAssertEqual(editor.existing, ref)
        XCTAssertEqual(editor.origin, CGPoint(x: box.rect.x, y: box.rect.y))
        XCTAssertFalse(model.hasPendingText, "nothing changed yet")
        type("New text", into: editor)
        XCTAssertTrue(model.hasPendingText)
        markup.place(atContentPoint: try contentPoint(CGPoint(x: 400, y: 600), in: controller))
        XCTAssertNil(markup.textBoxes.textEditor)
        await model.settle()
        let changed = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first)
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).count, 1)
        XCTAssertEqual(changed.contents, "New text")
        XCTAssertEqual(changed.rect.x, box.rect.x, accuracy: 0.5); XCTAssertEqual(changed.rect.y, box.rect.y, accuracy: 0.5)
        XCTAssertEqual(undoManager.undoActionName, Strings.actionEditAnnotation)
        undoManager.undo(); await model.settle()
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).first?.contents, "Old")
    }

    /// A text box left as it was changes nothing; one whose text is all taken away is deleted.
    func testATextBoxLeftAsItWasOrEmptied() async throws {
        let (controller, model, undoManager) = await makeController()
        _ = await model.addTextBox(page: 0, at: CGPoint(x: 100, y: 200), text: "Old")
        let box = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first)
        let markup = controller.markupInteraction
        XCTAssertTrue(markup.textBoxes.beginEditing(box))
        type("Old\n", into: try XCTUnwrap(markup.textBoxes.textEditor))
        XCTAssertFalse(model.hasPendingText, "a new line after the text is no change")
        markup.commitPendingText()
        await model.settle()
        XCTAssertEqual(undoManager.undoActionName, Strings.actionAddAnnotation, "no change")
        XCTAssertTrue(markup.textBoxes.beginEditing(box))
        type("", into: try XCTUnwrap(markup.textBoxes.textEditor))
        XCTAssertTrue(model.hasPendingText, "taking the text away is a change")
        let made = await markup.commitPendingText()?.value
        XCTAssertEqual(made, true)
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
        XCTAssertEqual(undoManager.undoActionName, Strings.actionDeleteAnnotation)
    }

    /// A text box the file locks may have its text changed, but taking all of it away would delete it:
    /// that is refused, saying the document does not allow it, and the box stays.
    func testEmptyingALockedTextBoxIsRefused() async throws {
        let (controller, model, undoManager) = await makeController(pages: 1, data: try fixtureData("locked-markup"))
        let box = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first { $0.kind == .textBox })
        XCTAssertTrue(box.locked)
        let markup = controller.markupInteraction
        XCTAssertEqual(markup.selecting.actions(for: box), [.edit], "its text may be changed; it is not deleted")
        XCTAssertTrue(markup.textBoxes.beginEditing(box))
        type("", into: try XCTUnwrap(markup.textBoxes.textEditor))
        XCTAssertTrue(model.hasPendingText)
        let made = await markup.commitPendingText()?.value
        XCTAssertEqual(made, false)
        XCTAssertEqual(model.failure?.message, Strings.editNotAllowed)
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).first { $0.kind == .textBox }?.contents, "Locked")
        XCTAssertFalse(undoManager.canUndo)
    }

    /// Edit on a note opens the note sheet with its text, for that note.
    func testEditingANoteOpensItsSheet() async throws {
        let (controller, model, _) = await makeController()
        _ = await model.addNote(page: 0, at: CGPoint(x: 100, y: 100), contents: "Hello")
        let note = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first)
        controller.markupInteraction.selecting.perform(.edit, on: note)
        let draft = try XCTUnwrap(model.noteDraft)
        XCTAssertEqual(draft.existing, AnnotationRef(page: 0, index: note.index))
        XCTAssertEqual(draft.text, "Hello")
    }

    /// Delete in the menu deletes the annotation, as one change.
    func testDeleteInTheMenuDeletesIt() async throws {
        let (controller, model, undoManager) = await makeController()
        _ = await model.addShape(page: 0, draft: .rect(CGRect(x: 100, y: 100, width: 100, height: 60), oval: false))
        let shape = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first)
        controller.markupInteraction.place(atContentPoint: try contentPoint(CGPoint(x: 150, y: 130), in: controller))
        controller.markupInteraction.selecting.perform(.delete, on: shape)
        await model.settle()
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
        XCTAssertEqual(undoManager.undoActionName, Strings.actionDeleteAnnotation)
    }

    /// With the eraser, one finger on a page erases: what the stroke crosses is deleted when the finger
    /// comes up, as one change. In the gap between pages it scrolls.
    func testTheEraserDeletesWhatItsStrokeCrossesAsOneChange() async throws {
        let (controller, model, undoManager) = await makeController(tool: .eraser)
        for x in [50.0, 150.0, 250.0] { _ = await model.addShape(page: 0, draft: .rect(CGRect(x: x, y: 100, width: 60, height: 60), oval: false)) }
        _ = await model.addShape(page: 0, draft: .rect(CGRect(x: 50, y: 400, width: 60, height: 60), oval: false))
        let markup = controller.markupInteraction
        XCTAssertTrue(markup.takesTouch(atContentPoint: try contentPoint(CGPoint(x: 300, y: 600), in: controller)), "anywhere on a page")
        XCTAssertFalse(markup.takesTouch(atContentPoint: try contentPoint(CGPoint(x: 300, y: 795), in: controller)), "the gap scrolls")
        XCTAssertTrue(markup.eraser.begin(atContentPoint: try contentPoint(CGPoint(x: 60, y: 120), in: controller)))
        markup.eraser.move(toContentPoint: try contentPoint(CGPoint(x: 160, y: 130), in: controller))
        markup.eraser.move(toContentPoint: try contentPoint(CGPoint(x: 260, y: 120), in: controller))
        let made = try XCTUnwrap(markup.eraser.end(atContentPoint: try contentPoint(CGPoint(x: 270, y: 120), in: controller)))
        let ok = await made.value
        XCTAssertTrue(ok)
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).count, 1, "the one off the stroke stays")
        XCTAssertEqual(undoManager.undoActionName, Strings.actionDeleteAnnotation)
        undoManager.undo(); await model.settle()
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).count, 4)
    }

    /// A slow stroke, its points much closer together than the slop (the stroke leaves most of them
    /// out), still erases what it crosses, and only that.
    func testASlowEraserStrokeErasesWhatItCrosses() async throws {
        let (controller, model, _) = await makeController(tool: .eraser)
        _ = await model.addShape(page: 0, draft: .rect(CGRect(x: 150, y: 100, width: 20, height: 60), oval: false))
        _ = await model.addShape(page: 0, draft: .rect(CGRect(x: 150, y: 300, width: 20, height: 60), oval: false))
        let eraser = controller.markupInteraction.eraser
        XCTAssertTrue(eraser.begin(atContentPoint: try contentPoint(CGPoint(x: 100, y: 130), in: controller)))
        for step in 1...400 { eraser.move(toContentPoint: try contentPoint(CGPoint(x: 100 + 0.25 * Double(step), y: 130), in: controller)) }
        let made = try XCTUnwrap(eraser.end(atContentPoint: try contentPoint(CGPoint(x: 200.1, y: 130), in: controller)))
        let ok = await made.value
        XCTAssertTrue(ok)
        let left = model.annotationIndex.annotations(onPage: 0)
        XCTAssertEqual(left.count, 1, "the one crossed goes")
        XCTAssertEqual(left.first?.rect.y ?? 0, 300, accuracy: 0.5, "the other stays")
    }

    /// A tap with the eraser deletes the annotation under it.
    func testATapWithTheEraserDeletesTheAnnotationUnderIt() async throws {
        let (controller, model, _) = await makeController(tool: .eraser)
        _ = await model.addShape(page: 0, draft: .rect(CGRect(x: 100, y: 100, width: 100, height: 60), oval: false))
        let markup = controller.markupInteraction
        let on = try contentPoint(CGPoint(x: 150, y: 130), in: controller)
        XCTAssertTrue(markup.takesTap(atContentPoint: on))
        markup.place(atContentPoint: on)
        await model.settle()
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
    }

    /// A stroke cancelled (the system taking the touch) erases nothing; another tool drops it.
    func testACancelledEraserStrokeErasesNothing() async throws {
        let (controller, model, _) = await makeController(tool: .eraser)
        _ = await model.addShape(page: 0, draft: .rect(CGRect(x: 100, y: 100, width: 100, height: 60), oval: false))
        let eraser = controller.markupInteraction.eraser
        XCTAssertTrue(eraser.begin(atContentPoint: try contentPoint(CGPoint(x: 150, y: 130), in: controller)))
        eraser.cancel()
        XCTAssertNil(eraser.end(atContentPoint: try contentPoint(CGPoint(x: 150, y: 130), in: controller)))
        XCTAssertTrue(eraser.begin(atContentPoint: try contentPoint(CGPoint(x: 150, y: 130), in: controller)))
        pick(.select, in: model, controller)
        XCTAssertNil(eraser.end(atContentPoint: try contentPoint(CGPoint(x: 150, y: 130), in: controller)))
        await model.settle()
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).count, 1)
    }

    /// Strokes drawn with Draw and waiting are added when Select or the eraser is picked.
    func testPickingSelectOrTheEraserAddsTheStrokesWaiting() async throws {
        let scale: CGFloat = 400.0 / 612.0
        for next in [Tool.select, .eraser] {
            let (controller, model, _) = await makeController(tool: .ink)
            let ink = try XCTUnwrap(controller.markupInteraction.drawing.ink)
            let points = (0...10).map { CGPoint(x: 100 + 10 * Double($0), y: 100) }
            ink.drawing = PKDrawing(strokes: [InkGeometryTests.stroke(points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) })])
            XCTAssertTrue(model.hasPendingInk)
            pick(next, in: model, controller)
            await model.settle()
            XCTAssertFalse(model.hasPendingInk, "\(next)")
            XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).map(\.kind), [.ink], "\(next)")
        }
    }

    // MARK: Helpers

    /// An annotation of `kind` at `rect` on `page`, number `index` there.
    func annotation(page: Int, index: UInt32, kind: AnnotationKind, contents: String? = nil, author: String? = nil,
                    rect: CGRect = CGRect(x: 0, y: 0, width: 10, height: 10), locked: Bool = false) -> AnnotationInfo {
        AnnotationInfo(page: UInt32(page), index: index, kind: kind,
                       rect: Rect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
                       contents: contents, author: author, modified: nil, color: nil, locked: locked)
    }

    /// Types `text` into the text box being edited, as the keyboard does.
    func type(_ text: String, into editor: InlineTextEditor) {
        editor.text = text
        editor.delegate?.textViewDidChange?(editor)
    }
}
