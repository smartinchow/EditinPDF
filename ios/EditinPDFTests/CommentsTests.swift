import EditinPDFCore
import UIKit
import XCTest
@testable import EditinPDF

/// Comments: the date a mark was last changed (`CommentDate`), the list's filter (`CommentFilter`) and
/// its rows, read as comments.
@MainActor
final class CommentsTests: XCTestCase {
    private func row(page: Int = 0, index: UInt32, comment: String?) -> CommentRow {
        CommentRow(id: AnnotationRef(page: page, index: index), page: page, kind: .highlight, title: "Highlight", detail: comment, author: nil,
                   modified: nil, rect: .zero, isLocked: false)
    }

    /// The engine gives a date as `YYYY-MM-DD HH:MM`, its time zone left out (the engine writes its own
    /// in UTC); a file's own PDF date (`D:…`, with its offset) is read too. Anything else is no date.
    func testDatesAreReadAsTheEngineGivesThem() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let pretty = try XCTUnwrap(CommentDate.parse("2026-10-21 14:05"))
        XCTAssertEqual(pretty, utc.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 14, minute: 5)))
        let pdf = try XCTUnwrap(CommentDate.parse("D:20261021160500+02'00'"))
        XCTAssertEqual(pdf, pretty, "the offset is taken off")
        XCTAssertEqual(CommentDate.parse("D:20261021140500Z"), pretty)
        XCTAssertEqual(CommentDate.parse("D:2026102114"), utc.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 14)))
        for bad in ["", "yesterday", "2026-13-40 99:99", "D:20", "D:abcd1021"] {
            XCTAssertNil(CommentDate.parse(bad), bad)
        }
    }

    /// Recent dates read as how long ago; older ones as a short date.
    func testDatesAreShownRelativeWhenRecent() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = CommentDate.text(for: now.addingTimeInterval(-3_600), now: now)
        let old = CommentDate.text(for: now.addingTimeInterval(-40 * 86_400), now: now)
        XCTAssertFalse(recent.isEmpty)
        XCTAssertNotEqual(recent, old)
        XCTAssertEqual(old, now.addingTimeInterval(-40 * 86_400).formatted(date: .abbreviated, time: .omitted))
    }

    /// With any comment, the list starts on the marks that have one; with none, on all of them.
    func testTheFilterStartsOnCommentsWhenThereAreAny() {
        let rows = [row(index: 0, comment: nil), row(index: 1, comment: "Check this"), row(index: 2, comment: nil)]
        XCTAssertEqual(CommentFilter.initial(for: rows), .withComments)
        XCTAssertEqual(CommentFilter.withComments.rows(rows).map(\.id.index), [1])
        XCTAssertEqual(CommentFilter.all.rows(rows).map(\.id.index), [0, 1, 2])
        XCTAssertEqual(CommentFilter.initial(for: [row(index: 0, comment: nil)]), .all)
        XCTAssertEqual(CommentFilter.initial(for: []), .all)
        XCTAssertEqual(CommentFilter.all.title, Strings.allMarks)
        XCTAssertEqual(CommentFilter.withComments.title, Strings.withComments)
    }

    /// A row leads with the comment; under it, the kind of mark and its page, counting from 1.
    func testARowReadsAsAComment() {
        let row = CommentRow(id: AnnotationRef(page: 2, index: 0), page: 2, kind: .ink, title: "Drawing", detail: "Fix this", author: "Ann",
                             modified: Date(timeIntervalSince1970: 0), rect: .zero, isLocked: false)
        XCTAssertEqual(row.headline, "Fix this")
        XCTAssertEqual(row.subtitle, "Drawing on page 3")
        XCTAssertTrue(row.hasComment)
        let empty = self.row(index: 1, comment: nil)
        XCTAssertEqual(empty.headline, Strings.addACommentPlaceholder)
        XCTAssertFalse(empty.hasComment)
    }

    /// Many annotations are listed and filtered quickly enough to keep the sheet responsive.
    func testManyRowsAreQuick() {
        var infos: [AnnotationInfo] = []
        for i in 0..<5_000 {
            let kind: AnnotationKind = i % 3 == 0 ? .note : .highlight
            let contents: String? = i % 2 == 0 ? "Comment \(i)" : nil
            let rect = Rect(x: 0, y: Double(i), width: 10, height: 10)
            infos.append(AnnotationInfo(page: UInt32(i % 50), index: UInt32(i), kind: kind, rect: rect, contents: contents, author: nil,
                                        modified: "2026-10-21 14:05", color: nil, locked: false, fontSize: nil, fill: nil, borderWidth: nil))
        }
        let index = AnnotationIndex(infos)
        let start = Date()
        let rows = DocumentModel.commentRows(index)
        let shown = CommentFilter.initial(for: rows).rows(rows)
        XCTAssertEqual(rows.count, 5_000)
        XCTAssertEqual(shown.count, 2_500)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "5,000 marks listed in under a second")
    }
}

/// Commenting on any mark, and Add Comment, on a real document.
extension AnnotationEditingTests {
    /// Comment over a highlight opens the comment sheet with its text (none yet); Save gives it the
    /// text written, one change named Edit Comment, which the list then shows.
    func testCommentingOnAHighlightGivesItAComment() async throws {
        let (controller, model, undoManager) = await makeController()
        let rect = Rect(x: 72, y: 100, width: 100, height: 14)
        let marked = await model.performAll([.addTextMarkup(page: 0, kind: .highlight, rects: [rect], color: RgbColor(red: 1, green: 1, blue: 0),
                                                            contents: "")], named: Strings.actionAddAnnotation, touching: [0])
        XCTAssertTrue(marked)
        let mark = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first)
        let selecting = controller.markupInteraction.selecting
        XCTAssertEqual(selecting.actions(for: mark), [.comment, .delete])
        selecting.perform(.comment, on: mark)
        let draft = try XCTUnwrap(model.noteDraft)
        XCTAssertTrue(draft.isComment)
        XCTAssertEqual(draft.title, Strings.comment)
        XCTAssertEqual(draft.existing, AnnotationRef(page: 0, index: mark.index))
        XCTAssertEqual(draft.text, "")
        let saved = await model.saveNoteDraft(text: "Check this figure")
        XCTAssertTrue(saved)
        XCTAssertNil(model.noteDraft)
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).first?.contents, "Check this figure")
        XCTAssertEqual(undoManager.undoActionName, Strings.actionEditComment)
        let rows = DocumentModel.commentRows(model.annotationIndex)
        XCTAssertEqual(CommentFilter.initial(for: rows), .withComments)
        XCTAssertEqual(CommentFilter.withComments.rows(rows).first?.headline, "Check this figure")
        XCTAssertNotNil(rows.first?.modified, "the engine dates the change")
        undoManager.undo(); await model.settle()
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).first?.contents ?? "", "", "one Undo takes it back")
    }

    /// A row of the list opens the same sheet for its mark (a note's is its own: Note).
    func testARowOfTheListOpensItsComment() async throws {
        let (_, model, _) = await makeController()
        _ = await model.addNote(page: 0, at: CGPoint(x: 100, y: 100), contents: "Hello")
        let row = try XCTUnwrap(DocumentModel.commentRows(model.annotationIndex).first)
        model.editComment(of: row)
        let draft = try XCTUnwrap(model.noteDraft)
        XCTAssertFalse(draft.isComment, "a note is written as a note")
        XCTAssertEqual(draft.text, "Hello")
        XCTAssertEqual(draft.existing, row.id)
    }

    /// Add Comment picks Note and shows the hint; the next tap on the page puts a note there and opens
    /// its sheet, and the hint goes.
    func testAddCommentPlacesANoteWithTheNextTap() async throws {
        let (controller, model, _) = await makeController(tool: nil)
        model.startAddingComment()
        XCTAssertEqual(model.tool, .note)
        XCTAssertTrue(model.showsAddCommentHint)
        controller.markupTool = model.tool
        controller.markupInteraction.place(atContentPoint: try contentPoint(CGPoint(x: 200, y: 300), in: controller))
        let draft = try XCTUnwrap(model.noteDraft, "the tap opened a new note")
        XCTAssertNil(draft.existing)
        XCTAssertFalse(model.showsAddCommentHint, "the hint goes once the comment is placed")
        model.startAddingComment()
        model.tool = .select
        XCTAssertFalse(model.showsAddCommentHint, "another tool puts the hint away")
    }
}
