import EditinPDFCore
import Foundation
import os

/// The engine document of one file, shared between the file document (any thread) and its model
/// (main actor).
///
/// The file document needs it to save: SwiftUI asks for a snapshot, then writes it on a background
/// queue (observed off the main thread). The model puts the document here when the file opens, and
/// again when a locked file is unlocked, so a document becomes savable exactly when it becomes open.
/// Until then it is nil, and a file that is locked or could not be read is never written.
///
/// It also counts the changes, undos and redos handed over to the model's queue that have not reached
/// the engine yet, so a save can wait for them (`waitForEdits`): the scene writes on a queue of its own,
/// while a change handed over a moment before may still be on its way.
///
/// And it says whether the reader asked for a save (`beginExplicitSave`): only a save asked for with Save
/// writes the engine's changes to the file. Any other write the system makes (an automatic save) writes
/// the file as it is (`PDFFileDocument.bytesToWrite`).
final class EngineHandle: Sendable {
    private let state: OSAllocatedUnfairLock<PdfDocument?>
    private let edits = EditsOnTheirWay()
    private let explicitSaves = OSAllocatedUnfairLock(initialState: 0)
    private let automatic = OSAllocatedUnfairLock(initialState: false)

    init(_ document: PdfDocument? = nil) {
        state = OSAllocatedUnfairLock(initialState: document)
    }

    /// The open document; nil while the file is locked or could not be read.
    var document: PdfDocument? {
        state.withLock { $0 }
    }

    /// Makes `document` the one that is saved from now on.
    func adopt(_ document: PdfDocument) {
        state.withLock { $0 = document }
    }

    /// Save is writing the file: until `endExplicitSave`, a write writes the engine's changes.
    func beginExplicitSave() {
        explicitSaves.withLock { $0 += 1 }
    }

    /// The write Save asked for is over (written or not).
    func endExplicitSave() {
        explicitSaves.withLock { $0 = max($0 - 1, 0) }
    }

    /// Whether Save is writing the file now.
    var isSavingExplicitly: Bool {
        explicitSaves.withLock { $0 > 0 }
    }

    /// Whether every write writes the engine's changes: the document is saved the system's way, on its
    /// own (`SavingMode.automatic`, where Back cannot ask).
    var writesAutomatically: Bool {
        get { automatic.withLock { $0 } }
        set { automatic.withLock { $0 = newValue } }
    }

    /// A change, undo or redo has been handed over: it is on its way to the engine.
    func editWillStart() {
        edits.change(by: 1)
    }

    /// A change, undo or redo handed over has run (made or refused).
    func editDidFinish() {
        edits.change(by: -1)
    }

    /// Waits, blocking the calling thread, until no change handed over is on its way, or `timeout`
    /// seconds have passed. Says whether none is left. Never call it on the main thread: the changes
    /// finish there.
    func waitForEdits(timeout: TimeInterval) -> Bool {
        edits.waitUntilNone(timeout: timeout)
    }
}

/// How many changes are on their way, behind a condition a saving thread can wait on.
private final class EditsOnTheirWay: @unchecked Sendable {
    // Every access to `count` is under `condition`'s lock.
    private let condition = NSCondition()
    private var count = 0

    func change(by delta: Int) {
        condition.lock()
        count = max(count + delta, 0)
        if count == 0 { condition.broadcast() }
        condition.unlock()
    }

    func waitUntilNone(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while count > 0 {
            if !condition.wait(until: deadline) { return count == 0 }
        }
        return true
    }
}
