import XCTest

/// What the UI tests share: opening one of the app's sample documents from the document browser,
/// tapping a toolbar button wherever the bar put it, and waiting for the page indicator.
@MainActor
extension XCTestCase {
    /// Launches the app with `fixture` staged in its Documents folder, and opens it from the document
    /// browser. Returns the running app.
    /// The document is staged under `name` when one is given.
    func launchAndOpen(_ fixture: String, as name: String? = nil) -> XCUIApplication {
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
        cell.tap()
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

    /// A fresh simulator shows a one-time card over its keyboard ("Speed up your typing"), which has
    /// to be dismissed before keys can be typed.
    func dismissKeyboardIntroduction(in app: XCUIApplication) {
        let button = app.buttons["Continue"]
        if button.waitForExistence(timeout: 1.5), button.isHittable { button.tap() }
    }
}
