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

    /// Why a save was refused: the reason the system's own alert shows when the changes could not be
    /// written. Our words, never the engine's.
    static var saveFailed: String {
        String(localized: "The changes could not be saved.", comment: "Reason shown when the edits to a PDF could not be written to its file")
    }

    // MARK: Editing

    /// The toolbar button that takes back the last change.
    static var undo: String {
        String(localized: "Undo", comment: "Toolbar button that takes back the last change to the PDF")
    }

    /// The toolbar button that makes again the change last taken back.
    static var redo: String {
        String(localized: "Redo", comment: "Toolbar button that makes again the change last taken back")
    }

    /// The title of the alert about a change that was not made.
    static var editFailed: String {
        String(localized: "That change could not be made.", comment: "Title of the alert shown when a change to the PDF was refused or failed")
    }

    /// Why a change was not made: the document's settings do not allow it.
    static var editNotAllowed: String {
        String(localized: "This document doesn't allow that change.", comment: "Shown when the PDF's security settings or format do not allow the change")
    }

    /// Why a delete was not made: it would have removed every page.
    static var cannotDeleteAllPages: String {
        String(localized: "A document needs at least one page.", comment: "Shown when deleting the chosen pages would leave the PDF without a page")
    }

    /// Why a change was not made: it was meant for the document as it was before another change.
    static var documentChangedTryAgain: String {
        String(localized: "The document changed. Try again.", comment: "Shown when a change was made for an older state of the PDF and was refused")
    }

    /// Why an insert was not made: the PDF to take pages from needs a password.
    static var insertSourceLocked: String {
        String(localized: "That PDF is password-protected. Remove its password and try again.", comment: "Shown when the PDF to take pages from needs a password")
    }

    /// Why an insert was not made: the file to take pages from is not a readable PDF.
    static var insertSourceUnreadable: String {
        String(localized: "That file could not be read as a PDF.", comment: "Shown when the file to take pages from is not a readable PDF")
    }

    /// Why an insert was not made: the PDF to take pages from does not allow its pages to be copied.
    static var insertSourceNotPermitted: String {
        String(localized: "That PDF doesn't allow its pages to be copied.", comment: "Shown when the PDF to take pages from does not allow copying its pages")
    }

    /// The name Undo and Redo give a rotation.
    static var actionRotate: String {
        String(localized: "Rotate Pages", comment: "Name of the change in Undo and Redo: pages were turned")
    }

    /// The name Undo and Redo give a page delete.
    static var actionDelete: String {
        String(localized: "Delete Pages", comment: "Name of the change in Undo and Redo: pages were removed")
    }

    /// The name Undo and Redo give a page move.
    static var actionMove: String {
        String(localized: "Move Pages", comment: "Name of the change in Undo and Redo: pages were reordered")
    }

    /// The name Undo and Redo give an inserted blank page.
    static var actionInsertBlank: String {
        String(localized: "Insert Blank Page", comment: "Name of the change in Undo and Redo: an empty page was added")
    }

    /// The name Undo and Redo give pages inserted from another file.
    static var actionInsertFile: String {
        String(localized: "Insert Pages", comment: "Name of the change in Undo and Redo: pages from another PDF were added")
    }

    /// The name Undo and Redo give added markup.
    static var actionAddAnnotation: String {
        String(localized: "Add Markup", comment: "Name of the change in Undo and Redo: a highlight, drawing, note or shape was added")
    }

    /// The name Undo and Redo give deleted markup.
    static var actionDeleteAnnotation: String {
        String(localized: "Delete Markup", comment: "Name of the change in Undo and Redo: markup was removed")
    }

    /// The name Undo and Redo give moved markup.
    static var actionMoveAnnotation: String {
        String(localized: "Move Markup", comment: "Name of the change in Undo and Redo: markup was moved")
    }

    /// The name Undo and Redo give edited markup.
    static var actionEditAnnotation: String {
        String(localized: "Edit Markup", comment: "Name of the change in Undo and Redo: markup's text or color was changed")
    }

    /// The name Undo and Redo give a filled-in form field.
    static var actionFillField: String {
        String(localized: "Fill Form", comment: "Name of the change in Undo and Redo: a form field was filled in")
    }

    // MARK: Organize

    /// The name of the Organize screen: the toolbar button that opens it, and its title.
    static var organize: String {
        String(localized: "Organize Pages", comment: "Toolbar button and screen title for reordering, turning, deleting and adding pages")
    }

    /// The Organize button that selects every page.
    static var selectAll: String {
        String(localized: "Select All", comment: "Organize button that selects every page")
    }

    /// The Organize button that clears the selection, once every page is selected.
    static var deselectAll: String {
        String(localized: "Deselect All", comment: "Organize button that clears the selection of pages")
    }

    /// The Organize button that turns the selected pages a quarter turn anticlockwise.
    static var rotateLeft: String {
        String(localized: "Rotate Left", comment: "Organize button that turns the selected pages a quarter turn anticlockwise")
    }

    /// The Organize button that turns the selected pages a quarter turn clockwise.
    static var rotateRight: String {
        String(localized: "Rotate Right", comment: "Organize button that turns the selected pages a quarter turn clockwise")
    }

    /// The Organize button that removes the selected pages, and the confirmation's button.
    static var delete: String {
        String(localized: "Delete", comment: "Organize button that removes the selected pages; also the button that confirms it")
    }

    /// The Organize button that adds an empty page after the selection.
    static var insertBlank: String {
        String(localized: "Insert Blank Page", comment: "Organize button that adds an empty page")
    }

    /// The question asked before several pages are deleted.
    static func deletePagesConfirm(count: Int) -> String {
        String(localized: "Delete \(count) pages?", comment: "Title of the confirmation before deleting several pages")
    }

    /// Under that question.
    static var deletePagesConfirmMessage: String {
        String(localized: "You can undo this.", comment: "Message of the confirmation before deleting several pages")
    }

    /// Shown in Organize when the document does not allow its pages to be changed.
    static var organizeNotAllowed: String {
        String(localized: "This document doesn't allow changing its pages.", comment: "Shown in Organize when the PDF's settings do not allow changing its pages")
    }

    /// How many pages are selected in Organize, as its title.
    static func pagesSelected(count: Int) -> String {
        String(localized: "\(count) selected", comment: "Title of the Organize screen while pages are selected: how many")
    }

    /// The Organize button that takes pages from another PDF.
    static var insertFromFile: String {
        String(localized: "Insert from File…", comment: "Organize button that opens the file picker to add pages from another PDF")
    }

    /// The Organize button that saves or shares the selected pages as a new PDF.
    static var extract: String {
        String(localized: "Extract Pages", comment: "Organize button that saves or shares the selected pages as a new PDF")
    }

    /// The name of the PDF made of pages `first` to `last` (counting from 1) of the document `base`, without ".pdf".
    static func extractedFileName(base: String, first: Int, last: Int) -> String {
        if first == last {
            return String(localized: "\(base) (page \(first))", comment: "File name, without extension, of one page extracted from a PDF: the PDF's name and the page number")
        }
        return String(localized: "\(base) (pages \(first)–\(last))", comment: "File name, without extension, of pages extracted from a PDF: the PDF's name, the first and the last page number")
    }

    /// Shown with Extract when the document is password-protected.
    static var extractUnprotectedNote: String {
        String(localized: "The extracted pages are not password-protected.", comment: "Shown under the Extract button for a password-protected PDF: the new PDF has no password")
    }

    /// The name a document is given in the file name of extracted pages when it has none.
    static var untitledDocument: String {
        String(localized: "Document", comment: "Name used for a PDF that has no file name, in the name of pages extracted from it")
    }

    /// Why a file was not inserted: it is too big to be read into memory safely.
    static var pickedFileTooLarge: String {
        String(localized: "That file is too large to insert (over 500 MB).", comment: "Shown when the PDF chosen to take pages from is larger than 500 megabytes")
    }

    /// Why a file was not inserted: the app could not read it.
    static var pickedFileUnreadable: String {
        String(localized: "That file could not be opened.", comment: "Shown when the chosen file could not be read at all")
    }

    // MARK: Markup

    /// The toolbar button that turns Markup mode, with its tool palette, on and off.
    static var markup: String {
        String(localized: "Markup", comment: "Toolbar button that shows or hides the markup tools")
    }

    /// Under the tool palette, for a document whose permissions forbid adding or changing annotations.
    static var markupNotAllowed: String {
        String(localized: "This document doesn't allow markup.", comment: "Under the markup tools when the document forbids annotations")
    }

    /// Under the tool palette while the page being read is turned: the engine cannot yet draw a text box on it.
    static var textBoxNeedsUprightPage: String {
        String(localized: "Text boxes can't be added to turned pages yet.", comment: "Under the markup tools when the current page is rotated: the Text Box tool is unavailable there")
    }

    /// The tool that picks annotations instead of making them.
    static var toolSelect: String {
        String(localized: "Select", comment: "Markup tool that selects existing annotations")
    }

    /// The highlight tool, and the selection menu's Highlight.
    static var highlight: String {
        String(localized: "Highlight", comment: "Markup tool and menu item that highlights text")
    }

    /// The underline tool, and the selection menu's Underline.
    static var underline: String {
        String(localized: "Underline", comment: "Markup tool and menu item that underlines text")
    }

    /// The strikethrough tool, and the selection menu's Strikethrough.
    static var strikeout: String {
        String(localized: "Strikethrough", comment: "Markup tool and menu item that strikes text through")
    }

    /// The freehand drawing tool.
    static var toolInk: String {
        String(localized: "Draw", comment: "Markup tool for drawing freehand")
    }

    /// The tool that types text onto the page.
    static var toolTextBox: String {
        String(localized: "Text Box", comment: "Markup tool that adds a box of typed text")
    }

    /// The sticky-note tool.
    static var toolNote: String {
        String(localized: "Note", comment: "Markup tool that adds a sticky note")
    }

    /// The rectangle tool.
    static var toolRectangle: String {
        String(localized: "Rectangle", comment: "Markup tool that draws a rectangle")
    }

    /// The oval tool.
    static var toolOval: String {
        String(localized: "Oval", comment: "Markup tool that draws an oval")
    }

    /// The straight-line tool.
    static var toolLine: String {
        String(localized: "Line", comment: "Markup tool that draws a straight line")
    }

    /// The arrow tool.
    static var toolArrow: String {
        String(localized: "Arrow", comment: "Markup tool that draws an arrow")
    }

    /// The tool that deletes the annotations it touches.
    static var toolEraser: String {
        String(localized: "Eraser", comment: "Markup tool that deletes annotations")
    }

    /// The palette button that opens the colour, width and size of the current tool.
    static var toolStyle: String {
        String(localized: "Style", comment: "Markup palette button that opens the current tool's colour and size")
    }

    /// The style picker's colour well.
    static var styleColor: String {
        String(localized: "Color", comment: "Label of the colour picker in the markup style picker")
    }

    /// The style picker's line width slider.
    static var styleWidth: String {
        String(localized: "Line Width", comment: "Label of the line width slider in the markup style picker")
    }

    /// A line width, in points, beside its slider.
    static func styleWidthValue(_ width: Double) -> String {
        String(localized: "\(width.formatted(.number.precision(.fractionLength(0...1)))) pt", comment: "A line width in points, shown beside its slider")
    }

    /// The style picker's font size stepper, with the size in points.
    static func styleFontSize(_ size: Double) -> String {
        String(localized: "Font Size: \(size.formatted(.number.precision(.fractionLength(0...1)))) pt", comment: "Font size stepper in the markup style picker, with the size in points")
    }

    /// The style picker's switch that fills a rectangle or an oval.
    static var styleFill: String {
        String(localized: "Fill", comment: "Switch in the markup style picker that fills a rectangle or oval")
    }

    /// The names of the style picker's eight colour swatches, in their order, for VoiceOver.
    static var styleSwatchNames: [String] {
        [String(localized: "Black", comment: "Colour swatch name"),
         String(localized: "Gray", comment: "Colour swatch name"),
         String(localized: "Red", comment: "Colour swatch name"),
         String(localized: "Orange", comment: "Colour swatch name"),
         String(localized: "Yellow", comment: "Colour swatch name"),
         String(localized: "Green", comment: "Colour swatch name"),
         String(localized: "Blue", comment: "Colour swatch name"),
         String(localized: "Purple", comment: "Colour swatch name")]
    }
}
