import EditinPDFCore
import PencilKit
import UIKit
import XCTest
@testable import EditinPDF

/// Saving is the reader's choice: nothing is written to the file until Save (`DocumentModel.save`), Back
/// with changes asks, and a recovery copy keeps the unsaved changes if the app is stopped meanwhile.
@MainActor
final class SavingTests: XCTestCase {
    // MARK: What counts as unsaved

    /// The count of unsaved changes moves with every change, undo and redo: undone back to the state last
    /// saved there is nothing to save, and once a change is made over an undone one, the state saved
    /// cannot come back.
    func testUnsavedFollowsChangesUndoAndRedo() async throws {
        let (model, undoManager) = try makeModel()
        await model.settle()
        XCTAssertFalse(model.hasUnsavedChanges, "as opened")
        let done1 = await rotate(model)
        XCTAssertTrue(done1)
        XCTAssertTrue(model.hasUnsavedChanges, "changed")
        undoManager.undo()
        await model.settle()
        XCTAssertFalse(model.hasUnsavedChanges, "undone back to the file as opened")
        undoManager.redo()
        await model.settle()
        XCTAssertTrue(model.hasUnsavedChanges, "redone")

        // Saved here, then one undone: unsaved; redone: saved again.
        let file = try FileStandIn(model: model, bytes: fixtureData("sample"))
        model.fileWriter = file
        let failure = await model.save()
        XCTAssertNil(failure)
        XCTAssertFalse(model.hasUnsavedChanges, "saved")
        undoManager.undo()
        await model.settle()
        XCTAssertTrue(model.hasUnsavedChanges, "undone past the save")
        undoManager.redo()
        await model.settle()
        XCTAssertFalse(model.hasUnsavedChanges, "redone back to what was saved")

        // Undone, then another change: the state saved is gone from the history for good.
        undoManager.undo()
        await model.settle()
        let turned = await rotate(model, by: 180)
        XCTAssertTrue(turned)
        XCTAssertTrue(model.hasUnsavedChanges)
        undoManager.undo()
        await model.settle()
        XCTAssertTrue(model.hasUnsavedChanges, "the state saved cannot be reached by undo any more")
    }

    /// Strokes waiting to be added count as something to save, though the history has not moved yet.
    func testStrokesWaitingNeedASave() async throws {
        let (controller, model) = await makeController()
        XCTAssertFalse(model.needsSave)
        try drawALine(in: controller)
        XCTAssertTrue(model.hasPendingInk)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertTrue(model.needsSave, "strokes waiting")
    }

    /// The model keeps its own undo manager: the scene's document, which saves whenever its own undo
    /// manager reports a change, never hears of an edit.
    func testTheModelHasAnUndoManagerOfItsOwn() {
        let model = isolatedModel(bytes: PageScrollViewControllerTests.letterPages(1))
        XCTAssertNotNil(model.undoManager)
        XCTAssertEqual(model.undoManager?.levelsOfUndo, DocumentModel.undoLimit)
    }

    // MARK: Save

    /// Save writes the document with its changes to the file and leaves nothing to save.
    func testSaveWritesTheFileAndClearsUnsaved() async throws {
        let (model, _) = try makeModel()
        let file = try FileStandIn(model: model, bytes: fixtureData("sample"))
        model.fileWriter = file
        await model.settle()
        let done2 = await rotate(model)
        XCTAssertTrue(done2)
        let failure = await model.save()
        XCTAssertNil(failure)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertFalse(model.needsSave)
        let saved = try PdfDocument.open(bytes: try file.bytesOnDisk(), password: nil)
        XCTAssertEqual(saved.pageInfo(page: 0)?.rotationDegrees, 90, "the change is in the file")
    }

    /// Without a file to write to, Save says it failed and the changes stay unsaved.
    func testSaveWithNoFileFails() async throws {
        let (model, _) = try makeModel()
        await model.settle()
        let done3 = await rotate(model)
        XCTAssertTrue(done3)
        let failure = await model.save()
        XCTAssertEqual(failure, .failed)
        XCTAssertTrue(model.hasUnsavedChanges)
    }

    /// Strokes waiting and text being typed are added before Save writes: both are in the file.
    func testSaveIncludesTheStrokesWaiting() async throws {
        let (controller, model) = await makeController()
        let file = try FileStandIn(model: model, bytes: PageScrollViewControllerTests.letterPages(3))
        model.fileWriter = file
        try drawALine(in: controller)
        let failure = await model.save()
        XCTAssertNil(failure)
        XCTAssertFalse(model.hasPendingInk)
        XCTAssertFalse(model.needsSave)
        let saved = try PdfDocument.open(bytes: try file.bytesOnDisk(), password: nil)
        XCTAssertEqual(saved.annotations().map(\.kind), [.ink], "the strokes waiting are in the file")
    }

    // MARK: Nothing is written without Save

    /// What the system's automatic save would write (a write not asked for by Save) is the file as it is
    /// on disk, whatever the document holds: the original bytes, untouched.
    func testAnAutomaticWriteLeavesTheOriginalBytes() async throws {
        let original = try fixtureData("sample")
        let (model, _) = try makeModel()
        let file = try FileStandIn(model: model, bytes: original)
        await model.settle()
        let done4 = await rotate(model)
        XCTAssertTrue(done4)
        let done5 = await file.writeAsTheSystemWould()
        XCTAssertTrue(done5, "the write itself goes through")
        XCTAssertEqual(try file.bytesOnDisk(), original, "an automatic write changes nothing")
        // A new file (nothing on disk yet) is written as the engine has it: the blank document's first write.
        let snapshot = try file.document.snapshot(contentType: .pdf)
        XCTAssertFalse(snapshot.isExplicitSave)
        XCTAssertNotEqual(try file.document.bytesToWrite(snapshot, existing: nil), original)
    }

    /// The scene's document (a `UIDocument`) never counts an edit as a change, so it never saves one on its
    /// own (as it closes, on a timer, in the background); told it changed all the same, its save writes the
    /// file as it was. Save writes through it.
    func testTheScenesDocumentSavesNothingOnItsOwn() async throws {
        let original = try fixtureData("sample")
        let url = try temporaryFile(original)
        let file = PDFFileDocument(bytes: original)
        let model = file.model
        let host = DocumentStandIn(fileURL: url, file: file)
        let opened = await withCheckedContinuation { done in host.open { done.resume(returning: $0) } }
        XCTAssertTrue(opened)
        await model.settle()
        let done6 = await rotate(model)
        XCTAssertTrue(done6)
        XCTAssertFalse(host.hasUnsavedChanges, "the edit is not reported to the scene's document")

        host.updateChangeCount(.done)
        let autosaved = await withCheckedContinuation { done in host.autosave { done.resume(returning: $0) } }
        XCTAssertTrue(autosaved)
        XCTAssertEqual(try Data(contentsOf: url), original, "the automatic save wrote nothing new")

        let writer = SceneDocumentWriter(document: host)
        model.fileWriter = writer
        let failure = await model.save()
        XCTAssertNil(failure)
        XCTAssertEqual(try PdfDocument.open(bytes: try Data(contentsOf: url), password: nil).pageInfo(page: 0)?.rotationDegrees, 90)
        _ = await withCheckedContinuation { done in host.close { done.resume(returning: $0) } }
    }

    // MARK: Discard and Save As

    /// Discard leaves the file as it was opened, byte for byte, and drops the recovery copy.
    func testDiscardLeavesTheOriginalUntouched() async throws {
        let original = try fixtureData("sample")
        let (model, _) = try makeModel()
        let file = try FileStandIn(model: model, bytes: original)
        model.fileWriter = file
        let store = isolatedRecovery()
        model.recovery = store
        model.recoveryKey = "discard"
        await model.settle()
        let done7 = await rotate(model)
        XCTAssertTrue(done7)
        await model.writeRecovery()
        XCTAssertNotNil(store.copy(key: "discard", newerThan: nil))
        model.discardChanges()
        XCTAssertEqual(try file.bytesOnDisk(), original)
        XCTAssertNil(store.copy(key: "discard", newerThan: nil), "the recovery copy goes")
    }

    /// Save As makes a copy with the changes and leaves the file as it was, and the recovery copy goes once
    /// the copy is saved.
    func testSaveAsLeavesTheOriginalUntouched() async throws {
        let original = try fixtureData("sample")
        let (model, _) = try makeModel()
        let file = try FileStandIn(model: model, bytes: original)
        model.fileWriter = file
        let store = isolatedRecovery()
        model.recovery = store
        model.recoveryKey = "saveAs"
        await model.settle()
        let done8 = await rotate(model)
        XCTAssertTrue(done8)
        await model.writeRecovery()
        guard case .success(let copy) = await model.copyBytes() else { return XCTFail("no copy") }
        XCTAssertEqual(try PdfDocument.open(bytes: copy, password: nil).pageInfo(page: 0)?.rotationDegrees, 90)
        model.copyWasSaved()
        XCTAssertEqual(try file.bytesOnDisk(), original, "the original is untouched")
        XCTAssertNil(store.copy(key: "saveAs", newerThan: nil))
    }

    // MARK: Recovery

    /// The recovery copy is written with the unsaved changes, found again for the same file (by a fresh
    /// model, as when the document opens again), restored as unsaved changes, and deleted by Save.
    func testRecoveryIsWrittenFoundRestoredAndDeleted() async throws {
        let original = try fixtureData("sample")
        let store = isolatedRecovery()
        let key = RecoveryStore.key(for: URL(fileURLWithPath: "/tmp/some folder/report.pdf"))
        XCTAssertEqual(key, RecoveryStore.key(for: URL(fileURLWithPath: "/tmp/some folder/./report.pdf")), "stable for the same file")
        XCTAssertNotEqual(key, RecoveryStore.key(for: URL(fileURLWithPath: "/tmp/some folder/other.pdf")))

        let (model, _) = try makeModel()
        model.recovery = store
        model.recoveryKey = key
        await model.settle()
        await model.writeRecovery()
        XCTAssertNil(store.copy(key: key, newerThan: nil), "nothing to recover: nothing written")
        let done9 = await rotate(model)
        XCTAssertTrue(done9)
        let before = Date(timeIntervalSinceNow: -60)
        await model.writeRecovery()
        let written = try XCTUnwrap(store.copy(key: key, newerThan: before))
        XCTAssertEqual(try written.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertNil(store.copy(key: key, newerThan: Date(timeIntervalSinceNow: 60)), "not offered over a file saved since")

        // Opened again: the file as it was, and the copy offered.
        let (reopened, _) = try makeModel()
        reopened.recovery = store
        reopened.recoveryKey = key
        let file = try FileStandIn(model: reopened, bytes: original)
        reopened.fileWriter = file
        await reopened.settle()
        XCTAssertTrue(reopened.hasRecoveredChanges(newerThan: before))
        let generation = reopened.documentGeneration
        let done10 = await reopened.restoreRecoveredChanges()
        XCTAssertTrue(done10)
        XCTAssertNotEqual(reopened.documentGeneration, generation, "the pages are shown again for the restored document")
        XCTAssertEqual(reopened.document()?.pageInfo(page: 0)?.rotationDegrees, 90, "restored")
        XCTAssertTrue(reopened.engine.document === reopened.document(), "and that is the document saved")
        XCTAssertTrue(reopened.hasUnsavedChanges, "restored changes are unsaved")
        XCTAssertEqual(try file.bytesOnDisk(), original, "restoring writes nothing to the file")

        let failure = await reopened.save()
        XCTAssertNil(failure)
        XCTAssertFalse(reopened.hasUnsavedChanges)
        XCTAssertNil(store.copy(key: key, newerThan: nil), "Save deletes the recovery copy")
        XCTAssertEqual(try PdfDocument.open(bytes: try file.bytesOnDisk(), password: nil).pageInfo(page: 0)?.rotationDegrees, 90)
    }

    /// Declined, the recovery copy goes and the document stays as the file is.
    func testDiscardingTheRecoveredChangesDeletesTheCopy() async throws {
        let store = isolatedRecovery()
        try store.write(try fixtureData("sample"), key: "declined")
        let (model, _) = try makeModel()
        model.recovery = store
        model.recoveryKey = "declined"
        XCTAssertTrue(model.hasRecoveredChanges(newerThan: nil))
        model.discardRecoveredChanges()
        XCTAssertNil(store.copy(key: "declined", newerThan: nil))
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    /// Strokes waiting are added before the recovery copy is written as the app leaves.
    func testRecoveryIncludesTheStrokesWaiting() async throws {
        let (controller, model) = await makeController()
        let store = isolatedRecovery()
        model.recovery = store
        model.recoveryKey = "ink"
        try drawALine(in: controller)
        await model.writeRecovery(addingWhatWaits: true)
        let url = try XCTUnwrap(store.copy(key: "ink", newerThan: nil))
        XCTAssertEqual(try PdfDocument.open(bytes: try Data(contentsOf: url), password: nil).annotations().map(\.kind), [.ink])
    }

    /// Copies older than the limit are swept at launch; newer ones stay.
    func testStaleRecoveryCopiesAreSwept() throws {
        let store = isolatedRecovery()
        try store.write(Data("old".utf8), key: "old")
        try store.write(Data("new".utf8), key: "new")
        let old = store.url(key: "old")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -31 * 24 * 3600)], ofItemAtPath: old.path)
        store.sweep(olderThan: RecoveryStore.maximumAge)
        XCTAssertNil(store.copy(key: "old", newerThan: nil))
        XCTAssertNotNil(store.copy(key: "new", newerThan: nil))
        XCTAssertEqual(RecoveryStore.maximumAge, 30 * 24 * 3600)
    }

    // MARK: Helpers

    /// Turns page 0 by `degrees`, as one change; says whether it was made.
    func rotate(_ model: DocumentModel, by degrees: Int32 = 90) async -> Bool {
        await model.perform(.rotatePages(pages: [0], degrees: degrees), named: Strings.actionRotate, touching: nil)
    }

    /// `pages` US Letter pages in a 400 x 800 view, Draw picked, with an undo manager.
    func makeController() async -> (PageScrollViewController, DocumentModel) {
        let model = isolatedModel(bytes: PageScrollViewControllerTests.letterPages(3))
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(origin: .zero, size: CGSize(width: 400, height: 800))
        controller.view.layoutIfNeeded()
        await model.settle()
        model.tool = .ink
        controller.markupTool = .ink
        return (controller, model)
    }

    /// A line across page 0 on Draw's canvas, waiting to be added.
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

    /// A recovery store in a folder of its own, removed when the test finishes.
    func isolatedRecovery() -> RecoveryStore {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "EditinPDFTests-recovery/\(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return RecoveryStore(directory: folder)
    }

    /// `bytes` in a file of their own, removed when the test finishes.
    func temporaryFile(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("saving-\(UUID().uuidString).pdf")
        try bytes.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// A file on disk written as the document scene writes one: from the file document's snapshot, through
/// `bytesToWrite`, with the bytes on disk as the existing file. Save writes through it
/// (`DocumentFileWriter`); `writeAsTheSystemWould` is a write Save did not ask for.
@MainActor
final class FileStandIn: DocumentFileWriter {
    let document: PDFFileDocument
    let url: URL

    /// A file holding `bytes`, and a file document sharing `model`'s engine.
    init(model: DocumentModel, bytes: Data) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("standin-\(UUID().uuidString).pdf")
        try bytes.write(to: url)
        document = PDFFileDocument(sharing: model.engine)
    }

    func bytesOnDisk() throws -> Data { try Data(contentsOf: url) }

    func writeToFile() async -> Bool { await write() }

    /// A write as the system's automatic save makes one, not asked for by Save.
    func writeAsTheSystemWould() async -> Bool { await write() }

    private func write() async -> Bool {
        do {
            let snapshot = try document.snapshot(contentType: .pdf)
            let existing = try? Data(contentsOf: url)
            let document = document
            let url = url
            return try await Task.detached {
                try document.bytesToWrite(snapshot, existing: existing).write(to: url)
                return true
            }.value
        } catch {
            return false
        }
    }
}

/// The scene's document as UIKit keeps one, writing what the file document gives it, as SwiftUI's does.
private final class DocumentStandIn: UIDocument, @unchecked Sendable {
    let file: PDFFileDocument

    init(fileURL: URL, file: PDFFileDocument) {
        self.file = file
        super.init(fileURL: fileURL)
    }

    override func load(fromContents contents: Any, ofType typeName: String?) throws {}

    override func contents(forType typeName: String) throws -> Any {
        let snapshot = try file.snapshot(contentType: .pdf)
        return try file.bytesToWrite(snapshot, existing: try? Data(contentsOf: fileURL))
    }
}
