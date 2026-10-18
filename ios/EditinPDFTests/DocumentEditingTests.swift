import EditinPDFCore
import XCTest
@testable import EditinPDF

// The model is main-actor isolated, so the tests are too. `sample.pdf` has three pages.
@MainActor
final class DocumentEditingTests: XCTestCase {
    func testRotateThenUndoThroughTheUndoManager() async throws {
        let (m, u) = try makeModel()
        let ok = await m.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        XCTAssertTrue(ok); XCTAssertEqual(m.pages[0].rotationDegrees, 90); XCTAssertEqual(m.revision, 1)
        XCTAssertTrue(u.canUndo); XCTAssertEqual(u.undoActionName, Strings.actionRotate)
        u.undo(); await m.settle()
        XCTAssertEqual(m.pages[0].rotationDegrees, 0); XCTAssertTrue(u.canRedo)
        u.redo(); await m.settle(); XCTAssertEqual(m.pages[0].rotationDegrees, 90)
    }

    func testUndoOfDeleteOnLastPageKeepsCurrentPageValid() async throws {
        let (m, u) = try makeModel()
        m.currentPage = 2
        await m.perform(.deletePages(pages: [2]), named: Strings.actionDelete, touching: nil)
        XCTAssertEqual(m.pageCount, 2); XCTAssertEqual(m.currentPage, 1)
        u.undo(); await m.settle(); XCTAssertEqual(m.pageCount, 3); XCTAssertLessThan(m.currentPage, 3)
    }

    func testEveryEditClearsTextSelectionAndSelectedAnnotation() async throws {
        let (m, _) = try makeModel()
        m.selection?.beginWord(page: 0, at: try firstGlyphCenter(m)); await m.selection?.waitUntilSettled()
        XCTAssertNotNil(m.selection?.selection, "a word is selected before the edit")
        m.selectedAnnotation = AnnotationRef(page: 0, index: 0)
        await m.perform(.rotatePages(pages: [1], degrees: 90), named: Strings.actionRotate, touching: [1])
        XCTAssertNil(m.selection?.selection); XCTAssertNil(m.selectedAnnotation)
    }

    func testRefusedEditShowsReasonAndLeavesUndoStackAlone() async throws {
        let (m, u) = try makeModel()
        let ok = await m.perform(.deletePages(pages: [0, 1, 2]), named: Strings.actionDelete, touching: nil)
        XCTAssertFalse(ok); XCTAssertEqual(m.failure?.message, Strings.cannotDeleteAllPages); XCTAssertEqual(m.revision, 0)
        u.undo(); await m.settle(); XCTAssertEqual(m.pageCount, 3)   // the dead entry is a no-op
    }

    func testUndoTappedWhileAnEditRunsUndoesThatEdit() async throws {
        let (m, u) = try makeModel()
        let job = m.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        u.undo()                                   // the entry was registered synchronously; its engine undo queues behind the rotate
        _ = await job.value; await m.settle()
        XCTAssertEqual(m.pages[0].rotationDegrees, 0); XCTAssertEqual(m.revision, 2)
    }

    // MARK: Beyond the brief's tests

    /// Two edits made against the same revision: the second was computed for a document that has
    /// changed by the time it runs, so the bridge refuses it instead of deleting the wrong page.
    func testAnEditForAnOlderRevisionIsRefusedAsStale() async throws {
        let (m, _) = try makeModel()
        let first = m.enqueue([.deletePages(pages: [0])], named: Strings.actionDelete, touching: nil)
        let second = m.enqueue([.deletePages(pages: [0])], named: Strings.actionDelete, touching: nil)
        let (firstOK, secondOK) = await (first.value, second.value)
        XCTAssertTrue(firstOK); XCTAssertFalse(secondOK)
        XCTAssertEqual(m.pageCount, 2)
        XCTAssertEqual(m.failure?.message, Strings.documentChangedTryAgain)
    }

    func testSeveralEditsAreOneUndoStepAndOneRevision() async throws {
        let (m, u) = try makeModel()
        let ok = await m.performAll([.rotatePages(pages: [0], degrees: 90), .rotatePages(pages: [1], degrees: 180)],
                                    named: Strings.actionRotate, touching: [0, 1])
        XCTAssertTrue(ok); XCTAssertEqual(m.revision, 1)
        XCTAssertEqual(m.pages.map(\.rotationDegrees), [90, 180, 0])
        u.undo(); await m.settle()
        XCTAssertEqual(m.pages.map(\.rotationDegrees), [0, 0, 0])
    }

    func testEachChangeSaysWhichPagesAndWhetherTheGeometryMoved() async throws {
        let (m, u) = try makeModel()
        await m.perform(.rotatePages(pages: [1], degrees: 90), named: Strings.actionRotate, touching: [1])
        XCTAssertEqual(m.lastChange, PageChange(revision: 1, pages: [1], geometryChanged: true))
        u.undo(); await m.settle()
        XCTAssertEqual(m.lastChange, PageChange(revision: 2, pages: [1], geometryChanged: true))
        await m.perform(.deletePages(pages: [0]), named: Strings.actionDelete, touching: nil)
        XCTAssertEqual(m.lastChange, PageChange(revision: 3, pages: nil, geometryChanged: true))
    }

    func testTheEnginesStateIsReadOnceOpenAndAgainAfterEachEdit() async throws {
        let (m, _) = try makeModel(fixture: "annotated")
        await m.settle()
        let capabilities = try XCTUnwrap(m.capabilities)
        XCTAssertTrue(capabilities.canEdit)
        XCTAssertFalse(m.annotationsByPage.isEmpty, "the annotated fixture has annotations")
        let before = m.annotationsByPage.values.reduce(0) { $0 + $1.count }
        let page = try XCTUnwrap(m.annotationsByPage.keys.min())
        let index = try XCTUnwrap(m.annotationsByPage[page]?.first?.index)
        let ok = await m.perform(.deleteAnnotation(page: UInt32(page), index: index), named: Strings.actionDeleteAnnotation, touching: [page])
        XCTAssertTrue(ok)
        XCTAssertEqual(m.annotationsByPage.values.reduce(0) { $0 + $1.count }, before - 1)
    }

    func testFormFieldsAreReadOnOpen() async throws {
        let (m, _) = try makeModel(fixture: "form")
        await m.settle()
        XCTAssertFalse(m.formFields.isEmpty)
    }

    func testIsApplyingLastsUntilTheQueueIsEmpty() async throws {
        let (m, _) = try makeModel()
        await m.settle()
        let job = m.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        XCTAssertTrue(m.isApplying)
        _ = await job.value; await m.settle()
        XCTAssertFalse(m.isApplying)
    }

    /// An engine undo that fails (here the engine has nothing left to undo, behind the undo
    /// manager's back) says so and empties the undo manager, whose stack no longer matches.
    func testAFailingUndoShowsItAndClearsTheUndoStack() async throws {
        let (m, u) = try makeModel()
        await m.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        _ = try XCTUnwrap(m.document()).undo()
        u.undo(); await m.settle()
        XCTAssertNotNil(m.failure)
        XCTAssertFalse(u.canUndo); XCTAssertFalse(u.canRedo)
    }

    func testTheToolbarsUndoAndRedoGoThroughTheUndoManager() async throws {
        let (m, u) = try makeModel()
        await m.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        m.undo(); await m.settle()
        XCTAssertEqual(m.pages[0].rotationDegrees, 0); XCTAssertTrue(u.canRedo)
        m.redo(); await m.settle()
        XCTAssertEqual(m.pages[0].rotationDegrees, 90)
    }

    func testAnEditWithoutAnUndoManagerStillApplies() async throws {
        let m = DocumentModel(bytes: try fixtureData("sample"))
        let ok = await m.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        XCTAssertTrue(ok); XCTAssertEqual(m.pages[0].rotationDegrees, 90)
    }

    func testAnEditOnADocumentThatIsNotOpenFailsQuietly() async throws {
        let m = DocumentModel(bytes: Data("garbage".utf8))
        let ok = await m.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        XCTAssertFalse(ok); XCTAssertNil(m.capabilities)
    }

    // MARK: The queue

    func testTheQueueRunsJobsInOrderOffTheMainThread() async throws {
        let queue = EditQueue()
        let log = OrderLog()
        async let a: Bool = queue.run { OrderLog.pause(); log.append(1); return Thread.isMainThread }
        async let b: Bool = queue.run { log.append(2); return Thread.isMainThread }
        let (onMainA, onMainB) = try await (a, b)
        XCTAssertFalse(onMainA); XCTAssertFalse(onMainB)
        XCTAssertEqual(log.values.sorted(), [1, 2])
        // Submitted synchronously, so their order is the order of submission.
        let first = queue.submit { await Task.detached { OrderLog.pause(); log.append(3) }.value }
        let second = queue.submit { log.append(4) }
        await first.value; await second.value
        XCTAssertEqual(Array(log.values.suffix(2)), [3, 4])
    }

    func testAFailingJobDoesNotStopTheQueue() async throws {
        let queue = EditQueue()
        do {
            _ = try await queue.run { () throws -> Int in throw EditError.WouldRemoveAllPages }
            XCTFail("the job threw")
        } catch {}
        let value = try await queue.run { 7 }
        XCTAssertEqual(value, 7)
    }

    // MARK: What a refused edit says

    func testEveryRefusalIsOurSentenceNeverTheEngines() {
        let engineText = "ENGINE-TEXT"
        let cases: [(EditError, String)] = [
            (.ReadOnly(message: engineText), Strings.editNotAllowed),
            (.NotPermitted(message: engineText), Strings.editNotAllowed),
            (.WouldRemoveAllPages, Strings.cannotDeleteAllPages),
            (.Invalid(message: engineText), ""),
            (.Stale(current: 4), Strings.documentChangedTryAgain),
            (.SourceNeedsPassword, Strings.insertSourceLocked),
            (.SourceUnreadable(message: engineText), Strings.insertSourceUnreadable),
            (.SourceNotPermitted, Strings.insertSourceNotPermitted),
            (.NothingToUndo, ""),
            (.NothingToRedo, ""),
            (.Failed(message: engineText), ""),
        ]
        for (error, message) in cases {
            let failure = EditFailure(error)
            XCTAssertEqual(failure.title, Strings.editFailed, "\(error)")
            XCTAssertEqual(failure.message, message, "\(error)")
            XCTAssertFalse(failure.message.contains(engineText), "\(error)")
        }
        let other = EditFailure(CocoaError(.fileReadUnknown))
        XCTAssertEqual(other.title, Strings.editFailed); XCTAssertEqual(other.message, "")
    }
}

/// Numbers appended from any thread, in the order they arrived.
private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int] = []
    var values: [Int] { lock.withLock { _values } }
    func append(_ value: Int) { lock.withLock { _values.append(value) } }
    /// Holds the thread for 50 ms, as slow engine work would. (A function of its own: the compiler
    /// refuses `Thread.sleep` straight in an async context.)
    static func pause() { Thread.sleep(forTimeInterval: 0.05) }
}
