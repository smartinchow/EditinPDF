import EditinPDFCore
import SwiftUI
import UniformTypeIdentifiers
import os

/// A PDF file as the document scene sees it, edited in place and saved by the system's autosave.
///
/// SwiftUI creates it off the main actor, once per opened file, and requires it to be `Sendable`;
/// that is why it holds only `engine` (a lock-guarded handle), the immutable `outcome` of opening the
/// file, and the main-actor `DocumentModel`, built on first use instead of in `init`. Observed off
/// the main thread on the iOS 26.5 simulator: `init(configuration:)` reported `Thread.isMainThread`
/// false on every open.
///
/// Saving: the snapshot is the engine document itself, so taking it (on the main thread) costs
/// nothing; the write, `save(mode: .incremental)`, runs in `fileWrapper` on SwiftUI's background
/// queue. The bridge's state lock makes it see whole edits. Every save is the file as opened plus one
/// appended update holding all current changes; nothing tells the engine it saved, so a failed
/// write can never leave it believing so. A file that is locked or could not be read has no engine
/// document, and its snapshot is refused: it is never written.
final class PDFFileDocument: ReferenceFileDocument {
    typealias Snapshot = PdfDocument

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

    /// The engine document, to be written by `fileWrapper`. Refused unless the file is open.
    func snapshot(contentType: UTType) throws -> PdfDocument {
        guard let document = engine.document else { throw Self.writeRefused }
        return document
    }

    /// The file as opened with the current changes appended. Runs off the main thread.
    func fileWrapper(snapshot: PdfDocument, configuration: WriteConfiguration) throws -> FileWrapper {
        do {
            return FileWrapper(regularFileWithContents: try snapshot.save(mode: .incremental))
        } catch {
            // The engine's words stay out of the alert and, since they may quote the file, out of the
            // readable log.
            Self.log.error("saving failed: \(String(describing: error), privacy: .private)")
            throw Self.writeRefused
        }
    }

    /// What a refused save throws: the system's alert shows our reason.
    private static var writeRefused: CocoaError {
        CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedFailureReasonErrorKey: Strings.saveFailed])
    }
}
