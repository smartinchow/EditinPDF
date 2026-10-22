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
        // Reading mode: a long press selects a word, and its menu changes its marks. The word is
        // highlighted already (the drag above), so the menu offers to take the highlight off.
        line.start.withOffset(CGVector(dx: 8, dy: 0)).press(forDuration: 1)
        let highlight = app.menuItems["Remove Highlight"]
        XCTAssertTrue(highlight.waitForExistence(timeout: 5), "the selection's menu offers no Remove Highlight")
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
        // "Rotated page", runs down near the right edge, from 72 points below the top of the page. The
        // drag starts on it: a finger 12 points above it is more than 8 points on screen off it on a
        // tablet, and scrolls. (It used to start there and mark, because the drag began some 10 points
        // along from where the finger went down; it now begins where the finger did.)
        let start = pagePoint(CGPoint(x: 711, y: 80), pageWidth: 792, in: app)
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

    /// Strokes left waiting (no Done) when the reader goes back to the documents are in the file: the
    /// document, opened again in a fresh launch of the app, shows them. And ⌘Z on a hardware keyboard
    /// takes back strokes waiting, as the Undo button does.
    func testStrokesLeftWaitingAreKeptWhenTheDocumentIsClosed() throws {
        let app = launchAndOpen("sample.pdf", as: "ink-closed.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let ink = app.buttons["tool-ink"]
        XCTAssertTrue(ink.waitForEnabled(timeout: 5))
        ink.tap()
        let done = app.buttons["doneDrawingButton"]

        // ⌘Z: the strokes waiting are added, then taken back.
        pagePoint(CGPoint(x: 150, y: 500), pageWidth: 612, in: app)
            .press(forDuration: 0.05, thenDragTo: pagePoint(CGPoint(x: 450, y: 500), pageWidth: 612, in: app))
        XCTAssertTrue(done.waitForExistence(timeout: 5), "nothing was drawn")
        XCTAssertTrue(press("z", modifiers: .command, in: app, until: NSPredicate(format: "exists == false"), holdsFor: done),
                      "⌘Z left the strokes waiting")
        XCTAssertTrue(app.buttons["redoButton"].waitForEnabled(timeout: 5), "⌘Z did not take the drawing back")
        sleep(2)
        let undone = pagePoint(CGPoint(x: 300, y: 500), pageWidth: 612, in: app).screenPoint
        XCTAssertFalse(try isInked(around: undone, in: app), "⌘Z left the drawing on the page")

        // Drawn, and left waiting: back to the documents without Done.
        pagePoint(CGPoint(x: 150, y: 300), pageWidth: 612, in: app)
            .press(forDuration: 0.05, thenDragTo: pagePoint(CGPoint(x: 450, y: 300), pageWidth: 612, in: app))
        XCTAssertTrue(done.waitForExistence(timeout: 5), "nothing was drawn")
        let back = app.navigationBars.buttons["BackButton"].exists ? app.navigationBars.buttons["BackButton"] : app.navigationBars.buttons.firstMatch
        back.tap()
        XCTAssertTrue(app.staticTexts["pageIndicator"].waitForNonExistence(timeout: 10), "the document did not close")
        sleep(2)

        // A fresh launch, without staging the sample again: the file as saved.
        app.terminate()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        openFromBrowser("ink-closed.pdf", in: app)
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        sleep(2)
        let kept = pagePoint(CGPoint(x: 300, y: 300), pageWidth: 612, in: app).screenPoint
        XCTAssertTrue(try isInked(around: kept, in: app), "the strokes left waiting were lost when the document closed")
        XCTAssertFalse(try isInked(around: undone, in: app), "the drawing ⌘Z took back is in the file")
        attach(app, "ink-kept-after-close")
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

    /// Rectangle, Oval, Line and Arrow: one finger drags each out on the page, instead of scrolling it,
    /// and it is added where it was dragged; each is a change Undo can take back.
    func testDraggingOutShapesAddsThem() throws {
        let app = launchAndOpen("sample.pdf")
        let indicator = app.staticTexts["pageIndicator"]
        expect(indicator, toRead: "1 / 3", within: 10)
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let undo = app.buttons["undoButton"]
        // Each drag, and a point on the line it draws (page points of the first page).
        let shapes: [(tool: String, from: CGPoint, to: CGPoint, onIt: CGPoint)] = [
            ("rectangle", CGPoint(x: 150, y: 300), CGPoint(x: 450, y: 420), CGPoint(x: 151, y: 360)),
            ("oval", CGPoint(x: 150, y: 450), CGPoint(x: 450, y: 560), CGPoint(x: 151, y: 505)),
            ("line", CGPoint(x: 150, y: 600), CGPoint(x: 450, y: 600), CGPoint(x: 300, y: 600)),
            ("arrow", CGPoint(x: 150, y: 700), CGPoint(x: 450, y: 640), CGPoint(x: 300, y: 670)),
        ]
        for shape in shapes {
            let button = app.buttons["tool-\(shape.tool)"]
            XCTAssertTrue(button.waitForEnabled(timeout: 5), "\(shape.tool) is disabled on a document that allows markup")
            button.tap()
            XCTAssertFalse(try isInked(around: pagePoint(shape.onIt, pageWidth: 612, in: app).screenPoint, in: app), "\(shape.tool): ink there already")
            pagePoint(shape.from, pageWidth: 612, in: app).press(forDuration: 0.05, thenDragTo: pagePoint(shape.to, pageWidth: 612, in: app))
            XCTAssertTrue(undo.waitForEnabled(timeout: 5), "dragging with \(shape.tool) added nothing")
            sleep(1)
            XCTAssertTrue(try isInked(around: pagePoint(shape.onIt, pageWidth: 612, in: app).screenPoint, in: app),
                          "the \(shape.tool) is not where it was dragged")
        }
        XCTAssertEqual(indicator.label, "1 / 3", "one finger scrolled")
        attach(app, "shapes")
        undo.tap()
        sleep(2)
        XCTAssertFalse(try isInked(around: pagePoint(shapes[3].onIt, pageWidth: 612, in: app).screenPoint, in: app), "Undo left the arrow")
        XCTAssertTrue(try isInked(around: pagePoint(shapes[2].onIt, pageWidth: 612, in: app).screenPoint, in: app), "Undo took more than the arrow")
    }

    /// Note: a tap opens the note sheet; what is written and cancelled changes nothing (typing there is
    /// not a change to the document), and Save puts the note's icon where it was tapped. Text Box: a tap
    /// puts a box to type in there, the keyboard comes up, and what is typed (two lines) is added
    /// exactly where it was typed once a tap elsewhere ends it, at the first zoom and zoomed in.
    func testTypingATextBoxAndWritingANote() throws {
        let app = launchAndOpen("sample.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let undo = app.buttons["undoButton"]

        let note = app.buttons["tool-note"]
        XCTAssertTrue(note.waitForEnabled(timeout: 5))
        note.tap()
        let noteText = app.textViews["noteText"]
        let save = app.buttons["noteSaveButton"]
        pagePoint(CGPoint(x: 450, y: 150), pageWidth: 612, in: app).tap()
        XCTAssertTrue(noteText.waitForExistence(timeout: 5), "no note sheet")
        dismissKeyboardIntroduction(in: app)
        XCTAssertFalse(save.isEnabled, "nothing written to save")
        type("Never mind", into: noteText)
        app.buttons["noteCancelButton"].tap()
        XCTAssertTrue(noteText.waitForNonExistence(timeout: 5), "Cancel left the sheet")
        sleep(1)
        XCTAssertFalse(undo.isEnabled, "writing in the note sheet and cancelling changed the document")
        XCTAssertFalse(try isInked(around: pagePoint(CGPoint(x: 460, y: 160), pageWidth: 612, in: app).screenPoint, in: app),
                       "a cancelled note was added")
        pagePoint(CGPoint(x: 450, y: 150), pageWidth: 612, in: app).tap()
        XCTAssertTrue(noteText.waitForExistence(timeout: 5), "no note sheet")
        type("Check this", into: noteText)
        XCTAssertTrue(save.waitForEnabled(timeout: 5))
        attach(app, "note-sheet")
        save.tap()
        XCTAssertTrue(noteText.waitForNonExistence(timeout: 5), "the sheet stayed")
        XCTAssertTrue(undo.waitForEnabled(timeout: 5), "the note was not added")
        sleep(2)
        XCTAssertTrue(try isInked(around: pagePoint(CGPoint(x: 460, y: 160), pageWidth: 612, in: app).screenPoint, in: app),
                      "no note where it was tapped")

        let textBox = app.buttons["tool-textBox"]
        XCTAssertTrue(textBox.waitForEnabled(timeout: 5), "Text Box is disabled on an upright page")
        textBox.tap()
        let editor = app.textViews["inlineTextEditor"]
        let at = pagePoint(CGPoint(x: 100, y: 150), pageWidth: 612, in: app)
        try typeTextBox("Hello\nWorld", at: at, endingAt: pagePoint(CGPoint(x: 400, y: 500), pageWidth: 612, in: app), in: app)
        XCTAssertTrue(try isInked(around: pagePoint(CGPoint(x: 112, y: 176), pageWidth: 612, in: app).screenPoint, in: app),
                      "no second line")
        attach(app, "textbox-note")

        // Zoomed in about twice, a text box lands where it is typed too.
        let scrollView = app.scrollViews["pageScrollView"].firstMatch
        scrollView.pinch(withScale: 2, velocity: 1)
        sleep(1)
        try typeTextBox("Zoomed\nin", at: scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45)),
                        endingAt: scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3)), in: app)
        attach(app, "textbox-zoomed")
        XCTAssertFalse(editor.exists)
    }

    /// The format bar over the keyboard: a box typed in, made two sizes larger and red there, is added
    /// so; Select's Format over it opens the sheet with those values, and Cancel leaves it.
    func testTextBoxFormatBarThenFormatFromTheMenu() throws {
        let app = launchAndOpen("sample.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let textBox = app.buttons["tool-textBox"]
        XCTAssertTrue(textBox.waitForEnabled(timeout: 5))
        textBox.tap()
        pagePoint(CGPoint(x: 100, y: 150), pageWidth: 612, in: app).tap()
        let editor = app.textViews["inlineTextEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "no box to type in")
        dismissKeyboardIntroduction(in: app)
        type("Formatted", into: editor)
        let larger = app.buttons["formatLargerButton"]
        XCTAssertTrue(larger.waitForExistence(timeout: 5), "no format bar over the keyboard")
        XCTAssertEqual(app.staticTexts["formatSizeValue"].value as? String, "14 pt", "Text Box's first size")
        larger.tap()
        larger.tap()
        XCTAssertEqual(app.staticTexts["formatSizeValue"].value as? String, "18 pt")
        app.buttons["formatColorMenu"].tap()
        let red = menuItem("Red", in: app)
        XCTAssertTrue(red.waitForExistence(timeout: 5), "no Red in the colour menu")
        attach(app, "textbox-format-colors")
        red.tap()
        XCTAssertTrue(editor.exists, "picking a colour ended the box")
        // More Colors… opens the system's picker over the page; the box waits for it, and takes the
        // keyboard back when it goes.
        app.buttons["formatColorMenu"].tap()
        let more = menuItem("More Colors…", in: app)
        XCTAssertTrue(more.waitForExistence(timeout: 5), "no More Colors…")
        more.tap()
        sleep(2)
        attach(app, "textbox-format-picker")
        XCTAssertTrue(editor.exists, "the colour picker ended the box")
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "close"])).firstMatch
        if close.exists {
            close.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        }
        XCTAssertTrue(larger.waitForExistence(timeout: 5), "the box did not take the keyboard back")
        XCTAssertTrue(editor.exists)
        attach(app, "textbox-format-bar")
        pagePoint(CGPoint(x: 400, y: 500), pageWidth: 612, in: app).tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "the box stayed")
        XCTAssertTrue(app.buttons["undoButton"].waitForEnabled(timeout: 5), "the text was not added")
        sleep(1)
        app.buttons["tool-select"].tap()
        pagePoint(CGPoint(x: 115, y: 160), pageWidth: 612, in: app).tap()
        let format = menuItem("Format", in: app)
        XCTAssertTrue(format.waitForExistence(timeout: 5), "the selected text box's menu offers no Format")
        format.tap()
        let stepper = app.steppers["formatSizeStepper"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 5), "no format sheet")
        XCTAssertEqual(stepper.label, "Font Size: 18 pt", "the sheet does not start from the box's size")
        XCTAssertTrue(app.buttons["formatColor-2"].isSelected, "the sheet does not start from the box's colour")
        XCTAssertFalse(app.buttons["formatApplyButton"].isEnabled, "Apply before anything changed")
        attach(app, "textbox-format-sheet")
        app.buttons["formatCancelButton"].tap()
        XCTAssertTrue(app.buttons["formatCancelButton"].waitForNonExistence(timeout: 5), "Cancel left the sheet")
    }

    /// Taps `at` with Text Box picked, types `text`, and taps `end` to add it: what was typed is drawn,
    /// once added, where it was typed (the dark pixels around it within a point).
    private func typeTextBox(_ text: String, at: XCUICoordinate, endingAt end: XCUICoordinate, in app: XCUIApplication) throws {
        at.tap()
        let editor = app.textViews["inlineTextEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "no box to type in")
        dismissKeyboardIntroduction(in: app)
        type(text, into: editor)
        XCTAssertTrue(app.buttons["doneDrawingButton"].waitForExistence(timeout: 5), "no Done while text waits")
        sleep(1)
        let area = editor.frame.insetBy(dx: -20, dy: -20)
        let typed = try XCTUnwrap(try darkBox(in: area, of: app), "nothing typed shows")
        attach(app, "textbox-typing")
        end.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "the box stayed")
        XCTAssertTrue(app.buttons["undoButton"].waitForEnabled(timeout: 5), "the text was not added")
        sleep(2)
        let added = try XCTUnwrap(try darkBox(in: area, of: app), "the text added does not show")
        for (a, b) in [(typed.minX, added.minX), (typed.minY, added.minY), (typed.maxX, added.maxX), (typed.maxY, added.maxY)] {
            XCTAssertEqual(a, b, accuracy: 1.5, "the text is not where it was typed: \(typed) then \(added)")
        }
    }

    /// The box, in screen points, of the dark pixels (text) in `area` of the screen; nil when there are none.
    private func darkBox(in area: CGRect, of app: XCUIApplication) throws -> CGRect? {
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: area.minX * scale, y: area.minY * scale,
                                                           width: area.width * scale, height: area.height * scale).integral))
        let width = crop.width, height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var box = CGRect.null
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) < 300 {
                    box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        guard !box.isNull else { return nil }
        return CGRect(x: area.minX + box.minX / scale, y: area.minY + box.minY / scale, width: box.width / scale, height: box.height / scale)
    }

    /// Text still being typed (no tap elsewhere, no Done) when the reader goes back to the documents is
    /// in the file: the document, opened again in a fresh launch of the app, shows it.
    func testTextLeftBeingTypedIsKeptWhenTheDocumentIsClosed() throws {
        let app = launchAndOpen("sample.pdf", as: "text-closed.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let textBox = app.buttons["tool-textBox"]
        XCTAssertTrue(textBox.waitForEnabled(timeout: 5))
        textBox.tap()
        pagePoint(CGPoint(x: 100, y: 300), pageWidth: 612, in: app).tap()
        let editor = app.textViews["inlineTextEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "no box to type in")
        dismissKeyboardIntroduction(in: app)
        type("Kept", into: editor)
        let back = app.navigationBars.buttons["BackButton"].exists ? app.navigationBars.buttons["BackButton"] : app.navigationBars.buttons.firstMatch
        back.tap()
        XCTAssertTrue(app.staticTexts["pageIndicator"].waitForNonExistence(timeout: 10), "the document did not close")
        sleep(2)

        // A fresh launch, without staging the sample again: the file as saved.
        app.terminate()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        openFromBrowser("text-closed.pdf", in: app)
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        sleep(2)
        XCTAssertTrue(try isInked(around: pagePoint(CGPoint(x: 112, y: 309), pageWidth: 612, in: app).screenPoint, in: app),
                      "the text left being typed was lost when the document closed")
        attach(app, "text-kept-after-close")
    }

    /// On a turned page Text Box is off, and the palette says why; the note saying so takes no touch:
    /// a rectangle dragged from under it is drawn (on a tablet, where it stands beside the tools over
    /// the page).
    func testTextBoxIsOffOnATurnedPageAndTheNoteDoesNotBlockThePage() throws {
        let app = launchAndOpen("rotated.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 1", within: 10)
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let rectangle = app.buttons["tool-rectangle"]
        XCTAssertTrue(rectangle.waitForEnabled(timeout: 5))
        XCTAssertFalse(app.buttons["tool-textBox"].isEnabled, "Text Box is on on a turned page")
        let note = app.staticTexts["textBoxNeedsUprightPage"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), "the palette does not say why")
        rectangle.tap()
        attach(app, "turned-page-palette")
        let scrollView = app.scrollViews["pageScrollView"].firstMatch
        // In the bottom bar (a compact width) the note is part of the bar; in the side palette (a
        // regular width), whose tools stand one below the other, it stands over the page beside them.
        guard app.buttons["tool-highlight"].frame.minY > app.buttons["tool-select"].frame.maxY - 1 else { return }
        XCTAssertLessThan(note.frame.height, 160, "the note is as tall as the tools")
        let start = scrollView.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: note.frame.midX - scrollView.frame.minX, dy: note.frame.midY - scrollView.frame.minY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 160, dy: 120)))
        XCTAssertTrue(app.buttons["undoButton"].waitForEnabled(timeout: 5), "a drag from under the note drew nothing")
        attach(app, "turned-page-drag-under-note")
    }

    /// Whether the screen around `point` (a 9-point square) has ink on it: any pixel well away from
    /// white.
    /// Underline, on a document with no marks yet, marks the line a finger drags across: Undo turns
    /// on, the line looks different, and Comments lists an underline.
    func testDraggingWithUnderlineMarksTheLineAndListsIt() throws {
        try markTheLine(with: "underline", listedAs: "Underline")
    }

    /// Strikethrough, on a document with no marks yet, marks the line a finger drags across, as
    /// Underline does.
    func testDraggingWithStrikethroughMarksTheLineAndListsIt() throws {
        try markTheLine(with: "strikeout", listedAs: "Strikethrough")
    }

    /// The owner's report (0.2.1, iPhone): Underline and Strikethrough "do not work". On a phone the
    /// selection's menu shows Copy and Highlight and keeps the other two behind its arrow; Underline,
    /// tapped in the palette while a word is selected, underlines that word.
    func testPickingUnderlineWithAWordSelectedUnderlinesIt() throws {
        try markTheLine(with: "underline", listedAs: "Underline", selectingFirst: true)
    }

    /// Strikethrough, tapped in the palette while a word is selected, strikes it through.
    func testPickingStrikethroughWithAWordSelectedStrikesItThrough() throws {
        try markTheLine(with: "strikeout", listedAs: "Strikethrough", selectingFirst: true)
    }

    /// Opens sample.pdf, picks `tool` and drags across the first line (or, `selectingFirst`, selects
    /// its first word with a long press under Select and then picks `tool`): Undo turns on, the pixels
    /// around the line change, and Comments lists one row reading `kind`.
    private func markTheLine(with tool: String, listedAs kind: String, selectingFirst: Bool = false) throws {
        let app = launchAndOpen("sample.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        let undo = app.buttons["undoButton"]
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let button = app.buttons["tool-\(tool)"]
        XCTAssertTrue(button.waitForEnabled(timeout: 5), "\(tool) is disabled on a document that allows markup")
        let line = textLine(in: app, page: app.scrollViews["pageScrollView"].firstMatch)
        // The line, from a little before it to a little after, a line's height above and below.
        let around = CGRect(x: line.start.screenPoint.x - 10, y: line.start.screenPoint.y - 14,
                            width: line.end.screenPoint.x - line.start.screenPoint.x + 20, height: 28)
        let before = try pixels(of: around, in: app)
        if selectingFirst {
            line.start.withOffset(CGVector(dx: 8, dy: 0)).press(forDuration: 1)
            XCTAssertTrue(app.menuItems["Highlight"].waitForExistence(timeout: 5), "the long press selected nothing")
            attach(app, "text-markup-\(tool)-selected")
            button.tap()
        } else {
            button.tap()
            line.start.press(forDuration: 0.05, thenDragTo: line.end)
        }
        XCTAssertTrue(undo.waitForEnabled(timeout: 5), "\(tool) marked nothing")
        sleep(1)
        attach(app, "text-markup-\(tool)\(selectingFirst ? "-picked" : "")")
        XCTAssertNotEqual(try pixels(of: around, in: app), before, "the \(tool) does not show on the page")
        XCTAssertTrue(tapToolbarButton("commentsButton", titled: "Comments", in: app), "no Comments button")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'commentRow-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "the \(tool) is not listed")
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows.firstMatch.label.contains(kind), "the row reads \"\(rows.firstMatch.label)\"")
        attach(app, "text-markup-\(tool)-listed")
    }

    /// The owner's report (0.2.2): a word underlined by picking Underline with it selected could not be
    /// un-underlined by selecting it again and picking Underline. Now that takes the underline off.
    func testPickingUnderlineOverAnUnderlinedWordTakesItOff() throws {
        try markTheWordThenTakeItOff(with: "underline", listedAs: "Underline")
    }

    /// Strikethrough picked over a struck-through word takes the strikethrough off.
    func testPickingStrikethroughOverAStruckWordTakesItOff() throws {
        try markTheWordThenTakeItOff(with: "strikeout", listedAs: "Strikethrough")
    }

    /// Highlight picked over a highlighted word takes the highlight off.
    func testPickingHighlightOverAHighlightedWordTakesItOff() throws {
        try markTheWordThenTakeItOff(with: "highlight", listedAs: "Highlight")
    }

    /// The selection's menu over a highlighted word offers Remove Highlight in place of Highlight, and it
    /// takes the highlight off.
    func testTheMenusRemoveHighlightTakesTheHighlightOff() throws {
        try markTheWordThenTakeItOff(with: "highlight", listedAs: "Highlight", throughTheMenu: true)
    }

    /// Opens sample.pdf, selects the first word of its first line under Select (a long press) and marks
    /// it with `tool` (the palette's button, or `throughTheMenu` the menu's item): the pixels around it
    /// change and Comments lists one row reading `kind`. Then selects the word again and picks `tool`
    /// again (or the menu's "Remove `kind`"): the pixels are as they were before the mark, Comments lists
    /// none, and Undo puts the mark back.
    private func markTheWordThenTakeItOff(with tool: String, listedAs kind: String, throughTheMenu: Bool = false) throws {
        let app = launchAndOpen("sample.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        let undo = app.buttons["undoButton"]
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let button = app.buttons["tool-\(tool)"]
        let select = app.buttons["tool-select"]
        XCTAssertTrue(button.waitForEnabled(timeout: 5), "\(tool) is disabled on a document that allows markup")
        let line = textLine(in: app, page: app.scrollViews["pageScrollView"].firstMatch)
        let around = CGRect(x: line.start.screenPoint.x - 10, y: line.start.screenPoint.y - 14,
                            width: line.end.screenPoint.x - line.start.screenPoint.x + 20, height: 28)
        let before = try pixels(of: around, in: app)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'commentRow-'"))
        /// Selects the word under Select; the menu comes up over it, offering `item`.
        func selectTheWord(offering item: String) {
            if !select.isSelected { select.tap() }
            line.start.withOffset(CGVector(dx: 8, dy: 0)).press(forDuration: 1)
            XCTAssertTrue(app.menuItems[item].waitForExistence(timeout: 5), "the menu does not offer \(item)")
        }

        selectTheWord(offering: throughTheMenu ? kind : "Copy")
        if throughTheMenu { app.menuItems[kind].tap() } else { button.tap() }
        XCTAssertTrue(undo.waitForEnabled(timeout: 5), "\(tool) marked nothing")
        sleep(1)
        let marked = try pixels(of: around, in: app)
        XCTAssertNotEqual(marked, before, "the \(tool) does not show on the page")
        XCTAssertTrue(tapToolbarButton("commentsButton", titled: "Comments", in: app), "no Comments button")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "the \(tool) is not listed")
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows.firstMatch.label.contains(kind), "the row reads \"\(rows.firstMatch.label)\"")
        app.buttons["commentsDoneButton"].tap()
        XCTAssertTrue(rows.firstMatch.waitForNonExistence(timeout: 5), "Done did not put the list away")

        selectTheWord(offering: throughTheMenu ? "Remove \(kind)" : "Copy")
        attach(app, "toggle-\(tool)-selected-again")
        if throughTheMenu { app.menuItems["Remove \(kind)"].tap() } else { button.tap() }
        let unmarked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (try? self.pixels(of: around, in: app)) == before }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [unmarked], timeout: 5), .completed, "the \(tool) still shows on the page")
        attach(app, "toggle-\(tool)-removed")
        XCTAssertTrue(tapToolbarButton("commentsButton", titled: "Comments", in: app), "no Comments button")
        XCTAssertTrue(app.staticTexts["No comments yet"].waitForExistence(timeout: 5), "the \(tool) is still listed")
        XCTAssertEqual(rows.count, 0)
        app.buttons["commentsDoneButton"].tap()
        XCTAssertTrue(tapToolbarButton("undoButton", titled: "Undo", in: app), "no Undo button")
        let back = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (try? self.pixels(of: around, in: app)) == marked }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [back], timeout: 5), .completed, "Undo did not put the \(tool) back")
    }

    /// A highlight dragged across "Page one" is listed in Comments, one row under its page; Done puts
    /// the list away, and after Undo the list says there are none.
    func testHighlightThenCommentsListThenUndo() {
        let app = launchAndOpen("sample.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        let undo = app.buttons["undoButton"]
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let highlight = app.buttons["tool-highlight"]
        XCTAssertTrue(highlight.waitForEnabled(timeout: 5), "Highlight is disabled on a document that allows markup")
        highlight.tap()
        let line = textLine(in: app, page: app.scrollViews["pageScrollView"].firstMatch)
        line.start.press(forDuration: 0.05, thenDragTo: line.end)
        XCTAssertTrue(undo.waitForEnabled(timeout: 5), "dragging with Highlight marked nothing")
        XCTAssertTrue(tapToolbarButton("commentsButton", titled: "Comments", in: app), "no Comments button")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'commentRow-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "the highlight is not listed")
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows.firstMatch.identifier.hasPrefix("commentRow-0-"), "listed on another page: \(rows.firstMatch.identifier)")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Page 1")).firstMatch.exists, "no heading for its page")
        XCTAssertTrue(rows.firstMatch.label.contains("Highlight"), "the row reads \"\(rows.firstMatch.label)\"")
        attach(app, "comments-list")
        app.buttons["commentsDoneButton"].tap()
        XCTAssertTrue(rows.firstMatch.waitForNonExistence(timeout: 5), "Done did not put the list away")
        XCTAssertTrue(tapToolbarButton("undoButton", titled: "Undo", in: app), "no Undo button")
        let undone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: undo)
        XCTAssertEqual(XCTWaiter().wait(for: [undone], timeout: 5), .completed, "Undo left something to undo")
        XCTAssertTrue(tapToolbarButton("commentsButton", titled: "Comments", in: app), "no Comments button")
        XCTAssertTrue(app.staticTexts["No comments yet"].waitForExistence(timeout: 5), "the list does not say it is empty")
        XCTAssertEqual(rows.count, 0)
        attach(app, "comments-empty")
    }

    /// Comment on a mark: a highlight dragged across "Page one", selected, gets a comment from its menu's
    /// Comment; the Comments list then leads its row with that comment, under the With Comments filter.
    func testCommentingOnAHighlightShowsInTheCommentsList() {
        let app = launchAndOpen("sample.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let highlight = app.buttons["tool-highlight"]
        XCTAssertTrue(highlight.waitForEnabled(timeout: 5))
        highlight.tap()
        let line = textLine(in: app, page: app.scrollViews["pageScrollView"].firstMatch)
        line.start.press(forDuration: 0.05, thenDragTo: line.end)
        XCTAssertTrue(app.buttons["undoButton"].waitForEnabled(timeout: 5), "dragging with Highlight marked nothing")
        sleep(1)
        app.buttons["tool-select"].tap()
        line.start.withOffset(CGVector(dx: 12, dy: 0)).tap()
        let comment = menuItem("Comment", in: app)
        XCTAssertTrue(comment.waitForExistence(timeout: 5), "the selected highlight's menu offers no Comment")
        attach(app, "comment-menu")
        comment.tap()
        let text = app.textViews["noteText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), "no comment sheet")
        XCTAssertTrue(app.navigationBars["Comment"].exists, "the sheet is not called Comment")
        dismissKeyboardIntroduction(in: app)
        type("Check this line", into: text)
        attach(app, "comment-sheet")
        app.buttons["noteSaveButton"].tap()
        XCTAssertTrue(text.waitForNonExistence(timeout: 5), "the sheet stayed")
        XCTAssertTrue(tapToolbarButton("commentsButton", titled: "Comments", in: app), "no Comments button")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'commentRow-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "nothing listed")
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows.firstMatch.label.hasPrefix("Check this line"), "the row reads \"\(rows.firstMatch.label)\"")
        XCTAssertTrue(rows.firstMatch.label.contains("Highlight on page 1"), "the row reads \"\(rows.firstMatch.label)\"")
        attach(app, "comments-list-with-comment")
        app.buttons["commentsDoneButton"].tap()
    }

    /// Add Comment in the Comments list: the list goes, the page says where to tap, and the tap puts a
    /// note there and opens its sheet; saved, it is listed.
    func testAddCommentFromTheListPlacesANote() {
        let app = launchAndOpen("sample.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        XCTAssertTrue(tapToolbarButton("commentsButton", titled: "Comments", in: app), "no Comments button")
        let add = app.buttons["addCommentButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "no Add Comment")
        attach(app, "comments-empty-add")
        add.tap()
        let hint = app.descendants(matching: .any)["addCommentHint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "no hint to tap where the comment goes")
        attach(app, "add-comment-hint")
        pagePoint(CGPoint(x: 400, y: 200), pageWidth: 612, in: app).tap()
        let text = app.textViews["noteText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), "the tap opened no note")
        XCTAssertFalse(hint.exists, "the hint stayed")
        dismissKeyboardIntroduction(in: app)
        type("A new comment", into: text)
        app.buttons["noteSaveButton"].tap()
        XCTAssertTrue(text.waitForNonExistence(timeout: 5), "the sheet stayed")
        XCTAssertTrue(tapToolbarButton("commentsButton", titled: "Comments", in: app), "no Comments button")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'commentRow-0-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "the note is not listed")
        XCTAssertTrue(rows.firstMatch.label.hasPrefix("A new comment"), "the row reads \"\(rows.firstMatch.label)\"")
        attach(app, "comments-list-added")
    }

    /// Sign: picked with no signature saved (the launch forgets any), it opens the pad, where one finger
    /// draws a made-up squiggle and Save keeps it. Each tap on the page then places it: two taps, two
    /// drawings in the Comments list, and one Undo takes the second back. Delete Signature, in the
    /// tool's menu, asks first, then forgets it: the next tap opens the pad again.
    func testSigningPlacesTheSavedSignatureWhereTapped() throws {
        let app = launchAndOpen("sample.pdf", arguments: ["-forgetSignature"])
        let indicator = app.staticTexts["pageIndicator"]
        expect(indicator, toRead: "1 / 3", within: 10)
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let sign = app.buttons["tool-signature"]
        XCTAssertTrue(sign.waitForEnabled(timeout: 5), "Sign is disabled on a document that allows markup")
        sign.tap()
        let canvas = app.descendants(matching: .any)["signatureCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5), "picking Sign with no signature saved did not open the pad")
        let save = app.buttons["signatureSaveButton"]
        XCTAssertTrue(save.exists, "the pad has no Save")
        XCTAssertFalse(save.isEnabled, "Save is on with nothing drawn")
        // Two strokes, one finger each.
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate { canvas.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)) }
        point(0.15, 0.65).press(forDuration: 0.05, thenDragTo: point(0.45, 0.3))
        point(0.45, 0.3).press(forDuration: 0.05, thenDragTo: point(0.85, 0.6))
        XCTAssertTrue(save.waitForEnabled(timeout: 5), "Save is still off after drawing")
        attach(app, "sign-pad")
        // On its side the pad is still there to sign on, with what was drawn. The screen turns a moment
        // after the device does (more than a second on a busy machine): waited for, ten seconds at most.
        XCUIDevice.shared.orientation = .landscapeLeft
        for _ in 0..<20 where app.frame.width <= app.frame.height || canvas.frame.width <= canvas.frame.height { usleep(500_000) }
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "the screen did not turn")
        XCTAssertTrue(canvas.isHittable, "the pad is not there on its side")
        XCTAssertGreaterThan(canvas.frame.width, canvas.frame.height, "on its side the pad is wider than it is high")
        XCTAssertTrue(save.isEnabled, "turning the phone lost the drawing")
        attach(app, "sign-pad-landscape")
        XCUIDevice.shared.orientation = .portrait
        for _ in 0..<20 where app.frame.width >= app.frame.height { usleep(500_000) }
        XCTAssertLessThan(app.frame.width, app.frame.height, "the screen did not turn upright again")
        save.tap()
        XCTAssertTrue(canvas.waitForNonExistence(timeout: 5), "Save did not put the pad away")

        let undo = app.buttons["undoButton"]
        pagePoint(CGPoint(x: 200, y: 300), pageWidth: 612, in: app).tap()
        XCTAssertTrue(undo.waitForEnabled(timeout: 5), "the first tap placed nothing")
        pagePoint(CGPoint(x: 400, y: 520), pageWidth: 612, in: app).tap()
        sleep(2)
        XCTAssertEqual(indicator.label, "1 / 3", "a tap moved the pages")
        XCTAssertFalse(canvas.exists, "a tap with a signature saved opened the pad")
        attach(app, "sign-placed")
        XCTAssertEqual(drawingsListed(in: app), 2, "two taps, two signatures")
        XCTAssertTrue(tapToolbarButton("undoButton", titled: "Undo", in: app), "no Undo button")
        sleep(1)
        XCTAssertEqual(drawingsListed(in: app), 1, "one Undo took back one signature")

        // Delete Signature asks first, then forgets the signature.
        let options = app.buttons["signatureMenuButton"]
        XCTAssertTrue(options.waitForExistence(timeout: 5), "Sign has no menu")
        options.tap()
        let delete = menuItem("Delete Signature", in: app)
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the menu offers no Delete Signature")
        delete.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "Delete Signature")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "deleting the signature was not confirmed first")
        attach(app, "sign-delete-confirm")
        confirm.tap()
        pagePoint(CGPoint(x: 300, y: 650), pageWidth: 612, in: app).tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5), "with the signature deleted, a tap did not open the pad")
        app.buttons["signatureCancelButton"].tap()
        XCTAssertTrue(canvas.waitForNonExistence(timeout: 5), "Cancel did not put the pad away")
        XCTAssertEqual(drawingsListed(in: app), 1, "deleting the saved signature took one off the page")
    }

    /// How many drawings the Comments list has: opened, counted, and put away.
    private func drawingsListed(in app: XCUIApplication) -> Int {
        XCTAssertTrue(tapToolbarButton("commentsButton", titled: "Comments", in: app), "no Comments button")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'commentRow-' AND label CONTAINS 'Drawing'"))
        _ = rows.firstMatch.waitForExistence(timeout: 5)
        let count = rows.count
        app.buttons["commentsDoneButton"].tap()
        _ = rows.firstMatch.waitForNonExistence(timeout: 5)
        return count
    }

    /// Select: a tap on a rectangle selects it (its menu offers Delete); one finger dragged from it
    /// moves it there, instead of scrolling; a tap and Delete take it off the page, and Undo brings it
    /// back.
    func testSelectingARectangleMovesItAndItsMenuDeletesIt() throws {
        let app = launchAndOpen("sample.pdf")
        let indicator = app.staticTexts["pageIndicator"]
        expect(indicator, toRead: "1 / 3", within: 10)
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let undo = app.buttons["undoButton"]
        let rectangle = app.buttons["tool-rectangle"]
        XCTAssertTrue(rectangle.waitForEnabled(timeout: 5))
        rectangle.tap()
        pagePoint(CGPoint(x: 150, y: 300), pageWidth: 612, in: app)
            .press(forDuration: 0.05, thenDragTo: pagePoint(CGPoint(x: 450, y: 420), pageWidth: 612, in: app))
        XCTAssertTrue(undo.waitForEnabled(timeout: 5), "no rectangle was added")
        sleep(1)
        let leftEdge = CGPoint(x: 151, y: 360), movedLeftEdge = CGPoint(x: 151, y: 460)
        XCTAssertTrue(try isInked(around: pagePoint(leftEdge, pageWidth: 612, in: app).screenPoint, in: app), "the rectangle is not there")
        app.buttons["tool-select"].tap()
        pagePoint(CGPoint(x: 300, y: 360), pageWidth: 612, in: app).tap()
        XCTAssertTrue(menuItem("Delete", in: app).waitForExistence(timeout: 5), "the selected rectangle's menu offers no Delete")
        attach(app, "select-menu")
        // Dragged 100 points down the page.
        pagePoint(CGPoint(x: 300, y: 360), pageWidth: 612, in: app)
            .press(forDuration: 0.05, thenDragTo: pagePoint(CGPoint(x: 300, y: 460), pageWidth: 612, in: app))
        sleep(2)
        XCTAssertEqual(indicator.label, "1 / 3", "the drag scrolled")
        XCTAssertFalse(try isInked(around: pagePoint(leftEdge, pageWidth: 612, in: app).screenPoint, in: app), "the rectangle stayed where it was")
        XCTAssertTrue(try isInked(around: pagePoint(movedLeftEdge, pageWidth: 612, in: app).screenPoint, in: app),
                      "the rectangle is not where it was dragged")
        attach(app, "select-moved")
        pagePoint(CGPoint(x: 300, y: 460), pageWidth: 612, in: app).tap()
        let delete = menuItem("Delete", in: app)
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "no Delete for the moved rectangle")
        delete.tap()
        sleep(2)
        XCTAssertFalse(try isInked(around: pagePoint(movedLeftEdge, pageWidth: 612, in: app).screenPoint, in: app), "Delete left the rectangle")
        undo.tap()
        sleep(2)
        XCTAssertTrue(try isInked(around: pagePoint(movedLeftEdge, pageWidth: 612, in: app).screenPoint, in: app),
                      "Undo did not bring the rectangle back")
    }

    /// `form.pdf`: the hint says how to fill the form in; a tap on the name field brings up its editor,
    /// "Ada" and Return fill it in, and a tap on the check box turns it on. Closed with Back and opened
    /// again, the field reads "Ada" and the box is checked (read off the widgets' accessibility values).
    func testFillAFormAndToggleACheckbox() {
        let app = launchAndOpen("form.pdf", as: "form-filled.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 1", within: 10)
        let hint = app.staticTexts["formHint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 10), "no hint over a form")
        hint.tap()
        XCTAssertTrue(hint.waitForNonExistence(timeout: 5), "a tap did not put the hint away")
        let name = app.buttons["formField-name-0"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "no overlay over the name field")
        XCTAssertEqual(name.value as? String, "")
        name.tap()
        let editor = app.textFields["formFieldEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "no editor for the name field")
        dismissKeyboardIntroduction(in: app)
        editor.typeText("Ada\n")
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "Return did not fill the field in")
        let agree = app.buttons["formField-agree-0"]
        XCTAssertEqual(agree.value as? String, "unchecked")
        agree.tap()
        expect(agree, toHaveValue: "checked", within: 5)
        expect(app.buttons["formField-name-0"], toHaveValue: "Ada", within: 5)
        XCTAssertTrue(app.buttons["undoButton"].isEnabled)
        attach(app, "form-filled")

        let back = app.navigationBars.buttons["BackButton"].exists ? app.navigationBars.buttons["BackButton"] : app.navigationBars.buttons.firstMatch
        back.tap()
        XCTAssertTrue(app.staticTexts["pageIndicator"].waitForNonExistence(timeout: 10), "the document did not close")
        sleep(2)
        // A fresh launch, without staging the form again: the file as saved.
        app.terminate()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        openFromBrowser("form-filled.pdf", in: app)
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 1", within: 10)
        expect(app.buttons["formField-name-0"], toHaveValue: "Ada", within: 10)
        expect(app.buttons["formField-agree-0"], toHaveValue: "checked", within: 5)
        attach(app, "form-reopened")
    }

    /// `form-kinds.pdf`: the field of several lines near the bottom of its page is scrolled clear of the
    /// keyboard while it is typed in, upright and on the device's side.
    func testTheKeyboardDoesNotCoverTheFieldBeingFilled() {
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let app = launchAndOpen("form-kinds.pdf")
            expect(app.staticTexts["pageIndicator"], toRead: "1 / 2", within: 10)
            let notes = app.buttons["formField-notes-0"]
            XCTAssertTrue(notes.waitForExistence(timeout: 10), "no overlay over the notes field")
            // On its side the field is below the screen: the pages are dragged up to it, a little at a
            // time, held at the end so they do not fly on.
            for _ in 0..<8 where notes.frame.midY > app.frame.maxY - 100 {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -120)),
                            withVelocity: .slow, thenHoldForDuration: 0.3)
            }
            XCTAssertTrue(notes.isHittable, "the notes field never came into view (\(orientation.rawValue))")
            notes.tap()
            let editor = app.textViews["formFieldEditor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 5), "no editor for the notes field")
            dismissKeyboardIntroduction(in: app)
            type("Line one\nLine two", into: editor)
            let keyboard = app.keyboards.firstMatch
            if keyboard.waitForExistence(timeout: 5) {
                sleep(1)
                XCTAssertLessThanOrEqual(editor.frame.maxY, keyboard.frame.minY + 1,
                                         "the keyboard covers the field being typed in (\(orientation.rawValue))")
                XCTAssertGreaterThanOrEqual(editor.frame.minY, app.navigationBars.firstMatch.frame.maxY - 1,
                                            "the field went under the navigation bar (\(orientation.rawValue))")
            }
            attach(app, "form-keyboard-\(orientation == .portrait ? "portrait" : "landscape")")
            app.terminate()
        }
    }

    /// `form.pdf`: text typed in a field and left there, the document closed with Back, is in the file.
    func testTextLeftInAFieldIsKeptWhenTheDocumentIsClosed() {
        let app = launchAndOpen("form.pdf", as: "form-closed.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 1", within: 10)
        let hint = app.staticTexts["formHint"]
        if hint.waitForExistence(timeout: 5) { hint.tap() }
        let name = app.buttons["formField-name-0"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "no overlay over the name field")
        name.tap()
        let editor = app.textFields["formFieldEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "no editor for the name field")
        dismissKeyboardIntroduction(in: app)
        type("Kept", into: editor)
        let back = app.navigationBars.buttons["BackButton"].exists ? app.navigationBars.buttons["BackButton"] : app.navigationBars.buttons.firstMatch
        back.tap()
        XCTAssertTrue(app.staticTexts["pageIndicator"].waitForNonExistence(timeout: 10), "the document did not close")
        sleep(2)
        app.terminate()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        openFromBrowser("form-closed.pdf", in: app)
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 1", within: 10)
        expect(app.buttons["formField-name-0"], toHaveValue: "Kept", within: 10)
    }

    /// `truncated-form.pdf`, a drop-down list of more options than are listed: the hint comes with the
    /// note that the form is too large to show in full.
    func testAFormListedShortSaysSo() {
        let app = launchAndOpen("truncated-form.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 1", within: 10)
        XCTAssertTrue(app.staticTexts["formHint"].waitForExistence(timeout: 10), "no hint over a form")
        let note = app.staticTexts["formTruncatedNote"]
        XCTAssertTrue(note.exists, "no note that the form is listed short")
        XCTAssertEqual(note.label, "This form is too large to show in full. Some fields or choices may be missing.")
        attach(app, "form-truncated-note")
    }

    /// A drop-down list's menu and a list box's sheet, as UIKit shows them. `form.pdf`: the colour is
    /// chosen from its menu at the widget. `form-kinds.pdf`: the city is chosen, then typed with Other…
    /// (the editor starts with the city chosen); two toppings are checked in the sheet, and Done fills
    /// the field once.
    func testChoosingFromAMenuAndFromASheet() {
        let app = launchAndOpen("form.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 1", within: 10)
        let hint = app.staticTexts["formHint"]
        if hint.waitForExistence(timeout: 5) { hint.tap() }
        let name = app.buttons["formField-name-0"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        let nameEditor = app.textFields["formFieldEditor"]
        XCTAssertTrue(nameEditor.waitForExistence(timeout: 5))
        dismissKeyboardIntroduction(in: app)
        nameEditor.typeText("Ada Lovelace\n")
        app.buttons["formField-agree-0"].tap()
        app.buttons["formField-size-1"].tap()
        expect(app.buttons["formField-size-1"], toHaveValue: "checked", within: 5)
        let color = app.buttons["formField-color-0"]
        color.tap()
        let green = menuItem("Green", in: app)
        XCTAssertTrue(green.waitForExistence(timeout: 5), "the menu does not offer Green")
        XCTAssertTrue(menuItem("Red", in: app).exists && menuItem("Blue", in: app).exists)
        attach(app, "form-menu")
        green.tap()
        expect(color, toHaveValue: "Green", within: 5)
        sleep(1)
        attach(app, "form-chosen")
        app.terminate()

        let kinds = launchAndOpen("form-kinds.pdf")
        expect(kinds.staticTexts["pageIndicator"], toRead: "1 / 2", within: 10)
        let kindsHint = kinds.staticTexts["formHint"]
        if kindsHint.waitForExistence(timeout: 5) { kindsHint.tap() }
        let city = kinds.buttons["formField-city-0"]
        XCTAssertTrue(city.waitForExistence(timeout: 10))
        city.tap()
        let rome = menuItem("Rome", in: kinds)
        XCTAssertTrue(rome.waitForExistence(timeout: 5), "the menu does not offer Rome")
        rome.tap()
        expect(city, toHaveValue: "Rome", within: 5)
        city.tap()
        let other = menuItem("Other…", in: kinds)
        XCTAssertTrue(other.waitForExistence(timeout: 5), "the menu does not offer Other…")
        other.tap()
        let editor = kinds.textFields["formFieldEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Other… brought up no editor")
        XCTAssertEqual(editor.value as? String, "Rome", "the editor starts with the city chosen")
        dismissKeyboardIntroduction(in: kinds)
        editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "Oslo\n")
        expect(city, toHaveValue: "Oslo", within: 5)

        let toppings = kinds.buttons["formField-toppings-0"]
        toppings.tap()
        let cheese = kinds.buttons["choiceOption-0"]
        XCTAssertTrue(cheese.waitForExistence(timeout: 5), "no sheet of options")
        cheese.tap()
        kinds.buttons["choiceOption-2"].tap()
        attach(kinds, "form-sheet")
        kinds.buttons["choiceDoneButton"].tap()
        XCTAssertTrue(cheese.waitForNonExistence(timeout: 5), "Done left the sheet")
        expect(toppings, toHaveValue: "Cheese and Peppers", within: 5)
        let undo = kinds.buttons["undoButton"]
        XCTAssertTrue(undo.isEnabled)
        sleep(1)
        attach(kinds, "form-kinds-filled")
    }

    /// Waits until `element`'s accessibility value is `value`.
    private func expect(_ element: XCUIElement, toHaveValue value: String, within seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        let has = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        let result = XCTWaiter().wait(for: [has], timeout: seconds)
        XCTAssertEqual(result, .completed, "\(element.identifier) holds \(String(describing: element.exists ? element.value : nil)), not \"\(value)\"", file: file, line: line)
    }

    /// An item of the edit menu titled `title`: the system shows them as menu items or as buttons.
    private func menuItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let types = [XCUIElement.ElementType.menuItem, .button].map { NSNumber(value: $0.rawValue) }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "elementType IN %@ AND label == %@", types, title)).firstMatch
    }

    // MARK: Undo and Redo

    /// After an edit, and a scroll down and back that brings the bar's background in and out, Undo and
    /// Redo are still in the bar, and can be tapped. (Alone at the bar's leading end they went missing:
    /// reported on a phone, and seen on the iPad simulator, not on the iPhone one. A name long enough
    /// to take a phone's bar puts them in the More menu now, with the other buttons.)
    func testUndoAndRedoStayAfterAnEditAndAScroll() throws {
        let app = launchAndOpen("sample.pdf")
        let indicator = app.staticTexts["pageIndicator"]
        expect(indicator, toRead: "1 / 3", within: 10)
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let ink = app.buttons["tool-ink"]
        XCTAssertTrue(ink.waitForEnabled(timeout: 5))
        ink.tap()
        pagePoint(CGPoint(x: 150, y: 300), pageWidth: 612, in: app)
            .press(forDuration: 0.05, thenDragTo: pagePoint(CGPoint(x: 450, y: 300), pageWidth: 612, in: app))
        let done = app.buttons["doneDrawingButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "nothing was drawn")
        done.tap()
        let undo = app.buttons["undoButton"], redo = app.buttons["redoButton"]
        XCTAssertTrue(undo.waitForEnabled(timeout: 5), "the drawing was not added")
        // Back to reading, where one finger scrolls.
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app))
        XCTAssertTrue(app.buttons["tool-ink"].waitForNonExistence(timeout: 5))
        for _ in 0..<2 { app.swipeUp() }
        for _ in 0..<2 { app.swipeDown() }
        sleep(1)
        attach(app, "undo-after-scroll")
        XCTAssertTrue(undo.exists, "Undo left the bar")
        XCTAssertTrue(undo.isHittable, "Undo is not where it can be tapped")
        XCTAssertTrue(redo.exists, "Redo left the bar")
        undo.tap()
        XCTAssertTrue(redo.waitForEnabled(timeout: 5), "Undo took nothing back")
    }

    /// ⇧⌘Z on a hardware keyboard (the Edit menu's Redo) redoes nothing while strokes wait to be added,
    /// as the toolbar's Redo is off then: it went to the scene's undo manager directly, and the strokes
    /// were then refused as stale and lost. Done adds them, with no alert. (With nothing waiting it
    /// redoes, as the toolbar's Redo does: so the keys are known to reach the app before it is seen
    /// that they do nothing.)
    func testTheKeyboardsRedoWaitsForTheStrokesWaiting() throws {
        let app = launchAndOpen("sample.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let ink = app.buttons["tool-ink"]
        XCTAssertTrue(ink.waitForEnabled(timeout: 5))
        ink.tap()
        let done = app.buttons["doneDrawingButton"], undo = app.buttons["undoButton"], redo = app.buttons["redoButton"]
        pagePoint(CGPoint(x: 150, y: 300), pageWidth: 612, in: app)
            .press(forDuration: 0.05, thenDragTo: pagePoint(CGPoint(x: 450, y: 300), pageWidth: 612, in: app))
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        XCTAssertTrue(undo.waitForEnabled(timeout: 5))
        undo.tap()
        XCTAssertTrue(redo.waitForEnabled(timeout: 5), "nothing to redo")
        XCTAssertTrue(press("z", modifiers: [.command, .shift], in: app, until: NSPredicate(format: "enabled == false"), holdsFor: redo),
                      "⇧⌘Z did not redo with nothing waiting")
        XCTAssertTrue(undo.waitForEnabled(timeout: 5))
        undo.tap()
        XCTAssertTrue(redo.waitForEnabled(timeout: 5), "nothing to redo")
        pagePoint(CGPoint(x: 150, y: 500), pageWidth: 612, in: app)
            .press(forDuration: 0.05, thenDragTo: pagePoint(CGPoint(x: 450, y: 500), pageWidth: 612, in: app))
        XCTAssertTrue(done.waitForExistence(timeout: 5), "nothing was drawn")
        XCTAssertFalse(redo.isEnabled, "Redo is off while strokes wait")
        app.typeKey("z", modifierFlags: [.command, .shift])
        sleep(2)
        XCTAssertTrue(done.exists, "the strokes are still waiting")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2), "the strokes were refused")
        sleep(2)
        XCTAssertTrue(try isInked(around: pagePoint(CGPoint(x: 300, y: 500), pageWidth: 612, in: app).screenPoint, in: app),
                      "the strokes were not added")
        XCTAssertFalse(try isInked(around: pagePoint(CGPoint(x: 300, y: 300), pageWidth: 612, in: app).screenPoint, in: app),
                       "the drawing undone came back")
    }

    /// ⌘Z while the search field is being typed in takes back the typing there, as it does in any
    /// field, not a change to the document.
    func testTheKeyboardsUndoInTheSearchFieldTakesBackTheTyping() throws {
        let app = launchAndOpen("sample.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        XCTAssertTrue(tapToolbarButton("markupButton", titled: "Markup", in: app), "no Markup button")
        let ink = app.buttons["tool-ink"]
        XCTAssertTrue(ink.waitForEnabled(timeout: 5))
        ink.tap()
        pagePoint(CGPoint(x: 150, y: 300), pageWidth: 612, in: app)
            .press(forDuration: 0.05, thenDragTo: pagePoint(CGPoint(x: 450, y: 300), pageWidth: 612, in: app))
        let done = app.buttons["doneDrawingButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        let undo = app.buttons["undoButton"]
        XCTAssertTrue(undo.waitForEnabled(timeout: 5), "the drawing was not added")
        XCTAssertTrue(tapToolbarButton("searchButton", titled: "Search", in: app), "no Search")
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        dismissKeyboardIntroduction(in: app)
        type("three", into: field)
        XCTAssertTrue(press("z", modifiers: .command, in: app, until: NSPredicate(format: "value != %@", "three"), holdsFor: field),
                      "⌘Z did not take back the typing")
        app.buttons["searchDoneButton"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(undo.waitForEnabled(timeout: 5), "⌘Z took back the drawing")
        sleep(1)
        XCTAssertTrue(try isInked(around: pagePoint(CGPoint(x: 300, y: 300), pageWidth: 612, in: app).screenPoint, in: app),
                      "⌘Z took back the drawing")
    }

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
