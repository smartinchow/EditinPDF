import EditinPDFCore
import Foundation
import os

/// What opening a file's bytes came to.
///
/// The engine's open is synchronous and can be slow, so it runs where the file is read, which is
/// off the main actor (observed off the main thread on the iOS 26.5 simulator), and the result
/// crosses to the main-actor `DocumentModel` as this value. So does every page's geometry, read
/// there too: one call to the engine per page, which for a long document is not something for the
/// main actor to wait on. The bridge declares `PdfDocument` and `PageInfo` `Sendable` (the document
/// is safe to share between threads), so the whole enum is.
enum OpenOutcome: Sendable {
    /// The file is a PDF the engine opened, with the geometry of each of its pages (page `n` is
    /// `pages[n]`).
    case open(PdfDocument, pages: [PageInfo])
    /// The file needs a password. The bytes are kept to try again (the only case that keeps them:
    /// an open file's bytes are the engine's, and a failed one's are not needed); `wrongPassword` says
    /// that a password was already tried and refused.
    case locked(Data, wrongPassword: Bool)
    /// The file could not be opened. `detail` is the engine's explanation, tidied into a sentence to
    /// go under `Strings.fileCouldNotBeOpened`; nil when there is none fit to show.
    case failed(detail: String?)

    private static let log = Logger(subsystem: Diagnostics.subsystem, category: "open")

    /// Opens `bytes` with `password` (none for a first try), and reads the geometry of every page of
    /// a document that opens. Blocks for as long as the engine takes.
    init(bytes: Data, password: String? = nil) {
        do {
            let document = try PdfDocument.open(bytes: bytes, password: password)
            // `pageInfo` answers for every index below `pageCount`; `compactMap` only means that a page
            // it did not answer for would be left out instead of trapping.
            self = .open(document, pages: (0..<document.pageCount()).compactMap { document.pageInfo(page: $0) })
        } catch OpenError.NeedsPassword {
            self = .locked(bytes, wrongPassword: false)
        } catch OpenError.WrongPassword {
            self = .locked(bytes, wrongPassword: true)
        } catch OpenError.Corrupt(let message) {
            self = .failed(detail: Strings.fileCouldNotBeOpenedDetail(message))
        } catch {
            // Not one of the bridge's typed errors: the engine panicked, which UniFFI reports as an
            // error instead of aborting. Nothing in it is fit to show, and it may quote the file, so it
            // stays out of the readable log too (`.private`: only a debugger sees it).
            Self.log.error("opening failed unexpectedly: \(String(describing: error), privacy: .private)")
            self = .failed(detail: nil)
        }
    }
}
