import UIKit
import XCTest
@testable import EditinPDF

// `DocumentModel` is main-actor isolated (it drives SwiftUI), so the tests that build one are too.
@MainActor
final class DocumentModelTests: XCTestCase {
    func fixture() throws -> Data { try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "hello", withExtension: "pdf"))) }
    func testOpensFixture() throws {
        let m = DocumentModel(bytes: try fixture())
        guard case .open = m.state else { return XCTFail("expected open, got \(m.state)") }
        XCTAssertEqual(m.pageCount, 1)
        XCTAssertEqual(m.pages.count, 1)
    }
    func testCorruptBytesFail() {
        let m = DocumentModel(bytes: Data("garbage".utf8))
        guard case .failed = m.state else { return XCTFail() }
    }

    // MARK: Beyond the brief's two tests

    func testFailureTextLeadsWithOurSentenceAndNeverSaysDamaged() {
        let m = DocumentModel(bytes: Data("garbage".utf8))
        guard case .failed(let message) = m.state else { return XCTFail("expected failed, got \(m.state)") }
        XCTAssertTrue(message.hasPrefix("This file could not be opened."), message)
        XCTAssertFalse(Strings.fileCouldNotBeOpened.localizedCaseInsensitiveContains("damaged"))
        XCTAssertEqual(m.pageCount, 0)
        XCTAssertNil(m.document())
    }

    func testOpenModelExposesItsDocumentAndPageGeometry() throws {
        let m = DocumentModel(bytes: try fixture())
        let document = try XCTUnwrap(m.document())
        XCTAssertEqual(document.pageCount(), 1)
        let page = try XCTUnwrap(m.pages.first)
        XCTAssertEqual(page.index, 0)
        XCTAssertGreaterThan(page.widthPt, 0)
        XCTAssertGreaterThan(page.heightPt, 0)
        XCTAssertEqual(m.currentPage, 0)
    }

    func testBuildsFromAnOutcomeComputedElsewhere() async throws {
        let bytes = try fixture()
        // The engine's open is the slow part; the document scene runs it off the main actor.
        let outcome = await Task.detached { OpenOutcome(bytes: bytes) }.value
        let m = DocumentModel(outcome: outcome)
        guard case .open = m.state else { return XCTFail("expected open, got \(m.state)") }
        XCTAssertEqual(m.pageCount, 1)
    }

    func testWrongPasswordThreeTimesThenTheRightOne() {
        let m = DocumentModel(bytes: Self.encryptedPDF(openPassword: "s3cret"))
        // Without a password it is locked, and nothing has been refused yet.
        guard case .locked(_, let refused) = m.state else { return XCTFail("expected locked, got \(m.state)") }
        XCTAssertFalse(refused)
        XCTAssertEqual(m.pageCount, 0)
        XCTAssertNil(m.document())

        for attempt in 1...3 {
            XCTAssertFalse(m.unlock(password: "nope \(attempt)"))
            guard case .locked(_, let wrong) = m.state else { return XCTFail("expected locked, got \(m.state)") }
            XCTAssertTrue(wrong, "attempt \(attempt) should be reported as refused")
        }

        XCTAssertTrue(m.unlock(password: "s3cret"))
        guard case .open = m.state else { return XCTFail("expected open, got \(m.state)") }
        XCTAssertEqual(m.pageCount, 1)
        XCTAssertNotNil(m.document())
        XCTAssertTrue(m.unlock(password: "anything"), "an open document stays open")
    }

    func testUnlockDoesNothingForAFileThatFailedToOpen() {
        let m = DocumentModel(bytes: Data("garbage".utf8))
        XCTAssertFalse(m.unlock(password: "irrelevant"))
        guard case .failed = m.state else { return XCTFail("expected failed, got \(m.state)") }
    }

    /// A one-page PDF that needs `openPassword` to open, made by the system's own PDF writer so that
    /// the engine is tested against a file it did not produce itself.
    static func encryptedPDF(openPassword: String) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextUserPassword as String: openPassword,
            kCGPDFContextOwnerPassword as String: openPassword + " (owner)",
            kCGPDFContextEncryptionKeyLength as String: 128,
        ]
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: page, format: format).pdfData { context in
            context.beginPage()
            "Locked page".draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
    }
}
