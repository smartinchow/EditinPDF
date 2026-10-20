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
        let shown = try XCTUnwrap(m.failure)
        XCTAssertFalse(u.canUndo, "a refused change leaves nothing to undo")
        u.undo(); await m.settle(); XCTAssertEqual(m.pageCount, 3)
        XCTAssertEqual(m.revision, 0); XCTAssertEqual(m.failure?.id, shown.id, "the undo changed nothing and said nothing new")
    }

    /// The refused change left no entry behind, so Undo takes back the change before it.
    func testUndoAfterARefusedEditUndoesTheChangeBeforeIt() async throws {
        let (m, u) = try makeModel()
        await m.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        let refused = await m.perform(.deletePages(pages: [0, 1, 2]), named: Strings.actionDelete, touching: nil)
        XCTAssertFalse(refused)
        XCTAssertEqual(u.undoActionName, Strings.actionRotate)
        u.undo(); await m.settle()
        XCTAssertEqual(m.pages[0].rotationDegrees, 0); XCTAssertEqual(m.pageCount, 3)
    }

    /// Edits tapped quickly, each worked out at the same revision, all happen when nothing between
    /// them can change what they mean.
    func testTwoRotationsQueuedTogetherBothHappen() async throws {
        let (m, u) = try makeModel()
        let first = m.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        let second = m.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        let (firstOK, secondOK) = await (first.value, second.value)
        XCTAssertTrue(firstOK); XCTAssertTrue(secondOK)
        XCTAssertEqual(m.pages[0].rotationDegrees, 180); XCTAssertNil(m.failure)
        u.undo(); await m.settle()
        XCTAssertEqual(m.pages[0].rotationDegrees, 0, "both were made in the same event: one undo step")
    }

    /// A point worked out before a turn of its page would land somewhere else: refused.
    func testAPointQueuedBehindARotationOfItsPageIsRefused() async throws {
        let (m, _) = try makeModel()
        let rotate = m.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        let note = m.enqueue([.addNote(page: 0, at: Point(x: 100, y: 100), contents: "", color: RgbColor(red: 1, green: 1, blue: 0))],
                             named: Strings.actionAddAnnotation, touching: [0])
        let (rotated, added) = await (rotate.value, note.value)
        XCTAssertTrue(rotated); XCTAssertFalse(added)
        XCTAssertEqual(m.failure?.message, Strings.documentChangedTryAgain)
        XCTAssertTrue(m.annotationsByPage[0, default: []].isEmpty)
    }

    /// A field filled in behind a rotation has no point to move: it happens.
    func testAFieldFilledBehindARotationHappens() async throws {
        let (m, _) = try makeModel(fixture: "form")
        await m.settle()
        let field = try XCTUnwrap(m.formFields.first { $0.kind == .text && !$0.readOnly })
        let rotate = m.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        let fill = m.enqueue([.setFieldValue(name: field.name, value: .text(text: "Hi"))], named: Strings.actionFillField, touching: nil)
        let (rotated, filled) = await (rotate.value, fill.value)
        XCTAssertTrue(rotated); XCTAssertTrue(filled)
        XCTAssertEqual(m.formFields.first { $0.name == field.name }?.value, ["Hi"])
    }

    func testUndoTappedWhileAnEditRunsUndoesThatEdit() async throws {
        let (m, u) = try makeModel()
        let job = m.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        u.undo()                                   // the entry was registered synchronously; its engine undo queues behind the rotate
        _ = await job.value; await m.settle()
        XCTAssertEqual(m.pages[0].rotationDegrees, 0); XCTAssertEqual(m.revision, 2)
    }

    /// The engine keeps the last 100 changes; the undo manager keeps them all. Undoing past the
    /// engine's history finds nothing to undo there: that change is taken off quietly, no alert, and
    /// what can be redone stays.
    func testUndoingPastTheEnginesHundredChangesIsQuietAndKeepsTheRedos() async throws {
        let m = isolatedModel(bytes: try blankDocument(widthPt: 200, heightPt: 200))
        let u = UndoManager()
        m.undoManager = u
        u.groupsByEvent = false
        await m.settle()
        for _ in 0..<101 {
            let turned = await change(m, u, [.rotatePages(pages: [0], degrees: 90)])
            XCTAssertTrue(turned)
        }
        XCTAssertEqual(m.revision, 101)
        for _ in 0..<101 {
            u.undo()
            await m.settle()
        }
        XCTAssertNil(m.failure, "no alert")
        XCTAssertFalse(u.canUndo, "the change the engine no longer has is off the undo manager")
        XCTAssertEqual(m.revision, 201, "100 undone; the last undo changed nothing")
        XCTAssertEqual(m.pages[0].rotationDegrees, 90, "the oldest turn stays")
        var redone = 0
        while u.canRedo, redone < 200 {
            u.redo()
            await m.settle()
            redone += 1
        }
        XCTAssertEqual(redone, 100, "every change undone can be redone")
        XCTAssertNil(m.failure)
        XCTAssertEqual(m.revision, 301)
    }

    /// A change that fails half way may have changed the document (`Failed` moves the revision on), so
    /// the engine's history may no longer match the undo manager's stack: no change is left on it, as
    /// when an undo fails.
    func testAChangeThatFailsHalfWayTakesEveryChangeOffTheUndoManager() async throws {
        let (m, u) = try await makeFailingModel(failing: .setInfo)
        let turned = await change(m, u, [.rotatePages(pages: [0], degrees: 90)])
        XCTAssertTrue(turned)
        XCTAssertTrue(u.canUndo)
        let titled = await change(m, u, [.setInfo(key: "Title", value: "x")], named: "Set the title")
        XCTAssertFalse(titled)
        XCTAssertNotNil(m.failure)
        XCTAssertEqual(m.revision, 2, "the document was read again at the revision the failure left")
        XCTAssertFalse(u.canUndo, "no change is left on the undo manager")
        XCTAssertEqual(m.pages[0].rotationDegrees, 90)
    }

    /// A signed document whose file is damaged cannot be changed (saving would rewrite it and break its
    /// signatures): every tool says so in one sentence of ours. Either alone changes nothing.
    func testASignedDocumentWhoseFileIsDamagedSaysWhyNothingCanBeChanged() async throws {
        let m = isolatedModel(bytes: handMadePDF(signed: true, damaged: true))
        await m.settle()
        let capabilities = try XCTUnwrap(m.capabilities)
        XCTAssertTrue(capabilities.isSigned && capabilities.rewritesOnSave)
        XCTAssertFalse(capabilities.canEdit || capabilities.canAnnotate || capabilities.canOrganize || capabilities.canFillForms)
        XCTAssertEqual(m.signatureLock, Strings.signedDocumentDamaged)
        for tool in Tool.allCases where tool.annotates {
            XCTAssertEqual(m.refusal(of: tool), Strings.signedDocumentDamaged, "\(tool)")
        }
        XCTAssertNil(m.refusal(of: .select))
        let filled = await m.fill("signature", with: .text(text: "x"))
        XCTAssertFalse(filled)
        XCTAssertEqual(m.failure?.message, Strings.signedDocumentDamaged)
        XCTAssertTrue(OrganizeController(model: m).organizeIsRefused)

        for (signed, damaged) in [(true, false), (false, true)] {
            let other = isolatedModel(bytes: handMadePDF(signed: signed, damaged: damaged))
            await other.settle()
            XCTAssertEqual(other.capabilities?.rewritesOnSave, damaged)
            XCTAssertEqual(other.capabilities?.canAnnotate, true, "signed \(signed), damaged \(damaged)")
            XCTAssertNil(other.signatureLock)
            XCTAssertNil(other.refusal(of: .ink))
        }
    }

    /// What the text box and note editors hold their text to is what the bridge takes: a note of that
    /// many characters is added; the bridge would refuse one more.
    func testTheEditorsTextLimitIsTheBridges() async throws {
        XCTAssertEqual(ShapeGeometry.maxTextLength, Int(maxTextChars()))
        XCTAssertEqual(ShapeGeometry.maxTextLength, 100_000)
        let long = String(repeating: "é", count: ShapeGeometry.maxTextLength + 5)
        let limited = ShapeGeometry.limitedText(long)
        XCTAssertEqual(limited.unicodeScalars.count, ShapeGeometry.maxTextLength)
        XCTAssertTrue(long.hasPrefix(limited))
        // Whole characters: an emoji of several scalars that does not fit is left out whole.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let edge = String(repeating: "a", count: ShapeGeometry.maxTextLength - 2) + family
        XCTAssertEqual(ShapeGeometry.limitedText(edge), String(repeating: "a", count: ShapeGeometry.maxTextLength - 2))

        let (m, _) = try makeModel()
        let added = await m.addNote(page: 0, at: CGPoint(x: 100, y: 100), contents: limited)
        XCTAssertTrue(added)
        XCTAssertNil(m.failure)
        XCTAssertEqual(m.annotationsByPage[0]?.first?.contents?.unicodeScalars.count, ShapeGeometry.maxTextLength)
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
    /// An undo the engine fails at (here once it has taken the change back, as it can) means its history
    /// and the undo manager's stack no longer match: the reader is told, and the stack is emptied.
    func testAFailingUndoShowsItAndClearsTheUndoStack() async throws {
        let (m, u) = try await makeFailingModel(failing: .undo)
        for _ in 0..<2 { await change(m, u, [.rotatePages(pages: [0], degrees: 90)]) }
        u.undo(); await m.settle()
        XCTAssertNotNil(m.failure)
        XCTAssertFalse(u.canUndo); XCTAssertFalse(u.canRedo)
        XCTAssertEqual(m.revision, 3, "the document was read again at the revision the failure left")
    }

    /// An undo the engine has no step for (its history moved without the model here; past its 100
    /// changes in use) is no failure: only that change goes, quietly.
    func testAnUndoTheEngineHasNoStepForIsQuiet() async throws {
        let (m, u) = try makeModel()
        await m.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        _ = try XCTUnwrap(m.document()).undo()
        u.undo(); await m.settle()
        XCTAssertNil(m.failure)
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

    // MARK: The reader's page follows its content

    func testDeletingAnEarlierPageKeepsTheReaderOnTheSamePage() async throws {
        let (m, u) = try makeModel()
        m.currentPage = 2
        await m.perform(.deletePages(pages: [0]), named: Strings.actionDelete, touching: nil)
        XCTAssertEqual(m.currentPage, 1, "still on \"Page three\", now the second page")
        u.undo(); await m.settle()
        XCTAssertEqual(m.pageCount, 3)
    }

    func testMovingPagesKeepsTheReaderOnTheSamePage() async throws {
        let (m, _) = try makeModel()
        m.currentPage = 0
        await m.perform(.movePages(pages: [0], to: 2), named: Strings.actionMove, touching: nil)
        XCTAssertEqual(m.currentPage, 2)
        await m.perform(.insertBlankPage(at: 0, widthPt: 612, heightPt: 792), named: Strings.actionInsertBlank, touching: nil)
        XCTAssertEqual(m.currentPage, 3)
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
