import EditinPDFCore
import Foundation
import Observation

/// What SwiftUI shows for one document: whether it is open, locked behind a password or could not
/// be read; its pages; which page the reader is on; its search; and the text selected in it.
/// Everything lives on the main actor, since views read it directly.
@MainActor
@Observable
final class DocumentModel {
    enum State {
        /// Needs a password; the bytes are kept for the next try. `wrongPassword` is true once a
        /// password has been tried and refused.
        case locked(Data, wrongPassword: Bool)
        case open(PdfDocument)
        /// Could not be opened; the text is ready to show.
        case failed(String)
    }

    private(set) var state: State
    /// The geometry of every page, read once when the document opens; empty until then.
    private(set) var pages: [PageInfo]
    /// The page the reader is on, counting from 0; the scroll view keeps it current.
    var currentPage = 0
    /// The search of the document: made once, when the document opens, and the same one for as long as
    /// the model lives; nil unless the document is open. It holds the engine's document, not the
    /// model.
    private(set) var search: SearchController?
    /// The selected text: made with `search`, when the document opens, and the same one for as long as
    /// the model lives; nil unless the document is open. It holds the engine's document, not the model.
    private(set) var selection: SelectionController?

    /// How many pages the document has; 0 unless it is open.
    var pageCount: Int { pages.count }

    /// Opens `bytes` with no password. Blocks for as long as the engine takes, so the document
    /// scene does not use it: that opens the file off the main actor and calls `init(outcome:)`.
    convenience init(bytes: Data) {
        self.init(outcome: OpenOutcome(bytes: bytes))
    }

    init(outcome: OpenOutcome) {
        (state, pages) = Self.resolve(outcome)
        search = document().map(SearchController.init(document:))
        selection = document().map(SelectionController.init(document:))
    }

    /// Tries `password` on a locked document, and says whether the document is open afterwards. A
    /// refused password leaves it locked with `wrongPassword` set, so the next try can show that.
    /// Blocks for as long as the engine takes.
    @discardableResult
    func unlock(password: String) -> Bool {
        switch state {
        case .open:
            return true
        case .failed:
            return false
        case .locked(let bytes, _):
            (state, pages) = Self.resolve(OpenOutcome(bytes: bytes, password: password))
            search = document().map(SearchController.init(document:))
            selection = document().map(SelectionController.init(document:))
            return document() != nil
        }
    }

    /// The open document, to draw and search; nil unless it is open.
    func document() -> PdfDocument? {
        if case .open(let document) = state { return document }
        return nil
    }

    private static func resolve(_ outcome: OpenOutcome) -> (State, [PageInfo]) {
        switch outcome {
        case .open(let document):
            // `pageInfo` answers for every index below `pageCount`; `compactMap` only means that a
            // page it did not answer for would be left out instead of trapping.
            return (.open(document), (0..<document.pageCount()).compactMap { document.pageInfo(page: $0) })
        case .locked(let bytes, let wrongPassword):
            return (.locked(bytes, wrongPassword: wrongPassword), [])
        case .failed(let message):
            return (.failed(message), [])
        }
    }
}
