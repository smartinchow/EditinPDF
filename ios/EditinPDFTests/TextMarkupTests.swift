import EditinPDFCore
import PDFKit
import UIKit
import XCTest
@testable import EditinPDF

/// Highlight, underline and strikethrough over selected text: the model's `markSelection`, and the
/// gestures that lead to it (`MarkupInteraction`, the selection's menu). As in `PageSelectionTests`,
/// the touches themselves are for the simulator: here the handlers are called the way the recognizers
/// call them.
@MainActor
final class TextMarkupTests: XCTestCase {
    // MARK: The model

    func testMarkingTheSelectionAddsAHighlightOverIt() async throws {
        let (m, u) = try makeModel()            // sample.pdf
        m.tool = .highlight
        m.selection?.beginWord(page: 0, at: try firstGlyphCenter(m)); await m.selection?.waitUntilSettled()
        let rects = try XCTUnwrap(m.selection?.pageRects?.rects)
        let ok = await m.markSelection(.highlight)
        XCTAssertTrue(ok)
        let a = try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).first)
        XCTAssertEqual(a.kind, .highlight)
        XCTAssertEqual(a.rect.x, rects[0].minX, accuracy: 2)
        XCTAssertNil(m.selection?.selection); XCTAssertEqual(u.undoActionName, Strings.actionAddAnnotation)
    }

    /// Each kind is made with its own tool's colour, whatever tool is picked (the menu is used in
    /// reading mode, with none).
    func testEachKindIsMadeInItsToolsColour() async throws {
        let (m, _) = try makeModel()
        await m.settle()
        let cases: [(MarkupKind, AnnotationKind, Tool)] = [(.underline, .underline, .underline), (.strikeOut, .strikeOut, .strikeout)]
        for (index, (kind, annotationKind, tool)) in cases.enumerated() {
            m.selection?.beginWord(page: 0, at: try firstGlyphCenter(m)); await m.selection?.waitUntilSettled()
            let ok = await m.markSelection(kind)
            XCTAssertTrue(ok)
            let a = try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).last)
            XCTAssertEqual(a.kind, annotationKind)
            XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).count, index + 1)
            let colour = try XCTUnwrap(a.color)
            let style = m.toolStyles[tool].color
            XCTAssertEqual(colour.red, style.r, accuracy: 0.01)
            XCTAssertEqual(colour.green, style.g, accuracy: 0.01)
            XCTAssertEqual(colour.blue, style.b, accuracy: 0.01)
        }
        XCTAssertEqual(Tool(markupKind: .highlight), .highlight)
    }

    /// The owner's report (0.2.1, on an iPhone): Underline and Strikethrough "do not work". On a phone
    /// the selection's menu shows Copy and Highlight and hides Underline and Strikethrough behind its
    /// arrow, so with text selected the reader taps them in the palette instead: that picks the tool and
    /// must mark the selection with it, as Highlight, Underline and Strikethrough do in the menu.
    func testPickingATextToolWithTextSelectedMarksTheSelection() async throws {
        let (m, u) = try makeModel()
        await m.settle()
        let cases: [(Tool, AnnotationKind)] = [(.underline, .underline), (.strikeout, .strikeOut), (.highlight, .highlight)]
        for (index, (tool, kind)) in cases.enumerated() {
            m.pick(.select)
            m.selection?.beginWord(page: 0, at: try firstGlyphCenter(m)); await m.selection?.waitUntilSettled()
            XCTAssertNotNil(m.selection?.selection, "nothing selected to mark")
            m.pick(tool)
            XCTAssertEqual(m.tool, tool, "the tool is picked too")
            try await waitForAnnotations(index + 1, on: m)
            XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).last?.kind, kind, "picking \(tool) did not mark the selection")
            XCTAssertNil(m.selection?.selection, "the selection stayed once marked")
        }
        XCTAssertEqual(u.undoActionName, Strings.actionAddAnnotation)
    }

    /// The selection goes with the mark: Underline tapped twice quickly, or Strikethrough right after
    /// it, marks the selection once (and the second tap does not take the underline off again). Each on
    /// a document of its own: Underline picked over the word underlined would take the underline off.
    func testPickingATextToolTwiceMarksTheSelectionOnce() async throws {
        for second in [Tool.underline, .strikeout] {
            let (m, u) = try makeModel()
            await m.settle()
            let before = m.annotationIndex.annotations(onPage: 0).count
            m.pick(.select)
            m.selection?.beginWord(page: 0, at: try firstGlyphCenter(m)); await m.selection?.waitUntilSettled()
            XCTAssertNotNil(m.selection?.selection)
            let first = m.pick(.underline)
            XCTAssertNil(m.selection?.selection, "the selection is handed over with the mark")
            XCTAssertNil(m.pick(second), "nothing left to mark")
            _ = await first?.value
            await m.settle()
            XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).count, before + 1, "marked twice after \(second)")
            XCTAssertEqual(u.undoActionName, Strings.actionAddAnnotation)
        }
    }

    /// With nothing selected, picking a text tool only picks it: the drag marks.
    func testPickingATextToolWithNothingSelectedMarksNothing() async throws {
        let (m, u) = try makeModel()
        await m.settle()
        m.pick(.underline)
        try await Task.sleep(for: .milliseconds(300))
        await m.settle()
        XCTAssertEqual(m.tool, .underline)
        XCTAssertFalse(u.canUndo)
        XCTAssertNil(m.failure)
        XCTAssertTrue(m.annotationIndex.annotations(onPage: 0).isEmpty)
    }

    /// Waits up to 5 seconds for page 0 of `m` to have `count` annotations.
    private func waitForAnnotations(_ count: Int, on m: DocumentModel, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 where m.annotationIndex.annotations(onPage: 0).count < count {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).count, count, "no mark was made", file: file, line: line)
    }

    func testWithNothingSelectedNothingIsMarked() async throws {
        let (m, u) = try makeModel()
        await m.settle()
        let ok = await m.markSelection(.highlight)
        XCTAssertFalse(ok)
        XCTAssertFalse(u.canUndo)
        XCTAssertNil(m.failure)
        XCTAssertTrue(m.annotationIndex.annotations(onPage: 0).isEmpty)
    }

    /// Review Focus 4: on a page turned by `/Rotate 90` the mark comes back over the text that was
    /// selected, in view space.
    func testAHighlightOnARotatedPageLandsOnTheSelectedText() async throws {
        let (m, _) = try makeModel(fixture: "rotated")
        await m.settle()
        XCTAssertEqual(m.pages[0].rotationDegrees, 90)
        m.selection?.beginWord(page: 0, at: try firstGlyphCenter(m)); await m.selection?.waitUntilSettled()
        let rects = try XCTUnwrap(m.selection?.pageRects?.rects)
        let selected = try XCTUnwrap(rects.first)
        let ok = await m.markSelection(.highlight)
        XCTAssertTrue(ok)
        let r = try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).first).rect
        let marked = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
        XCTAssertGreaterThan(marked.height, marked.width, "the line runs down the turned page")
        XCTAssertEqual(marked.minX, selected.minX, accuracy: 2)
        XCTAssertEqual(marked.minY, selected.minY, accuracy: 2)
        XCTAssertEqual(marked.maxX, selected.maxX, accuracy: 2)
        XCTAssertEqual(marked.maxY, selected.maxY, accuracy: 2)
    }

    /// Carried from Task 13 (5): a mark is a placement in view space; queued behind a turn of its page
    /// it is refused as stale, the reader is told the standard reason, and nothing stays on the page
    /// that looks marked: neither an annotation nor the selection it was made from.
    func testAMarkQueuedBehindARotationOfItsPageIsRefusedAndLeavesNoGhost() async throws {
        let (m, u) = try makeModel()
        await m.settle()
        m.selection?.beginWord(page: 0, at: try firstGlyphCenter(m)); await m.selection?.waitUntilSettled()
        let rotate = m.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        let marked = await m.markSelection(.highlight)
        let rotated = await rotate.value
        XCTAssertTrue(rotated); XCTAssertFalse(marked)
        XCTAssertEqual(m.failure?.message, Strings.documentChangedTryAgain)
        XCTAssertTrue(m.annotationIndex.annotations(onPage: 0).isEmpty)
        XCTAssertNil(m.selection?.selection)
        u.undo(); await m.settle()
        XCTAssertEqual(m.pages[0].rotationDegrees, 0, "the undo takes back the turn")
        XCTAssertFalse(u.canUndo, "the refused mark left nothing to undo")
    }

    // MARK: The gestures

    /// `pages` US Letter pages in a 400 x 800 view (see `PageSelectionTests`).
    func makeController(pages: Int = 3) async -> (PageScrollViewController, DocumentModel) {
        let model = isolatedModel(bytes: PageScrollViewControllerTests.letterPages(pages))
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(origin: .zero, size: CGSize(width: 400, height: 800))
        controller.view.layoutIfNeeded()
        await model.settle()
        return (controller, model)
    }

    let scale: CGFloat = 400.0 / 612.0

    /// The centre of glyph `index` of `page`, in the content view's coordinates.
    func contentPoint(ofGlyph index: Int, page: Int, in model: DocumentModel) throws -> CGPoint {
        let glyphs = try XCTUnwrap(model.document()).pageText(page: UInt32(page)).glyphs
        let glyph = try XCTUnwrap(glyphs.indices.contains(index) ? glyphs[index] : nil)
        return CGPoint(x: (glyph.rect.x + glyph.rect.width / 2) * scale,
                       y: CGFloat(page) * 530 + (glyph.rect.y + glyph.rect.height / 2) * scale)
    }

    func testTheMarkupPanIsOnTheContentViewAndTheScrollViewWaitsForIt() async {
        let (controller, _) = await makeController()
        let pan = controller.markupInteraction.pan
        XCTAssertTrue(controller.contentView.gestureRecognizers?.contains(pan) == true)
        XCTAssertEqual(pan.maximumNumberOfTouches, 1, "two fingers scroll and zoom")
        XCTAssertTrue(pan.delegate === controller.markupInteraction)
    }

    /// The rule: a finger on a page drags out text to mark only while Highlight, Underline or
    /// Strikethrough is picked and may be used; otherwise the pan takes no touch and the scroll view
    /// has it.
    func testThePanTakesATouchOnlyForAUsableTextToolOnAPage() async throws {
        let (controller, model) = await makeController()
        let markup = controller.markupInteraction
        let onText = try contentPoint(ofGlyph: 0, page: 0, in: model)
        XCTAssertFalse(markup.takesTouch(atContentPoint: onText), "reading")
        // (Select drags only the annotation it has selected, and the eraser erases anywhere on a page:
        // `AnnotationEditingTests`.)
        for tool in [Tool.select, .ink] {
            model.tool = tool
            XCTAssertFalse(markup.takesTouch(atContentPoint: onText), "\(tool)")
        }
        for tool in [Tool.highlight, .underline, .strikeout] {
            model.tool = tool
            XCTAssertTrue(markup.takesTouch(atContentPoint: onText), "\(tool)")
        }
        XCTAssertFalse(markup.takesTouch(atContentPoint: CGPoint(x: 200, y: 524)), "the gap between two pages")
    }

    func testAToolThatIsRefusedTakesNoTouch() async throws {
        let model = isolatedModel(bytes: PageScrollViewControllerTests.letterPages(2))
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(origin: .zero, size: CGSize(width: 400, height: 800))
        controller.view.layoutIfNeeded()
        model.tool = .highlight
        let onText = try contentPoint(ofGlyph: 0, page: 0, in: model)
        // Before the document's permissions are read, no tool may be used.
        XCTAssertFalse(controller.markupInteraction.takesTouch(atContentPoint: onText))
        await model.settle()
        XCTAssertTrue(controller.markupInteraction.takesTouch(atContentPoint: onText))
    }

    /// While a tool that annotates is picked the long press does not select: the tool has the finger.
    func testTheLongPressIsOffWhileAnAnnotatingToolIsPicked() async throws {
        let (controller, model) = await makeController()
        let selection = controller.selectionInteraction
        model.tool = .highlight
        XCTAssertFalse(selection.isLongPressAllowed(atContentPoint: try contentPoint(ofGlyph: 0, page: 0, in: model)))
        model.tool = .select
        XCTAssertTrue(selection.isLongPressAllowed(atContentPoint: try contentPoint(ofGlyph: 0, page: 0, in: model)))
        model.tool = nil
        XCTAssertTrue(selection.isLongPressAllowed(atContentPoint: try contentPoint(ofGlyph: 0, page: 0, in: model)))
    }

    /// A drag across "Page 0" with Highlight picked marks the text it went over, and the selection made
    /// on the way goes.
    func testADragWithTheHighlighterMarksTheTextDraggedOver() async throws {
        let (controller, model) = await makeController()
        model.tool = .highlight
        let markup = controller.markupInteraction
        let start = try contentPoint(ofGlyph: 0, page: 0, in: model)
        let end = try contentPoint(ofGlyph: 3, page: 0, in: model)
        markup.begin(atContentPoint: start)
        markup.move(toContentPoint: CGPoint(x: (start.x + end.x) / 2, y: start.y))
        XCTAssertTrue(markup.isMarking)
        let ok = await markup.end(atContentPoint: end)
        XCTAssertTrue(ok)
        XCTAssertFalse(markup.isMarking)
        let a = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first)
        XCTAssertEqual(a.kind, .highlight)
        XCTAssertEqual(a.rect.x, 72, accuracy: 2, "from the first glyph")
        XCTAssertGreaterThan(a.rect.width, 40, "to the fourth: \"Page\"")
        XCTAssertNil(model.selection?.selection)
    }

    /// A drag that ends on another page still marks the text of the page it began on, up to the end of it.
    func testADragOntoTheNextPageStaysOnThePageItBeganOn() async throws {
        let (controller, model) = await makeController()
        model.tool = .underline
        let markup = controller.markupInteraction
        markup.begin(atContentPoint: try contentPoint(ofGlyph: 0, page: 0, in: model))
        let ok = await markup.end(atContentPoint: try contentPoint(ofGlyph: 0, page: 1, in: model))
        XCTAssertTrue(ok)
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).first?.kind, .underline)
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 1).isEmpty)
    }

    /// Carried from Task 13 (4): the tool can still be picked when the reader has moved to a page, or a
    /// document, where it is refused; the drag that began before is not acted on.
    func testADragWhoseToolIsNoLongerUsableMarksNothing() async throws {
        let (controller, model) = await makeController()
        model.tool = .strikeout
        let markup = controller.markupInteraction
        markup.begin(atContentPoint: try contentPoint(ofGlyph: 0, page: 0, in: model))
        model.tool = .select
        let ok = await markup.end(atContentPoint: try contentPoint(ofGlyph: 3, page: 0, in: model))
        XCTAssertFalse(ok)
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
        XCTAssertNil(model.selection?.selection, "the selection made on the way does not stay")
    }

    /// Carried from Task 13 (3): a touch hits an annotation within 8 points on screen, whatever the zoom.
    func testTheHitSlopIsEightPointsOnScreen() async {
        let (controller, _) = await makeController()
        XCTAssertEqual(controller.markupInteraction.hitSlop(onPage: 0), 8 / scale, accuracy: 0.001)
        controller.scrollView.zoomScale = 4
        XCTAssertEqual(controller.markupInteraction.hitSlop(onPage: 0), 8 / (scale * 4), accuracy: 0.001)
        XCTAssertEqual(MarkupInteraction.hitSlop(screenScale: 0), 8, "no layout: the index's own")
    }

    // MARK: Text or white: mark or scroll (fix round 1)

    /// The white of a page, well away from "Page 1" at its top left, in the content view's coordinates.
    let whiteOfPage0 = CGPoint(x: 300, y: 300)

    /// One finger that goes down on the white of a page scrolls: the markup pan takes no touch there,
    /// and a drag from there marks nothing. (The delegate's own answers: `testTheDelegateAnswersFor…`.)
    func testADragThatStartsOnTheWhiteOfAPageScrollsAndMarksNothing() async throws {
        let (controller, model) = await makeController()
        model.tool = .highlight
        let markup = controller.markupInteraction
        await markup.loadText(onPage: 0)
        XCTAssertEqual(markup.isNearText(CGPoint(x: 300 / scale, y: 300 / scale), onPage: 0), false)
        XCTAssertFalse(markup.takesTouch(atContentPoint: whiteOfPage0), "the scroll view has it")
        markup.begin(atContentPoint: whiteOfPage0)
        XCTAssertFalse(markup.isMarking)
        let ok = await markup.end(atContentPoint: try contentPoint(ofGlyph: 3, page: 0, in: model))
        XCTAssertFalse(ok)
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
        XCTAssertNil(model.selection?.selection)
    }

    /// With the page's text read, a drag that starts on a word still marks.
    func testADragThatStartsOnAWordStillMarks() async throws {
        let (controller, model) = await makeController()
        model.tool = .highlight
        let markup = controller.markupInteraction
        await markup.loadText(onPage: 0)
        let start = try contentPoint(ofGlyph: 0, page: 0, in: model)
        XCTAssertTrue(markup.takesTouch(atContentPoint: start))
        markup.begin(atContentPoint: start)
        XCTAssertTrue(markup.isMarking)
        let ok = await markup.end(atContentPoint: try contentPoint(ofGlyph: 3, page: 0, in: model))
        XCTAssertTrue(ok)
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).first?.kind, .highlight)
    }

    /// A drag that starts just off a word (above it, within the slop on screen that has the touch taken
    /// as on the text) starts at that word, and marks from it: a drag taken for the text marks.
    func testADragThatStartsJustOffAWordMarksFromIt() async throws {
        let (controller, model) = await makeController()
        model.tool = .highlight
        let markup = controller.markupInteraction
        await markup.loadText(onPage: 0)
        let glyph = try XCTUnwrap(try XCTUnwrap(model.document()).pageText(page: 0).glyphs.first).rect
        let above = CGPoint(x: (glyph.x + glyph.width / 2) * scale, y: (glyph.y - markup.hitSlop(onPage: 0) * 0.8) * scale)
        XCTAssertTrue(markup.takesTouch(atContentPoint: above))
        markup.begin(atContentPoint: above)
        let ok = await markup.end(atContentPoint: try contentPoint(ofGlyph: 3, page: 0, in: model))
        XCTAssertTrue(ok, "a drag taken as on the text marked nothing")
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).first?.kind, .highlight)
    }

    /// The same down the line of a turned page, where the text runs down and a finger just above the
    /// line's first glyph is level with no line of text (the UI test `testDraggingDownTheTextOfATurnedPageMarksIt`).
    func testADragThatStartsJustBeforeATurnedLineMarksFromIt() async throws {
        let model = isolatedModel(bytes: try fixtureData("rotated"))
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(origin: .zero, size: CGSize(width: 400, height: 800))
        controller.view.layoutIfNeeded()
        await model.settle()
        model.tool = .highlight
        let markup = controller.markupInteraction
        await markup.loadText(onPage: 0)
        let glyphs = try XCTUnwrap(model.document()).pageText(page: 0).glyphs
        let first = try XCTUnwrap(glyphs.first).rect, fourth = glyphs[3].rect
        XCTAssertGreaterThan(fourth.y, first.y, "the line runs down the page")
        let scale = 400.0 / CGFloat(model.pages[0].widthPt)
        let above = CGPoint(x: (first.x + first.width / 2) * scale, y: (first.y - markup.hitSlop(onPage: 0) * 0.9) * scale)
        XCTAssertTrue(markup.takesTouch(atContentPoint: above))
        markup.begin(atContentPoint: above)
        let ok = await markup.end(atContentPoint: CGPoint(x: (fourth.x + fourth.width / 2) * scale, y: (fourth.y + fourth.height / 2) * scale))
        XCTAssertTrue(ok, "a drag taken as on the text marked nothing")
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).first?.kind, .highlight)
    }

    /// A finger a little off the text, within 8 points on screen of a glyph, is on it; further off it is not.
    func testATouchJustOffTheTextIsOnIt() async throws {
        let (controller, model) = await makeController()
        model.tool = .underline
        let markup = controller.markupInteraction
        await markup.loadText(onPage: 0)
        let glyph = try XCTUnwrap(try XCTUnwrap(model.document()).pageText(page: 0).glyphs.first).rect
        let slop = markup.hitSlop(onPage: 0)
        XCTAssertEqual(markup.isNearText(CGPoint(x: glyph.x - slop * 0.9, y: glyph.y + glyph.height / 2), onPage: 0), true)
        XCTAssertEqual(markup.isNearText(CGPoint(x: glyph.x - slop * 1.1, y: glyph.y + glyph.height / 2), onPage: 0), false)
    }

    /// Until a page's text has been read, a touch on it is taken (as before the fix): the first touch
    /// asks for the text, and once it is read the white of the page scrolls.
    func testBeforeThePagesTextIsReadATouchOnItIsTaken() async throws {
        let (controller, model) = await makeController()
        model.tool = .strikeout
        let markup = controller.markupInteraction
        XCTAssertNil(markup.isNearText(CGPoint(x: 400, y: 400), onPage: 1), "not read yet; this asks for it")
        XCTAssertTrue(markup.takesTouch(atContentPoint: CGPoint(x: 300, y: 530 + 300)))
        // The reading asked for above, still on its way.
        await markup.text.settle()
        XCTAssertEqual(markup.isNearText(CGPoint(x: 400, y: 400), onPage: 1), false)
        XCTAssertFalse(markup.takesTouch(atContentPoint: CGPoint(x: 300, y: 530 + 300)))
    }

    /// The glyph boxes are of one revision of the document: after a change they are read again.
    func testThePagesTextIsReadAgainAfterAChange() async throws {
        let (controller, model) = await makeController()
        model.tool = .highlight
        let markup = controller.markupInteraction
        await markup.loadText(onPage: 0)
        XCTAssertNotNil(markup.isNearText(CGPoint(x: 10, y: 10), onPage: 0))
        await model.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        XCTAssertNil(markup.isNearText(CGPoint(x: 10, y: 10), onPage: 0), "the boxes of the old revision are dropped")
    }

    /// The pan's delegate, asked directly. A touch that never went down, and a recognizer with no touch,
    /// are at the content view's origin: the top left corner of page 0, white.
    func testTheDelegateAnswersForTheWhiteOfAPage() async throws {
        let (controller, model) = await makeController()
        let markup = controller.markupInteraction
        let touch = UITouch()
        XCTAssertEqual(touch.location(in: controller.contentView), .zero)
        XCTAssertFalse(markup.gestureRecognizer(markup.pan, shouldReceive: touch), "reading: the scroll view has it")
        XCTAssertFalse(markup.gestureRecognizerShouldBegin(markup.pan))
        model.tool = .highlight
        XCTAssertTrue(markup.gestureRecognizer(markup.pan, shouldReceive: touch), "the page's text is not read yet: taken")
        await markup.text.settle()
        XCTAssertFalse(markup.gestureRecognizer(markup.pan, shouldReceive: touch), "read: white, so the scroll view has it")
        XCTAssertFalse(markup.gestureRecognizerShouldBegin(markup.pan), "nor does the pan begin there")
        XCTAssertFalse(markup.gestureRecognizer(controller.selectionInteraction.longPress, shouldReceive: touch), "not its recognizer")
    }

    /// The same delegate, for a touch on text: a page whose line starts at its top left corner, where a
    /// touch that never went down is.
    func testTheDelegateAnswersForText() async throws {
        let bytes = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage()
            ("Corner" as NSString).draw(at: .zero, withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
        }
        let model = isolatedModel(bytes: bytes)
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(origin: .zero, size: CGSize(width: 400, height: 800))
        controller.view.layoutIfNeeded()
        await model.settle()
        let markup = controller.markupInteraction
        let touch = UITouch()
        model.tool = .strikeout
        await markup.loadText(onPage: 0)
        XCTAssertEqual(markup.isNearText(.zero, onPage: 0), true)
        XCTAssertTrue(markup.gestureRecognizer(markup.pan, shouldReceive: touch), "on text: the pan takes it")
        XCTAssertTrue(markup.gestureRecognizerShouldBegin(markup.pan), "and begins")
        model.tool = .select
        XCTAssertFalse(markup.gestureRecognizer(markup.pan, shouldReceive: touch), "Select: not the pan's")
    }

    // MARK: Reading the pages' text (fix round 2)

    /// Pages asked for one after the other in quick succession (a fling) are not all read: only those
    /// still wanted when a read starts.
    func testPagesScrolledPastQuicklyAreNotRead() async {
        let log = ReadLog()
        let text = PageTextBoxes(revision: { 1 }) { page, _ in log.add(page); return [] }
        for page in 0...20 { text.want([page]) }
        await text.settle()
        XCTAssertEqual(log.pages, [20])
        XCTAssertNotNil(text.boxes(onPage: 20))
    }

    /// The same through the scroll view's calls: the markup interaction asks for the pages in view as
    /// they go by, and only the last are read.
    func testTheScrollViewsRequestsReadOnlyThePagesInViewAtTheEnd() async throws {
        let (controller, model) = await makeController(pages: 30)
        let markup = controller.markupInteraction
        let log = ReadLog()
        markup.text = PageTextBoxes(revision: { [weak model] in model?.revision ?? 0 }) { page, _ in log.add(page); return [] }
        model.tool = .underline
        for first in 0...20 { markup.prefetchText(onPages: first..<(first + 2)) }
        await markup.text.settle()
        XCTAssertEqual(Set(log.pages), [20, 21])
    }

    /// At most `pagesKept` pages are read ahead, nearest the middle of the view first.
    func testAtMostEightPagesAreReadAheadNearestTheMiddleFirst() async throws {
        let (controller, model) = await makeController(pages: 30)
        let markup = controller.markupInteraction
        let log = ReadLog()
        markup.text = PageTextBoxes(revision: { [weak model] in model?.revision ?? 0 }) { page, _ in log.add(page); return [] }
        model.tool = .highlight
        markup.prefetchText(onPages: 0..<21)
        XCTAssertEqual(markup.text.wanted.count, PageTextBoxes.pagesKept)
        XCTAssertEqual(markup.text.wanted.first, 10, "the middle of the view first")
        XCTAssertEqual(Set(markup.text.wanted), Set(6...13))
        await markup.text.settle()
        XCTAssertEqual(log.pages.count, PageTextBoxes.pagesKept)
        XCTAssertEqual(log.pages.first, 10)
    }

    /// Nothing is read ahead for a tool that does not mark text, or one that may not be used.
    func testNothingIsReadAheadWithoutAUsableTextTool() async throws {
        let model = isolatedModel(bytes: PageScrollViewControllerTests.letterPages(3))
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(origin: .zero, size: CGSize(width: 400, height: 800))
        controller.view.layoutIfNeeded()
        let markup = controller.markupInteraction
        model.tool = .highlight
        markup.prefetchText(onPages: 0..<2)
        XCTAssertEqual(markup.text.wanted, [], "the document's permissions are not read yet: refused")
        await model.settle()
        markup.prefetchText(onPages: 0..<2)
        XCTAssertEqual(Set(markup.text.wanted), [0, 1])
        model.tool = .ink
        markup.prefetchText(onPages: 0..<2)
        XCTAssertEqual(markup.text.wanted, [], "not a text tool: what was not started is not read")
    }

    /// A read that comes back for a page scrolled past is kept as the one used longest ago: it never
    /// pushes out the boxes of a page in view.
    func testALateReadDoesNotPushOutThePagesInView() async throws {
        let log = ReadLog()
        let gate = DispatchSemaphore(value: 0)
        let text = PageTextBoxes(revision: { 1 }) { page, _ in
            log.add(page)
            if page == 0 { _ = gate.wait(timeout: .now() + 5) }
            return [CGRect(x: 0, y: 0, width: 1, height: 1)]
        }
        let inView = Array(1...PageTextBoxes.pagesKept)
        text.want(inView)
        await text.settle()
        text.want([0])
        for _ in 0..<1000 where !log.pages.contains(0) { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(log.pages.contains(0), "page 0 is being read")
        text.want(inView)
        gate.signal()
        await text.settle()
        for page in inView { XCTAssertNotNil(text.boxes(onPage: page), "page \(page) was pushed out") }
        XCTAssertNil(text.boxes(onPage: 0), "the late read was the first to go")
    }

    /// A page whose text the engine cannot read is read once for a revision of the document, not over
    /// and over: it counts as a page without text (a finger there scrolls), the other pages wanted are
    /// still read, and it is read again once the document changes.
    func testAPageThatCannotBeReadIsReadOncePerRevision() async {
        let log = ReadLog()
        let revision = RevisionBox()
        let text = PageTextBoxes(revision: { revision.value }) { page, _ in
            log.add(page)
            return page == 3 ? nil : [CGRect(x: 0, y: 0, width: 1, height: 1)]
        }
        text.want([3, 4])
        await text.settle()
        XCTAssertEqual(log.pages, [3, 4], "the unreadable page once, and the next one wanted")
        XCTAssertEqual(text.boxes(onPage: 3), [], "no text to touch: a finger there scrolls")
        text.want([3, 4])
        text.request(3)
        await text.settle()
        XCTAssertEqual(log.pages, [3, 4], "not read again at the same revision")
        revision.value = 2
        XCTAssertNil(text.boxes(onPage: 3), "a new revision: not known")
        text.want([3])
        await text.settle()
        XCTAssertEqual(log.pages, [3, 4, 3], "read again, once")
    }

    // MARK: Two fingers (fix round 2)

    /// The pan counts every finger on the screen, not only its own: a second one down fails it.
    func testASecondFingerAnywhereCounts() {
        XCTAssertFalse(MarkupPanGestureRecognizer.isMoreThanOneFinger([.began]))
        XCTAssertFalse(MarkupPanGestureRecognizer.isMoreThanOneFinger([.moved]))
        XCTAssertTrue(MarkupPanGestureRecognizer.isMoreThanOneFinger([.moved, .began]), "a second finger elsewhere")
        XCTAssertTrue(MarkupPanGestureRecognizer.isMoreThanOneFinger([.moved, .stationary]))
        XCTAssertFalse(MarkupPanGestureRecognizer.isMoreThanOneFinger([.moved, .ended]), "a finger that has come up")
        XCTAssertFalse(MarkupPanGestureRecognizer.isMoreThanOneFinger([.moved, .cancelled]))
    }

    // MARK: Lines (Minor 1)

    /// A page of `lines` lines of 24-point text, 48 points apart, from 72 points down.
    static func linesPage(_ lines: [String]) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage()
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 72, y: 72 + CGFloat(index) * 48), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
    }

    /// A selection across two lines is marked with one quad for each line, not one box over both.
    func testAMarkOverTwoLinesHasAQuadForEachLine() async throws {
        let model = isolatedModel(bytes: Self.linesPage(["First line", "Second line"]))
        await model.settle()
        let document = try XCTUnwrap(model.document())
        let glyphs = try document.pageText(page: 0).glyphs
        let first = try XCTUnwrap(glyphs.first).rect
        let last = try XCTUnwrap(glyphs.last).rect
        XCTAssertGreaterThan(last.y, first.y + 30, "two lines")
        model.selection?.beginWord(page: 0, at: CGPoint(x: first.x + first.width / 2, y: first.y + first.height / 2))
        await model.selection?.waitUntilSettled()
        model.selection?.extend(to: CGPoint(x: last.x + last.width, y: last.y + last.height / 2))
        await model.selection?.waitUntilSettled()
        let lines = try XCTUnwrap(model.selection?.pageRects?.rects)
        XCTAssertEqual(lines.count, 2, "one box for each line")
        let ok = await model.markSelection(.highlight)
        XCTAssertTrue(ok)
        let saved = try document.save(mode: .incremental)
        let annotation = try XCTUnwrap(PDFDocument(data: saved)?.page(at: 0)?.annotations.first { $0.type == "Highlight" })
        XCTAssertEqual(annotation.quadrilateralPoints?.count, 8, "two quads of four points")
    }

    // MARK: The menu

    func menu(of controller: PageScrollViewController) throws -> UIMenu {
        let menuInteraction = try XCTUnwrap(controller.scrollView.interactions.compactMap { $0 as? UIEditMenuInteraction }.first)
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero)
        return try XCTUnwrap(controller.selectionInteraction.editMenuInteraction(menuInteraction, menuFor: configuration, suggestedActions: []))
    }

    func testTheMenuOffersCopyHighlightUnderlineAndStrikethrough() async throws {
        let (controller, _) = await makeController()
        XCTAssertEqual(try menu(of: controller).children.map(\.title), [Strings.copy, Strings.highlight, Strings.underline, Strings.strikeout])
        XCTAssertEqual(try menu(of: controller).children.map(\.title), ["Copy", "Highlight", "Underline", "Strikethrough"])
    }

    func testTheMenusHighlightMarksTheSelection() async throws {
        let (controller, model) = await makeController()
        model.selection?.beginWord(page: 0, at: CGPoint(x: 80, y: 84)); await model.selection?.waitUntilSettled()
        XCTAssertNotNil(model.selection?.selection)
        let ok = await controller.selectionInteraction.mark(.highlight)
        XCTAssertTrue(ok)
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).first?.kind, .highlight)
    }
}

/// The pages a reader was asked for, in order, from any thread.
final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var read: [Int] = []

    func add(_ page: Int) { lock.withLock { read.append(page) } }
    var pages: [Int] { lock.withLock { read } }
}

/// A revision of the document that a test moves on.
@MainActor
final class RevisionBox {
    var value: UInt64 = 1
}
