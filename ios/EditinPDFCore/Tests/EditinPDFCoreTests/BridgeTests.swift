import XCTest
@testable import EditinPDFCore

final class BridgeTests: XCTestCase {
    func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "hello", withExtension: "pdf", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    func testVersionMentionsPdfcraft() {
        XCTAssertTrue(engineVersion().contains("pdfcraft v0.7"))
        XCTAssertTrue(engineVersion().hasPrefix("editinpdf-core 0.2.0"))
    }
    func testSearchHitLimitIsExported() { XCTAssertEqual(searchHitLimit(), 1000) }
    func testOpenRenderSearch() throws {
        let doc = try PdfDocument.open(bytes: fixture(), password: nil)
        XCTAssertEqual(doc.pageCount(), 1)
        let tile = try doc.renderTile(page: 0, scale: 1, rect: TileRect(x: 0, y: 0, width: 64, height: 64))
        XCTAssertEqual(tile.rgba.count, 64 * 64 * 4)
        XCTAssertEqual(doc.search(query: "hello", caseSensitive: false).count, 1)
    }
    func testCorruptThrowsTypedError() {
        XCTAssertThrowsError(try PdfDocument.open(bytes: Data("nope".utf8), password: nil)) { error in
            guard case OpenError.Corrupt = error else { return XCTFail("expected Corrupt, got \(error)") }
        }
    }
    func testEditSaveReopenFromSwift() throws {
        let doc = try PdfDocument.open(bytes: fixture(), password: nil)
        let outcome = try doc.apply(edit: .insertBlankPage(at: 1, widthPt: 200, heightPt: 300), baseRevision: 0)
        XCTAssertEqual(outcome.revision, 1)
        XCTAssertThrowsError(try doc.apply(edit: .deletePages(pages: [0]), baseRevision: 0)) { error in
            guard case EditError.Stale(let current) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(current, 1)
        }
        let back = try PdfDocument.open(bytes: doc.save(mode: .incremental), password: nil)
        XCTAssertEqual(back.pageCount(), 2)
        XCTAssertEqual(try PdfDocument.open(bytes: blankDocument(widthPt: 595, heightPt: 842), password: nil).pageCount(), 1)
    }
}
