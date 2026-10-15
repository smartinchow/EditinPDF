import Foundation

/// Every sentence a person reads in the app, in one place: the wording is reviewed here, and
/// localisation, when it comes, has a single entry point. Views and models ask this type for their
/// text instead of spelling out their own.
enum Strings {
    /// How many pages the document has, shown on the document screen while the document is locked
    /// or could not be read, until the password prompt and the error message replace it.
    static func pageCount(_ count: Int) -> String {
        String(localized: "\(count) pages", comment: "Placeholder on the document screen: how many pages the document has")
    }

    /// The page indicator over an open document: the page the reader is on, counting from 1, and
    /// how many pages the document has.
    static func pageIndicator(current: Int, count: Int) -> String {
        String(localized: "\(current) / \(count)", comment: "Page indicator over the open document: the page being read, then how many pages there are")
    }

    /// The name of the thumbnails: the toolbar button that opens them, and the title of their sheet.
    static var thumbnails: String {
        String(localized: "Thumbnails", comment: "Toolbar button and sheet title for the grid of small pictures of the pages")
    }

    /// What a thumbnail in the grid is called, for VoiceOver and UI tests; `page` counts from 1.
    static func thumbnailLabel(page: Int) -> String {
        String(localized: "Page \(page)", comment: "Accessibility label of one page's thumbnail")
    }

    /// The page number under a thumbnail, counting from 1.
    static func pageNumber(_ page: Int) -> String {
        String(localized: "\(page)", comment: "Caption under a page's thumbnail: the page number")
    }

    /// The button that closes a sheet.
    static var done: String {
        String(localized: "Done", comment: "Button that closes a sheet")
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
