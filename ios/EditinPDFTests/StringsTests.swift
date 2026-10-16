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
}
