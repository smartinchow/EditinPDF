import EditinPDFCore
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
        let model = DocumentModel(bytes: PageScrollViewControllerTests.letterPages(pages))
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
        for tool in [Tool.select, .ink, .eraser] {
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
        let model = DocumentModel(bytes: PageScrollViewControllerTests.letterPages(2))
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(origin: .zero, size: CGSize(width: 400, height: 800))
        controller.view.layoutIfNeeded()
        model.tool = .highlight
        // Before the document's permissions are read, no tool may be used.
        XCTAssertFalse(controller.markupInteraction.takesTouch(atContentPoint: CGPoint(x: 100, y: 100)))
        await model.settle()
        XCTAssertTrue(controller.markupInteraction.takesTouch(atContentPoint: CGPoint(x: 100, y: 100)))
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
