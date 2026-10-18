import Foundation
import Observation

/// Runs engine work one job at a time, in the order it was handed over, off the main actor.
///
/// Every change to the document (an edit, an undo, a redo) and the reading of the document's state
/// after it go through one queue, so they reach the engine in the order the reader made them, and an
/// undo tapped while an edit is still running undoes that edit, never an older one. Nothing here
/// calls the engine on the main actor: the bridge's `save` holds the document's lock for the whole
/// write, so a call made there during an autosave would freeze the screen until the save is done.
///
/// A job is a chain link: it waits for the job before it to finish (whether it succeeded or not),
/// then runs. `submit` links the job at once, synchronously, which is what keeps the order of jobs
/// the order of the calls.
@MainActor
@Observable
final class EditQueue {
    /// The last job handed over; the next one waits for it.
    @ObservationIgnored private var tail: Task<Void, Never>?
    /// How many jobs are handed over and not finished.
    private(set) var pendingCount = 0

    /// Whether any job is waiting or running.
    var isBusy: Bool { pendingCount > 0 }

    /// Hands over `job`, which runs on the main actor once every earlier job has finished. The job
    /// itself sends its engine work off the main actor (`run` and `offMain` do); doing the rest on
    /// the main actor, inside the job, means what a job publishes is published before the next job
    /// starts. Linked at once: jobs run in the order of the calls to `submit`.
    @discardableResult
    func submit<T: Sendable>(_ job: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let previous = tail
        pendingCount += 1
        let task = Task { @MainActor in
            await previous?.value
            let value = await job()
            self.pendingCount -= 1
            return value
        }
        tail = Task { _ = await task.value }
        return task
    }

    /// Runs `work` off the main actor once every earlier job has finished, and gives back what it
    /// returned or threw.
    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await submit { await Self.offMain(work) }.value.get()
    }

    /// Runs `work` on a thread of the cooperative pool, never the main thread, and gives back its
    /// outcome. For a job's engine calls.
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> Result<T, Error> {
        await Task.detached(priority: .userInitiated) { Result { try work() } }.value
    }

    /// Returns once every job handed over so far, and any handed over while waiting, has finished.
    func settle() async {
        while let last = tail {
            await last.value
            if tail == last { tail = nil }
        }
    }
}

/// One change, the target of its entries on the undo manager: the edit's undo entry, and the redo
/// and undo entries that follow from it. `applied` is set once the engine has made the change. A
/// change the engine refuses has its entry taken off the undo manager again
/// (`removeAllActions(withTarget:)`); until then, and should anything run it all the same, an entry
/// of a change that is not applied does nothing.
@MainActor
final class EditToken {
    var applied = false
}
