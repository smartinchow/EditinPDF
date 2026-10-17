import UniformTypeIdentifiers
import XCTest
@testable import EditinPDF

final class PDFFileDocumentTests: XCTestCase {
    func fixture() throws -> Data { try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "hello", withExtension: "pdf"))) }

    func testReadsPDFs() {
        XCTAssertEqual(PDFFileDocument.readableContentTypes, [.pdf])
    }

    func testSnapshotIsTheOriginalFileBytes() throws {
        let bytes = try fixture()
        let document = PDFFileDocument(bytes: bytes)
        XCTAssertEqual(try document.snapshot(contentType: .pdf), bytes)
    }

    @MainActor
    func testModelIsBuiltOnceFromWhatWasReadOffTheMainActor() async throws {
        let bytes = try fixture()
        // As in the document scene: the file is read, and the engine opens it, off the main actor.
        let document = await Task.detached { PDFFileDocument(bytes: bytes) }.value
        let model = document.model
        XCTAssertTrue(model === document.model, "every redraw of the scene must see the same model")
        guard case .open = model.state else { return XCTFail("expected open, got \(model.state)") }
        XCTAssertEqual(model.pageCount, 1)
    }

    @MainActor
    func testAFileTheEngineCannotReadIsADocumentInTheFailedState() {
        let document = PDFFileDocument(bytes: Data("not a pdf".utf8))
        guard case .failed(let detail) = document.model.state else { return XCTFail("expected failed, got \(document.model.state)") }
        XCTAssertNotNil(detail, "the engine says why, for the alert to show under its title")
    }
}
