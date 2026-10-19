import EditinPDFCore
import XCTest
@testable import EditinPDF

@MainActor
final class ExtractedPagesTests: XCTestCase {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testExtractedPagesWritesAPDFOfThosePages() throws {
        let doc = try PdfDocument.open(bytes: fixtureData("sample"), password: nil)
        let url = try ExtractedPages(document: doc, pages: [0, 2], fileName: "sample (pages 1–3)").write(to: scratch())
        XCTAssertEqual(url.pathExtension, "pdf")
        XCTAssertEqual(url.lastPathComponent, "sample (pages 1–3).pdf")
        XCTAssertEqual(try PdfDocument.open(bytes: Data(contentsOf: url), password: nil).pageCount(), 2)
    }

    func testFileNameWithSlashStaysInTheFolder() throws {
        let doc = try PdfDocument.open(bytes: fixtureData("sample"), password: nil)
        let dir = try scratch()
        let url = try ExtractedPages(document: doc, pages: [1], fileName: "a/b.pdf").write(to: dir)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
    }

    func testInsertingALockedPDFExplainsWhy() async throws {
        let (m, _) = try makeModel()
        await m.perform(.insertPagesFrom(name: "l.pdf", bytes: try fixtureData("locked"), pages: nil, at: 0), named: Strings.actionInsertFile, touching: nil)
        XCTAssertEqual(m.failure?.message, Strings.insertSourceLocked)
    }

    func testInsertFromFileAddsPagesAfterSelectionAndSelectsThem() async throws {
        let (m, _) = try makeModel()
        await m.settle()
        let c = OrganizeController(model: m)
        c.selection = [0]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try fixtureData("sample").write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        await c.insertFromFile(url)?.value
        XCTAssertNil(m.failure)
        XCTAssertEqual(m.pageCount, 6)
        XCTAssertEqual(c.selection, [1, 2, 3])
        XCTAssertFalse(c.isReadingFile)
        XCTAssertTrue(c.canInsertFile || m.isApplying)
    }

    func testOversizedFileIsRefusedWithoutChange() async throws {
        let (m, _) = try makeModel()
        await m.settle()
        let c = OrganizeController(model: m)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try fixtureData("sample").write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        await c.insertFromFile(url, limit: 10)?.value
        XCTAssertEqual(m.failure?.message, Strings.pickedFileTooLarge)
        XCTAssertEqual(m.pageCount, 3)
        XCTAssertFalse(c.isReadingFile)
    }

    func testMissingFileIsReportedUnreadable() async throws {
        let (m, _) = try makeModel()
        await m.settle()
        let c = OrganizeController(model: m)
        await c.insertFromFile(URL(fileURLWithPath: "/nonexistent/x.pdf"))?.value
        XCTAssertEqual(m.failure?.message, Strings.pickedFileUnreadable)
    }

    func testRenumberingActionsAreOffWhileAFileIsRead() async throws {
        let (m, _) = try makeModel()
        await m.settle()
        let c = OrganizeController(model: m)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try fixtureData("sample").write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let task = c.insertFromFile(url)
        XCTAssertTrue(c.isReadingFile)
        XCTAssertFalse(c.canInsertFile); XCTAssertFalse(c.canInsertBlank); XCTAssertFalse(c.canMove)
        XCTAssertNil(c.insertFromFile(url), "a second pick is ignored")
        await task?.value
        XCTAssertEqual(m.pageCount, 6)
    }

    func testExtractNamesTheFileByItsPages() async throws {
        let (m, _) = try makeModel()
        await m.settle()
        let c = OrganizeController(model: m, documentName: "doc")
        XCTAssertNil(c.extractedPages())
        c.selection = [1, 2]
        XCTAssertEqual(c.extractedPages()?.fileName, "doc (pages 2–3)")
        XCTAssertEqual(c.extractedPages()?.pages, [1, 2])
        c.selection = [1]
        XCTAssertEqual(c.extractedPages()?.fileName, "doc (page 2)")
    }

    func testIsEncryptedOnlyOnceUnlocked() async throws {
        let (m, _) = try makeModel()
        XCTAssertFalse(m.isEncrypted)
        let locked = DocumentModel(bytes: try fixtureData("locked"))
        XCTAssertFalse(locked.isEncrypted)
        await locked.unlock(password: "hunter2")
        XCTAssertTrue(locked.isEncrypted)
    }

    func testExtractStrings() {
        XCTAssertEqual(Strings.insertFromFile, "Insert from File…")
        XCTAssertEqual(Strings.extract, "Extract Pages")
        XCTAssertEqual(Strings.extractedFileName(base: "a", first: 2, last: 3), "a (pages 2–3)")
        XCTAssertEqual(Strings.extractedFileName(base: "a", first: 2, last: 2), "a (page 2)")
        XCTAssertEqual(Strings.extractUnprotectedNote, "The extracted pages are not password-protected.")
        XCTAssertEqual(Strings.untitledDocument, "Document")
        XCTAssertEqual(Strings.pickedFileTooLarge, "That file is too large to insert (over 500 MB).")
        XCTAssertEqual(Strings.pickedFileUnreadable, "That file could not be opened.")
    }
}
