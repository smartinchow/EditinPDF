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
}
