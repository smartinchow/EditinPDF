import XCTest

/// The viewer end to end, on the simulator: the app is launched with one of its sample documents
/// staged in its Documents folder (`-openFixture`, Debug builds only), and each test opens it from
/// the document browser as a person would, then reads it, scrolls it, searches it, unlocks it or
/// watches it fail.
///
/// Elements are found by their accessibility identifiers, not by their wording; the one thing read
/// by its text is the page indicator's "page / pages".
///
/// Only one of them depends on the app closing a document scene itself, which iOS versions are reported
/// to do differently: `testAFileThatIsNotAPDFSaysSoAndCloses`, which expects the alert's Close button to
/// take the reader back to the document browser. Where it does not, the screen left behind says why,
/// and the system's own way back is there.
@MainActor
final class ViewerSmokeTests: XCTestCase {
    // MARK: Reading, scrolling and searching

    /// `sample.pdf`: three pages, "Page one", "Page two" and "Page three".
    func testOpensScrollsAndSearches() {
        let app = launchAndOpen("sample.pdf")
        let indicator = app.staticTexts["pageIndicator"]
        expect(indicator, toRead: "1 / 3", within: 10)

        // As many swipes as the pages take: two on a phone, more where the pages are taller than the
        // screen is (an iPad, its pages fitted to its width).
        swipe(app, up: true, until: indicator, reads: "3 / 3")
        // Back to the top, so that a search result has somewhere to take the reader.
        swipe(app, up: false, until: indicator, reads: "1 / 3")

        // Zoomed in and out again, the indicator still names a page of the three.
        let pages = app.scrollViews["pageScrollView"]
        XCTAssertTrue(pages.exists, "no page scroll view")
        pages.pinch(withScale: 2, velocity: 1)
        expect(indicator, toReadAPageOf: 3, within: 5)
        pages.pinch(withScale: 0.5, velocity: -1)
        expect(indicator, toReadAPageOf: 3, within: 5)
        // Back to the top, where the search below starts from.
        app.swipeDown()
        expect(indicator, toRead: "1 / 3", within: 5)

        // With Markup in the bar, a phone has Search in the More menu.
        XCTAssertTrue(tapToolbarButton("searchButton", titled: "Search", in: app), "no Search")
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the search sheet did not come up")
        dismissKeyboardIntroduction(in: app)
        type("three", into: field)
        let hit = app.buttons["searchHit-0"]
        XCTAssertTrue(hit.waitForExistence(timeout: 5), "no result for \"three\"")
        hit.tap()
        expect(indicator, toRead: "3 / 3", within: 5)
    }

    // MARK: Selecting and copying

    /// A long press on "Page" at the top of the first page selects the word and brings up its handles;
    /// Copy puts it on the pasteboard, which is read by pasting into the search field (the test runner
    /// cannot read the pasteboard itself on the iOS 26.5 simulator: it never returns).
    func testASelectedWordIsCopiedAndPastesIntoTheSearchField() {
        let app = launchAndOpen("sample.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)

        // The first page is a 612 pt wide Letter page, fitted to the width the bars leave: the window's
        // on most phones, less on one whose bar stands at the side (the iPhone Duo on iOS 27.1). Its frame
        // on screen is read from the page itself. In its own points "Page" runs from 72 to 97.7 across
        // and 74.2 to 85.2 down, so (85, 79.7) is the middle of the word.
        let page = app.otherElements["page-0"].frame
        let scale = page.width / 612
        let word = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: page.minX + 85 * scale, dy: page.minY + 79.7 * scale))
        word.press(forDuration: 0.8)
        XCTAssertTrue(app.otherElements["selectionHandleStart"].waitForExistence(timeout: 5), "no selection after a long press on the word")
        XCTAssertTrue(app.otherElements["selectionHandleEnd"].exists)

        // With Undo and Redo leading the bar, a phone's bar has no room for Copy as well: it is in
        // the More menu then, by its title.
        XCTAssertTrue(tapToolbarButton("copyButton", titled: "Copy", in: app), "nothing to copy")
        XCTAssertTrue(tapToolbarButton("searchButton", titled: "Search", in: app), "no Search")
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the search sheet did not come up")
        dismissKeyboardIntroduction(in: app)
        field.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "no Paste in the field's menu: nothing was copied")
        paste.tap()
        // An empty field reads as its placeholder, so a match is the pasted word.
        XCTAssertEqual(field.value as? String, "Page")
    }

    // MARK: The toolbar when the bar is short of room

    /// A long file name takes up the navigation bar, and iOS moves the toolbar's buttons into its More
    /// ("...") menu. There they must have their titles: with icons alone the menu came up empty
    /// (reported on an iPhone). Where the bar has room for them (a wide display, or the iPhone Duo's
    /// bar standing at the side) they are shown as icons.
    func testTheToolbarsButtonsHaveTheirTitlesInTheMoreMenu() {
        let app = launchAndOpen("sample.pdf", as: "Quarterly financial report for the board 2026 final.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        // Looked for in the whole app, not the navigation bar: on the iPhone Duo (iOS 27.1) the bar's
        // buttons stand in a column at the side of the screen.
        let more = app.buttons["OverflowBarButtonItem"]
        guard more.waitForExistence(timeout: 2) else {
            XCTAssertTrue(app.buttons["searchButton"].exists, "no More menu, and no Search button either")
            XCTAssertTrue(app.buttons["thumbnailsButton"].exists)
            return
        }
        more.tap()
        // The menu's items are SwiftUI's own copies of the buttons, without their identifiers: found by title.
        let search = app.buttons.matching(NSPredicate(format: "label == %@", "Search")).firstMatch
        let thumbnails = app.buttons.matching(NSPredicate(format: "label == %@", "Thumbnails")).firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "the More menu has no Search")
        XCTAssertTrue(thumbnails.exists, "the More menu has no Thumbnails")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", "Copy")).firstMatch.exists, "nothing is selected to copy")
        search.tap()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 5), "Search in the More menu did not open the search")
    }

    /// Save a Copy is in the More menu, and puts up the system's exporter, offered as the document's name
    /// and " copy"; Cancel puts it away and leaves the document open.
    func testSaveACopyOpensTheExporter() {
        let app = launchAndOpen("sample.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        XCTAssertTrue(tapToolbarButton("saveCopyButton", titled: "Save a Copy…", in: app), "no Save a Copy")
        // The system's exporter (a document picker, its elements named by the system), offering the name.
        let name = app.textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(name.waitForExistence(timeout: 15), "the exporter did not come up")
        XCTAssertEqual(name.value as? String, "sample copy")
        XCTAssertTrue(app.buttons["DOCPicker.actionButton"].exists, "the exporter has no Save button")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "save-a-copy-exporter"
        shot.lifetime = .keepAlways
        add(shot)
        // Cancel: on the iOS 27 simulator an element of its own under the picker's bar, not a button.
        let cancel = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Cancel'")).firstMatch
        if cancel.exists, cancel.isHittable {
            cancel.tap()
        } else {
            name.swipeDown(velocity: .fast)
            app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].swipeDown(velocity: .fast)
        }
        XCTAssertTrue(name.waitForNonExistence(timeout: 10), "the exporter did not go")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 5)
        XCTAssertFalse(app.alerts.firstMatch.exists, "a cancelled copy says nothing")
    }

    /// Undo and Redo lead the bar's buttons, with their titles (for the More menu), and
    /// are disabled while there is nothing to undo or redo.
    func testUndoAndRedoAreThereAndDisabledOnAnUnchangedDocument() {
        let app = launchAndOpen("sample.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        let undo = app.buttons["undoButton"]
        let redo = app.buttons["redoButton"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "no Undo button")
        XCTAssertTrue(redo.exists, "no Redo button")
        XCTAssertFalse(undo.isEnabled, "nothing to undo")
        XCTAssertFalse(redo.isEnabled, "nothing to redo")
        XCTAssertEqual(undo.label, "Undo")
        XCTAssertEqual(redo.label, "Redo")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "toolbar"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: A password

    /// `locked.pdf`: one page, opened by the password "hunter2".
    func testAProtectedDocumentAsksForItsPasswordAndOpensWithIt() {
        let app = launchAndOpen("locked.pdf")
        let field = app.secureTextFields["passwordField"]
        let unlock = app.buttons["unlockButton"]
        let refused = app.staticTexts["wrongPasswordLabel"]
        let indicator = app.staticTexts["pageIndicator"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the password prompt did not come up")
        XCTAssertFalse(refused.exists, "nothing has been refused yet")
        XCTAssertFalse(indicator.exists, "no pages before the password is given")
        XCTAssertFalse(unlock.isEnabled, "nothing to try yet")

        dismissKeyboardIntroduction(in: app)
        type("nope", into: field, expecting: "••••")
        XCTAssertTrue(unlock.isEnabled)
        unlock.tap()
        XCTAssertTrue(refused.waitForExistence(timeout: 5), "a wrong password is not reported")
        XCTAssertFalse(indicator.exists, "a wrong password opens nothing")

        // A refused password is typed again, not edited: the field is empty and ready.
        type("hunter2", into: field, expecting: "•••••••")
        unlock.tap()
        expect(indicator, toRead: "1 / 1", within: 10)
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "the prompt goes away once the document is open")
    }

    /// The keyboard's own return key does what Unlock does.
    func testTheKeyboardsReturnKeyUnlocksToo() {
        let app = launchAndOpen("locked.pdf")
        let field = app.secureTextFields["passwordField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the password prompt did not come up")
        dismissKeyboardIntroduction(in: app)
        field.typeText("hunter2\n")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 1", within: 10)
    }

    /// The prompt cannot be swiped away like other sheets: Cancel puts it away. The document stays
    /// locked, and its screen says so, with a button that brings the prompt back (and the system's own
    /// way out of a document, whatever the iOS version, since nothing covers it any more).
    func testCancelPutsThePromptAwayAndEnterPasswordBringsItBack() {
        let app = launchAndOpen("locked.pdf")
        let field = app.secureTextFields["passwordField"]
        let cancel = app.buttons["cancelUnlockButton"]
        let enterPassword = app.buttons["enterPasswordButton"]
        let indicator = app.staticTexts["pageIndicator"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "the password prompt did not come up")

        // Drag down from the prompt's title bar, as a person would to dismiss a sheet.
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        top.press(forDuration: 0.1, thenDragTo: bottom)
        XCTAssertFalse(field.waitForNonExistence(timeout: 2), "the prompt was swiped away")

        cancel.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Cancel did not put the prompt away")
        XCTAssertTrue(enterPassword.waitForExistence(timeout: 5), "the locked document does not offer to enter the password")
        XCTAssertFalse(indicator.exists, "still locked: no pages")
        XCTAssertEqual(app.state, .runningForeground)

        enterPassword.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Enter Password did not bring the prompt back")
        dismissKeyboardIntroduction(in: app)
        type("hunter2", into: field, expecting: "•••••••")
        app.buttons["unlockButton"].tap()
        expect(indicator, toRead: "1 / 1", within: 10)
        XCTAssertFalse(enterPassword.exists, "an open document has nothing to unlock")
    }

    // MARK: A file that is not a PDF

    /// `garbage.pdf`: 2 KB of text. The alert says it could not be opened, and its one button closes the document.
    func testAFileThatIsNotAPDFSaysSoAndCloses() {
        let app = launchAndOpen("garbage.pdf")
        // The alert is the system's, and its buttons carry no accessibility identifier (UIAlertAction has
        // none to give; the hierarchy on the iOS 26.5 simulator shows the button with its label only), so
        // the button is found as the alert's only one: Close.
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "no alert about the file")
        XCTAssertEqual(alert.buttons.count, 1, "the alert has a Close button and nothing else")
        XCTAssertFalse(app.staticTexts["pageIndicator"].exists, "a file that did not open has no pages")

        alert.buttons.firstMatch.tap()
        // Back at the document browser, where the file is listed.
        XCTAssertTrue(app.cells[browserIdentifier(of: "garbage.pdf")].waitForExistence(timeout: 10), "the document browser did not come back")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(app.staticTexts["pageIndicator"].exists)
    }
}
