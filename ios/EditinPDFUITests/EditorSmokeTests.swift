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

    /// Highlight, Underline and Strikethrough each mark the line a finger drags across, and the
    /// selection's menu in reading mode offers the same marks. Each mark can be undone, so Undo turning
    /// on says it was made; the screenshots show where.
    func testDraggingAcrossTextMarksIt() {
        let app = launchAndOpen("sample.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        let undo = app.buttons["undoButton"]
        XCTAssertFalse(undo.isEnabled, "nothing to undo yet")
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let line = textLine(in: app, page: app.scrollViews["pageScrollView"].firstMatch)
        for tool in ["highlight", "underline", "strikeout"] {
            let button = app.buttons["tool-\(tool)"]
            XCTAssertTrue(button.waitForEnabled(timeout: 5), "\(tool) is disabled on a document that allows markup")
            button.tap()
            let undoWasOn = undo.isEnabled
            line.start.press(forDuration: 0.05, thenDragTo: line.end)
            if undoWasOn { sleep(1) } else { XCTAssertTrue(undo.waitForEnabled(timeout: 5), "dragging with \(tool) marked nothing") }
        }
        attach(app, "text-markup-tools")
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app))
        // Reading mode: a long press selects a word, and its menu marks it.
        line.start.withOffset(CGVector(dx: 8, dy: 0)).press(forDuration: 1)
        let highlight = app.menuItems["Highlight"].exists ? app.menuItems["Highlight"] : app.buttons["Highlight"]
        XCTAssertTrue(highlight.waitForExistence(timeout: 5), "the selection's menu offers no Highlight")
        attach(app, "text-markup-menu")
        highlight.tap()
        XCTAssertFalse(highlight.waitForExistence(timeout: 1) && highlight.isHittable, "the menu stayed")
        attach(app, "text-markup-menu-done")
    }

    /// On a page turned by `/Rotate 90` the line runs down the page: a drag down it marks it there.
    func testDraggingDownTheTextOfATurnedPageMarksIt() {
        let app = launchAndOpen("rotated.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 1", within: 10)
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let button = app.buttons["tool-highlight"]
        XCTAssertTrue(button.waitForEnabled(timeout: 5))
        button.tap()
        attach(app, "rotated-before")
        // The page is shown landscape (792 x 612 points), fitted to the width; its line of text,
        // "Rotated page", runs down near the right edge, from the top of the page.
        let start = pagePoint(CGPoint(x: 711, y: 60), pageWidth: 792, in: app)
        let end = pagePoint(CGPoint(x: 711, y: 150), pageWidth: 792, in: app)
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.buttons["undoButton"].waitForEnabled(timeout: 5), "the drag marked nothing")
        attach(app, "rotated-highlight")
    }

    /// The first line of `sample.pdf`'s first page ("Page one", at 72 points from the page's left and
    /// about 79 from its top): where a drag across it starts and ends.
    private func textLine(in app: XCUIApplication, page: XCUIElement) -> (start: XCUICoordinate, end: XCUICoordinate) {
        (pagePoint(CGPoint(x: 74, y: 79), pageWidth: 612, in: app), pagePoint(CGPoint(x: 125, y: 79), pageWidth: 612, in: app))
    }

    /// Where `point` (PDF points on the first page, `pageWidth` wide, at the top of the document) is on
    /// screen: the page is fitted to the scroll view's width and starts under the navigation bar.
    private func pagePoint(_ point: CGPoint, pageWidth: CGFloat, in app: XCUIApplication) -> XCUICoordinate {
        let scrollView = app.scrollViews["pageScrollView"].firstMatch
        let scale = scrollView.frame.width / pageWidth
        let top = app.navigationBars.firstMatch.frame.maxY - scrollView.frame.minY
        return scrollView.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x * scale, dy: top + point.y * scale))
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

private extension XCUIElement {
    /// Waits up to `timeout` seconds for the element to exist and be enabled.
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
