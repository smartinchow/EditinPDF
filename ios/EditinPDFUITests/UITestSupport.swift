import XCTest

/// What the UI tests share: opening one of the app's sample documents from the document browser,
/// tapping a toolbar button wherever the bar put it, and waiting for the page indicator.
@MainActor
extension XCTestCase {
    /// Launches the app with `fixture` staged in its Documents folder, and opens it from the document
    /// browser. Returns the running app.
    /// The document is staged under `name` when one is given; `arguments` are added to the launch's.
    func launchAndOpen(_ fixture: String, as name: String? = nil, arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        // The second pair keeps a document scene from an earlier test from coming back: each test starts at the browser.
        // The last makes each tool start with its first style, whatever an earlier test picked (the text size, say).
        app.launchArguments = ["-openFixture", fixture, "-ApplePersistenceIgnoreState", "YES", "-resetToolStyles"] + arguments
        if let name { app.launchArguments += ["-fixtureName", name] }
        app.launch()
        openFromBrowser(name ?? fixture, in: app)
        return app
    }

    /// What the document browser calls a file: its name with the dot written out as ", ".
    func browserIdentifier(of file: String) -> String {
        file.replacingOccurrences(of: ".", with: ", ")
    }

    /// Opens `file` from the app's folder under "On My iPhone". The browser comes up wherever it was
    /// left, so this works from whichever level shows: Browse, then the location, then the folder.
    func openFromBrowser(_ file: String, in app: XCUIApplication) {
        let cell = app.cells[browserIdentifier(of: file)]
        let location = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'DOC.sidebar.item.On My'")).firstMatch
        let folder = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'EditinPDF'")).firstMatch
        let browse = app.buttons["Browse"].firstMatch
        // Inside the app's folder, the browser's back button is named for the location above it.
        let inFolder = app.buttons.matching(NSPredicate(format: "identifier == 'BackButton' AND label BEGINSWITH 'On My'")).firstMatch
        for _ in 0..<8 {
            if cell.waitForExistence(timeout: 2) { break }
            if inFolder.exists {
                // In the folder, but the file is further down than the browser's half-height sheet
                // shows (the folder fills up with the documents earlier tests and walks left there).
                // The sheet is in the lower part of the screen: the drag scrolls its list.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
            } else if location.exists, location.isHittable {
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
        // A cell reached by scrolling the list can still be moving when it is tapped, and the tap then
        // opens nothing (seen once the folder holds many documents): tapped again while it is still
        // there to tap, until the browser, and the cell with it, goes.
        for _ in 0..<3 {
            cell.tap()
            if cell.waitForNonExistence(timeout: 4) || !cell.isHittable { return }
        }
    }

    /// Taps the toolbar button `identifier`, or, when the bar has moved it into its More menu, the
    /// menu's item `title` (the menu's copies have no identifiers). False if it is in neither.
    func tapToolbarButton(_ identifier: String, titled title: String, in app: XCUIApplication) -> Bool {
        let button = app.buttons[identifier]
        if button.waitForExistence(timeout: 3) {
            button.tap()
            return true
        }
        let more = app.buttons["OverflowBarButtonItem"]
        guard more.exists else { return false }
        more.tap()
        let item = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        guard item.waitForExistence(timeout: 5) else { return false }
        item.tap()
        return true
    }

    /// Waits until the page indicator names one of the `count` pages: "N / count", N from 1 to `count`.
    func expect(_ indicator: XCUIElement, toReadAPageOf count: Int, within seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        let pages = (1...count).map(String.init).joined(separator: "|")
        let reads = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES %@", "^(\(pages)) / \(count)$"), object: indicator)
        let result = XCTWaiter().wait(for: [reads], timeout: seconds)
        XCTAssertEqual(result, .completed, "the page indicator \(indicator.exists ? "reads \"\(indicator.label)\"" : "is not there"), not a page of \(count)", file: file, line: line)
    }

    /// Waits until the page indicator reads `text`.
    func expect(_ indicator: XCUIElement, toRead text: String, within seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        let reads = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", text), object: indicator)
        let result = XCTWaiter().wait(for: [reads], timeout: seconds)
        XCTAssertEqual(result, .completed, "the page indicator \(indicator.exists ? "reads \"\(indicator.label)\"" : "is not there"), not \"\(text)\"", file: file, line: line)
    }

    /// Swipes up (or down) until `indicator` reads `text`, eight swipes at most, then expects it to.
    func swipe(_ app: XCUIApplication, up: Bool, until indicator: XCUIElement, reads text: String,
               file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 {
            if indicator.label == text { break }
            if up { app.swipeUp() } else { app.swipeDown() }
            let reads = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", text), object: indicator)
            _ = XCTWaiter().wait(for: [reads], timeout: 1.5)
        }
        expect(indicator, toRead: text, within: 5, file: file, line: line)
    }

    /// Types `text` into `element`, then waits until the element holds `expected` (`text` when nil; a
    /// secure field holds a "•" for each character): the keyboard is a process of its own, and what it
    /// types reaches the app a moment after `typeText` returns. On a slow machine (the CI runner) a tap
    /// that follows at once came before the text: Back closed the document with an empty text box, and
    /// the text was never in the file. (Text ended by the keyboard's own Return needs no wait: the
    /// keyboard hands it over in order.)
    func type(_ text: String, into element: XCUIElement, expecting expected: String? = nil, within seconds: TimeInterval = 10,
              file: StaticString = #filePath, line: UInt = #line) {
        element.typeText(text)
        let value = expected ?? text
        let arrived = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [arrived], timeout: seconds), .completed,
                       "\(element.identifier) holds \(String(describing: element.exists ? element.value : nil)), not \"\(value)\", after typing",
                       file: file, line: line)
    }

    /// Presses `key` with `modifiers` on the hardware keyboard the test drives, until `predicate` holds
    /// for `object`, three times at most, waiting `seconds` after each press. On the iOS 27 simulator the
    /// first key a launch of the app is sent is lost, once an earlier launch has been sent keys: the
    /// software keyboard steps aside for the hardware one, and nothing else happens (⌘Z in the search
    /// field did nothing on the CI runner, after the tests before it had pressed ⌘Z and ⇧⌘Z; reproduced
    /// on an iPhone 18 Pro, iOS 27.0, simulator). The next press arrives. Says whether `predicate` held.
    func press(_ key: String, modifiers: XCUIElement.KeyModifierFlags, in app: XCUIApplication,
               until predicate: NSPredicate, holdsFor object: Any, within seconds: TimeInterval = 4) -> Bool {
        for _ in 0..<3 {
            app.typeKey(key, modifierFlags: modifiers)
            let holds = XCTNSPredicateExpectation(predicate: predicate, object: object)
            if XCTWaiter().wait(for: [holds], timeout: seconds) == .completed { return true }
        }
        return false
    }

    /// A fresh simulator shows a one-time card over its keyboard ("Speed up your typing"), which has
    /// to be dismissed before keys can be typed.
    func dismissKeyboardIntroduction(in app: XCUIApplication) {
        let button = app.buttons["Continue"]
        if button.waitForExistence(timeout: 1.5), button.isHittable { button.tap() }
    }
}
