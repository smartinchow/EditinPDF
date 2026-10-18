import CoreGraphics
import EditinPDFCore
import XCTest
@testable import EditinPDF

/// Where the reader is, across a new width: the pure part of the relayout that keeps the page.
final class ReadingPositionTests: XCTestCase {
    /// `count` US Letter pages.
    func letter(_ count: Int) -> [PageInfo] {
        Array(repeating: PageInfo(index: 0, widthPt: 612, heightPt: 792, rotationDegrees: 0, label: nil), count: count)
    }

    func testThePageAndHowFarDownAndAcrossAreKept() throws {
        // 400 wide: pages 518 tall, every 530 points.
        let narrow = PageLayout(pages: letter(10), fitWidth: 400)
        let visible = CGRect(x: 100, y: 3 * 530 + 259, width: 100, height: 200)
        let position = try XCTUnwrap(ReadingPosition(visibleArea: visible, zoom: 4, in: narrow))
        XCTAssertEqual(position.page, 3)
        XCTAssertEqual(position.fractionDown, 0.5, accuracy: 0.0001)
        XCTAssertEqual(position.fractionAcross, 0.25, accuracy: 0.0001)
        XCTAssertEqual(position.zoom, 4)

        // 800 wide: pages 1035 tall, every 1047 points.
        let wide = PageLayout(pages: letter(10), fitWidth: 800)
        let point = position.topLeft(in: wide)
        XCTAssertEqual(point.x, 200, accuracy: 0.0001)
        XCTAssertEqual(point.y, 3 * 1_047 + 1_035.0 / 2, accuracy: 0.0001)
    }

    func testATopInTheGapCountsAsTheTopOfThePageBelow() throws {
        let layout = PageLayout(pages: letter(4), fitWidth: 400)
        let position = try XCTUnwrap(ReadingPosition(visibleArea: CGRect(x: 0, y: 524, width: 400, height: 800), zoom: 1, in: layout))
        XCTAssertEqual(position.page, 1)
        XCTAssertEqual(position.fractionDown, 0)
    }

    func testAboveTheFirstPageAndBelowTheLastStayOnThem() throws {
        let layout = PageLayout(pages: letter(2), fitWidth: 400)
        let above = try XCTUnwrap(ReadingPosition(visibleArea: CGRect(x: -20, y: -50, width: 400, height: 800), zoom: 1, in: layout))
        XCTAssertEqual(above.page, 0)
        XCTAssertEqual(above.fractionDown, 0)
        XCTAssertEqual(above.fractionAcross, 0, "a left edge in the inset is the column's edge")
        let below = try XCTUnwrap(ReadingPosition(visibleArea: CGRect(x: 0, y: 5_000, width: 400, height: 800), zoom: 1, in: layout))
        XCTAssertEqual(below.page, 1)
        XCTAssertEqual(below.fractionDown, 1)
    }

    func testNoPagesOrNoWidthHaveNoPosition() {
        XCTAssertNil(ReadingPosition(visibleArea: CGRect(x: 0, y: 0, width: 10, height: 10), zoom: 1,
                                     in: PageLayout(pages: [], fitWidth: 400)))
        XCTAssertNil(ReadingPosition(visibleArea: CGRect(x: 0, y: 0, width: 10, height: 10), zoom: 1,
                                     in: PageLayout(pages: letter(2), fitWidth: 0)))
        XCTAssertNil(ReadingPosition(visibleArea: .null, zoom: 1, in: PageLayout(pages: letter(2), fitWidth: 400)))
    }

    func testAZoomThatIsNotANumberIsOne() throws {
        let layout = PageLayout(pages: letter(2), fitWidth: 400)
        let position = try XCTUnwrap(ReadingPosition(visibleArea: CGRect(x: 0, y: 0, width: 10, height: 10), zoom: .nan, in: layout))
        XCTAssertEqual(position.zoom, 1)
    }

    func testAPageTheNewLayoutLacksGoesToTheTop() {
        let position = ReadingPosition(page: 7, fractionDown: 0.5, fractionAcross: 0, zoom: 1)
        XCTAssertEqual(position.topLeft(in: PageLayout(pages: letter(2), fitWidth: 400)), .zero)
    }
}
