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

/// How a document is saved.
enum SavingMode: Equatable {
    /// Only by Save; Back asks first (ADR 0002, section 3).
    case explicit
    /// The system's way, on its own, as before the reader could choose: where Back cannot be taken over or
    /// Save has no document to write through (a system that shows documents otherwise than the iOS 26 and
    /// 27 simulators show them), so that a reader is never left unable to save.
    case automatic

    /// `.explicit` only when the scene's document controller, its document (to write through) and its
    /// back action (to ask first) are all there.
    static func decide(controllerFound: Bool, documentFound: Bool, backActionFound: Bool) -> SavingMode {
        controllerFound && documentFound && backActionFound ? .explicit : .automatic
    }
}

/// What a recovery copy found as the document opens is.
enum RecoveredCopyKind: Equatable {
    /// Written after the file last changed, on top of the file as it is (the file's bytes are where the
    /// copy starts: every save appends to them): it can be restored in place of the document.
    case restorable
    /// Kept from an earlier version of the file (the file changed since, or the copy does not start with
    /// it): it can only be saved as a copy, or discarded.
    case earlierVersion

    /// What a copy holding `copy`, written at `copyDate`, is for a file holding `file` (nil: unreadable),
    /// last changed at `fileDate`.
    static func of(copy: Data, copyDate: Date?, file: Data?, fileDate: Date?) -> RecoveredCopyKind {
        guard let file, !file.isEmpty, copy.starts(with: file) else { return .earlierVersion }
        if let copyDate, let fileDate, copyDate <= fileDate { return .earlierVersion }
        return .restorable
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
    /// typed text). The screen says "Edited" meanwhile, and Back asks. Never for a document saved the
    /// system's way (`SavingMode.automatic`).
    var needsSave: Bool { savingMode != .automatic && (hasUnsavedChanges || hasPendingEdit) }

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

    /// Discard Changes: the file stays as it was last saved; nothing is written, and this session's
    /// recovery copy goes. The screen then closes the document (`isClosing`).
    func discardChanges() {
        deleteRecovery()
    }

    /// Save As saved a copy (`copyBytes`) where the reader chose: the file stays as it was, and the
    /// document closes, so this session's recovery copy goes.
    func copyWasSaved() {
        deleteRecovery()
    }

    // MARK: Recovery

    /// Writes the recovery copy: the document as the engine holds it, unsaved changes and all, off the
    /// main actor. With `addingWhatWaits` (the scene going to the background, the screen going), what
    /// waits is added first (`addEverythingWaiting`, the note being written included), so the copy has it.
    /// Nothing is written without unsaved changes, without a key, while the document closes
    /// (`isClosing`), for a document saved the system's way, or over a copy kept from before that the
    /// reader has not answered yet (`recoveryHeld`). A copy written while Save, Discard or Save As happened
    /// is removed again: it would be offered over a file that has those changes, or after the reader let
    /// them go.
    func writeRecovery(addingWhatWaits: Bool = false) async {
        if addingWhatWaits { _ = await addEverythingWaiting() } else { await settle() }
        guard let key = recoveryKey, hasUnsavedChanges, !isClosing, !recoveryHeld, savingMode != .automatic,
              let document = document() else { return }
        let epoch = recoveryEpoch
        let store = recovery
        let written = await EditQueue.offMain {
            try store.write(try document.save(mode: .incremental), key: key)
        }
        switch written {
        case .success:
            recoveryOwned = true
        case .failure:
            // Nothing of the document, nor of the error (it may quote the file), in the readable log.
            Self.saveLog.error("the recovery copy could not be written")
        }
        if recoveryEpoch != epoch { store.delete(key: key) }
    }

    /// Removes this session's recovery copy (`recoveryOwned`), now and any being written
    /// (`recoveryEpoch`). A copy kept from before and not answered yet stays.
    func deleteRecovery() {
        recoveryEpoch += 1
        guard let key = recoveryKey, recoveryOwned, !recoveryHeld else { return }
        recovery.delete(key: key)
        recoveryOwned = false
    }

    /// Looks for a recovery copy of this document kept from before, as it opens, and says what it is for
    /// the file at `fileURL` as it is now (`RecoveredCopyKind`); nil when there is none. The copy found is
    /// held (`recoveryHeld`) until the reader answers. Reads both off the main actor.
    func findRecoveredChanges(fileURL: URL?) async -> RecoveredCopyKind? {
        guard let key = recoveryKey, let url = recovery.copy(key: key, newerThan: nil) else { return nil }
        let kind = await EditQueue.offMain { () throws -> RecoveredCopyKind in
            let copy = try Data(contentsOf: url)
            let copyDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let file = fileURL.flatMap { try? Data(contentsOf: $0) }
            let fileDate = fileURL.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            return RecoveredCopyKind.of(copy: copy, copyDate: copyDate, file: file, fileDate: fileDate)
        }
        guard case .success(let found) = kind else { return nil }
        recoveryHeld = true
        return found
    }

    /// Restore: the document becomes its recovery copy, opened off the main actor (with the password the
    /// document was opened with), every change in it unsaved; the file is not written until Save. The copy
    /// is this session's from then on. Says whether it was restored: a copy that cannot be read or opened
    /// leaves the document as it is, and goes (the screen says so).
    func restoreRecoveredChanges() async -> Bool {
        guard let key = recoveryKey, let url = recovery.copy(key: key, newerThan: nil) else {
            recoveryHeld = false
            return false
        }
        await settle()
        let password = openedWithPassword
        let opened = await EditQueue.offMain { OpenOutcome(bytes: try Data(contentsOf: url), password: password) }
        recoveryHeld = false
        guard case .success(let outcome) = opened, case .open = outcome else {
            Self.saveLog.error("the recovery copy could not be opened")
            recovery.delete(key: key)
            return false
        }
        install(outcome)
        didRestore()
        recoveryOwned = true
        return true
    }

    /// The bytes of the recovery copy kept from before, for Save As of one from an earlier version of the
    /// file; nil when it cannot be read.
    func recoveredCopyBytes() async -> Data? {
        guard let key = recoveryKey, let url = recovery.copy(key: key, newerThan: nil) else { return nil }
        return try? await EditQueue.offMain { try Data(contentsOf: url) }.get()
    }

    /// The reader declined the recovery copy kept from before, or saved it as a copy: it goes, and the
    /// document stays as its file is.
    func discardRecoveredChanges() {
        recoveryHeld = false
        guard let key = recoveryKey else { return }
        recovery.delete(key: key)
    }
}
