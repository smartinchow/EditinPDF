import Foundation

/// Every sentence a person reads in the app, in one place: the wording is reviewed here, and
/// localisation, when it comes, has a single entry point. Views and models ask this type for their
/// text instead of spelling out their own.
enum Strings {
    /// How many pages the document has, shown on the document screen until the page indicator
    /// replaces it.
    static func pageCount(_ count: Int) -> String {
        String(localized: "\(count) pages", comment: "Placeholder on the document screen: how many pages the document has")
    }

    /// The sentence that starts every message about a file the engine could not read.
    static var fileCouldNotBeOpened: String {
        String(localized: "This file could not be opened.", comment: "Message shown when a PDF cannot be read")
    }

    /// `detail` is the engine's own wording for why it could not read the file (an
    /// `OpenError.Corrupt` message). It is not ours, so it follows our sentence instead of replacing
    /// it, and it is only tidied into a sentence (the engine writes fragments: lower case, no full
    /// stop). The file is not called "damaged": the engine also refuses files that are sound but use
    /// something it does not support.
    static func fileCouldNotBeOpened(detail: String) -> String {
        var reason = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = reason.first else { return fileCouldNotBeOpened }
        reason = first.uppercased() + reason.dropFirst()
        if let last = reason.last, !".!?…".contains(last) { reason += "." }
        return "\(fileCouldNotBeOpened) \(reason)"
    }
}
