import XCTest

/// Saving end to end, on the simulator: nothing reaches the file but by Save; Back with unsaved changes
/// asks whether to Save, Save As or Discard them, or to stay; changes the app was stopped with are
/// offered again. The change each test makes is deleting the last of `sample.pdf`'s three pages, read
/// off the page indicator ("1 / 2"), here and once the file is opened again.
@MainActor
final class SavingSmokeTests: XCTestCase {
    /// With no change, Back closes at once, asking nothing.
    func testBackWithNoChangesClosesAtOnce() {
        let app = launchAndOpen("sample.pdf", as: "save-none.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        XCTAssertFalse(editedIndicator(in: app).exists, "an unchanged document says it was edited")
        tapBack(in: app)
        XCTAssertFalse(saveQuestion(in: app).waitForExistence(timeout: 2), "Back asked about an unchanged document")
        expectClosed(app)
    }

    /// A change shows "Edited"; Back asks, with Save, Save As…, Discard Changes and Cancel; Cancel stays in
    /// the document, changed.
    func testBackWithChangesAsksAndCancelStays() {
        let app = launchAndOpen("sample.pdf", as: "save-cancel.pdf")
        deleteTheLastPage(in: app)
        XCTAssertTrue(editedIndicator(in: app).waitForExistence(timeout: 5), "no sign of the unsaved change")
        tapBack(in: app)
        let question = saveQuestion(in: app)
        XCTAssertTrue(question.waitForExistence(timeout: 10), "Back asked nothing")
        XCTAssertEqual(question.label, "Save changes to “save-cancel”?")
        for title in ["Save", "Save As…", "Discard Changes", "Cancel"] {
            XCTAssertTrue(question.buttons[title].firstMatch.exists, "no \(title) in the question")
        }
        attach(app, "save-question")
        question.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(question.waitForNonExistence(timeout: 5))
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 2", within: 5)
        XCTAssertTrue(editedIndicator(in: app).exists, "still unsaved")
    }

    /// Discard closes, and the file is as it was: opened again, it has its three pages. Going to the
    /// background and back meanwhile wrote nothing either.
    func testDiscardLeavesTheFileAsItWas() {
        let app = launchAndOpen("sample.pdf", as: "save-discard.pdf")
        deleteTheLastPage(in: app)
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.activate()
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 2", within: 10)
        goBack(in: app, choosing: "Discard Changes")
        expectClosed(app)
        relaunchAndOpen("save-discard.pdf", in: app)
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2), "the discarded changes were offered again")
        XCTAssertFalse(editedIndicator(in: app).exists)
    }

    /// The question's Save writes the change and closes: opened again, the file has two pages, nothing to
    /// save, and Back closes at once.
    func testSaveFromTheQuestionKeepsTheChange() {
        let app = launchAndOpen("sample.pdf", as: "save-save.pdf")
        deleteTheLastPage(in: app)
        goBack(in: app, choosing: "Save")
        expectClosed(app)
        relaunchAndOpen("save-save.pdf", in: app)
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 2", within: 10)
        XCTAssertFalse(editedIndicator(in: app).exists, "a saved document says it was edited")
        tapBack(in: app)
        XCTAssertFalse(saveQuestion(in: app).waitForExistence(timeout: 2))
        expectClosed(app)
    }

    /// Save in the More menu writes the change and leaves the document open with nothing to save; ⌘S on a
    /// hardware keyboard does the same.
    func testSaveInTheMoreMenuAndCommandS() {
        let app = launchAndOpen("sample.pdf", as: "save-menu.pdf")
        deleteTheLastPage(in: app)
        XCTAssertTrue(tapToolbarButton("saveButton", titled: "Save", in: app), "no Save")
        XCTAssertTrue(editedIndicator(in: app).waitForNonExistence(timeout: 10), "Save left the change unsaved")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 2", within: 5)

        // Another change, saved with ⌘S.
        deleteTheLastPage(in: app, leaving: 1)
        XCTAssertTrue(editedIndicator(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(press("s", modifiers: .command, in: app, until: NSPredicate(format: "exists == false"), holdsFor: editedIndicator(in: app)),
                      "⌘S did not save")
        attach(app, "saved-with-command-s")
        tapBack(in: app)
        XCTAssertFalse(saveQuestion(in: app).waitForExistence(timeout: 2), "Back asked after a save")
        expectClosed(app)
        relaunchAndOpen("save-menu.pdf", in: app)
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 1", within: 10)
    }

    /// The question's Save As… puts up the exporter: cancelled, the document stays open and changed;
    /// exported, it closes, and the file is as it was while the copy has the change.
    func testSaveAsLeavesTheFileAsItWas() {
        // A name of its own for each run, so that no copy an earlier run saved is in the way (the iPad's
        // exporter then asks whether to replace it, and that question cannot be answered by the test).
        let name = "save-as-\(UUID().uuidString.prefix(8))"
        let app = launchAndOpen("sample.pdf", as: "\(name).pdf")
        deleteTheLastPage(in: app)
        goBack(in: app, choosing: "Save As…")
        XCTAssertTrue(waitForExporter(in: app), "no exporter")
        cancelExporter(in: app)
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 2", within: 10)
        XCTAssertTrue(editedIndicator(in: app).exists, "still unsaved after the exporter was cancelled")

        goBack(in: app, choosing: "Save As…")
        XCTAssertTrue(waitForExporter(in: app), "no exporter")
        attach(app, "save-as-exporter")
        confirmExporter(in: app)
        expectClosed(app)
        relaunchAndOpen("\(name).pdf", in: app)
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        tapBack(in: app)
        expectClosed(app)
        openFromBrowser("\(name) copy.pdf", in: app)
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 2", within: 10)
    }

    /// The app stopped with an unsaved change (no Back, no choice): opened again, the change is offered.
    /// Restored, it is back, still unsaved; discarded then, the file is as it was, and nothing is offered.
    func testUnsavedChangesAreOfferedAfterTheAppStopped() {
        let app = launchAndOpen("sample.pdf", as: "save-recover.pdf")
        deleteTheLastPage(in: app)
        sleep(7)   // the recovery copy is written a few seconds after the change
        relaunchAndOpen("save-recover.pdf", in: app)
        let offer = app.alerts["Restore unsaved changes?"]
        XCTAssertTrue(offer.waitForExistence(timeout: 10), "the unsaved change was not offered")
        attach(app, "restore-offer")
        offer.buttons["Restore"].firstMatch.tap()
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 2", within: 10)
        XCTAssertTrue(editedIndicator(in: app).waitForExistence(timeout: 5), "restored changes are unsaved")
        goBack(in: app, choosing: "Discard Changes")
        expectClosed(app)
        relaunchAndOpen("save-recover.pdf", in: app)
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2), "offered again after Discard")
    }

    /// Declined, the changes kept are gone: the file opens as it was, and nothing is offered the next time.
    func testDiscardingTheOfferedChanges() {
        let app = launchAndOpen("sample.pdf", as: "save-decline.pdf")
        deleteTheLastPage(in: app)
        sleep(7)
        relaunchAndOpen("save-decline.pdf", in: app)
        let offer = app.alerts["Restore unsaved changes?"]
        XCTAssertTrue(offer.waitForExistence(timeout: 10), "the unsaved change was not offered")
        offer.buttons["Discard"].firstMatch.tap()
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        XCTAssertFalse(editedIndicator(in: app).exists)
        relaunchAndOpen("save-decline.pdf", in: app)
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2), "offered again after it was declined")
    }

    /// Put away unanswered (the system's Cancel), the offer leaves the document as its file is and keeps
    /// the changes for the next time it opens.
    func testPuttingTheOfferAwayKeepsItForNextTime() {
        let app = launchAndOpen("sample.pdf", as: "save-later.pdf")
        deleteTheLastPage(in: app)
        sleep(7)
        relaunchAndOpen("save-later.pdf", in: app)
        let offer = app.alerts["Restore unsaved changes?"]
        XCTAssertTrue(offer.waitForExistence(timeout: 10), "the unsaved change was not offered")
        let cancel = offer.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.exists, "no way to put the offer away")
        cancel.tap()
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        tapBack(in: app)
        XCTAssertFalse(saveQuestion(in: app).waitForExistence(timeout: 2))
        expectClosed(app)
        openFromBrowser("save-later.pdf", in: app)
        XCTAssertTrue(offer.waitForExistence(timeout: 10), "not offered again")
        offer.buttons["Discard"].firstMatch.tap()
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
    }

    /// Text selected (the toolbar gains Copy, and SwiftUI sets the navigation bar again), then a change:
    /// "Edited" still shows, and Back still asks.
    func testWithTextSelectedBackStillAsks() {
        let app = launchAndOpen("sample.pdf", as: "save-selected.pdf")
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
        deleteTheLastPage(in: app)
        pagePoint(CGPoint(x: 82, y: 79), pageWidth: 612, in: app).press(forDuration: 1)
        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 5), "no text selected")
        XCTAssertTrue(editedIndicator(in: app).waitForExistence(timeout: 5), "\"Edited\" went with the selection")
        attach(app, "edited-with-selection")
        goBack(in: app, choosing: "Cancel")
        XCTAssertTrue(editedIndicator(in: app).waitForExistence(timeout: 5))
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 2", within: 5)
    }

    /// ⌘W (the File menu's Close) asks as Back does when there are unsaved changes, and closes at once when
    /// there are none.
    func testCommandWAsksAsBackDoes() {
        let app = launchAndOpen("sample.pdf", as: "save-command-w.pdf")
        deleteTheLastPage(in: app)
        XCTAssertTrue(press("w", modifiers: .command, in: app, until: NSPredicate(format: "exists == true"), holdsFor: saveQuestion(in: app)),
                      "⌘W asked nothing")
        saveQuestion(in: app).buttons["Cancel"].firstMatch.tap()
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 2", within: 5)
        XCTAssertTrue(tapToolbarButton("saveButton", titled: "Save", in: app), "no Save")
        XCTAssertTrue(editedIndicator(in: app).waitForNonExistence(timeout: 10))
        XCTAssertTrue(press("w", modifiers: .command, in: app, until: NSPredicate(format: "exists == false"), holdsFor: app.staticTexts["pageIndicator"]),
                      "⌘W did not close a saved document")
        XCTAssertFalse(saveQuestion(in: app).exists)
    }

    /// A write the system makes on its own (the scene's document made to look edited after Save, so that it
    /// saves as it closes) leaves the file as last saved: the change after Save, discarded, is not in it.
    func testTheSystemsOwnWriteLeavesTheFileAsLastSaved() {
        let app = launchAndOpen("sample.pdf", as: "save-system-write.pdf", arguments: ["-dirtySceneDocumentAfterSave"])
        deleteTheLastPage(in: app)
        XCTAssertTrue(tapToolbarButton("saveButton", titled: "Save", in: app), "no Save")
        XCTAssertTrue(editedIndicator(in: app).waitForNonExistence(timeout: 10), "Save left the change unsaved")
        deleteTheLastPage(in: app, leaving: 1)
        goBack(in: app, choosing: "Discard Changes")
        expectClosed(app)
        sleep(2)
        relaunchAndOpen("save-system-write.pdf", in: app)
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 2", within: 10)
    }

    /// Sent to the background, then stopped at once (no time for the few seconds' wait after a change): the
    /// change is offered when the document opens again, written as the app went to the background.
    func testUnsavedChangesAreKeptWhenStoppedInTheBackground() {
        let app = launchAndOpen("sample.pdf", as: "save-background.pdf")
        deleteTheLastPage(in: app)
        XCUIDevice.shared.press(.home)
        sleep(2)
        relaunchAndOpen("save-background.pdf", in: app)
        let offer = app.alerts["Restore unsaved changes?"]
        XCTAssertTrue(offer.waitForExistence(timeout: 10), "the change was not kept as the app went to the background")
        offer.buttons["Discard"].firstMatch.tap()
        expect(app.staticTexts["pageIndicator"], toRead: "1 / 3", within: 10)
    }

    // MARK: Helpers

    /// "Edited", under the document's name (iOS 26 and later: it may be read as part of the name's menu
    /// button) or beside the page indicator (before).
    private func editedIndicator(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Edited'")).firstMatch
    }

    /// Deletes the last page in Organize Pages, leaving `leaving` pages.
    private func deleteTheLastPage(in app: XCUIApplication, leaving: Int = 2, file: StaticString = #filePath, line: UInt = #line) {
        expect(app.staticTexts["pageIndicator"], toReadAPageOf: leaving + 1, within: 10, file: file, line: line)
        XCTAssertTrue(tapToolbarButton("organizeButton", titled: "Organize Pages", in: app), "no Organize button", file: file, line: line)
        let page = app.cells["organizePage-\(leaving)"]
        XCTAssertTrue(page.waitForExistence(timeout: 5), "the Organize grid did not come up", file: file, line: line)
        page.tap()
        app.buttons["organizeDelete"].tap()
        XCTAssertTrue(page.waitForNonExistence(timeout: 5), "the page was not deleted", file: file, line: line)
        app.buttons["organizeDone"].tap()
        expect(app.staticTexts["pageIndicator"], toReadAPageOf: leaving, within: 5, file: file, line: line)
    }

    /// Waits for the system's exporter (a document picker) to come up.
    private func waitForExporter(in app: XCUIApplication) -> Bool {
        let save = exporterConfirm(in: app)
        for _ in 0..<20 {
            if save.exists, save.isHittable { return true }
            usleep(500_000)
        }
        return false
    }

    /// The exporter's button that saves the copy where it shows (the app's folder, where the browser was
    /// left): "Save", or "Move" on some systems.
    private func exporterConfirm(in app: XCUIApplication) -> XCUIElement {
        // Not the toolbar's own Save, which a regular width shows in the bar beside it.
        app.buttons.matching(NSPredicate(format: "(label IN {'Save', 'Move', 'Export'} OR identifier IN {'Save', 'Move', 'Export'}) AND identifier != 'saveButton'")).firstMatch
    }

    /// Saves the copy with the exporter's button, and replaces the copy an earlier run of the test left
    /// there. A tap while the exporter is still settling (seen on the iPad's full-screen one) is lost: the
    /// button is tapped again while the exporter is still up, three times at most.
    ///
    /// The iPad's full-screen exporter does not always list its Save button (it is drawn at the trailing
    /// end of the exporter's navigation bar, and the accessibility tree leaves it out): it is tapped
    /// there then.
    private func confirmExporter(in app: XCUIApplication) {
        let save = exporterConfirm(in: app)
        let replace = app.buttons.matching(NSPredicate(format: "label == 'Replace'")).firstMatch
        let bar = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        let indicator = app.staticTexts["pageIndicator"]
        for _ in 0..<3 {
            if save.waitForExistence(timeout: 3), save.isHittable {
                save.tap()
            } else if bar.exists {
                bar.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -40, dy: 0)).tap()
            }
            if replace.waitForExistence(timeout: 3) { replace.tap() }
            if indicator.waitForNonExistence(timeout: 8) { return }
            attach(app, "save-as-exporter-still-up")
        }
    }

    /// Cancels the exporter: by its close button where a tap reaches one, otherwise by swiping it down.
    private func cancelExporter(in app: XCUIApplication) {
        let closers = app.buttons.matching(NSPredicate(format: "label IN {'Close', 'Cancel'} OR identifier IN {'Close', 'Cancel'}"))
        for _ in 0..<10 {
            if let closer = closers.allElementsBoundByIndex.first(where: { $0.isHittable }) {
                closer.tap()
                return
            }
            usleep(500_000)
        }
        app.swipeDown(velocity: .fast)
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
