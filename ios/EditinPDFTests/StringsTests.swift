import XCTest
@testable import EditinPDF

final class StringsTests: XCTestCase {
    func testTheTitleOfTheFailureIsOurSentence() {
        XCTAssertEqual(Strings.fileCouldNotBeOpened, "This file could not be opened.")
        XCTAssertFalse(Strings.fileCouldNotBeOpened.localizedCaseInsensitiveContains("damaged"))
    }

    func testEngineWordingIsKeptAsTheDetailUnderOurTitle() {
        XCTAssertEqual(Strings.fileCouldNotBeOpenedDetail("Cross-reference table not found."), "Cross-reference table not found.")
    }

    func testEngineWordingBecomesASentence() {
        // The engine words its errors as fragments: lower case, no full stop.
        XCTAssertEqual(Strings.fileCouldNotBeOpenedDetail("the file is not a readable PDF: no page tree was found"),
                       "The file is not a readable PDF: no page tree was found.")
    }

    func testEngineWordingKeepsItsOwnPunctuation() {
        XCTAssertEqual(Strings.fileCouldNotBeOpenedDetail("Unsupported feature?"), "Unsupported feature?")
        XCTAssertEqual(Strings.fileCouldNotBeOpenedDetail("Stop!"), "Stop!")
    }

    func testNoEngineWordingLeavesNoDetail() {
        XCTAssertNil(Strings.fileCouldNotBeOpenedDetail(""))
        XCTAssertNil(Strings.fileCouldNotBeOpenedDetail(" \n"))
    }

    func testEngineWordingIsTrimmed() {
        XCTAssertEqual(Strings.fileCouldNotBeOpenedDetail("  bad header.\n"), "Bad header.")
    }

    func testPasswordWording() {
        XCTAssertEqual(Strings.passwordTitle, "Password Required")
        XCTAssertEqual(Strings.passwordExplanation, "This document is protected. Enter the password to open it.")
        XCTAssertEqual(Strings.passwordPlaceholder, "Password")
        XCTAssertEqual(Strings.wrongPassword, "Wrong password")
        XCTAssertEqual(Strings.unlock, "Unlock")
        XCTAssertEqual(Strings.cancel, "Cancel")
        XCTAssertEqual(Strings.enterPassword, "Enter Password")
        XCTAssertEqual(Strings.close, "Close")
    }

    func testPageIndicatorIsThePageOverTheCount() {
        XCTAssertEqual(Strings.pageIndicator(current: 3, count: 12), "3 / 12")
        XCTAssertEqual(Strings.pageIndicator(current: 1, count: 1), "1 / 1")
        // Below a thousand, so the region's digit grouping does not come into it.
        XCTAssertEqual(Strings.pageIndicator(current: 120, count: 999), "120 / 999")
    }

    func testThumbnailWording() {
        XCTAssertEqual(Strings.thumbnails, "Thumbnails")
        XCTAssertEqual(Strings.thumbnailLabel(page: 3), "Page 3")
        XCTAssertEqual(Strings.pageNumber(3), "3")
        XCTAssertEqual(Strings.pageNumber(120), "120")
        XCTAssertEqual(Strings.done, "Done")
    }

    func testSearchWording() {
        XCTAssertEqual(Strings.search, "Search")
        XCTAssertEqual(Strings.searchPlaceholder, "Search")
        XCTAssertEqual(Strings.searchHitPage(3), "Page 3")
        XCTAssertEqual(Strings.searchHitLabel(page: 3, snippet: "Page three is here"), "Page 3: Page three is here")
        XCTAssertEqual(Strings.searchNoMatches, "No matches found")
        XCTAssertEqual(Strings.searchPrevious, "Previous match")
        XCTAssertEqual(Strings.searchNext, "Next match")
        XCTAssertEqual(Strings.searchEnd, "End search")
    }

    func testSearchPositionIsTheHitOverTheCount() {
        XCTAssertEqual(Strings.searchPosition(current: 3, count: 12), "3 of 12")
        XCTAssertEqual(Strings.searchPosition(current: 1, count: 1), "1 of 1")
    }

    /// When a search stopped at its limit, the count is a floor: "1 of 1,000+", the numbers written the
    /// way the reader's region writes them (as this test writes them, so it holds in any region).
    func testATruncatedSearchPositionSaysThereMayBeMore() {
        XCTAssertEqual(Strings.searchPositionTruncated(current: 1, count: 1_000), "1 of \(1_000.formatted())+")
        XCTAssertEqual(Strings.searchPositionTruncated(current: 1_000, count: 1_000), "\(1_000.formatted()) of \(1_000.formatted())+")
        XCTAssertEqual(Strings.searchPositionTruncated(current: 7, count: 50), "7 of 50+")
    }

    func testSelectionWording() {
        XCTAssertEqual(Strings.copy, "Copy")
        XCTAssertEqual(Strings.selectionStart, "Start of selection")
        XCTAssertEqual(Strings.selectionEnd, "End of selection")
    }

    /// The limit is the engine's, so the note says whatever number it is given, written the way the
    /// reader's region writes it (this test writes it the same way, so it holds in any region).
    func testTheTruncationNoteNamesTheLimit() {
        XCTAssertEqual(Strings.searchTruncated(limit: 1_000), "Showing the first \(1_000.formatted()) matches")
        XCTAssertEqual(Strings.searchTruncated(limit: 50), "Showing the first 50 matches")
    }

    func testTheSaveFailureIsOurSentence() {
        XCTAssertEqual(Strings.saveFailed, "The changes could not be saved.")
    }

    func testTheEditingSentencesAndActionNames() {
        XCTAssertEqual(Strings.undo, "Undo")
        XCTAssertEqual(Strings.redo, "Redo")
        XCTAssertEqual(Strings.undoAction(Strings.actionAddAnnotation), "Undo Add Markup")
        XCTAssertEqual(Strings.redoAction(Strings.actionRotate), "Redo Rotate Pages")
        XCTAssertEqual(Strings.editFailed, "That change could not be made.")
        XCTAssertEqual(Strings.editNotAllowed, "This document doesn't allow that change.")
        XCTAssertEqual(Strings.signedDocumentDamaged, "This signed document is damaged. Changing it would break its signatures.")
        XCTAssertEqual(Strings.cannotDeleteAllPages, "A document needs at least one page.")
        XCTAssertEqual(Strings.documentChangedTryAgain, "The document changed. Try again.")
        XCTAssertEqual(Strings.drawingNotAdded, "Your drawing wasn't added because its page was moved or turned meanwhile. Draw it again.")
        XCTAssertEqual(Strings.typedTextCopied, "Your text wasn't added because the page changed meanwhile. It's copied, ready to paste.")
        XCTAssertEqual(Strings.selectLessText, "Select less text to mark at once.")
        XCTAssertEqual(Strings.insertSourceLocked, "That PDF is password-protected. Remove its password and try again.")
        XCTAssertEqual(Strings.insertSourceUnreadable, "That file could not be read as a PDF.")
        XCTAssertEqual(Strings.insertSourceNotPermitted, "That PDF doesn't allow its pages to be copied.")
        XCTAssertEqual(Strings.actionRotate, "Rotate Pages")
        XCTAssertEqual(Strings.actionDelete, "Delete Pages")
        XCTAssertEqual(Strings.actionMove, "Move Pages")
        XCTAssertEqual(Strings.actionInsertBlank, "Insert Blank Page")
        XCTAssertEqual(Strings.actionInsertFile, "Insert Pages")
        XCTAssertEqual(Strings.actionAddAnnotation, "Add Markup")
        XCTAssertEqual(Strings.actionDeleteAnnotation, "Delete Markup")
        XCTAssertEqual(Strings.actionMoveAnnotation, "Move Markup")
        XCTAssertEqual(Strings.actionEditAnnotation, "Edit Markup")
        XCTAssertEqual(Strings.actionFillField, "Fill Form")
        XCTAssertEqual(Strings.actionSign, "Add Signature")
    }

    func testOrganizeStrings() {
        XCTAssertEqual(Strings.organize, "Organize Pages")
        XCTAssertEqual(Strings.selectAll, "Select All")
        XCTAssertEqual(Strings.deselectAll, "Deselect All")
        XCTAssertEqual(Strings.rotateLeft, "Rotate Left")
        XCTAssertEqual(Strings.rotateRight, "Rotate Right")
        XCTAssertEqual(Strings.delete, "Delete")
        XCTAssertEqual(Strings.insertBlank, "Insert Blank Page")
        XCTAssertEqual(Strings.deletePagesConfirm(count: 3), "Delete 3 pages?")
        XCTAssertEqual(Strings.deletePagesConfirmMessage, "You can undo this.")
        XCTAssertEqual(Strings.organizeNotAllowed, "This document doesn't allow changing its pages.")
        XCTAssertEqual(Strings.pagesSelected(count: 2), "2 selected")
    }

    func testMarkupWording() {
        XCTAssertEqual(Strings.markup, "Markup")
        XCTAssertEqual(Strings.markupNotAllowed, "This document doesn't allow markup.")
        XCTAssertEqual(Strings.textBoxNeedsUprightPage, "Text boxes can't be added to turned pages yet.")
        XCTAssertEqual(Strings.toolSelect, "Select")
        XCTAssertEqual(Strings.highlight, "Highlight")
        XCTAssertEqual(Strings.underline, "Underline")
        XCTAssertEqual(Strings.strikeout, "Strikethrough")
        XCTAssertEqual(Strings.toolInk, "Draw")
        XCTAssertEqual(Strings.doneDrawing, "Done")
        XCTAssertEqual(Strings.toolTextBox, "Text Box")
        XCTAssertEqual(Strings.toolNote, "Note")
        XCTAssertEqual(Strings.toolRectangle, "Rectangle")
        XCTAssertEqual(Strings.toolOval, "Oval")
        XCTAssertEqual(Strings.toolLine, "Line")
        XCTAssertEqual(Strings.toolArrow, "Arrow")
        XCTAssertEqual(Strings.toolEraser, "Eraser")
        XCTAssertEqual(Strings.toolStyle, "Style")
        XCTAssertEqual(Strings.styleColor, "Color")
        XCTAssertEqual(Strings.styleWidth, "Line Width")
        XCTAssertEqual(Strings.styleWidthValue(2.5), "2.5 pt")
        XCTAssertEqual(Strings.styleFontSize(14), "Font Size: 14 pt")
        XCTAssertEqual(Strings.styleFill, "Fill")
        XCTAssertEqual(Strings.styleSwatchNames, ["Black", "Gray", "Red", "Orange", "Yellow", "Green", "Blue", "Purple"])
        XCTAssertEqual(Strings.noteTitle, "Note")
        XCTAssertEqual(Strings.notePlaceholder, "Add a note")
        XCTAssertEqual(Strings.save, "Save")
        XCTAssertEqual(Strings.cancel, "Cancel")
    }

    func testCommentsWording() {
        XCTAssertEqual(Strings.comments, "Comments")
        XCTAssertEqual(Strings.noComments, "No comments yet")
        XCTAssertEqual(Strings.edit, "Edit")
        XCTAssertEqual(Strings.commentsPage(3), "Page 3")
        XCTAssertEqual(Strings.annotationKindName(.note), "Note")
        XCTAssertEqual(Strings.annotationKindName(.textBox), "Text")
        XCTAssertEqual(Strings.annotationKindName(.ink), "Drawing")
        XCTAssertEqual(Strings.annotationKindName(.other(subtype: "Polygon")), "Comment")
    }

    func testFormWording() {
        XCTAssertEqual(Strings.formHint, "Tap a field to fill it in.")
        XCTAssertEqual(Strings.formNotAllowed, "This document doesn't allow filling in its form.")
        XCTAssertEqual(Strings.formTruncated, "This form is too large to show in full. Some fields or choices may be missing.")
        XCTAssertEqual(Strings.chooseOption, "Choose")
        XCTAssertEqual(Strings.otherChoice, "Other…")
        XCTAssertEqual(Strings.fieldChecked, "checked")
        XCTAssertEqual(Strings.fieldUnchecked, "unchecked")
        XCTAssertEqual(Strings.radioButtonLabel(field: "size", option: "L"), "size, L")
        XCTAssertEqual(Strings.actionFillField, "Fill Form")
    }

    func testSignWording() {
        XCTAssertEqual(Strings.sign, "Sign")
        XCTAssertEqual(Strings.signatureTitle, "Your Signature")
        XCTAssertEqual(Strings.clear, "Clear")
        XCTAssertEqual(Strings.changeSignature, "Change Signature")
        XCTAssertEqual(Strings.deleteSignature, "Delete Signature")
        XCTAssertEqual(Strings.signatureOptions, "Signature Options")
        XCTAssertEqual(Strings.signHere, "Sign here")
        XCTAssertEqual(Strings.signatureCanvas, "Drawing area for your signature")
        XCTAssertEqual(Strings.deleteSignatureConfirm, "Delete your saved signature?")
        XCTAssertEqual(Strings.deleteSignatureConfirmMessage, "Signatures already placed stay on their pages.")
        XCTAssertEqual(Strings.signatureNotSaved, "Your signature could not be saved.")
        XCTAssertEqual(Strings.signatureNotDeleted, "Your signature could not be deleted.")
        XCTAssertEqual(Strings.actionSign, "Add Signature")
        XCTAssertEqual(Strings.save, "Save")
        XCTAssertEqual(Strings.cancel, "Cancel")
    }

    func testExtractAndInsertWording() {
        XCTAssertEqual(Strings.insertFromFile, "Insert from File…")
        XCTAssertEqual(Strings.extract, "Extract Pages")
        XCTAssertEqual(Strings.extractedFileName(base: "a", first: 2, last: 3), "a (pages 2–3)")
        XCTAssertEqual(Strings.extractedFileName(base: "a", first: 2, last: 2), "a (page 2)")
        XCTAssertEqual(Strings.extractUnprotectedNote, "The extracted pages are not password-protected.")
        XCTAssertEqual(Strings.untitledDocument, "Document")
        XCTAssertEqual(Strings.pickedFileTooLarge, "That file is too large to insert (over 500 MB).")
        XCTAssertEqual(Strings.pickedFileUnreadable, "That file could not be opened.")
    }

    func testSaveACopyWording() {
        XCTAssertEqual(Strings.saveCopy, "Save a Copy…")
        XCTAssertEqual(Strings.copyName(of: "Report"), "Report copy")
        XCTAssertEqual(Strings.copyFailedTitle, "The copy could not be saved.")
        XCTAssertEqual(Strings.copySignedMessage, "This signed document is damaged. Saving its changes, even in a copy, would break its signatures.")
        XCTAssertEqual(Strings.copyFailedMessage, "Try again, or choose another place to save it.")
        XCTAssertEqual(Strings.copyWaitingNotAddedMessage, "Some of your latest changes could not be added, so no copy was made. Check the page, then try again.")
    }

    func testSendFeedbackWording() {
        XCTAssertEqual(Strings.sendFeedback, "Send Feedback")
        XCTAssertEqual(Strings.feedbackSubject(version: "1.2", build: "3"), "EditinPDF feedback (1.2, build 3)")
        XCTAssertEqual(Strings.feedbackAboutThisDevice, "About this device")
        XCTAssertEqual(Strings.feedbackAppLine(version: "1.2", build: "3"), "App: EditinPDF 1.2 (3)")
        XCTAssertEqual(Strings.feedbackSystemLine("iOS 27.0"), "System: iOS 27.0")
        XCTAssertEqual(Strings.feedbackDeviceLine("iPhone17,1"), "Device: iPhone17,1")
        XCTAssertEqual(Strings.feedbackNoMailTitle, "Email Your Feedback")
        XCTAssertEqual(Strings.feedbackNoMailMessage(address: "a@b.c"), "No mail app is set up here. Send your feedback to a@b.c from any email app.")
        XCTAssertEqual(Strings.copyAddress, "Copy Address")
        XCTAssertEqual(Strings.ok, "OK")
    }

    func testTextBoxFormatWording() {
        XCTAssertEqual(Strings.formatTextBox, "Format Text Box")
        XCTAssertEqual(Strings.format, "Format")
        XCTAssertEqual(Strings.smallerText, "Smaller Text")
        XCTAssertEqual(Strings.largerText, "Larger Text")
        XCTAssertEqual(Strings.textSize, "Text Size")
        XCTAssertEqual(Strings.textSizeValue(14), "14 pt")
        XCTAssertEqual(Strings.textSizeValue(9.5), "9.5 pt")
        XCTAssertEqual(Strings.textColor, "Text Color")
        XCTAssertEqual(Strings.moreColors, "More Colors…")
        XCTAssertEqual(Strings.background, "Background")
        XCTAssertEqual(Strings.noBackground, "No Background")
        XCTAssertEqual(Strings.backgroundNames, ["Light Yellow", "Light Blue", "Light Green", "Light Pink", "White"])
        XCTAssertEqual(Strings.backgroundNames.count, TextBoxFormat.backgrounds.count)
        XCTAssertEqual(Strings.border, "Border")
        XCTAssertEqual(Strings.apply, "Apply")
    }

    func testCommentingOnMarksWording() {
        XCTAssertEqual(Strings.comments, "Comments", "the toolbar button's title")
        XCTAssertEqual(Strings.comment, "Comment")
        XCTAssertEqual(Strings.addACommentPlaceholder, "Add a comment")
        XCTAssertEqual(Strings.actionEditComment, "Edit Comment")
        XCTAssertEqual(Strings.addComment, "Add Comment")
        XCTAssertEqual(Strings.addCommentHint, "Tap where the comment goes")
        XCTAssertEqual(Strings.markOnPage("Highlight", page: 3), "Highlight on page 3")
        XCTAssertEqual(Strings.allMarks, "All Marks")
        XCTAssertEqual(Strings.withComments, "With Comments")
        XCTAssertEqual(Strings.commentsFilter, "Show")
        XCTAssertEqual(Strings.showOnPage, "Show on Page")
    }
}
