import EditinPDFCore
import os

/// The engine document of one file, shared between the file document (any thread) and its model
/// (main actor).
///
/// The file document needs it to save: SwiftUI asks for a snapshot on the main thread and writes it
/// on a background queue. The model puts the document here when the file opens, and again when a
/// locked file is unlocked, so a document becomes savable exactly when it becomes open. Until then
/// it is nil, and a file that is locked or could not be read is never written.
final class EngineHandle: Sendable {
    private let state: OSAllocatedUnfairLock<PdfDocument?>

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
}
