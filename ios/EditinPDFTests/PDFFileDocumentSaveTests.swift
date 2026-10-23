import EditinPDFCore
import UniformTypeIdentifiers
import XCTest
@testable import EditinPDF

/// What Save writes: the engine's incremental save of the open document, and nothing for a document
/// that is locked or could not be read. (A write Save did not ask for: `SavingTests`.)
@MainActor final class PDFFileDocumentSaveTests: XCTestCase {
    func testSnapshotOfUntouchedDocumentWritesTheOriginalBytes() throws {
        let bytes = try fixtureData("hello")
        let file = PDFFileDocument(bytes: bytes)
        let snap = try file.snapshot(contentType: .pdf)
        XCTAssertEqual(try snap.document.save(mode: .incremental), bytes)
    }

    func testSnapshotAfterAnEditReopensWithTheEdit() throws {
        let file = PDFFileDocument(bytes: try fixtureData("hello"))
        let doc = try XCTUnwrap(file.engine.document)
        _ = try doc.apply(edit: .rotatePages(pages: [0], degrees: 90), baseRevision: 0)
        // What fileWrapper writes (WriteConfiguration has no public init; the write itself is covered
        // by Task 11's UI test reopening the file).
        let data = try file.snapshot(contentType: .pdf).document.save(mode: .incremental)
        XCTAssertEqual(try PdfDocument.open(bytes: data, password: nil).pageInfo(page: 0)?.rotationDegrees, 90)
    }

    func testSnapshotOfLockedOrFailedDocumentThrows() throws {
        XCTAssertThrowsError(try PDFFileDocument(bytes: Data("garbage".utf8)).snapshot(contentType: .pdf))
        let locked = try fixtureData("locked")
        XCTAssertThrowsError(try PDFFileDocument(bytes: locked).snapshot(contentType: .pdf))
    }

    func testUnlockingAdoptsTheDocumentForSaving() async throws {
        let file = PDFFileDocument(bytes: try fixtureData("locked"))
        XCTAssertNil(file.engine.document)
        let opened = await file.model.unlock(password: "hunter2")   // locked.pdf's password, as in ViewerSmokeTests
        XCTAssertTrue(opened); XCTAssertNotNil(file.engine.document)
    }

    func testNewDocumentIsOneBlankPage() throws {
        let file = PDFFileDocument()
        XCTAssertEqual(file.engine.document?.pageCount(), 1)
        XCTAssertEqual(file.model.pages.first.map { [595.0, 612.0].contains($0.widthPt.rounded()) }, true)
    }

    /// A refused write says why in our words, not the engine's.
    func testTheRefusalOfASnapshotCarriesOurReason() {
        do {
            _ = try PDFFileDocument(bytes: Data("garbage".utf8)).snapshot(contentType: .pdf)
            XCTFail("expected a refusal")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileWriteUnknown)
            XCTAssertEqual(error.userInfo[NSLocalizedFailureReasonErrorKey] as? String, Strings.saveFailed)
        } catch {
            XCTFail("expected a CocoaError, got \(error)")
        }
    }

    /// The model and the file share one handle: what the screen edits is what Save writes.
    func testTheModelEditsTheDocumentTheFileSaves() throws {
        let file = PDFFileDocument(bytes: try fixtureData("hello"))
        XCTAssertTrue(file.model.document() === file.engine.document)
    }
}
