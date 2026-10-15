import EditinPDFCore
import Foundation
import os

/// What opening a file's bytes came to.
///
/// The engine's open is synchronous and can be slow, so it runs where the file is read, which is
/// off the main actor, and the result crosses to the main-actor `DocumentModel` as this value. The
/// bridge declares `PdfDocument` `Sendable` (it is safe to share between threads), so the whole
/// enum is.
enum OpenOutcome: Sendable {
    /// The file is a PDF the engine opened.
    case open(PdfDocument)
    /// The file needs a password. The bytes are kept to try again; `wrongPassword` says that a
    /// password was already tried and refused.
    case locked(Data, wrongPassword: Bool)
    /// The file could not be opened. The text is ready to show.
    case failed(String)

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.editinpdf.ios", category: "open")

    /// Opens `bytes` with `password` (none for a first try). Blocks for as long as the engine takes.
    init(bytes: Data, password: String? = nil) {
        do {
            self = .open(try PdfDocument.open(bytes: bytes, password: password))
        } catch OpenError.NeedsPassword {
            self = .locked(bytes, wrongPassword: false)
        } catch OpenError.WrongPassword {
            self = .locked(bytes, wrongPassword: true)
        } catch OpenError.Corrupt(let message) {
            self = .failed(Strings.fileCouldNotBeOpened(detail: message))
        } catch {
            // Not one of the bridge's typed errors: the engine panicked, which UniFFI reports as an
            // error instead of aborting. Nothing in it is fit to show.
            Self.log.error("opening failed unexpectedly: \(String(describing: error), privacy: .public)")
            self = .failed(Strings.fileCouldNotBeOpened)
        }
    }
}
