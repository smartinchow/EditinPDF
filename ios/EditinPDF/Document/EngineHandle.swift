import EditinPDFCore
import Foundation
import os

/// The engine document of one file, shared between the file document (any thread) and its model
/// (main actor).
///
/// The file document needs it to save: SwiftUI asks for a snapshot on the main thread and writes it
/// on a background queue. The model puts the document here when the file opens, and again when a
/// locked file is unlocked, so a document becomes savable exactly when it becomes open. Until then
/// it is nil, and a file that is locked or could not be read is never written.
///
/// It also counts the changes, undos and redos handed over to the model's queue that have not reached
/// the engine yet, so a save can wait for them (`waitForEdits`): the scene saves as the document closes,
/// on a queue of its own, while a change handed over a moment before (the strokes added as the back
/// button goes down) may still be on its way.
final class EngineHandle: Sendable {
    private let state: OSAllocatedUnfairLock<PdfDocument?>
    private let edits = EditsOnTheirWay()

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
