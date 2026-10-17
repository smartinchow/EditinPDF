import XCTest
@testable import EditinPDF

final class StringsTests: XCTestCase {
    func testTheTitleOfTheFailureIsOurSentence() {
        XCTAssertEqual(Strings.fileCouldNotBeOpened, "This file could not be opened.")
        XCTAssertFalse(Strings.fileCouldNotBeOpened.localizedCaseInsensitiveContains("damaged"))
    }

    func testEngineWordingIsKeptAsTheDetailUnderOurTitle() {
        XCTAssertEqual(Strings.fileCouldNotBeOpenedDetail("Cross-reference table not found."), "Cross-reference table not found.")
    }

    func testEngineWordingBecomesASentence() {
        // The engine words its errors as fragments: lower case, no full stop.
        XCTAssertEqual(Strings.fileCouldNotBeOpenedDetail("the file is not a readable PDF: no page tree was found"),
                       "The file is not a readable PDF: no page tree was found.")
    }

    func testEngineWordingKeepsItsOwnPunctuation() {
        XCTAssertEqual(Strings.fileCouldNotBeOpenedDetail("Unsupported feature?"), "Unsupported feature?")
        XCTAssertEqual(Strings.fileCouldNotBeOpenedDetail("Stop!"), "Stop!")
    }

    func testNoEngineWordingLeavesNoDetail() {
        XCTAssertNil(Strings.fileCouldNotBeOpenedDetail(""))
        XCTAssertNil(Strings.fileCouldNotBeOpenedDetail(" \n"))
    }

    func testEngineWordingIsTrimmed() {
        XCTAssertEqual(Strings.fileCouldNotBeOpenedDetail("  bad header.\n"), "Bad header.")
    }

    func testPasswordWording() {
        XCTAssertEqual(Strings.passwordTitle, "Password Required")
        XCTAssertEqual(Strings.passwordExplanation, "This document is protected. Enter the password to open it.")
        XCTAssertEqual(Strings.passwordPlaceholder, "Password")
        XCTAssertEqual(Strings.wrongPassword, "Wrong password")
        XCTAssertEqual(Strings.unlock, "Unlock")
        XCTAssertEqual(Strings.cancel, "Cancel")
        XCTAssertEqual(Strings.enterPassword, "Enter Password")
        XCTAssertEqual(Strings.close, "Close")
    }

    func testPageIndicatorIsThePageOverTheCount() {
        XCTAssertEqual(Strings.pageIndicator(current: 3, count: 12), "3 / 12")
        XCTAssertEqual(Strings.pageIndicator(current: 1, count: 1), "1 / 1")
        // Below a thousand, so the region's digit grouping does not come into it.
        XCTAssertEqual(Strings.pageIndicator(current: 120, count: 999), "120 / 999")
    }

    func testThumbnailWording() {
        XCTAssertEqual(Strings.thumbnails, "Thumbnails")
        XCTAssertEqual(Strings.thumbnailLabel(page: 3), "Page 3")
        XCTAssertEqual(Strings.pageNumber(3), "3")
        XCTAssertEqual(Strings.pageNumber(120), "120")
        XCTAssertEqual(Strings.done, "Done")
    }

    func testSearchWording() {
        XCTAssertEqual(Strings.search, "Search")
        XCTAssertEqual(Strings.searchPlaceholder, "Search")
        XCTAssertEqual(Strings.searchHitPage(3), "Page 3")
        XCTAssertEqual(Strings.searchHitLabel(page: 3, snippet: "Page three is here"), "Page 3: Page three is here")
        XCTAssertEqual(Strings.searchNoMatches, "No matches found")
        XCTAssertEqual(Strings.searchPrevious, "Previous match")
        XCTAssertEqual(Strings.searchNext, "Next match")
        XCTAssertEqual(Strings.searchEnd, "End search")
    }

    func testSearchPositionIsTheHitOverTheCount() {
        XCTAssertEqual(Strings.searchPosition(current: 3, count: 12), "3 of 12")
        XCTAssertEqual(Strings.searchPosition(current: 1, count: 1), "1 of 1")
    }

    /// When a search stopped at its limit, the count is a floor: "1 of 1,000+", the numbers written the
    /// way the reader's region writes them (as this test writes them, so it holds in any region).
    func testATruncatedSearchPositionSaysThereMayBeMore() {
        XCTAssertEqual(Strings.searchPositionTruncated(current: 1, count: 1_000), "1 of \(1_000.formatted())+")
        XCTAssertEqual(Strings.searchPositionTruncated(current: 1_000, count: 1_000), "\(1_000.formatted()) of \(1_000.formatted())+")
        XCTAssertEqual(Strings.searchPositionTruncated(current: 7, count: 50), "7 of 50+")
    }

    func testSelectionWording() {
        XCTAssertEqual(Strings.copy, "Copy")
        XCTAssertEqual(Strings.selectionStart, "Start of selection")
        XCTAssertEqual(Strings.selectionEnd, "End of selection")
    }

    /// The limit is the engine's, so the note says whatever number it is given, written the way the
    /// reader's region writes it (this test writes it the same way, so it holds in any region).
    func testTheTruncationNoteNamesTheLimit() {
        XCTAssertEqual(Strings.searchTruncated(limit: 1_000), "Showing the first \(1_000.formatted()) matches")
        XCTAssertEqual(Strings.searchTruncated(limit: 50), "Showing the first 50 matches")
    }
}
