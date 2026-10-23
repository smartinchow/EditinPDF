import EditinPDFCore
import Foundation
import UIKit
import os

/// Where Save writes the document's file: the scene's document (`SceneDocumentWriter`), or a test's.
@MainActor
protocol DocumentFileWriter: AnyObject {
    /// Writes the document, with its changes, to its file. Says whether it was written.
    func writeToFile() async -> Bool
}

/// Why Save wrote nothing.
enum SaveFailure: Error, Equatable {
    /// Something waiting to be added (strokes, typed text, a note) was refused, so a save would leave it
    /// out: none is made.
    case waitingNotAdded
    /// The document is not open, there is no file to write, or the write failed.
    case failed

    /// What the alert says under its title (`Strings.saveFailedTitle`).
    var message: String {
        switch self {
        case .waitingNotAdded: Strings.saveWaitingNotAddedMessage
        case .failed: Strings.saveFailedMessage
        }
    }
}

/// Save through the scene's document, the `UIDocument` SwiftUI's document scene keeps the file open with
/// (`UIDocumentViewController.document`): its save writes what `PDFFileDocument.fileWrapper` gives it,
/// which is the engine's changes while Save writes (`EngineHandle.beginExplicitSave`). Held weakly: the
/// scene owns the document.
@MainActor
final class SceneDocumentWriter: DocumentFileWriter {
    private weak var document: UIDocument?

    init(document: UIDocument) {
        self.document = document
    }

    func writeToFile() async -> Bool {
        guard let document else { return false }
        return await withCheckedContinuation { done in
            document.save(to: document.fileURL, for: .forOverwriting) { done.resume(returning: $0) }
        }
    }
}

/// Saving is the reader's choice (ADR 0002, section 3): the changes reach the file only with Save. Back
/// with unsaved changes asks whether to Save, Save As or Discard them (`DocumentScreen`), and a recovery
/// copy (`RecoveryStore`) keeps them while the document is open, for when the app is stopped before.
extension DocumentModel {
    private static let saveLog = Logger(subsystem: Diagnostics.subsystem, category: "save")

    /// Whether the document differs from its file as last saved (or opened): its history is somewhere
    /// else than where it was saved. Undone back to there, it has none.
    var hasUnsavedChanges: Bool { savedPosition != historyPosition }

    /// Whether Save has something to write: unsaved changes, or something waiting to be added (strokes,
    /// typed text). The screen says "Edited" meanwhile, and Back asks.
    var needsSave: Bool { hasUnsavedChanges || hasPendingEdit }

    /// Save: adds what waits (`addEverythingWaiting`), then has the file written with the changes
    /// (`fileWriter`), and once it is, the document has nothing to save and its recovery copy goes. Nil
    /// when saved. A save already on its way is waited for first (the question Back asks closes only once
    /// its own Save has written). Changes made while the file is written stay unsaved, whether the write
    /// took them or not: the next Save writes them.
    func save() async -> SaveFailure? {
        while !beginSaving() { try? await Task.sleep(for: .milliseconds(50)) }
        defer { endSaving() }
        guard await addEverythingWaiting() else { return .waitingNotAdded }
        guard document() != nil, let fileWriter else { return .failed }
        let position = historyPosition
        engine.beginExplicitSave()
        let written = await fileWriter.writeToFile()
        engine.endExplicitSave()
        guard written else {
            Self.saveLog.error("Save could not write the file")
            return .failed
        }
        markSaved(at: position)
        deleteRecovery()
        return nil
    }

    /// Discard Changes: the file stays as it was last saved; nothing is written, and the recovery copy
    /// goes. The document is closing: what it holds is let go with it.
    func discardChanges() {
        isClosing = true
        deleteRecovery()
    }

    /// Save As saved a copy (`copyBytes`) where the reader chose: the file stays as it was, and the
    /// document closes, so its recovery copy goes.
    func copyWasSaved() {
        isClosing = true
        deleteRecovery()
    }

    // MARK: Recovery

    /// Writes the recovery copy: the document as the engine holds it, unsaved changes and all, off the
    /// main actor. With `addingWhatWaits` (the app leaving the screen), what waits is added first
    /// (`addEverythingWaiting`), so the copy has it. Nothing is written without unsaved changes, without
    /// a key, or once the reader chose to close without them (`isClosing`). A copy written while Save,
    /// Discard or Save As happened is removed again: it would be offered over a file that has those
    /// changes, or after the reader let them go.
    func writeRecovery(addingWhatWaits: Bool = false) async {
        if addingWhatWaits { _ = await addEverythingWaiting() } else { await settle() }
        guard let key = recoveryKey, hasUnsavedChanges, !isClosing, let document = document() else { return }
        let epoch = recoveryEpoch
        let store = recovery
        let written = await EditQueue.offMain {
            try store.write(try document.save(mode: .incremental), key: key)
        }
        if case .failure = written {
            // Nothing of the document, nor of the error (it may quote the file), in the readable log.
            Self.saveLog.error("the recovery copy could not be written")
        }
        if recoveryEpoch != epoch { store.delete(key: key) }
    }

    /// Removes the recovery copy, now and any being written (`recoveryEpoch`).
    func deleteRecovery() {
        recoveryEpoch += 1
        guard let key = recoveryKey else { return }
        recovery.delete(key: key)
    }

    /// Whether a recovery copy of this document is there, written after `date` (the file's last change;
    /// nil for any): the app was stopped with unsaved changes, and the file has not changed since.
    func hasRecoveredChanges(newerThan date: Date?) -> Bool {
        guard let key = recoveryKey else { return false }
        return recovery.copy(key: key, newerThan: date) != nil
    }

    /// Restore: the document becomes its recovery copy, opened off the main actor (with the password the
    /// document was opened with), every change in it unsaved; the file is not written until Save. Says
    /// whether it was restored: a copy that cannot be read or opened leaves the document as it is, and
    /// goes.
    func restoreRecoveredChanges() async -> Bool {
        guard let key = recoveryKey, let url = recovery.copy(key: key, newerThan: nil) else { return false }
        await settle()
        let password = openedWithPassword
        let opened = await EditQueue.offMain { OpenOutcome(bytes: try Data(contentsOf: url), password: password) }
        guard case .success(let outcome) = opened, case .open = outcome else {
            Self.saveLog.error("the recovery copy could not be opened")
            recovery.delete(key: key)
            return false
        }
        install(outcome)
        didRestore()
        return true
    }

    /// The reader declined the recovery copy: it goes, and the document stays as its file is.
    func discardRecoveredChanges() {
        guard let key = recoveryKey else { return }
        recovery.delete(key: key)
    }
}
