import XCTest
@testable import EditinPDF

final class StringsTests: XCTestCase {
    func testEngineWordingFollowsOurSentence() {
        XCTAssertEqual(Strings.fileCouldNotBeOpened(detail: "Cross-reference table not found."),
                       "This file could not be opened. Cross-reference table not found.")
    }

    func testEngineWordingBecomesASentence() {
        // The engine words its errors as fragments: lower case, no full stop.
        XCTAssertEqual(Strings.fileCouldNotBeOpened(detail: "the file is not a readable PDF: no page tree was found"),
                       "This file could not be opened. The file is not a readable PDF: no page tree was found.")
    }

    func testEngineWordingKeepsItsOwnPunctuation() {
        XCTAssertEqual(Strings.fileCouldNotBeOpened(detail: "Unsupported feature?"), "This file could not be opened. Unsupported feature?")
        XCTAssertEqual(Strings.fileCouldNotBeOpened(detail: "Stop!"), "This file could not be opened. Stop!")
    }

    func testNoEngineWordingLeavesJustOurSentence() {
        XCTAssertEqual(Strings.fileCouldNotBeOpened(detail: ""), "This file could not be opened.")
        XCTAssertEqual(Strings.fileCouldNotBeOpened(detail: " \n"), "This file could not be opened.")
    }

    func testEngineWordingIsTrimmed() {
        XCTAssertEqual(Strings.fileCouldNotBeOpened(detail: "  bad header.\n"), "This file could not be opened. Bad header.")
    }

    func testPageCountPlaceholder() {
        XCTAssertEqual(Strings.pageCount(1), "1 pages")
        XCTAssertEqual(Strings.pageCount(12), "12 pages")
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
