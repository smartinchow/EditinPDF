import UIKit
import XCTest
@testable import EditinPDF

// The controller is main-actor isolated (it is UIKit), so these tests are too. The controller is
// never put in a window here: no safe-area insets, and its tiled layers never draw.
@MainActor
final class PageScrollViewControllerTests: XCTestCase {
    /// A document of `count` US Letter pages; at 400 points wide each page is 518 tall, so page `n`
    /// starts at `n * 530`.
    static func letterPages(_ count: Int) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        return renderer.pdfData { context in
            for page in 1...count {
                context.beginPage()
                ("Page \(page)" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
    }

    func makeController(pages: Int = 12, size: CGSize = CGSize(width: 400, height: 800)) -> (PageScrollViewController, DocumentModel) {
        let model = DocumentModel(bytes: Self.letterPages(pages))
        XCTAssertEqual(model.pageCount, pages)
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.layoutIfNeeded()
        return (controller, model)
    }

    func testOnlyTheVisiblePagesAndTwoEitherSideHaveViews() {
        let (controller, model) = makeController()
        // 0 ... 800 shows pages 0 and 1.
        XCTAssertEqual(controller.loadedPages, [0, 1, 2, 3])
        XCTAssertEqual(model.currentPage, 0)

        // 3180 ... 3980 shows pages 6 and 7; the views of pages 0 to 3 are gone.
        controller.scrollView.contentOffset = CGPoint(x: 0, y: 3_180)
        XCTAssertEqual(controller.loadedPages, [4, 5, 6, 7, 8, 9])
        XCTAssertEqual(controller.contentView.subviews.count, 6)
    }

    func testAPageViewThatScrollsAwayIsReleased() {
        // UIKit autoreleases a view while making it and moving it about, and the app's run loop
        // drains the pool after every event; the test drains its own around each step, or the
        // test's pool alone would keep the view (`leaks -traceTree` shows no other referrer).
        let (controller, _) = autoreleasepool { makeController() }
        weak var first: PageView?
        autoreleasepool {
            first = controller.pageView(for: 0)
            XCTAssertNotNil(first)
        }
        autoreleasepool {
            controller.scrollView.contentOffset = CGPoint(x: 0, y: 3_180)
        }
        XCTAssertNil(first)
    }

    func testTheControllerIsReleasedWithItsPageViews() {
        weak var released: PageScrollViewController?
        weak var page: PageView?
        autoreleasepool {
            let (controller, _) = makeController()
            released = controller
            page = controller.pageView(for: 0)
            XCTAssertNotNil(page)
        }
        // Nothing the controller made holds on to it: the scroll view's delegate is weak, and the
        // page views and their layers only hold the document.
        XCTAssertNil(released)
        XCTAssertNil(page)
    }

    func testPageViewsSitInTheLayout() throws {
        let (controller, _) = makeController()
        let view = try XCTUnwrap(controller.pageView(for: 1))
        XCTAssertEqual(view.frame, CGRect(x: 0, y: 530, width: 400, height: 518))
        XCTAssertEqual(view.page, 1)
        XCTAssertEqual(view.pointSize, CGSize(width: 612, height: 792))
        XCTAssertEqual(controller.scrollView.contentSize, CGSize(width: 400, height: 12 * 518 + 11 * 12))
    }

    func testTheCurrentPageIsThePageAtTheCentreOfTheView() {
        let (controller, model) = makeController()
        // The centre is at 400 + offset.
        controller.scrollView.contentOffset = CGPoint(x: 0, y: 3_180)       // 3580: page 6
        XCTAssertEqual(model.currentPage, 6)
        controller.scrollView.contentOffset = CGPoint(x: 0, y: 3_250)       // 3650: still page 6
        XCTAssertEqual(model.currentPage, 6)
        controller.scrollView.contentOffset = CGPoint(x: 0, y: 3_310)       // 3710: page 7
        XCTAssertEqual(model.currentPage, 7)
        controller.scrollView.contentOffset = CGPoint(x: 0, y: 3_302)       // 3702: the gap, page 7 stays
        XCTAssertEqual(model.currentPage, 7)
    }

    func testZoomingKeepsTheCentrePage() {
        let (controller, model) = makeController()
        XCTAssertEqual(controller.scrollView.minimumZoomScale, 1)
        XCTAssertEqual(controller.scrollView.maximumZoomScale, 8)
        controller.scrollView.zoomScale = 4
        // At zoom 4 the 800-point view shows 200 layout points, here 2150 ... 2350: page 4 alone
        // (2120 ... 2638), with its centre at 2250.
        controller.scrollView.contentOffset = CGPoint(x: 0, y: 4 * 2_150)
        XCTAssertEqual(model.currentPage, 4)
        XCTAssertEqual(controller.loadedPages, [2, 3, 4, 5, 6])
    }

    func testAScrollTargetBringsItsPageToTheTop() {
        let (controller, model) = makeController()
        controller.scroll(to: 10)
        XCTAssertEqual(controller.scrollView.contentOffset.y, 5_300)
        XCTAssertEqual(model.currentPage, 10)
        // The last page cannot reach the top: the view stops at the end of the document.
        controller.scroll(to: 11)
        XCTAssertEqual(controller.scrollView.contentOffset.y, controller.scrollView.contentSize.height - 800)
        // A page the document does not have changes nothing.
        controller.scroll(to: 12)
        XCTAssertEqual(controller.scrollView.contentOffset.y, controller.scrollView.contentSize.height - 800)
    }

    func testAScrollTargetSetBeforeTheFirstLayoutIsKept() {
        let model = DocumentModel(bytes: Self.letterPages(12))
        let controller = PageScrollViewController(model: model)
        controller.scroll(to: 5)
        controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.scrollView.contentOffset.y, 2_650)
        XCTAssertEqual(model.currentPage, 5)
    }

    func testANewWidthLaysThePagesOutAgainAtTheSamePlace() throws {
        let (controller, model) = makeController()
        controller.scroll(to: 6)
        controller.view.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        controller.view.layoutIfNeeded()
        // At 600 wide a page is 776 tall and starts every 788 points.
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 6)).frame, CGRect(x: 0, y: 6 * 788, width: 600, height: 776))
        XCTAssertEqual(controller.scrollView.contentOffset.y, 6 * 788)
        XCTAssertEqual(model.currentPage, 6)
    }
}
