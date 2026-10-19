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

    /// Markup in the toolbar brings up the tool palette (a bar at the bottom on a phone, a column at the
    /// leading edge on a tablet), with Select picked; a tool is picked by tapping it, its style opens
    /// from the palette, and Markup again puts the palette away.
    func testMarkupShowsThePaletteAndAToolsStyle() {
        let app = launchAndOpen("sample.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let select = app.buttons["tool-select"]
        XCTAssertTrue(select.waitForExistence(timeout: 5), "no tool palette")
        XCTAssertTrue(select.isSelected, "Markup starts with Select")
        let ink = app.buttons["tool-ink"]
        XCTAssertTrue(ink.waitForEnabled(timeout: 5), "Draw is disabled on a document that allows markup")
        ink.tap()
        XCTAssertTrue(ink.isSelected)
        let palette = XCTAttachment(screenshot: app.screenshot())
        palette.name = "palette"
        palette.lifetime = .keepAlways
        add(palette)
        app.buttons["toolStyleButton"].tap()
        XCTAssertTrue(app.sliders["toolWidthSlider"].waitForExistence(timeout: 5), "no style picker for Draw")
        XCTAssertTrue(app.buttons["swatch-0"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "palette-style"
        shot.lifetime = .keepAlways
        add(shot)
        // A sheet (phone) and a popover (tablet) both go with a tap outside them, on the dimmed pages.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.2)).tap()
        XCTAssertTrue(app.sliders["toolWidthSlider"].waitForNonExistence(timeout: 5), "the style picker did not go")
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app))
        XCTAssertTrue(ink.waitForNonExistence(timeout: 5), "the palette stayed after Markup was turned off")
    }
}

private extension XCUIElement {
    /// Waits up to `timeout` seconds for the element to exist and be enabled.
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
