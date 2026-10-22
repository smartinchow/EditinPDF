import EditinPDFCore
import CoreTransferable
import Foundation
import UniformTypeIdentifiers
import os

/// Why Save a Copy made no copy.
enum CopyFailure: Error, Equatable {
    /// The bridge refused the save (`SaveError.Signed`): a signed document whose file is damaged, saving
    /// changes would rewrite it and break its signatures.
    case signed
    /// The document is not open, the engine could not write it, or the copy could not be written where
    /// the reader chose.
    case failed

    /// What the alert says under its title (`Strings.copyFailedTitle`).
    var message: String {
        switch self {
        case .signed: Strings.copySignedMessage
        case .failed: Strings.copyFailedMessage
        }
    }
}

extension DocumentModel {
    private static let copyLog = Logger(subsystem: Diagnostics.subsystem, category: "copy")

    /// The bytes of a copy of the document as the reader sees it, for Save a Copy: what the file's own
    /// save writes (`PDFFileDocument.savedBytes`: the file as opened with one appended update holding
    /// every change, a password-protected file still protected by its password).
    ///
    /// What waits is added first, through the closing path (`commitPendingInk(closing: true)`: the
    /// strokes drawn, the text box and the form field being typed in), and so is the note being written,
    /// as when the scene leaves (`saveNoteDraftOnLeaving`); then every change, undo and redo handed over
    /// is waited for (`settle`). The save runs off the main actor: the bridge holds the document's lock
    /// for the whole write.
    ///
    /// Nothing tells the engine it saved, so the document stays changed and is saved to its own file as
    /// before: only a copy is made. Fails with `.signed` when the bridge refuses the save for the
    /// document's signatures, `.failed` when the document is not open or the engine cannot write it.
    func copyBytes() async -> Result<Data, CopyFailure> {
        commitPendingInk(closing: true)
        saveNoteDraftOnLeaving()
        await settle()
        guard let document = document() else { return .failure(.failed) }
        let saved = await EditQueue.offMain { try document.save(mode: .incremental) }
        switch saved {
        case .success(let bytes):
            return .success(bytes)
        case .failure(SaveError.Signed):
            return .failure(.signed)
        case .failure(let error):
            // The engine's words stay out of the alert and, since they may quote the file, out of the readable log.
            Self.copyLog.error("making a copy failed: \(String(describing: error), privacy: .private)")
            return .failure(.failed)
        }
    }
}

/// The copy Save a Copy hands to the system's exporter, which writes it where the reader chooses: the
/// bytes made by `DocumentModel.copyBytes`, as a PDF. (Transferable rather than a `FileDocument`: the iOS
/// 27 SDK marks the exporter's `FileDocument` forms as to be deprecated.)
struct PDFCopy: Transferable {
    let bytes: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { copy in copy.bytes }
    }
}
