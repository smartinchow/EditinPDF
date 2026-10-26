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

    /// Whether a copy kept from before is still unanswered.
    var recoveryHeld: Bool { !recoveryHeldKeys.isEmpty }

    /// Whether this session has a recovery copy of its own.
    var recoveryOwned: Bool { recoveryOwnedKey != nil }

    /// Writes the recovery copy: the document as the engine holds it, unsaved changes and all, off the
    /// main actor. With `addingWhatWaits` (the scene going to the background, the screen going), what
    /// waits is added first (`addEverythingWaiting`, the note being written included), so the copy has it.
    /// It goes under this session's key (`recoveryOwnedKey`): `recoveryKey`, or, while a copy kept from
    /// before is unanswered there, the next free slot (`RecoveryStore.slots`), so that a crash loses
    /// neither. Nothing is written without unsaved changes, without a key, while the document closes
    /// (`isClosing`), or for a document saved the system's way. A copy written while Save, Discard or Save
    /// As happened is removed again: it would be offered over a file that has those changes, or after the
    /// reader let them go.
    func writeRecovery(addingWhatWaits: Bool = false) async {
        if addingWhatWaits { _ = await addEverythingWaiting() } else { await settle() }
        guard hasUnsavedChanges, !isClosing, savingMode != .automatic, let key = sessionRecoveryKey(),
              let document = document() else { return }
        let epoch = recoveryEpoch
        let store = recovery
        let written = await EditQueue.offMain {
            try store.write(try document.save(mode: .incremental), key: key)
        }
        switch written {
        case .success:
            recoveryOwnedKey = key
        case .failure:
            // Nothing of the document, nor of the error (it may quote the file), in the readable log.
            Self.saveLog.error("the recovery copy could not be written")
        }
        if recoveryEpoch != epoch { store.delete(key: key) }
    }

    /// The key this session's copy goes under: the one it has, or the first slot that holds no copy kept
    /// from before. Nil without a document key, or when every slot holds one.
    private func sessionRecoveryKey() -> String? {
        if let recoveryOwnedKey { return recoveryOwnedKey }
        guard let recoveryKey else { return nil }
        return RecoveryStore.slots(of: recoveryKey).first { slot in
            !recoveryHeldKeys.contains(slot) && recovery.copy(key: slot, newerThan: nil) == nil
        }
    }

    /// Removes this session's recovery copy (`recoveryOwnedKey`), now and any being written
    /// (`recoveryEpoch`). Copies kept from before and not answered yet stay.
    func deleteRecovery() {
        recoveryEpoch += 1
        guard let key = recoveryOwnedKey else { return }
        recovery.delete(key: key)
        recoveryOwnedKey = nil
    }

    /// Looks for the next recovery copy of this document kept from before, as it opens (the newest first,
    /// one at a time: the screen asks again once the reader has answered), and says what it is for the
    /// file at `fileURL` as it is now (`RecoveredCopyKind`); nil when there is none left. Every copy found is
    /// held (`recoveryHeldKeys`) until the reader answers it. After a Restore, the others are only offered as
    /// copies (`.earlierVersion`): restoring one more would replace the first. Reads off the main actor.
    func findRecoveredChanges(fileURL: URL?) async -> RecoveredCopyKind? {
        guard let recoveryKey else { return nil }
        let store = recovery
        let candidates = RecoveryStore.slots(of: recoveryKey).filter { $0 != recoveryOwnedKey }
        let found = await EditQueue.offMain { () throws -> (String, RecoveredCopyKind, [String])? in
            let copies = candidates.compactMap { key -> (String, URL, Date)? in
                guard let url = store.copy(key: key, newerThan: nil) else { return nil }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (key, url, date)
            }.sorted { $0.2 > $1.2 }
            guard let newest = copies.first else { return nil }
            let copy = try Data(contentsOf: newest.1)
            let file = fileURL.flatMap { try? Data(contentsOf: $0) }
            let fileDate = fileURL.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            let kind = RecoveredCopyKind.of(copy: copy, copyDate: newest.2, file: file, fileDate: fileDate)
            return (newest.0, kind, copies.map(\.0))
        }
        guard case .success(let next?) = found else {
            offeredRecoveryKey = nil
            return nil
        }
        recoveryHeldKeys.formUnion(next.2)
        offeredRecoveryKey = next.0
        return restoredThisSession ? .earlierVersion : next.1
    }

    /// Restore: the document becomes the copy offered (`offeredRecoveryKey`), opened off the main actor
    /// (with the password the document was opened with), every change in it unsaved; the file is not
    /// written until Save. The copy is this session's from then on. Says whether it was restored: a copy
    /// that cannot be read or opened leaves the document as it is, and goes (the screen says so).
    func restoreRecoveredChanges() async -> Bool {
        guard let key = offeredRecoveryKey else { return false }
        recoveryHeldKeys.remove(key)
        offeredRecoveryKey = nil
        guard let url = recovery.copy(key: key, newerThan: nil) else { return false }
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
        if let recoveryOwnedKey, recoveryOwnedKey != key { recovery.delete(key: recoveryOwnedKey) }
        recoveryOwnedKey = key
        restoredThisSession = true
        return true
    }

    /// The bytes of the copy offered, for Save As of one from an earlier version of the file; nil when it
    /// cannot be read.
    func recoveredCopyBytes() async -> Data? {
        guard let key = offeredRecoveryKey, let url = recovery.copy(key: key, newerThan: nil) else { return nil }
        return try? await EditQueue.offMain { try Data(contentsOf: url) }.get()
    }

    /// The reader declined the copy offered, or saved it as a copy: it goes, and the document stays as it is.
    func discardRecoveredChanges() {
        guard let key = offeredRecoveryKey else { return }
        recoveryHeldKeys.remove(key)
        offeredRecoveryKey = nil
        recovery.delete(key: key)
    }
}
