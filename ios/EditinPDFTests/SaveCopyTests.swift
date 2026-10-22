import EditinPDFCore
import PencilKit
import UIKit
import XCTest
@testable import EditinPDF

/// Save a Copy: the bytes of the copy (`DocumentModel.copyBytes`) are what autosave would write, with
/// everything waiting added first and every change on its way made, and the document stays open and as
/// it was: still changed (nothing tells the engine it saved), with the same changes.
@MainActor
final class SaveCopyTests: XCTestCase {
    /// `pages` US Letter pages in a 400 x 800 view, `tool` picked, with an undo manager.
    func makeController(pages: Int = 3, tool: Tool?) async -> (PageScrollViewController, DocumentModel) {
        let model = isolatedModel(bytes: PageScrollViewControllerTests.letterPages(pages))
        model.undoManager = UndoManager()
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(origin: .zero, size: CGSize(width: 400, height: 800))
        controller.view.layoutIfNeeded()
        await model.settle()
        model.tool = tool
        controller.markupTool = tool
        return (controller, model)
    }

    /// A line across page 0, from (100, 100) to (200, 150), on Draw's canvas, waiting to be added.
    func drawALine(in controller: PageScrollViewController) throws {
        let drawing = controller.markupInteraction.drawing
        XCTAssertTrue(drawing.prepareToDraw(atContentPoint: CGPoint(x: 200, y: 200)))
        let ink = try XCTUnwrap(drawing.ink)
        let points = (0...20).map { CGPoint(x: 100 + 5 * Double($0), y: 100 + 2.5 * Double($0)) }
        let stroke = InkGeometryTests.stroke(points.map { CGPoint(x: ($0.x - ink.canvasOrigin.x) / ink.pointsPerCanvasPoint,
                                                                  y: ($0.y - ink.canvasOrigin.y) / ink.pointsPerCanvasPoint) })
        ink.drawing = PKDrawing(strokes: [stroke])
        drawing.canvasViewDrawingDidChange(ink)
    }

    /// The copy has the strokes waiting on the canvas and the changes made before them, opens as a PDF
    /// of its own, and the document it was made from is still changed, with the same changes, and its
    /// own save writes the same bytes.
    func testACopyHasTheStrokesWaitingAndLeavesTheDocumentAsItWas() async throws {
        let (controller, model) = await makeController(tool: .ink)
        let turned = await model.perform(.rotatePages(pages: [1], degrees: 90), named: Strings.actionRotate, touching: [1])
        XCTAssertTrue(turned)
        try drawALine(in: controller)
        XCTAssertTrue(model.hasPendingInk)

        let bytes = try await model.copyBytes().get()

        let copy = try PdfDocument.open(bytes: bytes, password: nil)
        XCTAssertEqual(copy.pageCount(), 3)
        XCTAssertEqual(copy.pageInfo(page: 1)?.rotationDegrees, 90, "the change made before")
        XCTAssertEqual(copy.annotations().filter { $0.page == 0 }.map(\.kind), [.ink], "the strokes that were waiting")
        let document = try XCTUnwrap(model.document())
        XCTAssertTrue(document.isDirty(), "the document still has changes to save")
        XCTAssertFalse(model.hasPendingInk)
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).map(\.kind), [.ink])
        XCTAssertEqual(model.pages[1].rotationDegrees, 90)
        let revision = model.revision
        XCTAssertEqual(try document.save(mode: .incremental), bytes, "the copy is what the file's own save writes")
        XCTAssertEqual(model.revision, revision, "making the copy changed nothing")
    }

    /// Text being typed in a text box is in the copy: the box ends, and its text is added first.
    func testACopyHasTheTextBeingTyped() async throws {
        let (controller, model) = await makeController(tool: .textBox)
        let markup = controller.markupInteraction
        let frame = try XCTUnwrap(controller.pageView(for: 0)).frame
        let scale = frame.width / CGFloat(model.pages[0].widthPt)
        markup.place(atContentPoint: CGPoint(x: frame.minX + 100 * scale, y: frame.minY + 200 * scale))
        let editor = try XCTUnwrap(markup.textBoxes.textEditor)
        editor.text = "Typed, not ended"
        editor.delegate?.textViewDidChange?(editor)
        XCTAssertTrue(model.hasPendingText)

        let bytes = try await model.copyBytes().get()

        let copy = try PdfDocument.open(bytes: bytes, password: nil)
        let boxes = copy.annotations().filter { $0.kind == .textBox }
        XCTAssertEqual(boxes.map(\.contents), ["Typed, not ended"])
        XCTAssertTrue(try XCTUnwrap(model.document()).isDirty())
    }

    /// A change handed over and not made yet is made before the copy is: the copy waits for it.
    func testACopyWaitsForTheChangesOnTheirWay() async throws {
        let (model, _) = try makeModel(fixture: "sample")
        await model.settle()
        model.enqueue([.rotatePages(pages: [0], degrees: 180)], named: Strings.actionRotate, touching: [0])
        let bytes = try await model.copyBytes().get()
        XCTAssertEqual(try PdfDocument.open(bytes: bytes, password: nil).pageInfo(page: 0)?.rotationDegrees, 180)
    }

    /// An unchanged document copies as the bytes it was opened from.
    func testACopyOfAnUnchangedDocumentIsTheFileAsOpened() async throws {
        let bytes = try fixtureData("hello")
        let model = isolatedModel(bytes: bytes)
        await model.settle()
        let copy = try await model.copyBytes().get()
        XCTAssertEqual(copy, bytes)
    }

    /// A password-protected document's copy keeps its password: the incremental save keeps the file's
    /// encryption. It needs the password to open, and has the change.
    func testACopyOfAProtectedDocumentKeepsItsPassword() async throws {
        let model = DocumentModel(outcome: OpenOutcome(bytes: try fixtureData("locked")), toolStyles: isolatedToolStyles(),
                                  signatures: isolatedSignatures())
        let opened = await model.unlock(password: "hunter2")   // locked.pdf's password, as in ViewerSmokeTests
        XCTAssertTrue(opened)
        await model.settle()
        let turned = await model.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        XCTAssertTrue(turned)

        let bytes = try await model.copyBytes().get()

        XCTAssertThrowsError(try PdfDocument.open(bytes: bytes, password: nil)) { error in
            XCTAssertEqual(error as? OpenError, .NeedsPassword, "the copy is still protected")
        }
        let copy = try PdfDocument.open(bytes: bytes, password: "hunter2")
        XCTAssertEqual(copy.pageInfo(page: 0)?.rotationDegrees, 90)
    }

    /// A document locked or not opened has no copy.
    func testALockedDocumentHasNoCopy() async throws {
        let model = DocumentModel(outcome: OpenOutcome(bytes: try fixtureData("locked")), toolStyles: isolatedToolStyles(),
                                  signatures: isolatedSignatures())
        let result = await model.copyBytes()
        XCTAssertEqual(result.failure, .failed)
    }

    /// A save the bridge refuses because it would break the document's signatures says so, in our
    /// sentence; any other failure says the copy was not saved.
    func testARefusedSaveSaysWhy() async throws {
        for (error, expected) in [(SaveError.Signed, CopyFailure.signed), (SaveError.Failed(message: "disk"), CopyFailure.failed)] {
            let document = RefusingDocument(wrapping: try PdfDocument.open(bytes: try fixtureData("hello"), password: nil), refusal: error)
            let pages = (0..<document.pageCount()).compactMap { document.pageInfo(page: $0) }
            let model = DocumentModel(outcome: .open(document, pages: pages), toolStyles: isolatedToolStyles(), signatures: isolatedSignatures())
            await model.settle()
            let result = await model.copyBytes()
            XCTAssertEqual(result.failure, expected, "\(error)")
        }
        XCTAssertEqual(CopyFailure.signed.message, Strings.copySignedMessage)
        XCTAssertEqual(CopyFailure.failed.message, Strings.copyFailedMessage)
    }

    /// The copy as the exporter writes it: the bytes, as a PDF.
    func testTheExportedFileIsTheCopysBytes() async throws {
        guard #available(iOS 18.2, *) else { throw XCTSkip("exported(as:) needs iOS 18.2") }
        let bytes = try fixtureData("hello")
        let exported = try await PDFCopy(bytes: bytes).exported(as: .pdf)
        XCTAssertEqual(exported, bytes)
    }
}

/// The engine document `real` is, except that every save is refused with `refusal`.
private final class RefusingDocument: PdfDocument, @unchecked Sendable {
    let refusal: SaveError

    init(wrapping real: PdfDocument, refusal: SaveError) {
        self.refusal = refusal
        super.init(unsafeFromHandle: real.uniffiCloneHandle())
    }

    required init(unsafeFromHandle handle: UInt64) {
        refusal = .Signed
        super.init(unsafeFromHandle: handle)
    }

    override func save(mode: SaveMode) throws -> Data {
        throw refusal
    }
}

private extension Result {
    /// The failure, nil on success.
    var failure: Failure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}
