import CoreGraphics
import EditinPDFCore
import XCTest
@testable import EditinPDF

final class PageLayoutTests: XCTestCase {
    let pages = [PageInfo(index: 0, widthPt: 612, heightPt: 792, rotationDegrees: 0, label: nil),
                 PageInfo(index: 1, widthPt: 792, heightPt: 612, rotationDegrees: 90, label: nil)]

    func testFramesStackVerticallyAndFitWidth() {
        let l = PageLayout(pages: pages, fitWidth: 306, gap: 10)
        XCTAssertEqual(l.frame(of: 0), CGRect(x: 0, y: 0, width: 306, height: 396))
        XCTAssertEqual(l.frame(of: 1).minY, 406)                  // 396 + gap
        XCTAssertEqual(l.frame(of: 1).width, 306)                  // landscape page also fit to width
        XCTAssertEqual(l.contentSize.height, 406 + 306 * 612 / 792, accuracy: 0.5)
    }

    func testVisibleAndHitTest() {
        let l = PageLayout(pages: pages, fitWidth: 306, gap: 10)
        XCTAssertEqual(l.visiblePages(in: CGRect(x: 0, y: 390, width: 306, height: 20)), 0..<2)
        XCTAssertEqual(l.page(at: CGPoint(x: 10, y: 500)), 1)
        XCTAssertNil(l.page(at: CGPoint(x: 10, y: 399)))           // in the gap
    }

    // MARK: Beyond the brief's two tests

    func testContentIsTheFitWidthWideWithNoGapAboveOrBelow() {
        let l = PageLayout(pages: pages, fitWidth: 306, gap: 10)
        XCTAssertEqual(l.contentSize.width, 306)
        XCTAssertEqual(l.frame(of: 0).minY, 0)
        XCTAssertEqual(l.contentSize.height, l.frame(of: 1).maxY)
        XCTAssertEqual(l.pageCount, 2)
    }

    func testTheDefaultGapIsTwelvePoints() {
        let l = PageLayout(pages: pages, fitWidth: 306)
        XCTAssertEqual(l.frame(of: 1).minY, l.frame(of: 0).maxY + 12)
    }

    func testPagesStartOnWholePoints() {
        // 400 x 792 / 612 = 517.6: heights are rounded so that every later page starts on a whole
        // point, which keeps page edges on device pixels at zoom 1.
        let letter = PageInfo(index: 0, widthPt: 612, heightPt: 792, rotationDegrees: 0, label: nil)
        let l = PageLayout(pages: Array(repeating: letter, count: 5), fitWidth: 400)
        for page in 0..<5 {
            XCTAssertEqual(l.frame(of: page).minY, l.frame(of: page).minY.rounded())
            XCTAssertEqual(l.frame(of: page).height, 518)
        }
    }

    func testScalePerPointIsLayoutPointsPerPDFPoint() {
        let l = PageLayout(pages: pages, fitWidth: 306, gap: 10)
        XCTAssertEqual(l.scalePerPoint, 0.5)                       // 306 / 612, the first page's
        XCTAssertEqual(l.scale(of: 0), 0.5)
        XCTAssertEqual(l.scale(of: 1), 306 / 792, accuracy: 1e-12) // every page is fitted to the width
    }

    func testVisiblePagesOutsideAndBetweenThePages() {
        let l = PageLayout(pages: pages, fitWidth: 306, gap: 10)
        XCTAssertEqual(l.visiblePages(in: CGRect(x: 0, y: 0, width: 306, height: 100)), 0..<1)
        XCTAssertEqual(l.visiblePages(in: CGRect(x: 0, y: 500, width: 306, height: 900)), 1..<2)
        XCTAssertTrue(l.visiblePages(in: CGRect(x: 0, y: 397, width: 306, height: 5)).isEmpty)   // only the gap
        XCTAssertTrue(l.visiblePages(in: CGRect(x: 0, y: -200, width: 306, height: 100)).isEmpty) // above the first
        XCTAssertTrue(l.visiblePages(in: CGRect(x: 0, y: 2000, width: 306, height: 100)).isEmpty) // below the last
        XCTAssertTrue(l.visiblePages(in: .null).isEmpty)
    }

    func testHitTestingStaysOnThePages() {
        let l = PageLayout(pages: pages, fitWidth: 306, gap: 10)
        XCTAssertEqual(l.page(at: CGPoint(x: 0, y: 0)), 0)
        XCTAssertEqual(l.page(at: CGPoint(x: 305, y: 395)), 0)
        XCTAssertEqual(l.page(at: CGPoint(x: 0, y: 406)), 1)
        XCTAssertNil(l.page(at: CGPoint(x: 306, y: 100)))          // right of the page
        XCTAssertNil(l.page(at: CGPoint(x: -1, y: 100)))           // left of the page
        XCTAssertNil(l.page(at: CGPoint(x: 10, y: -1)))            // above the first
        XCTAssertNil(l.page(at: CGPoint(x: 10, y: 10_000)))        // below the last
    }

    func testFindsPagesInALongDocument() {
        let letter = PageInfo(index: 0, widthPt: 612, heightPt: 792, rotationDegrees: 0, label: nil)
        let l = PageLayout(pages: Array(repeating: letter, count: 10_000), fitWidth: 306, gap: 10)
        // Each page is 396 tall and starts 406 below the one before it.
        XCTAssertEqual(l.frame(of: 7_321).minY, 7_321 * 406)
        XCTAssertEqual(l.page(at: CGPoint(x: 1, y: 7_321 * 406 + 1)), 7_321)
        XCTAssertEqual(l.visiblePages(in: CGRect(x: 0, y: 7_321 * 406 + 390, width: 306, height: 20)), 7_321..<7_323)
    }

    func testNoPagesIsAnEmptyLayout() {
        let l = PageLayout(pages: [], fitWidth: 306)
        XCTAssertEqual(l.contentSize, CGSize(width: 306, height: 0))
        XCTAssertTrue(l.visiblePages(in: CGRect(x: 0, y: 0, width: 306, height: 500)).isEmpty)
        XCTAssertNil(l.page(at: .zero))
        XCTAssertEqual(l.frame(of: 0), .zero)
    }

    func testAPageTheLayoutDoesNotHaveHasNoFrame() {
        let l = PageLayout(pages: pages, fitWidth: 306)
        XCTAssertEqual(l.frame(of: 2), .zero)
        XCTAssertEqual(l.frame(of: -1), .zero)
    }

    func testAPageWithoutAUsableSizeStillTakesItsPlace() {
        // A page box the engine reports as empty must not break the column: it gets the shape of a
        // Letter page instead of an infinite or zero height.
        let odd = [PageInfo(index: 0, widthPt: 0, heightPt: 0, rotationDegrees: 0, label: nil),
                   PageInfo(index: 1, widthPt: 612, heightPt: 792, rotationDegrees: 0, label: nil)]
        let l = PageLayout(pages: odd, fitWidth: 306, gap: 10)
        XCTAssertEqual(l.frame(of: 0), CGRect(x: 0, y: 0, width: 306, height: 396))
        XCTAssertEqual(l.frame(of: 1).minY, 406)
        XCTAssertTrue(l.contentSize.height.isFinite)
    }
}
