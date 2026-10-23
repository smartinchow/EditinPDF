import EditinPDFCore
import UIKit
import XCTest
@testable import EditinPDF

/// Highlight, Underline and Strikethrough over text that already has the mark take it off, as in a word
/// processor (`MarkupToggle`, `DocumentModel.markSelection`, `pick`, and the selection's menu).
@MainActor
final class MarkupToggleTests: XCTestCase {
    // MARK: Helpers

    /// A model of one page reading "One two three" (24 pt, at the top left), settled.
    private func oneTwoThree() async -> (DocumentModel, UndoManager) {
        let model = isolatedModel(bytes: TextMarkupTests.linesPage(["One two three"]))
        let undoManager = UndoManager()
        model.undoManager = undoManager
        await model.settle()
        return (model, undoManager)
    }

    private func glyphs(_ m: DocumentModel) throws -> [TextGlyph] {
        try XCTUnwrap(m.document()).pageText(page: 0).glyphs
    }

    /// The glyphs of the first `word` on page 0 (one glyph for each character).
    private func range(of word: String, in m: DocumentModel) throws -> Range<Int> {
        let texts = try glyphs(m).map(\.text)
        let letters = Array(word).map(String.init)
        let start = try XCTUnwrap((0...(texts.count - letters.count)).first { Array(texts[$0..<($0 + letters.count)]) == letters },
                                  "no \(word) on the page")
        return start..<(start + letters.count)
    }

    private func middle(of glyph: TextGlyph) -> CGPoint {
        CGPoint(x: glyph.rect.x + glyph.rect.width / 2, y: glyph.rect.y + glyph.rect.height / 2)
    }

    /// Selects the glyphs `range` of page 0 (from the start of a word), as a long press and a handle do.
    private func select(_ range: Range<Int>, in m: DocumentModel) async throws {
        let all = try glyphs(m)
        m.selection?.beginWord(page: 0, at: middle(of: all[range.lowerBound]))
        await m.selection?.waitUntilSettled()
        let last = all[range.upperBound - 1].rect
        m.selection?.extend(to: CGPoint(x: last.x + last.width * 0.75, y: last.y + last.height / 2))
        await m.selection?.waitUntilSettled()
        let selected = try XCTUnwrap(m.selection?.selection, "nothing selected")
        XCTAssertEqual(Int(selected.start)..<Int(selected.end), range, "selected other glyphs")
    }

    private func select(_ word: String, in m: DocumentModel) async throws {
        try await select(try range(of: word, in: m), in: m)
    }

    private func marks(_ m: DocumentModel, _ kind: AnnotationKind) -> [AnnotationInfo] {
        m.annotationIndex.annotations(onPage: 0).filter { $0.kind == kind }
    }

    /// Whether a quad of `mark` holds the middle of `glyph`.
    private func covers(_ mark: AnnotationInfo, _ glyph: TextGlyph) -> Bool {
        let p = middle(of: glyph)
        return mark.quads.contains { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(p) }
    }

    private let kinds: [(MarkupKind, AnnotationKind, String)] = [
        (.underline, .underline, "Remove Underline"),
        (.strikeOut, .strikeOut, "Remove Strikethrough"),
        (.highlight, .highlight, "Remove Highlight"),
    ]

    // MARK: Taking a mark off

    func testMarkingMarkedTextAgainTakesTheMarkOffInOneUndoStep() async throws {
        for (kind, annotationKind, name) in kinds {
            let (m, u) = await oneTwoThree()
            try await select("two", in: m)
            let added = await m.markSelection(kind)
            XCTAssertTrue(added)
            let original = try XCTUnwrap(marks(m, annotationKind).first)
            XCTAssertFalse(original.quads.isEmpty, "the bridge lists the mark's quads")
            try await select("two", in: m)
            let removed = await m.markSelection(kind)
            XCTAssertTrue(removed, "\(kind) was not taken off")
            XCTAssertTrue(m.annotationIndex.annotations(onPage: 0).isEmpty, "\(kind) is still there")
            XCTAssertNil(m.selection?.selection)
            XCTAssertEqual(u.undoActionName, name)
            XCTAssertEqual(name, Strings.removeMarkup(kind))
            u.undo(); await m.settle()
            let back = try XCTUnwrap(marks(m, annotationKind).first, "one undo puts the mark back")
            XCTAssertEqual(back.quads, original.quads)
            XCTAssertEqual(u.undoActionName, Strings.actionAddAnnotation, "the undo took back one step")
        }
    }

    /// A mark over "One two three" with a comment, cut by selecting "two": what stays is "One" and
    /// "three", in the mark's colour (not the tool's now), and the comment goes with "One".
    func testAMarkLongerThanTheSelectionIsCutIntoWhatStays() async throws {
        let (m, u) = await oneTwoThree()
        let all = try glyphs(m)
        let one = try range(of: "One", in: m), two = try range(of: "two", in: m), three = try range(of: "three", in: m)
        try await select(one.lowerBound..<three.upperBound, in: m)
        let added = await m.markSelection(.underline)
        XCTAssertTrue(added)
        let original = try XCTUnwrap(marks(m, .underline).first)
        let commented = await m.performAll([.setAnnotationContents(page: 0, index: original.index, contents: "note")],
                                           named: Strings.actionEditAnnotation, touching: [0])
        XCTAssertTrue(commented)
        m.toolStyles[.underline].color = RGBA(r: 0, g: 1, b: 0)
        try await select("two", in: m)
        let removed = await m.markSelection(.underline)
        XCTAssertTrue(removed)
        let pieces = marks(m, .underline).sorted { ($0.quads.first?.x ?? 0) < ($1.quads.first?.x ?? 0) }
        XCTAssertEqual(pieces.count, 2, "\(pieces)")
        guard pieces.count == 2 else { return }
        for glyph in one { XCTAssertTrue(covers(pieces[0], all[glyph]), "One is not kept") }
        for glyph in three { XCTAssertTrue(covers(pieces[1], all[glyph]), "three is not kept") }
        for glyph in two { XCTAssertFalse(pieces.contains { covers($0, all[glyph]) }, "two is still marked") }
        for piece in pieces { XCTAssertEqual(piece.color, original.color, "the piece took another colour") }
        XCTAssertEqual(pieces[0].contents, "note")
        XCTAssertEqual(pieces[1].contents ?? "", "")
        XCTAssertEqual(u.undoActionName, Strings.removeUnderline)
        u.undo(); await m.settle()
        let back = marks(m, .underline)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first?.contents, "note")
        XCTAssertEqual(back.first?.quads, original.quads)
    }

    /// "two" underlined, then all three words selected: only "One" and "three" are underlined, and
    /// "two" is not underlined twice.
    func testTextPartlyMarkedIsMarkedOnlyWhereItIsNot() async throws {
        let (m, u) = await oneTwoThree()
        let all = try glyphs(m)
        let one = try range(of: "One", in: m), two = try range(of: "two", in: m), three = try range(of: "three", in: m)
        try await select("two", in: m)
        _ = await m.markSelection(.underline)
        let first = try XCTUnwrap(marks(m, .underline).first)
        try await select(one.lowerBound..<three.upperBound, in: m)
        let added = await m.markSelection(.underline)
        XCTAssertTrue(added)
        let list = marks(m, .underline)
        XCTAssertEqual(list.count, 2)
        let new = try XCTUnwrap(list.first { $0.index != first.index })
        for glyph in Array(one) + Array(three) { XCTAssertTrue(covers(new, all[glyph]), "glyph \(glyph) is not marked") }
        for glyph in two { XCTAssertFalse(covers(new, all[glyph]), "two is marked twice") }
        XCTAssertEqual(u.undoActionName, Strings.actionAddAnnotation)
    }

    /// Two words marked one at a time are all marked: the space between them does not count.
    func testTwoMarkedWordsSelectedTogetherAreTakenOffTogether() async throws {
        let (m, _) = await oneTwoThree()
        let one = try range(of: "One", in: m), two = try range(of: "two", in: m)
        try await select("One", in: m)
        _ = await m.markSelection(.highlight)
        try await select("two", in: m)
        _ = await m.markSelection(.highlight)
        XCTAssertEqual(marks(m, .highlight).count, 2)
        try await select(one.lowerBound..<two.upperBound, in: m)
        let removed = await m.markSelection(.highlight)
        XCTAssertTrue(removed)
        XCTAssertTrue(marks(m, .highlight).isEmpty)
    }

    /// Text whose only mark the file locks keeps it: the reader is told the document doesn't allow it.
    func testALockedMarkIsNeverTakenOff() async throws {
        let model = isolatedModel(bytes: Self.lockedUnderlinePage())
        let u = UndoManager()
        model.undoManager = u
        await model.settle()
        let locked = try XCTUnwrap(marks(model, .underline).first, "the file's underline is not listed")
        XCTAssertTrue(locked.locked)
        XCTAssertFalse(locked.quads.isEmpty)
        try await select("two", in: model)
        let removed = await model.markSelection(.underline)
        XCTAssertFalse(removed)
        XCTAssertEqual(model.failure?.message, Strings.editNotAllowed)
        XCTAssertEqual(marks(model, .underline), [locked])
        XCTAssertFalse(u.canUndo)
        XCTAssertNil(model.selection?.selection)
    }

    /// The tool picked again while it is the current one takes the mark off the selected text.
    func testPickingTheCurrentToolAgainTakesTheMarkOff() async throws {
        let (m, u) = await oneTwoThree()
        try await select("two", in: m)
        _ = await m.pick(.underline)?.value
        XCTAssertEqual(marks(m, .underline).count, 1)
        XCTAssertEqual(m.tool, .underline)
        try await select("two", in: m)
        let again = try XCTUnwrap(m.pick(.underline), "the current tool picked again does nothing")
        XCTAssertNil(m.selection?.selection, "the selection is handed over at once")
        XCTAssertNil(m.pick(.underline), "a second tap finds nothing to take off")
        let removed = await again.value
        XCTAssertTrue(removed)
        XCTAssertTrue(marks(m, .underline).isEmpty)
        XCTAssertEqual(u.undoActionName, Strings.removeUnderline)
    }

    /// A step that deletes a mark and adds pieces of it back shifts the places of its page's
    /// annotations, done and undone, and depends on them.
    func testTakingAMarkOffShiftsTheAnnotations() {
        let rect = Rect(x: 0, y: 0, width: 10, height: 10)
        let edits: [Edit] = [.deleteAnnotations(page: 0, indices: [0]),
                             .addTextMarkup(page: 0, kind: .underline, rects: [rect], color: RgbColor(red: 0, green: 0, blue: 1),
                                            contents: "", opacityOf: 0)]
        XCTAssertTrue(DocumentModel.shift(of: edits).contains(.annotations))
        XCTAssertTrue(DocumentModel.undoShift(of: edits).contains(.annotations))
        XCTAssertTrue(DocumentModel.dependence(of: edits).contains(.annotations))
    }

    // MARK: The menu

    /// Three US Letter pages in a 400 x 800 view, as `TextMarkupTests.makeController` makes them.
    private func makeController() async -> (PageScrollViewController, DocumentModel) {
        let model = isolatedModel(bytes: PageScrollViewControllerTests.letterPages(3))
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(origin: .zero, size: CGSize(width: 400, height: 800))
        controller.view.layoutIfNeeded()
        await model.settle()
        return (controller, model)
    }

    private func menu(of controller: PageScrollViewController) throws -> UIMenu {
        let menuInteraction = try XCTUnwrap(controller.scrollView.interactions.compactMap { $0 as? UIEditMenuInteraction }.first)
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero)
        return try XCTUnwrap(controller.selectionInteraction.editMenuInteraction(menuInteraction, menuFor: configuration, suggestedActions: []))
    }

    func testTheMenuOffersToTakeOffAMarkTheSelectionHas() async throws {
        let (controller, model) = await makeController()
        let point = CGPoint(x: 80, y: 84)
        model.selection?.beginWord(page: 0, at: point); await model.selection?.waitUntilSettled()
        controller.selectionInteraction.lookUpMarks()
        await controller.selectionInteraction.waitForMarkedLookUp()
        XCTAssertEqual(try menu(of: controller).children.map(\.title), [Strings.copy, Strings.highlight, Strings.underline, Strings.strikeout])
        let ok = await model.markSelection(.underline)
        XCTAssertTrue(ok)
        // The same word selected again, at the next revision: what was found for it before is not used.
        model.selection?.beginWord(page: 0, at: point); await model.selection?.waitUntilSettled()
        controller.selectionInteraction.lookUpMarks()
        await controller.selectionInteraction.waitForMarkedLookUp()
        let titles = try menu(of: controller).children.map(\.title)
        XCTAssertEqual(Set(titles), [Strings.copy, Strings.highlight, Strings.removeUnderline, Strings.strikeout], "\(titles)")
        let removed = await controller.selectionInteraction.mark(.underline)
        XCTAssertTrue(removed)
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
    }

    // MARK: A drag only adds

    /// The centre of glyph `index` of page 0 in `makeController`'s content view.
    private func contentPoint(ofGlyph index: Int, in model: DocumentModel) throws -> CGPoint {
        let glyph = try glyphs(model)[index]
        let scale: CGFloat = 400.0 / 612.0
        return CGPoint(x: (glyph.rect.x + glyph.rect.width / 2) * scale, y: (glyph.rect.y + glyph.rect.height / 2) * scale)
    }

    /// Drags `tool` from glyph `first` to glyph `last` of page 0, as `TextMarkupTests` does, and says
    /// whether a mark was made.
    private func drag(_ tool: Tool, from first: Int, to last: Int, in controller: PageScrollViewController,
                      model: DocumentModel) async throws -> Bool {
        model.tool = tool
        let markup = controller.markupInteraction
        let start = try contentPoint(ofGlyph: first, in: model)
        let end = try contentPoint(ofGlyph: last, in: model)
        markup.begin(atContentPoint: start)
        markup.move(toContentPoint: CGPoint(x: (start.x + end.x) / 2, y: start.y))
        return await markup.end(atContentPoint: end)
    }

    /// "Page 1": the highlighter dragged over highlighted text leaves it highlighted and adds nothing; dragged on past
    /// it, it adds a highlight over the rest only. (Picking Highlight over it would take it off.)
    func testADragOverMarkedTextAddsOnlyWhereThereIsNone() async throws {
        let (controller, model) = await makeController()
        let all = try glyphs(model)
        XCTAssertEqual(all.prefix(6).map(\.text).joined(), "Page 1")
        let added = try await drag(.highlight, from: 0, to: 3, in: controller, model: model)
        XCTAssertTrue(added)
        let first = try XCTUnwrap(marks(model, .highlight).first)
        let again = try await drag(.highlight, from: 0, to: 3, in: controller, model: model)
        XCTAssertFalse(again, "a drag over highlighted text changed it")
        XCTAssertEqual(marks(model, .highlight), [first], "the highlight was taken off or doubled")
        XCTAssertNil(model.failure)
        XCTAssertNil(model.selection?.selection)
        let further = try await drag(.highlight, from: 0, to: 5, in: controller, model: model)
        XCTAssertTrue(further)
        let list = marks(model, .highlight)
        XCTAssertEqual(list.count, 2)
        let new = try XCTUnwrap(list.first { $0.index != first.index })
        for glyph in 0..<4 { XCTAssertFalse(covers(new, all[glyph]), "glyph \(glyph) is highlighted twice") }
        XCTAssertTrue(covers(new, all[5]), "the rest is not highlighted")
    }

    // MARK: The plan

    /// Glyphs one point wide side by side on a line, one for each character of `text`.
    private func line(_ text: String) -> [TextGlyph] {
        text.enumerated().map { i, c in TextGlyph(text: String(c), rect: Rect(x: Double(i), y: 0, width: 1, height: 10)) }
    }

    private func underline(index: UInt32, over glyphs: Range<Int>, locked: Bool = false) -> AnnotationInfo {
        AnnotationInfo(page: 0, index: index, kind: .underline,
                       rect: Rect(x: Double(glyphs.lowerBound), y: 0, width: Double(glyphs.count), height: 10),
                       contents: "c", author: nil, modified: nil, color: RgbColor(red: 0, green: 0, blue: 1), locked: locked,
                       fontSize: nil, fill: nil, borderWidth: nil, restyleInPlaceOnly: false,
                       quads: [Rect(x: Double(glyphs.lowerBound), y: 0, width: Double(glyphs.count), height: 10)])
    }

    func testThePlanCutsAMarkAroundTheSelection() {
        let glyphs = line("aaa bbb ccc")
        let mark = underline(index: 4, over: 0..<11)
        let plan = MarkupToggle.plan(.underline, selection: 4..<7, glyphs: glyphs, annotations: [mark])
        XCTAssertEqual(plan, .remove(deleting: [4], pieces: [
            .init(source: mark, runs: [0..<3], keepsContents: true),
            .init(source: mark, runs: [8..<11], keepsContents: false),
        ]))
        // Cut at its end, the mark keeps its start, with the comment.
        XCTAssertEqual(MarkupToggle.plan(.underline, selection: 8..<11, glyphs: glyphs, annotations: [mark]),
                       .remove(deleting: [4], pieces: [.init(source: mark, runs: [0..<7], keepsContents: true)]))
        // Cut at its start, what stays after takes the comment.
        XCTAssertEqual(MarkupToggle.plan(.underline, selection: 0..<4, glyphs: glyphs, annotations: [mark]),
                       .remove(deleting: [4], pieces: [.init(source: mark, runs: [4..<11], keepsContents: true)]))
    }

    func testThePlanMarksOnlyWhatIsNotMarked() {
        let glyphs = line("aaa bbb ccc")
        XCTAssertEqual(MarkupToggle.plan(.underline, selection: 0..<11, glyphs: glyphs, annotations: [underline(index: 0, over: 4..<7)]),
                       .mark(runs: [0..<3, 8..<11]))
        XCTAssertEqual(MarkupToggle.plan(.underline, selection: 0..<11, glyphs: glyphs, annotations: []), .markSelection)
        // A mark of another kind is not this one.
        var highlight = underline(index: 0, over: 0..<11)
        highlight.kind = .highlight
        XCTAssertEqual(MarkupToggle.plan(.underline, selection: 0..<11, glyphs: glyphs, annotations: [highlight]), .markSelection)
        XCTAssertEqual(MarkupToggle.plan(.highlight, selection: 0..<3, glyphs: glyphs, annotations: [highlight]),
                       .remove(deleting: [0], pieces: [.init(source: highlight, runs: [4..<11], keepsContents: true)]))
    }

    func testThePlanLeavesLockedMarks() {
        let glyphs = line("aaa bbb")
        let locked = underline(index: 0, over: 0..<7, locked: true)
        XCTAssertEqual(MarkupToggle.plan(.underline, selection: 0..<3, glyphs: glyphs, annotations: [locked]), .locked)
        let unlocked = underline(index: 1, over: 0..<3)
        XCTAssertEqual(MarkupToggle.plan(.underline, selection: 0..<3, glyphs: glyphs, annotations: [locked, unlocked]),
                       .remove(deleting: [1], pieces: []))
    }

    /// The work is bounded: a page of many glyphs under a mark of many quads, all over them, is too much.
    func testThePlanStopsWhenTheWorkIsTooMuch() {
        let glyphs = (0..<5_000).map { TextGlyph(text: "a", rect: Rect(x: Double($0 % 500), y: Double($0 / 500) * 12, width: 1, height: 10)) }
        var mark = underline(index: 0, over: 0..<1)
        // The last quad holds every glyph: each glyph is looked at against all of them.
        mark.quads = Array(repeating: Rect(x: -1, y: -1, width: 0.5, height: 0.5), count: 9_999) + [Rect(x: 0, y: 0, width: 600, height: 200)]
        XCTAssertEqual(MarkupToggle.plan(.underline, selection: 0..<5_000, glyphs: glyphs, annotations: [mark]), .tooMuch)
        XCTAssertNil(MarkupToggle.covers(.underline, selection: 0..<5_000, glyphs: glyphs, annotations: [mark]))
        mark.quads = [Rect(x: 0, y: 0, width: 600, height: 200)]
        XCTAssertEqual(MarkupToggle.covers(.underline, selection: 0..<5_000, glyphs: glyphs, annotations: [mark]), true)
    }

    // MARK: A locked mark

    /// A one-page PDF (US Letter) written here, reading "One two three" in 24 pt Helvetica from (72, 700),
    /// with an underline over the whole line that the file locks (`/F 128`).
    static func lockedUnderlinePage() -> Data {
        let content = "BT /F1 24 Tf 72 700 Td (One two three) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
                + "/Resources << /Font << /F1 5 0 R >> >> /Annots [6 0 R] >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Annot /Subtype /Underline /Rect [60 690 300 730] /C [0 0 1] /F 128 "
                + "/QuadPoints [60 730 300 730 60 690 300 690] >>",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (number, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(number + 1) 0 obj\n\(body)\nendobj\n"
        }
        let table = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n"
        return Data(pdf.utf8)
    }
}
