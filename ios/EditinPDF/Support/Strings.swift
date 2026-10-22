import EditinPDFCore
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

    /// The button that puts a prompt or a sheet away without doing anything: the password prompt (the
    /// document stays locked), the note sheet (the note stays as it was), the signature pad (the saved
    /// signature stays as it was).
    static var cancel: String {
        String(localized: "Cancel", comment: "Button that puts away a prompt or sheet without changing anything: the prompt for a PDF's password (the PDF stays locked), the note editor (the note stays as it was), the sheet of a form field's options (the field stays as it was), the signature pad (the saved signature stays as it was)")
    }

    /// The button that keeps what was written or drawn: the note sheet's, the signature pad's.
    static var save: String {
        String(localized: "Save", comment: "Button that keeps what was written or drawn: the note editor's (the note's text), the signature pad's (the signature drawn, for placing on pages)")
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

    // MARK: Save a Copy

    /// The More menu's item that saves a copy of the document where the reader chooses.
    static var saveCopy: String {
        String(localized: "Save a Copy…", comment: "More menu item: saves a copy of the document, with its changes, in a folder and under a name the reader chooses")
    }

    /// The name the copy is offered under, without its extension: the document's name and " copy".
    static func copyName(of name: String) -> String {
        String(localized: "\(name) copy", comment: "File name, without extension, offered for a copy of a document: the document's name, then the word for a copy")
    }

    /// The title of the alert when a copy could not be made or written.
    static var copyFailedTitle: String {
        String(localized: "The copy could not be saved.", comment: "Title of the alert shown when Save a Copy made no copy")
    }

    /// Why a copy of a signed, damaged document with changes is refused.
    static var copySignedMessage: String {
        String(localized: "This signed document is damaged. Saving its changes, even in a copy, would break its signatures.", comment: "Message of the alert when Save a Copy is refused for a digitally signed PDF whose file is damaged: writing its changes would break the signatures")
    }

    /// Why no copy was made when something waiting to be added (strokes, typed text) was refused.
    static var copyWaitingNotAddedMessage: String {
        String(localized: "Some of your latest changes could not be added, so no copy was made. Check the page, then try again.", comment: "Message of the alert when Save a Copy made no copy because strokes or typed text waiting to be added to the document were refused")
    }

    /// What the alert says when a copy could not be made or written for any other reason.
    static var copyFailedMessage: String {
        String(localized: "Try again, or choose another place to save it.", comment: "Message of the alert when Save a Copy could not make or write the copy")
    }

    // MARK: Send Feedback

    /// The More menu's item that writes an email to the app's makers.
    static var sendFeedback: String {
        String(localized: "Send Feedback", comment: "More menu item: writes an email with feedback about the app to its makers")
    }

    /// The subject of the feedback email: the app's version and build.
    static func feedbackSubject(version: String, build: String) -> String {
        String(localized: "EditinPDF feedback (\(version), build \(build))", comment: "Subject of the feedback email: the app's version, then its build number")
    }

    /// The heading of the block about the device at the end of the feedback email.
    static var feedbackAboutThisDevice: String {
        String(localized: "About this device", comment: "Heading of the block at the end of the feedback email that says which app version, system and device it was sent from")
    }

    /// The feedback email's line naming the app's version and build.
    static func feedbackAppLine(version: String, build: String) -> String {
        String(localized: "App: EditinPDF \(version) (\(build))", comment: "Line of the feedback email: the app's version, then its build number in parentheses")
    }

    /// The feedback email's line naming the system and its version ("iOS 27.0").
    static func feedbackSystemLine(_ system: String) -> String {
        String(localized: "System: \(system)", comment: "Line of the feedback email: the operating system and its version, e.g. iOS 27.0")
    }

    /// The feedback email's line naming the device model ("iPhone17,1").
    static func feedbackDeviceLine(_ model: String) -> String {
        String(localized: "Device: \(model)", comment: "Line of the feedback email: the device's model identifier, e.g. iPhone17,1")
    }

    /// The title of the alert shown when no mail app could write the feedback email.
    static var feedbackNoMailTitle: String {
        String(localized: "Email Your Feedback", comment: "Title of the alert shown when the device has no mail app set up to write the feedback email")
    }

    /// What that alert says: where to write.
    static func feedbackNoMailMessage(address: String) -> String {
        String(localized: "No mail app is set up here. Send your feedback to \(address) from any email app.", comment: "Message of the alert shown when no mail app could write the feedback email: the address to write to")
    }

    /// The alert's button that copies the feedback address.
    static var copyAddress: String {
        String(localized: "Copy Address", comment: "Button that copies the feedback email address")
    }

    /// The button that puts an alert away.
    static var ok: String {
        String(localized: "OK", comment: "Button that puts an alert away")
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

    /// The Edit menu's Undo (the iPad's menu bar, ⌘Z), naming the change it takes back: `name` is one of
    /// the names below (`actionRotate`, `actionAddAnnotation`, ...), as the system's menu shows them.
    static func undoAction(_ name: String) -> String {
        String(localized: "Undo \(name)", comment: "Edit menu item that takes back the last change to the PDF; the name of the change follows, such as Add Markup")
    }

    /// The Edit menu's Redo (⇧⌘Z), naming the change it makes again, as `undoAction`.
    static func redoAction(_ name: String) -> String {
        String(localized: "Redo \(name)", comment: "Edit menu item that makes again the change last taken back; the name of the change follows, such as Add Markup")
    }

    /// The title of the alert about a change that was not made.
    static var editFailed: String {
        String(localized: "That change could not be made.", comment: "Title of the alert shown when a change to the PDF was refused or failed")
    }

    /// Why a change was not made: the document's settings do not allow it.
    static var editNotAllowed: String {
        String(localized: "This document doesn't allow that change.", comment: "Shown when the PDF's security settings or format do not allow the change")
    }

    /// Why nothing in a signed document may be changed: its file is damaged, so saving any change would
    /// rewrite the whole file and break its signatures. Said in place of each tool's own refusal.
    static var signedDocumentDamaged: String {
        String(localized: "This signed document is damaged. Changing it would break its signatures.", comment: "Shown in place of the markup, organize and form refusals for a digitally signed PDF whose file is damaged: saving any change would rewrite the file and break its signatures")
    }

    /// Why a delete was not made: it would have removed every page.
    static var cannotDeleteAllPages: String {
        String(localized: "A document needs at least one page.", comment: "Shown when deleting the chosen pages would leave the PDF without a page")
    }

    /// Why a change was not made: it was meant for the document as it was before another change.
    static var documentChangedTryAgain: String {
        String(localized: "The document changed. Try again.", comment: "Shown when a change was made for an older state of the PDF and was refused")
    }

    /// Why strokes drawn with Draw were not added: their page was moved, or turned, while they were on
    /// their way, so where they were drawn is not known on it any more.
    static var drawingNotAdded: String {
        String(localized: "Your drawing wasn't added because its page was moved or turned meanwhile. Draw it again.", comment: "Shown when strokes drawn on a page could not be added because the page was moved, deleted or rotated while they were being added")
    }

    /// Why text typed in a text box was not added, and where it is: its page (or the text box it was
    /// for) changed while it was on its way, and the text is on the pasteboard, on this device only
    /// (`DocumentModel.keepLocally`), where "copied, ready to paste" holds.
    static var typedTextCopied: String {
        String(localized: "Your text wasn't added because the page changed meanwhile. It's copied, ready to paste.", comment: "Shown when text typed in a text box could not be added because its page changed; the text was put on the pasteboard")
    }

    /// Why a highlight, underline or strikethrough was not made: the selection has more lines than one
    /// mark takes.
    static var selectLessText: String {
        String(localized: "Select less text to mark at once.", comment: "Shown when the selected text has too many lines for one highlight, underline or strikethrough")
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

    /// The name Undo and Redo give a signature placed on a page.
    static var actionSign: String {
        String(localized: "Add Signature", comment: "Name of the change in Undo and Redo: the saved signature was placed on a page")
    }

    // MARK: Forms

    /// The hint shown once over a document with a form, in reading mode.
    static var formHint: String {
        String(localized: "Tap a field to fill it in.", comment: "Hint shown once when a PDF with a form opens")
    }

    /// Why a field was not filled in: the document's security settings or format forbid filling its form.
    static var formNotAllowed: String {
        String(localized: "This document doesn't allow filling in its form.", comment: "Shown when a form field is tapped in a PDF whose security settings or format forbid filling in its form")
    }

    /// The note shown once with the form's hint when the form has more than the app lists: more fields,
    /// more options in a list, or more places a field is shown.
    static var formTruncated: String {
        String(localized: "This form is too large to show in full. Some fields or choices may be missing.", comment: "Shown once when a PDF's form has more fields, more options in a list, or more places a field is shown, than the app can show")
    }

    /// The title of the menu of a drop-down list's options, and of the sheet where several of a list's
    /// options are checked.
    static var chooseOption: String {
        String(localized: "Choose", comment: "Title of the menu or sheet where a form field's options are chosen")
    }

    /// The item of a drop-down list's menu that lets the reader type a value of their own.
    static var otherChoice: String {
        String(localized: "Other…", comment: "Menu item of a form's drop-down list that lets the reader type a value of their own")
    }

    /// What VoiceOver says of a check box or radio button that is on.
    static var fieldChecked: String {
        String(localized: "checked", comment: "Accessibility value of a form's check box or radio button that is on")
    }

    /// What VoiceOver says of a check box or radio button that is off.
    static var fieldUnchecked: String {
        String(localized: "unchecked", comment: "Accessibility value of a form's check box or radio button that is off")
    }

    /// What VoiceOver calls one radio button of a group: the group's name, then what the button stands
    /// for. Its own key: a bare "%@, %@" would be shared with any other pair.
    static func radioButtonLabel(field: String, option: String) -> String {
        String(localized: "radioButtonLabel", defaultValue: "\(field), \(option)", comment: "Accessibility label of one radio button of a form: the field's name, then the option the button stands for")
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

    /// The button that removes something: the selected pages in Organize (and the confirmation's
    /// button), the selected markup (its menu), a comment in the Comments list (its swipe).
    static var delete: String {
        String(localized: "Delete", comment: "Button that removes something: the selected pages in Organize (also the button that confirms it), the selected markup on a page, a comment in the list of comments")
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

    /// The palette button, there while strokes drawn with Draw or text typed in a text box are waiting,
    /// that adds them to the page. Its own key: the "Done" that closes a sheet may be translated otherwise.
    static var doneDrawing: String {
        String(localized: "doneDrawing", defaultValue: "Done", comment: "Markup palette button that adds the strokes just drawn, or the text just typed in a text box, to the page")
    }

    /// The tool that types text onto the page.
    static var toolTextBox: String {
        String(localized: "Text Box", comment: "Markup tool that adds a box of typed text")
    }

    /// The sticky-note tool.
    static var toolNote: String {
        String(localized: "Note", comment: "Markup tool that adds a sticky note")
    }

    /// The title of the sheet a note is written and read in. Its own key: the tool's "Note" may be
    /// translated otherwise.
    static var noteTitle: String {
        String(localized: "noteTitle", defaultValue: "Note", comment: "Title of the sheet where a sticky note's text is written or read")
    }

    /// What the note sheet's empty text says.
    static var notePlaceholder: String {
        String(localized: "Add a note", comment: "Placeholder in the empty text of a sticky note being written")
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

    // MARK: Text box format

    /// The bar over the keyboard while a text box is typed in, and the sheet Select's Format opens:
    /// their name, for VoiceOver, and the sheet's title. Also the name of the change it makes, in Undo
    /// and Redo.
    static var formatTextBox: String {
        String(localized: "Format Text Box", comment: "Title of the controls that change a text box's size, colours and border; also the name of that change in Undo and Redo")
    }

    /// The menu item over a selected text box that opens its format.
    static var format: String {
        String(localized: "Format", comment: "Menu item over the selected text box that changes its text size, colours and border")
    }

    /// The format's button that makes the text smaller.
    static var smallerText: String {
        String(localized: "Smaller Text", comment: "Button in the text box format bar that makes the text smaller")
    }

    /// The format's button that makes the text larger.
    static var largerText: String {
        String(localized: "Larger Text", comment: "Button in the text box format bar that makes the text larger")
    }

    /// The text's size in the format, in points (for the bar, and for VoiceOver).
    static func textSizeValue(_ size: Double) -> String {
        String(localized: "textSizeValue", defaultValue: "\(size.formatted(.number.precision(.fractionLength(0...1)))) pt", comment: "A text box's text size in points, between the Smaller and Larger buttons of the format bar")
    }

    /// The name of the text's size, for VoiceOver.
    static var textSize: String {
        String(localized: "Text Size", comment: "Name of a text box's text size in the format bar, for VoiceOver")
    }

    /// The format's text colour menu and picker.
    static var textColor: String {
        String(localized: "Text Color", comment: "Menu in the text box format bar that picks the colour of the text")
    }

    /// The format's item that opens the system's colour picker for the text.
    static var moreColors: String {
        String(localized: "More Colors…", comment: "Item of the text colour menu that opens a colour picker with every colour")
    }

    /// The format's background menu.
    static var background: String {
        String(localized: "Background", comment: "Menu in the text box format bar that picks the box's background colour")
    }

    /// The format's choice of no background.
    static var noBackground: String {
        String(localized: "No Background", comment: "Item of the text box background menu: the box has no background")
    }

    /// The names of the format's background colours, in their order (`TextBoxFormat.backgrounds`).
    static var backgroundNames: [String] {
        [String(localized: "background.yellow", defaultValue: "Light Yellow", comment: "A text box background colour"),
         String(localized: "background.blue", defaultValue: "Light Blue", comment: "A text box background colour"),
         String(localized: "background.green", defaultValue: "Light Green", comment: "A text box background colour"),
         String(localized: "background.pink", defaultValue: "Light Pink", comment: "A text box background colour"),
         String(localized: "background.white", defaultValue: "White", comment: "A text box background colour")]
    }

    /// The format's switch that draws a border round the box.
    static var border: String {
        String(localized: "Border", comment: "Switch in the text box format bar that draws a border round the box")
    }

    /// The format sheet's button that makes the change.
    static var apply: String {
        String(localized: "Apply", comment: "Button of the text box format sheet that changes the text box")
    }

    // MARK: Signing

    /// The markup tool that places the reader's saved signature.
    static var sign: String {
        String(localized: "Sign", comment: "Markup tool that places the reader's saved signature on the page")
    }

    /// The title of the pad the signature is drawn in.
    static var signatureTitle: String {
        String(localized: "Your Signature", comment: "Title of the sheet where the reader draws the signature that the Sign tool places")
    }

    /// The signature pad's button that wipes what was drawn, to start again.
    static var clear: String {
        String(localized: "Clear", comment: "Button of the signature pad that wipes what was drawn, to start again")
    }

    /// What the signature pad says under the line the signature is drawn on.
    static var signHere: String {
        String(localized: "Sign here", comment: "Hint under the line the signature is drawn on, in the signature pad")
    }

    /// What VoiceOver calls the signature pad's drawing area.
    static var signatureCanvas: String {
        String(localized: "Drawing area for your signature", comment: "Accessibility label of the area of the signature pad that is drawn on")
    }

    /// The button beside the Sign tool that opens its menu (Change Signature, Delete Signature).
    static var signatureOptions: String {
        String(localized: "Signature Options", comment: "Markup palette button, while Sign is picked, that opens the menu to change or delete the saved signature")
    }

    /// The menu item that opens the pad to draw the signature again.
    static var changeSignature: String {
        String(localized: "Change Signature", comment: "Menu item of the Sign tool that opens the pad to draw the saved signature again")
    }

    /// The menu item, and the confirmation's button, that forgets the saved signature.
    static var deleteSignature: String {
        String(localized: "Delete Signature", comment: "Menu item of the Sign tool, and the button that confirms it, that forgets the saved signature")
    }

    /// The question asked before the saved signature is forgotten.
    static var deleteSignatureConfirm: String {
        String(localized: "Delete your saved signature?", comment: "Title of the confirmation before the saved signature is forgotten")
    }

    /// Under that question.
    static var deleteSignatureConfirmMessage: String {
        String(localized: "Signatures already placed stay on their pages.", comment: "Message of the confirmation before the saved signature is forgotten: the ones placed on pages are not removed")
    }

    /// Why the signature drawn was not kept: its file could not be written.
    static var signatureNotSaved: String {
        String(localized: "Your signature could not be saved.", comment: "Shown when the signature drawn in the pad could not be written to the device")
    }

    /// Why the saved signature is still there: its file could not be removed.
    static var signatureNotDeleted: String {
        String(localized: "Your signature could not be deleted.", comment: "Shown when the saved signature could not be removed from the device")
    }

    // MARK: Comments

    /// The name of the list of the document's comments: the toolbar button that opens it, and its title.
    static var comments: String {
        String(localized: "Comments", comment: "Toolbar button and sheet title for the list of the document's comments and markup")
    }

    /// What the list of comments says when the document has none.
    static var noComments: String {
        String(localized: "No comments yet", comment: "Shown in the list of comments when the document has no comments or markup")
    }

    /// The menu item over the selected markup that changes its text (a note's, a text box's).
    static var edit: String {
        String(localized: "Edit", comment: "Menu item over the selected note or text box that changes its text")
    }

    /// The heading over the comments of one page in the list of comments; `page` counts from 1. Its
    /// own key: the thumbnails' "Page n" may be translated otherwise.
    static func commentsPage(_ page: Int) -> String {
        String(localized: "commentsPage", defaultValue: "Page \(page)", comment: "Heading over the comments of one page in the list of comments: the page number")
    }

    /// What a kind of annotation is called in the list of comments. Each its own key: a tool may be
    /// named alike and translated otherwise.
    static func annotationKindName(_ kind: AnnotationKind) -> String {
        switch kind {
        case .note: String(localized: "annotationKind.note", defaultValue: "Note", comment: "A sticky note, as named in the list of comments")
        case .highlight: String(localized: "annotationKind.highlight", defaultValue: "Highlight", comment: "Highlighted text, as named in the list of comments")
        case .underline: String(localized: "annotationKind.underline", defaultValue: "Underline", comment: "Underlined text, as named in the list of comments")
        case .strikeOut: String(localized: "annotationKind.strikeOut", defaultValue: "Strikethrough", comment: "Struck-through text, as named in the list of comments")
        case .squiggly: String(localized: "annotationKind.squiggly", defaultValue: "Squiggly", comment: "Text with a squiggly underline, as named in the list of comments")
        case .ink: String(localized: "annotationKind.ink", defaultValue: "Drawing", comment: "A freehand drawing, as named in the list of comments")
        case .textBox: String(localized: "annotationKind.textBox", defaultValue: "Text", comment: "A box of typed text on the page, as named in the list of comments")
        case .rectangle: String(localized: "annotationKind.rectangle", defaultValue: "Rectangle", comment: "A rectangle drawn on the page, as named in the list of comments")
        case .oval: String(localized: "annotationKind.oval", defaultValue: "Oval", comment: "An oval drawn on the page, as named in the list of comments")
        case .line: String(localized: "annotationKind.line", defaultValue: "Line", comment: "A line or an arrow drawn on the page, as named in the list of comments")
        case .stamp: String(localized: "annotationKind.stamp", defaultValue: "Stamp", comment: "A stamp on the page, as named in the list of comments")
        case .other: String(localized: "annotationKind.other", defaultValue: "Comment", comment: "Any other kind of annotation, as named in the list of comments")
        }
    }
}
