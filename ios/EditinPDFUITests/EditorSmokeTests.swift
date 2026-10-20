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
        // One finger on the white of the page scrolls, text tool or not.
        let indicator = app.staticTexts["pageIndicator"]
        pagePoint(CGPoint(x: 300, y: 600), pageWidth: 612, in: app)
            .press(forDuration: 0.05, thenDragTo: pagePoint(CGPoint(x: 300, y: 100), pageWidth: 612, in: app))
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "1 / 3"), object: indicator)
        XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 5), .completed, "a drag on the white of the page did not scroll")
        attach(app, "text-markup-scrolled")
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app))
        // Back to the top, where the marked line is.
        app.scrollViews["pageScrollView"].firstMatch.swipeDown(velocity: .fast)
        app.scrollViews["pageScrollView"].firstMatch.swipeDown(velocity: .fast)
        expect(indicator, toRead: "1 / 3", within: 5)
        // Reading mode: a long press selects a word, and its menu marks it.
        line.start.withOffset(CGVector(dx: 8, dy: 0)).press(forDuration: 1)
        let highlight = app.menuItems["Highlight"].exists ? app.menuItems["Highlight"] : app.buttons["Highlight"]
        XCTAssertTrue(highlight.waitForExistence(timeout: 5), "the selection's menu offers no Highlight")
        attach(app, "text-markup-menu")
        highlight.tap()
        XCTAssertFalse(highlight.waitForExistence(timeout: 1) && highlight.isHittable, "the menu stayed")
        attach(app, "text-markup-menu-done")
    }

    /// Two fingers zoom with a text tool picked, as in reading mode, and mark nothing: the top of the
    /// first page, where its line is, looks different once zoomed in on the middle of the view.
    func testPinchingZoomsWithATextToolPicked() throws {
        let app = launchAndOpen("sample.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let highlight = app.buttons["tool-highlight"]
        XCTAssertTrue(highlight.waitForEnabled(timeout: 5))
        highlight.tap()
        let scrollView = app.scrollViews["pageScrollView"].firstMatch
        let line = textLine(in: app, page: scrollView)
        // Around the line: from a little before it to a little after, a line's height above and below.
        let around = CGRect(x: line.start.screenPoint.x - 20, y: line.start.screenPoint.y - 20,
                            width: line.end.screenPoint.x - line.start.screenPoint.x + 40, height: 40)
        let before = try pixels(of: around, in: app)
        scrollView.pinch(withScale: 3, velocity: 2)
        sleep(1)
        attach(app, "text-markup-pinched")
        XCTAssertNotEqual(try pixels(of: around, in: app), before, "the pinch did not zoom")
        XCTAssertFalse(app.buttons["undoButton"].isEnabled, "the pinch marked something")
    }

    /// The pixels of `rect` (points on the screen) in a screenshot of `app`.
    private func pixels(of rect: CGRect, in app: XCUIApplication) throws -> Data {
        let image = app.screenshot().image
        let scale = image.scale
        let cropped = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale,
                                                                       width: rect.width * scale, height: rect.height * scale)))
        return try XCTUnwrap(UIImage(cgImage: cropped).pngData())
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

    /// Draw: one finger draws on the page instead of scrolling it; the strokes wait on the page, with
    /// Done in the palette and Undo on, and are added as one drawing that stays where it was drawn;
    /// Undo takes the whole drawing back. Two fingers zoom, and a drawing made zoomed in lands where
    /// it was drawn too.
    func testDrawingWithAFingerAddsInkThatUndoTakesBack() throws {
        let app = launchAndOpen("sample.pdf")
        let indicator = app.staticTexts["pageIndicator"]
        expect(indicator, toRead: "1 / 3", within: 10)
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let ink = app.buttons["tool-ink"]
        XCTAssertTrue(ink.waitForEnabled(timeout: 5), "Draw is disabled on a document that allows markup")
        ink.tap()
        let undo = app.buttons["undoButton"], redo = app.buttons["redoButton"], done = app.buttons["doneDrawingButton"]
        XCTAssertFalse(undo.isEnabled, "nothing to undo yet")
        XCTAssertFalse(done.exists, "no Done before anything is drawn")

        // Two strokes across the white of the first page, one finger each: they draw, not scroll.
        let first = (pagePoint(CGPoint(x: 150, y: 300), pageWidth: 612, in: app), pagePoint(CGPoint(x: 450, y: 300), pageWidth: 612, in: app))
        let second = (pagePoint(CGPoint(x: 150, y: 360), pageWidth: 612, in: app), pagePoint(CGPoint(x: 450, y: 420), pageWidth: 612, in: app))
        first.0.press(forDuration: 0.05, thenDragTo: first.1)
        second.0.press(forDuration: 0.05, thenDragTo: second.1)
        XCTAssertTrue(done.waitForExistence(timeout: 5), "no Done after drawing")
        XCTAssertEqual(indicator.label, "1 / 3", "one finger scrolled")
        XCTAssertTrue(undo.isEnabled, "Undo is on while strokes wait")
        XCTAssertFalse(redo.isEnabled, "Redo is off while strokes wait")
        let midway = pagePoint(CGPoint(x: 300, y: 300), pageWidth: 612, in: app).screenPoint
        XCTAssertTrue(try isInked(around: midway, in: app), "the stroke is not on the canvas")
        attach(app, "ink-pending")

        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "Done stayed after the strokes were added")
        XCTAssertTrue(undo.waitForEnabled(timeout: 5), "adding the drawing left nothing to undo")
        sleep(2)
        XCTAssertTrue(try isInked(around: midway, in: app), "the drawing did not stay where it was drawn")
        attach(app, "ink-added")

        undo.tap()
        XCTAssertTrue(redo.waitForEnabled(timeout: 5), "Undo took nothing back")
        sleep(2)
        XCTAssertFalse(try isInked(around: midway, in: app), "Undo left the drawing")
        XCTAssertFalse(undo.isEnabled, "the whole drawing was one change")

        // Zoomed in three times, a stroke under the finger stays under it once added.
        let scrollView = app.scrollViews["pageScrollView"].firstMatch
        scrollView.pinch(withScale: 3, velocity: 2)
        sleep(1)
        let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(done.waitForExistence(timeout: 5), "nothing was drawn zoomed in")
        let centre = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).screenPoint
        attach(app, "ink-zoomed-pending")
        done.tap()
        XCTAssertTrue(undo.waitForEnabled(timeout: 5))
        sleep(2)
        XCTAssertTrue(try isInked(around: centre, in: app), "the drawing made zoomed in moved")
        attach(app, "ink-zoomed-added")
    }

    /// On a page turned by `/Rotate 90`, a drawing stays where it was drawn.
    func testDrawingOnATurnedPageStaysWhereItWasDrawn() throws {
        let app = launchAndOpen("rotated.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 1", within: 10)
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let ink = app.buttons["tool-ink"]
        XCTAssertTrue(ink.waitForEnabled(timeout: 5))
        ink.tap()
        // The page is shown landscape (792 x 612 points), fitted to the width.
        let start = pagePoint(CGPoint(x: 200, y: 250), pageWidth: 792, in: app)
        let end = pagePoint(CGPoint(x: 600, y: 250), pageWidth: 792, in: app)
        start.press(forDuration: 0.05, thenDragTo: end)
        let done = app.buttons["doneDrawingButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "nothing was drawn")
        done.tap()
        XCTAssertTrue(app.buttons["undoButton"].waitForEnabled(timeout: 5), "the drawing was not added")
        sleep(2)
        XCTAssertTrue(try isInked(around: pagePoint(CGPoint(x: 400, y: 250), pageWidth: 792, in: app).screenPoint, in: app),
                      "the drawing did not stay where it was drawn")
        attach(app, "ink-rotated")
    }

    /// Whether the screen around `point` (a 9-point square) has ink on it: any pixel well away from
    /// white.
    private func isInked(around point: CGPoint, in app: XCUIApplication) throws -> Bool {
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let box = CGRect(x: (point.x - 4.5) * scale, y: (point.y - 4.5) * scale, width: 9 * scale, height: 9 * scale).integral
        let cropped = try XCTUnwrap(image.cropping(to: box))
        let width = cropped.width, height = cropped.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        return stride(from: 0, to: pixels.count, by: 4).contains { i in
            Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) < 3 * 160
        }
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
