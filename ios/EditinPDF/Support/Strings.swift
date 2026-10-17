import Foundation

/// Every sentence a person reads in the app, in one place: the wording is reviewed here, and
/// localisation, when it comes, has a single entry point. Views and models ask this type for their
/// text instead of spelling out their own.
enum Strings {
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

    /// `searchPosition` for a search that stopped at the most results it gives (`count`), so there may
    /// be more: "1 of 1,000+". The numbers are written the way the reader's region writes them.
    static func searchPositionTruncated(current: Int, count: Int) -> String {
        String(localized: "\(current.formatted()) of \(count.formatted())+",
               comment: "Which search result is on show, and how many were found when the search stopped at its limit, so there may be more")
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

    // MARK: Files that do not open

    /// The title of the alert about a file the engine could not read; the engine's explanation goes
    /// under it (`fileCouldNotBeOpenedDetail`).
    static var fileCouldNotBeOpened: String {
        String(localized: "This file could not be opened.", comment: "Title of the message shown when a PDF cannot be read")
    }

    /// `engineText` is the engine's own wording for why it could not read the file (an
    /// `OpenError.Corrupt` message). It is not ours, so it goes under our title instead of replacing
    /// it, and it is only tidied into a sentence (the engine writes fragments: lower case, no full
    /// stop); nil if there is nothing in it to show. The file is not called "damaged": the engine also
    /// refuses files that are sound but use something it does not support.
    static func fileCouldNotBeOpenedDetail(_ engineText: String) -> String? {
        var detail = engineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = detail.first else { return nil }
        detail = first.uppercased() + detail.dropFirst()
        if let last = detail.last, !".!?…".contains(last) { detail += "." }
        return detail
    }

    // MARK: Password

    /// The title of the prompt for the password of a protected document, and of the screen of a
    /// protected document whose prompt was put away.
    static var passwordTitle: String {
        String(localized: "Password Required", comment: "Title of the prompt that asks for a PDF's password, and of the screen of a locked PDF")
    }

    /// What the password prompt says over its field, and the screen of a protected document whose
    /// prompt was put away under its title.
    static var passwordExplanation: String {
        String(localized: "This document is protected. Enter the password to open it.", comment: "Explanation in the prompt that asks for a PDF's password, and on the screen of a locked PDF")
    }

    /// The button on the screen of a protected document that brings its password prompt back.
    static var enterPassword: String {
        String(localized: "Enter Password", comment: "Button on the screen of a locked PDF that brings back the prompt for its password")
    }

    /// What the password field says while it is empty.
    static var passwordPlaceholder: String {
        String(localized: "Password", comment: "Placeholder of the field a PDF's password is typed in")
    }

    /// Under the password field once a password was tried and refused.
    static var wrongPassword: String {
        String(localized: "Wrong password", comment: "Shown under the password field when the password typed does not open the PDF")
    }

    /// The button that tries the password.
    static var unlock: String {
        String(localized: "Unlock", comment: "Button that tries the password typed for a protected PDF")
    }

    /// The button that puts the password prompt away; the document stays locked.
    static var cancel: String {
        String(localized: "Cancel", comment: "Button that puts away the prompt for a PDF's password; the PDF stays locked")
    }

    /// The button of the message about a file that could not be opened; it closes the document.
    static var close: String {
        String(localized: "Close", comment: "Button that closes a document that could not be opened")
    }
}
