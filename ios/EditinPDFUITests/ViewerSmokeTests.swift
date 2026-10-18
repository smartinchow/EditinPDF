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

        app.swipeUp()
        app.swipeUp()
        expect(indicator, toRead: "3 / 3", within: 5)
        // Back to the top, so that a search result has somewhere to take the reader.
        app.swipeDown()
        app.swipeDown()
        expect(indicator, toRead: "1 / 3", within: 5)

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

        app.buttons["searchButton"].tap()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the search sheet did not come up")
        dismissKeyboardIntroduction(in: app)
        field.typeText("three")
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

        // The first page is a 612 pt wide Letter page, fitted to the width of the window, and its top is
        // at the bottom of the navigation bar. In its own points "Page" runs from 72 to 97.7 across and
        // 74.2 to 85.2 down, so (85, 79.7) is the middle of the word.
        let scale = app.windows.firstMatch.frame.width / 612
        let pageTop = app.navigationBars.firstMatch.frame.maxY
        let word = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 85 * scale, dy: pageTop + 79.7 * scale))
        word.press(forDuration: 0.8)
        XCTAssertTrue(app.otherElements["selectionHandleStart"].waitForExistence(timeout: 5), "no selection after a long press on the word")
        XCTAssertTrue(app.otherElements["selectionHandleEnd"].exists)

        let copy = app.buttons["copyButton"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "nothing to copy")
        copy.tap()

        app.buttons["searchButton"].tap()
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
    /// (reported on an iPhone). Where the bar has room for them (a wide display) they are in it as icons.
    func testTheToolbarsButtonsHaveTheirTitlesInTheMoreMenu() {
        let app = launchAndOpen("sample.pdf", as: "Quarterly financial report for the board 2026 final.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        let bar = app.navigationBars.firstMatch
        let more = bar.buttons["OverflowBarButtonItem"]
        guard more.waitForExistence(timeout: 2) else {
            XCTAssertTrue(bar.buttons["searchButton"].exists, "no More menu, and no Search button in the bar either")
            XCTAssertTrue(bar.buttons["thumbnailsButton"].exists)
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
        field.typeText("nope")
        XCTAssertTrue(unlock.isEnabled)
        unlock.tap()
        XCTAssertTrue(refused.waitForExistence(timeout: 5), "a wrong password is not reported")
        XCTAssertFalse(indicator.exists, "a wrong password opens nothing")

        // A refused password is typed again, not edited: the field is empty and ready.
        field.typeText("hunter2")
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
        field.typeText("hunter2")
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

    // MARK: Helpers

    /// Launches the app with `fixture` staged in its Documents folder, and opens it from the document
    /// browser. Returns the running app.
    /// The document is staged under `name` when one is given.
    private func launchAndOpen(_ fixture: String, as name: String? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        // The second pair keeps a document scene from an earlier test from coming back: each test starts at the browser.
        app.launchArguments = ["-openFixture", fixture, "-ApplePersistenceIgnoreState", "YES"]
        if let name { app.launchArguments += ["-fixtureName", name] }
        app.launch()
        openFromBrowser(name ?? fixture, in: app)
        return app
    }

    /// What the document browser calls a file: its name with the dot written out as ", ".
    private func browserIdentifier(of file: String) -> String {
        file.replacingOccurrences(of: ".", with: ", ")
    }

    /// Opens `file` from the app's folder under "On My iPhone". The browser comes up wherever it was
    /// left, so this works from whichever level shows: Browse, then the location, then the folder.
    private func openFromBrowser(_ file: String, in app: XCUIApplication) {
        let cell = app.cells[browserIdentifier(of: file)]
        let location = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'DOC.sidebar.item.On My'")).firstMatch
        let folder = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'EditinPDF'")).firstMatch
        let browse = app.buttons["Browse"].firstMatch
        for _ in 0..<8 {
            if cell.waitForExistence(timeout: 2) { break }
            if location.exists, location.isHittable {
                location.tap()
                _ = folder.waitForExistence(timeout: 4)
            } else if folder.exists, folder.isHittable {
                folder.tap()
                _ = cell.waitForExistence(timeout: 4)
            } else if browse.exists, browse.isHittable {
                browse.tap()
                sleep(1)
            }
        }
        XCTAssertTrue(cell.exists, "the document browser never listed \(file)")
        cell.tap()
    }

    /// Waits until the page indicator names one of the `count` pages: "N / count", N from 1 to `count`.
    private func expect(_ indicator: XCUIElement, toReadAPageOf count: Int, within seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        let pages = (1...count).map(String.init).joined(separator: "|")
        let reads = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES %@", "^(\(pages)) / \(count)$"), object: indicator)
        let result = XCTWaiter().wait(for: [reads], timeout: seconds)
        XCTAssertEqual(result, .completed, "the page indicator \(indicator.exists ? "reads \"\(indicator.label)\"" : "is not there"), not a page of \(count)", file: file, line: line)
    }

    /// Waits until the page indicator reads `text`.
    private func expect(_ indicator: XCUIElement, toRead text: String, within seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        let reads = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", text), object: indicator)
        let result = XCTWaiter().wait(for: [reads], timeout: seconds)
        XCTAssertEqual(result, .completed, "the page indicator \(indicator.exists ? "reads \"\(indicator.label)\"" : "is not there"), not \"\(text)\"", file: file, line: line)
    }

    /// A fresh simulator shows a one-time card over its keyboard ("Speed up your typing"), which has
    /// to be dismissed before keys can be typed.
    private func dismissKeyboardIntroduction(in app: XCUIApplication) {
        let button = app.buttons["Continue"]
        if button.waitForExistence(timeout: 1.5), button.isHittable { button.tap() }
    }
}
