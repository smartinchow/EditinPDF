import EditinPDFCore
import SwiftUI
import UniformTypeIdentifiers
import os

/// A PDF file as the document scene sees it, edited in place and written only when the reader chooses
/// Save (ADR 0002, section 3).
///
/// SwiftUI creates it off the main actor, once per opened file, and requires it to be `Sendable`;
/// that is why it holds only `engine` (a lock-guarded handle), the immutable `outcome` of opening the
/// file, and the main-actor `DocumentModel`, built on first use instead of in `init`. Observed off
/// the main thread on the iOS 26.5 simulator: `init(configuration:)` reported `Thread.isMainThread`
/// false on every open.
///
/// Saving: the scene's document never hears of an edit (the model registers its changes with an undo
/// manager of its own, `DocumentModel.undoManager`), so the system has nothing to save on its own; Save
/// asks the scene's document to write (`SceneDocumentWriter`), with `EngineHandle.beginExplicitSave`.
/// The snapshot is the engine document itself, so taking it costs nothing, with whether Save asked for
/// it; the write, `save(mode: .incremental)`, runs in `fileWrapper`, which SwiftUI calls on a background
/// queue (observed off the main thread on the iOS 26.5 simulator). The bridge's state lock makes it see
/// whole edits. A write Save did not ask for writes the file as it is (`bytesToWrite`). Every save is
/// the file as opened plus one appended update holding all current changes (but for a damaged file the
/// engine rebuilt, written out in full: `EditCapabilities.rewritesOnSave`); nothing tells the engine it
/// saved, so a failed write can never leave it believing so. A file that is locked or could not be read
/// has no engine document, and its snapshot is refused: it is never written.
final class PDFFileDocument: ReferenceFileDocument {
    /// What a write is taken from: the engine document, and whether Save asked for the write.
    struct Snapshot: Sendable {
        let document: PdfDocument
        let isExplicitSave: Bool
    }

    static var readableContentTypes: [UTType] { [.pdf] }

    /// The engine document saves are taken from; nil until the file is open.
    let engine: EngineHandle
    /// What the engine made of the file's bytes, decided where the file was read: it is the slow
    /// part. Only a locked outcome keeps the bytes (for the password); an open one has handed them
    /// to the engine.
    private let outcome: OpenOutcome

    @MainActor private var cachedModel: DocumentModel?

    private static let log = Logger(subsystem: Diagnostics.subsystem, category: "save")

    /// The model for this file's screen. Built on first use, then kept, so every redraw of the
    /// scene sees the same page position and state.
    @MainActor var model: DocumentModel {
        if let cachedModel { return cachedModel }
        let built = DocumentModel(outcome: outcome, engine: engine)
        cachedModel = built
        return built
    }

    /// A new document: one blank page, Letter where the reader measures in US units, A4 elsewhere.
    convenience init() {
        let (width, height): (Double, Double) = Locale.current.measurementSystem == .us ? (612, 792) : (595, 842)
        do {
            self.init(outcome: OpenOutcome(bytes: try blankDocument(widthPt: width, heightPt: height)))
        } catch {
            Self.log.error("making a blank document failed: \(String(describing: error), privacy: .private)")
            self.init(outcome: .failed(detail: nil))
        }
    }

    /// Opens `bytes`. Blocks for as long as the engine takes.
    convenience init(bytes: Data) {
        self.init(outcome: OpenOutcome(bytes: bytes))
    }

    /// A file document saving `engine`'s document, for a test to write through as the scene does. Its
    /// own model is of no file (`outcome` failed).
    init(sharing engine: EngineHandle) {
        outcome = .failed(detail: nil)
        self.engine = engine
    }

    private init(outcome: OpenOutcome) {
        self.outcome = outcome
        if case .open(let document, _) = outcome {
            engine = EngineHandle(document)
        } else {
            engine = EngineHandle()
        }
    }

    /// A file the engine cannot read still opens as a document, in the failed state, so the screen
    /// can say why; only a file with no readable contents at all is refused here.
    convenience init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.init(bytes: bytes)
    }

    /// The engine document, to be written by `fileWrapper`, and whether Save is writing it now. Refused
    /// unless the file is open.
    func snapshot(contentType: UTType) throws -> Snapshot {
        guard let document = engine.document else { throw Self.writeRefused }
        return Snapshot(document: document, isExplicitSave: engine.isSavingExplicitly)
    }

    /// How long a save waits for the changes on their way to reach the engine (`savedBytes`). It
    /// waits only while one is on its way, off the main thread, and a change on a big document (pages
    /// inserted from a large file, a long drawing) can take seconds.
    static let editWait: TimeInterval = 10

    /// What Save writes: the file as opened with the current changes appended; for any other write, the
    /// file as it is (`bytesToWrite`). Runs off the main thread.
    func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        if let existing = configuration.existingFile, existing.isRegularFile, Self.leavesTheFile(snapshot, hasFile: true) {
            Self.log.notice("a save Save did not ask for: the file is written as it is")
            return existing
        }
        do {
            return FileWrapper(regularFileWithContents: try savedBytes(of: snapshot.document))
        } catch {
            // The engine's words stay out of the alert and, since they may quote the file, out of the
            // readable log.
            Self.log.error("saving failed: \(String(describing: error), privacy: .private)")
            throw Self.writeRefused
        }
    }

    /// What a write of `snapshot` puts in the file, which holds `existing` (nil: no file yet). Save's
    /// (`isExplicitSave`) is the engine document with its changes (`savedBytes`). Any other write, which
    /// the system makes on its own (an automatic save, the document closing, the app going to the
    /// background), is the file as it is: the changes reach the file only when the reader chooses Save. A
    /// file not written yet (a new document's first write) is written as the engine has it.
    func bytesToWrite(_ snapshot: Snapshot, existing: Data?) throws -> Data {
        if let existing, Self.leavesTheFile(snapshot, hasFile: true) { return existing }
        return try savedBytes(of: snapshot.document)
    }

    /// Whether a write of `snapshot` writes the file as it is: one Save did not ask for, of a file that
    /// is there (`hasFile`).
    static func leavesTheFile(_ snapshot: Snapshot, hasFile: Bool) -> Bool {
        hasFile && !snapshot.isExplicitSave
    }

    /// What Save writes: `snapshot` (the engine document) saved incrementally, once the changes handed
    /// over have reached it, for up to `wait` seconds (`editWait`; a test's own). Save adds what waits and
    /// waits for the changes on their way before it writes (`DocumentModel.save`); this is the second
    /// line, for a change handed over as the write starts. Off the main thread only: on it, the changes
    /// could not finish, and it saves what the engine has. When the wait runs out it saves what the
    /// engine has too, and logs a warning that says so (and nothing of the document).
    func savedBytes(of snapshot: PdfDocument, waitingAtMost wait: TimeInterval = editWait) throws -> Data {
        if !Thread.isMainThread, !engine.waitForEdits(timeout: wait) {
            // Nothing of the document in the log: only that the save did not wait any longer.
            Self.log.warning("saving without a change still on its way: it had not reached the document after \(wait, privacy: .public) s")
        }
        return try snapshot.save(mode: .incremental)
    }

    /// What a refused save throws: the system's alert shows our reason.
    private static var writeRefused: CocoaError {
        CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedFailureReasonErrorKey: Strings.saveFailed])
    }
}
