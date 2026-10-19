import XCTest

/// Changing a document end to end, on the simulator: each test opens one of the app's sample
/// documents from the document browser (see `UITestSupport`), changes it, and reads the result off
/// the page indicator.
@MainActor
final class EditorSmokeTests: XCTestCase {
    /// `sample.pdf` has three pages. Deleting the third in Organize leaves two; Undo in the main
    /// toolbar brings it back.
    func testOrganizeDeleteAndUndo() {
        let app = launchAndOpen("sample.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        XCTAssertTrue(tapToolbarButton("organizeButton", titled: "Organize Pages", in: app), "no Organize button")
        let page = app.cells["organizePage-2"]
        XCTAssertTrue(page.waitForExistence(timeout: 5), "the Organize grid did not come up")
        page.tap()
        XCTAssertTrue(page.isSelected, "a tapped page is selected")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "organize"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["organizeDelete"].tap()
        XCTAssertTrue(app.cells["organizePage-2"].waitForNonExistence(timeout: 5), "the page was not deleted")
        app.buttons["organizeDone"].tap()
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 2", within: 5)
        XCTAssertTrue(tapToolbarButton("undoButton", titled: "Undo", in: app), "no Undo button")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 5)
    }

    /// Insert Blank Page tapped twice in quick succession never says the document changed under it:
    /// the button is off while the first page is being added.
    func testInsertBlankTappedTwiceShowsNoFailure() {
        let app = launchAndOpen("sample.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        XCTAssertTrue(tapToolbarButton("organizeButton", titled: "Organize Pages", in: app), "no Organize button")
        let insert = app.buttons["organizeInsertBlank"]
        XCTAssertTrue(insert.waitForExistence(timeout: 5), "no Insert Blank Page")
        insert.tap()
        insert.tap()
        XCTAssertTrue(app.cells["organizePage-3"].waitForExistence(timeout: 5), "no page was inserted")
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2), "an alert came up")
        app.buttons["organizeDone"].tap()
        // The second tap adds a page only if the first was done by then.
        let indicator = app.staticTexts["pageIndicator"]
        let reads = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES %@", "^1 / [45]$"), object: indicator)
        XCTAssertEqual(XCTWaiter().wait(for: [reads], timeout: 5), .completed, "the indicator reads \"\(indicator.label)\"")
    }
}
