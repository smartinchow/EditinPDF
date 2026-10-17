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

    // MARK: Search

    /// The name of the search: the toolbar button that opens it, and the title of its sheet.
    static var search: String {
        String(localized: "Search", comment: "Toolbar button and sheet title for searching the text of the document")
    }

    /// What the search field says while it is empty.
    static var searchPlaceholder: String {
        String(localized: "Search", comment: "Placeholder of the field the search words are typed in")
    }

    /// The page a search result is on, over its text; `page` counts from 1.
    static func searchHitPage(_ page: Int) -> String {
        String(localized: "Page \(page)", comment: "Over a search result's text: the page it is on")
    }

    /// What a search result is called, for VoiceOver and UI tests: its page, then the text around
    /// the match; `page` counts from 1.
    static func searchHitLabel(page: Int, snippet: String) -> String {
        String(localized: "Page \(page): \(snippet)", comment: "Accessibility label of one search result: its page number, then the text around the match")
    }

    /// Shown in place of the results when a search found nothing.
    static var searchNoMatches: String {
        String(localized: "No matches found", comment: "Shown when the search words are not in the document")
    }

    /// Under the results when there are as many as a search gives: there may be more. `limit` is the
    /// most it gives, written the way the reader's region writes numbers (1,000).
    static func searchTruncated(limit: Int) -> String {
        String(localized: "Showing the first \(limit.formatted()) matches", comment: "Under a full list of search results: only the first ones are shown")
    }

    /// Over the pages while a search has results: which one is on show (`current`, counting from 1)
    /// and how many there are.
    static func searchPosition(current: Int, count: Int) -> String {
        String(localized: "\(current) of \(count)", comment: "Which search result is on show, and how many there are")
    }

    /// The button that moves to the result before the one on show.
    static var searchPrevious: String {
        String(localized: "Previous match", comment: "Button that moves to the previous search result")
    }

    /// The button that moves to the result after the one on show.
    static var searchNext: String {
        String(localized: "Next match", comment: "Button that moves to the next search result")
    }

    /// The button that ends the search: it takes the results and their highlights away.
    static var searchEnd: String {
        String(localized: "End search", comment: "Button that clears the search and its highlights")
    }

    // MARK: Selection

    /// The action that puts the selected text on the pasteboard: the item of the menu that comes up
    /// over a selection, and the toolbar button that does the same without the menu.
    static var copy: String {
        String(localized: "Copy", comment: "Action that copies the selected text: the item of the menu over a selection, and a toolbar button")
    }

    /// What the handle at the start of the selected text is called, for VoiceOver and UI tests.
    static var selectionStart: String {
        String(localized: "Start of selection", comment: "Accessibility label of the handle at the start of the selected text")
    }

    /// What the handle at the end of the selected text is called, for VoiceOver and UI tests.
    static var selectionEnd: String {
        String(localized: "End of selection", comment: "Accessibility label of the handle at the end of the selected text")
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
