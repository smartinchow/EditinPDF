import EditinPDFCore
import os
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

    func testFailureIsOurTitleOverTheEnginesExplanationAndNeverSaysDamaged() {
        let m = DocumentModel(bytes: Data("garbage".utf8))
        guard case .failed(let detail) = m.state else { return XCTFail("expected failed, got \(m.state)") }
        XCTAssertEqual(Strings.fileCouldNotBeOpened, "This file could not be opened.")
        guard let detail else { return XCTFail("the engine says why it could not read the file") }
        // A sentence of its own, to go under the title; the title is not repeated in it.
        XCTAssertFalse(detail.hasPrefix(Strings.fileCouldNotBeOpened), detail)
        // What the reader sees, the title and the message together, never calls the file damaged.
        XCTAssertFalse("\(Strings.fileCouldNotBeOpened) \(detail)".localizedCaseInsensitiveContains("damaged"))
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

    func testWrongPasswordThreeTimesThenTheRightOne() async {
        let m = DocumentModel(bytes: Self.encryptedPDF(openPassword: "s3cret"))
        // Without a password it is locked, and nothing has been refused yet.
        guard case .locked(_, let refused) = m.state else { return XCTFail("expected locked, got \(m.state)") }
        XCTAssertFalse(refused)
        XCTAssertEqual(m.pageCount, 0)
        XCTAssertNil(m.document())

        for attempt in 1...3 {
            let opened = await m.unlock(password: "nope \(attempt)")
            XCTAssertFalse(opened)
            guard case .locked(_, let wrong) = m.state else { return XCTFail("expected locked, got \(m.state)") }
            XCTAssertTrue(wrong, "attempt \(attempt) should be reported as refused")
        }

        let opened = await m.unlock(password: "s3cret")
        XCTAssertTrue(opened)
        guard case .open = m.state else { return XCTFail("expected open, got \(m.state)") }
        XCTAssertEqual(m.pageCount, 1)
        XCTAssertNotNil(m.document())
        let again = await m.unlock(password: "anything")
        XCTAssertTrue(again, "an open document stays open")
    }

    func testUnlockDoesNothingForAFileThatFailedToOpen() async {
        let m = DocumentModel(bytes: Data("garbage".utf8))
        let opened = await m.unlock(password: "irrelevant")
        XCTAssertFalse(opened)
        guard case .failed = m.state else { return XCTFail("expected failed, got \(m.state)") }
    }

    // MARK: Unlocking runs the engine off the main actor

    /// What the opening closure of an unlock saw, written from the thread it ran on.
    private final class Probe: Sendable {
        private let threads = OSAllocatedUnfairLock(initialState: [Bool]())
        func record() { threads.withLock { $0.append(Thread.isMainThread) } }
        /// For each call: whether it ran on the main thread.
        var ranOnMain: [Bool] { threads.withLock { $0 } }
    }

    func testUnlockOpensTheFileOffTheMainThread() async {
        let m = DocumentModel(bytes: Self.encryptedPDF(openPassword: "s3cret"))
        let probe = Probe()
        let opened = await m.unlock(password: "s3cret") { bytes, password in
            probe.record()
            return OpenOutcome(bytes: bytes, password: password)
        }
        XCTAssertTrue(opened)
        XCTAssertEqual(probe.ranOnMain, [false], "the engine's open is the slow part: it must not block the main actor")
        guard case .open = m.state else { return XCTFail("expected open, got \(m.state)") }
    }

    func testAWrongPasswordIsAlsoTriedOffTheMainThread() async {
        let m = DocumentModel(bytes: Self.encryptedPDF(openPassword: "s3cret"))
        let probe = Probe()
        let opened = await m.unlock(password: "nope") { bytes, password in
            probe.record()
            return OpenOutcome(bytes: bytes, password: password)
        }
        XCTAssertFalse(opened)
        XCTAssertEqual(probe.ranOnMain, [false])
        guard case .locked(_, let wrong) = m.state else { return XCTFail("expected locked, got \(m.state)") }
        XCTAssertTrue(wrong)
    }

    func testAFileTheEngineRefusesAfterThePasswordFailsOutright() async {
        // A password can get the engine past the lock and then meet something it cannot read.
        let m = DocumentModel(bytes: Self.encryptedPDF(openPassword: "s3cret"))
        let opened = await m.unlock(password: "s3cret") { _, _ in .failed(detail: "Unsupported encryption.") }
        XCTAssertFalse(opened)
        guard case .failed(let detail) = m.state else { return XCTFail("expected failed, got \(m.state)") }
        XCTAssertEqual(detail, "Unsupported encryption.")
        XCTAssertNil(m.document())
        XCTAssertNil(m.search)
        XCTAssertNil(m.selection)
    }

    func testAnUnlockThatFinishesAfterTheDocumentIsOpenLeavesItAlone() async throws {
        let m = DocumentModel(bytes: Self.encryptedPDF(openPassword: "s3cret"))
        // The first unlock is held inside the engine's open until the second has finished.
        let slowStarted = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        async let slow = m.unlock(password: "s3cret") { bytes, password in
            slowStarted.withLock { $0 = true }
            _ = release.wait(timeout: .now() + 10)
            return OpenOutcome(bytes: bytes, password: password)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !slowStarted.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(slowStarted.withLock { $0 }, "the first unlock never reached the engine")
        let second = await m.unlock(password: "s3cret")
        XCTAssertTrue(second)
        let opened = try XCTUnwrap(m.document())
        let search = try XCTUnwrap(m.search)

        release.signal()
        let first = await slow
        XCTAssertTrue(first, "the document is open")
        XCTAssertTrue(m.document() === opened, "a late answer does not replace the document that is already on screen")
        XCTAssertTrue(m.search === search, "nor its search")
    }

    func testAnOpenDocumentHasASearchAndOthersDoNot() async throws {
        let open = DocumentModel(bytes: try fixture())
        let search = try XCTUnwrap(open.search)
        XCTAssertTrue(search === open.search, "one search for the document, not a new one at every look")
        XCTAssertTrue(search.hits.isEmpty)

        XCTAssertNil(DocumentModel(bytes: Data("garbage".utf8)).search, "nothing to search in a file that did not open")

        // A locked document gets its search when the password opens it.
        let locked = DocumentModel(bytes: Self.encryptedPDF(openPassword: "s3cret"))
        XCTAssertNil(locked.search)
        let refused = await locked.unlock(password: "nope")
        XCTAssertFalse(refused)
        XCTAssertNil(locked.search)
        let accepted = await locked.unlock(password: "s3cret")
        XCTAssertTrue(accepted)
        let unlocked = try XCTUnwrap(locked.search)
        let again = await locked.unlock(password: "anything")
        XCTAssertTrue(again, "an open document stays open")
        XCTAssertTrue(unlocked === locked.search, "and keeps its search")
    }

    func testTheSearchDoesNotKeepTheModelAlive() throws {
        var model: DocumentModel? = DocumentModel(bytes: try fixture())
        weak let weakModel = model
        let search = model?.search
        model = nil
        XCTAssertNil(weakModel, "the search holds the engine's document, never the model")
        XCTAssertNotNil(search)
    }

    func testTheModelsSearchFindsTextInItsDocument() async throws {
        let model = DocumentModel(bytes: try fixture())
        let search = try XCTUnwrap(model.search)
        search.query = "world"
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while search.hits.count != 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(search.hits.count, 1)
    }

    func testAnOpenDocumentHasASelectionAndOthersDoNot() async throws {
        let open = DocumentModel(bytes: try fixture())
        let selection = try XCTUnwrap(open.selection)
        XCTAssertTrue(selection === open.selection, "one selection for the document, not a new one at every look")
        XCTAssertNil(selection.selection)

        XCTAssertNil(DocumentModel(bytes: Data("garbage".utf8)).selection, "nothing to select in a file that did not open")

        // A locked document gets its selection when the password opens it.
        let locked = DocumentModel(bytes: Self.encryptedPDF(openPassword: "s3cret"))
        XCTAssertNil(locked.selection)
        let refused = await locked.unlock(password: "nope")
        XCTAssertFalse(refused)
        XCTAssertNil(locked.selection)
        let accepted = await locked.unlock(password: "s3cret")
        XCTAssertTrue(accepted)
        let unlocked = try XCTUnwrap(locked.selection)
        let again = await locked.unlock(password: "anything")
        XCTAssertTrue(again, "an open document stays open")
        XCTAssertTrue(unlocked === locked.selection, "and keeps its selection")
    }

    func testTheSelectionDoesNotKeepTheModelAlive() throws {
        var model: DocumentModel? = DocumentModel(bytes: try fixture())
        weak let weakModel = model
        let selection = model?.selection
        model = nil
        XCTAssertNil(weakModel, "the selection holds the engine's document, never the model")
        XCTAssertNotNil(selection)
    }

    func testTheModelsSelectionSelectsTextInItsDocument() async throws {
        let model = DocumentModel(bytes: try fixture())
        let selection = try XCTUnwrap(model.selection)
        // "Hello world" is drawn at the page's top left, so a point inside it, a little in from the corner.
        let text = try XCTUnwrap(model.document()).pageText(page: 0)
        let glyph = try XCTUnwrap(text.glyphs.first)
        selection.beginWord(page: 0, at: CGPoint(x: glyph.rect.x + glyph.rect.width / 2, y: glyph.rect.y + glyph.rect.height / 2))
        await selection.waitUntilSettled()
        XCTAssertEqual(selection.text, "Hello")
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
