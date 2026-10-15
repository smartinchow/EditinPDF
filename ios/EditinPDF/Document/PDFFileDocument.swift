import SwiftUI
import UniformTypeIdentifiers

/// A PDF file as the document scene sees it. Read-only in M1: nothing edits the file, so what is
/// written back is what was read.
///
/// SwiftUI creates it off the main actor, once per opened file, and requires it to be `Sendable`;
/// that is why it holds only immutable values (the bytes and what the engine made of them) and
/// builds the main-actor `DocumentModel` on first use instead of in `init`.
final class PDFFileDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    /// The file exactly as read. M2 replaces this with the engine's saved bytes.
    private let bytes: Data
    /// What the engine made of `bytes`, decided where the file was read: it is the slow part.
    private let outcome: OpenOutcome

    @MainActor private var cachedModel: DocumentModel?

    /// The model for this file's screen. Built on first use, then kept, so every redraw of the
    /// scene sees the same page position and state.
    @MainActor var model: DocumentModel {
        if let cachedModel { return cachedModel }
        let built = DocumentModel(outcome: outcome)
        cachedModel = built
        return built
    }

    init(bytes: Data) {
        self.bytes = bytes
        self.outcome = OpenOutcome(bytes: bytes)
    }

    /// A file the engine cannot read still opens as a document, in the failed state, so the screen
    /// can say why; only a file with no readable contents at all is refused here.
    convenience init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.init(bytes: bytes)
    }

    func snapshot(contentType: UTType) throws -> Data {
        bytes
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}
