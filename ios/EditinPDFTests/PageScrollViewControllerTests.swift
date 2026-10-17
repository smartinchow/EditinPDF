import UIKit
import XCTest
@testable import EditinPDF

// The controller is main-actor isolated (it is UIKit), so these tests are too. The controller is
// never put in a window here: no safe-area insets, and its tiled layers never draw.
@MainActor
final class PageScrollViewControllerTests: XCTestCase {
    /// A document of `count` US Letter pages; at 400 points wide each page is 518 tall, so page `n`
    /// starts at `n * 530`. Turned to `landscape`, a page is 309 tall and page `n` starts at `n * 321`.
    static func letterPages(_ count: Int, landscape: Bool = false) -> Data {
        let size = landscape ? CGSize(width: 792, height: 612) : CGSize(width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        return renderer.pdfData { context in
            for page in 1...count {
                context.beginPage()
                ("Page \(page)" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
    }

    func makeController(pages: Int = 12, landscape: Bool = false,
                        size: CGSize = CGSize(width: 400, height: 800)) -> (PageScrollViewController, DocumentModel) {
        let model = DocumentModel(bytes: Self.letterPages(pages, landscape: landscape))
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

    func testShortPagesAreCurrentAtTheEndsOfTheDocument() {
        // Ten landscape pages, 3198 points in all, so the 800-point view ends at offset 2398. A page
        // (309) is shorter than half the view, so the first and the last never reach its centre.
        let (controller, model) = makeController(pages: 10, landscape: true)
        // On open the centre (400) is on page 1, but the reader is on page 0, at the top.
        XCTAssertEqual(controller.scrollView.contentOffset.y, 0)
        XCTAssertEqual(model.currentPage, 0)
        // In between, the page at the centre: 1000 + 400 = 1400 is on page 4 (1284 ... 1593).
        controller.scrollView.contentOffset = CGPoint(x: 0, y: 1_000)
        XCTAssertEqual(model.currentPage, 4)
        // At the end the centre (2798) is on page 8, but the reader is on the last page.
        controller.scroll(to: 9)
        XCTAssertEqual(controller.scrollView.contentOffset.y, 2_398)
        XCTAssertEqual(model.currentPage, 9)
        // Zoomed in, the ends still count: back at the top it is page 0 again.
        controller.scrollView.zoomScale = 2
        controller.scrollView.contentOffset = .zero
        XCTAssertEqual(model.currentPage, 0)
    }

    func testADocumentThatFitsInTheViewIsOnItsFirstPage() {
        // Two landscape pages (630 points) fit in the 800-point view: it is at both ends at once, and
        // the reader is on the first page. So is the reader of a single page.
        let (_, two) = makeController(pages: 2, landscape: true)
        XCTAssertEqual(two.currentPage, 0)
        let (_, one) = makeController(pages: 1)
        XCTAssertEqual(one.currentPage, 0)
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

    // MARK: Revealing a box (a search hit): the page's top is not always where the hit is

    /// `count` pages of `size` PDF points, each with some text near its top.
    static func pages(_ count: Int, size: CGSize) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        return renderer.pdfData { context in
            for page in 1...count {
                context.beginPage()
                ("Page \(page)" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
    }

    /// A controller over `count` pages 612 points wide and `height` tall, in a view `size` big: at 400 wide
    /// a page is 400 / 612 layout points to a PDF point, so one 3,000 points tall is 1,961 layout points.
    func makeTallController(count: Int = 1, height: CGFloat = 3_000,
                            size: CGSize = CGSize(width: 400, height: 800)) -> (PageScrollViewController, DocumentModel) {
        let model = DocumentModel(bytes: Self.pages(count, size: CGSize(width: 612, height: height)))
        XCTAssertEqual(model.pageCount, count)
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.layoutIfNeeded()
        return (controller, model)
    }

    /// The part of the content in view, in layout points at zoom 1: what the bars and the zoom leave.
    func inView(_ controller: PageScrollViewController) -> CGRect {
        let scrollView = controller.scrollView
        return scrollView.convert(scrollView.bounds.inset(by: scrollView.adjustedContentInset), to: controller.contentView)
    }

    /// A box on a 612-point-wide page fitted to 400 points, as the layout draws it, with the page at `top`.
    func fitted(_ box: CGRect, top: CGFloat = 0, scale: CGFloat = 400.0 / 612.0) -> CGRect {
        CGRect(x: box.minX * scale, y: top + box.minY * scale, width: box.width * scale, height: box.height * scale)
    }

    /// The box is near the bottom of a page three times as tall as the view: the page's top does not show it.
    func testARevealedBoxNearTheBottomOfATallPageComesIntoView() {
        let (controller, _) = makeTallController()
        let box = CGRect(x: 100, y: 2_800, width: 80, height: 20)
        controller.scroll(to: 0)
        XCTAssertFalse(inView(controller).intersects(fitted(box)), "the page's top is far from it")

        // What the representable does for a hit: jump to the page, then reveal.
        controller.reveal(PageRect(page: 0, rect: box))
        XCTAssertTrue(inView(controller).contains(fitted(box)), "\(inView(controller)) should contain \(fitted(box))")
        // It is near the end of the page, so the view stops at the end of the document and cannot centre it.
        XCTAssertEqual(controller.scrollView.contentOffset.y, controller.scrollView.contentSize.height - 800)
    }

    func testARevealedBoxThatFitsIsInTheMiddleOfTheView() {
        let (controller, _) = makeTallController()
        let box = CGRect(x: 100, y: 1_500, width: 80, height: 20)
        controller.reveal(PageRect(page: 0, rect: box))
        let shown = fitted(box)
        XCTAssertTrue(inView(controller).contains(shown))
        XCTAssertEqual(inView(controller).midY, shown.midY, accuracy: 0.5, "centred up and down")
        XCTAssertEqual(controller.scrollView.contentOffset.y, shown.midY - 400, accuracy: 0.5)
        XCTAssertEqual(controller.scrollView.contentOffset.x, 0, "nothing to scroll across at zoom 1")
    }

    func testARevealedBoxAlreadyInViewDoesNotMoveTheView() {
        let (controller, _) = makeTallController()
        controller.scrollView.contentOffset = CGPoint(x: 0, y: 600)
        // 600 ... 1,400 is in view; this box is at 800 ... 850 in layout points.
        let box = CGRect(x: 100, y: 1_240, width: 80, height: 20)
        XCTAssertTrue(inView(controller).contains(fitted(box)))
        controller.reveal(PageRect(page: 0, rect: box))
        XCTAssertEqual(controller.scrollView.contentOffset, CGPoint(x: 0, y: 600))
    }

    /// Zoomed in 4 times the view shows 100 x 200 layout points, and the box is not at the page's corner.
    func testARevealedBoxComesIntoViewWhenZoomedIn() {
        let (controller, _) = makeTallController()
        controller.scrollView.zoomScale = 4
        controller.scroll(to: 0)
        let box = CGRect(x: 400, y: 1_500, width: 80, height: 20)
        XCTAssertFalse(inView(controller).intersects(fitted(box)))
        controller.reveal(PageRect(page: 0, rect: box))
        let shown = fitted(box)
        XCTAssertEqual(inView(controller).width, 100, accuracy: 0.001)
        XCTAssertEqual(inView(controller).height, 200, accuracy: 0.001)
        XCTAssertTrue(inView(controller).contains(shown), "\(inView(controller)) should contain \(shown)")
        XCTAssertEqual(inView(controller).midX, shown.midX, accuracy: 0.5, "centred across")
        XCTAssertEqual(inView(controller).midY, shown.midY, accuracy: 0.5, "and up and down")
    }

    func testARevealedBoxNearTheRightEdgeOfAZoomedPageStopsAtTheEdge() {
        let (controller, _) = makeTallController()
        controller.scrollView.zoomScale = 4
        let box = CGRect(x: 560, y: 1_500, width: 40, height: 20)
        controller.reveal(PageRect(page: 0, rect: box))
        let shown = fitted(box)
        XCTAssertTrue(inView(controller).contains(shown))
        XCTAssertEqual(inView(controller).maxX, 400, accuracy: 0.001, "the page's right edge; centring would go past it")
    }

    /// A box larger than the view cannot be centred: the view starts at its top and left edges.
    func testARevealedBoxLargerThanTheViewStartsAtItsTopLeftEdge() {
        let (controller, _) = makeTallController()
        controller.scrollView.zoomScale = 4
        // 500 x 400 points is about 327 x 261 layout points; the view shows 100 x 200.
        let box = CGRect(x: 100, y: 1_000, width: 500, height: 400)
        controller.reveal(PageRect(page: 0, rect: box))
        let shown = fitted(box)
        XCTAssertEqual(inView(controller).minX, shown.minX, accuracy: 0.5)
        XCTAssertEqual(inView(controller).minY, shown.minY, accuracy: 0.5)
    }

    /// The bars cover the top and bottom of the view: the box lands in what they leave, not under them.
    func testARevealedBoxLandsBetweenTheBars() {
        let (controller, _) = makeTallController()
        controller.scrollView.contentInset = UIEdgeInsets(top: 60, left: 0, bottom: 40, right: 0)
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.scrollView.adjustedContentInset.top, 60)
        let box = CGRect(x: 100, y: 1_500, width: 80, height: 20)
        controller.reveal(PageRect(page: 0, rect: box))
        let shown = fitted(box)
        // 700 points are in view: 60 below the top, 40 above the bottom.
        XCTAssertEqual(inView(controller).height, 700)
        XCTAssertTrue(inView(controller).contains(shown))
        XCTAssertEqual(inView(controller).midY, shown.midY, accuracy: 0.5)
        XCTAssertEqual(controller.scrollView.contentOffset.y, shown.midY - 60 - 350, accuracy: 0.5)
    }

    func testARevealedBoxOnALaterPageUsesThatPagesPlace() {
        let (controller, _) = makeTallController(count: 3)
        // Pages 1,961 tall, 12 apart: page 2 starts at 3,946.
        let box = CGRect(x: 100, y: 1_000, width: 80, height: 20)
        controller.reveal(PageRect(page: 2, rect: box))
        XCTAssertTrue(inView(controller).contains(fitted(box, top: 2 * (1_961 + 12))))
    }

    /// Each page is fitted to the width on its own: a box on a narrow page is magnified more.
    func testARevealedBoxIsScaledByItsOwnPage() {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage(withBounds: CGRect(x: 0, y: 0, width: 612, height: 792), pageInfo: [:])
            context.beginPage(withBounds: CGRect(x: 0, y: 0, width: 306, height: 396), pageInfo: [:])
        }
        let model = DocumentModel(bytes: data)
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        controller.view.layoutIfNeeded()
        // Page 1 is 400 / 306 times its size, and starts at 518 + 12. The page's own scale puts the box
        // near the end of the document (928 of 1,048), the first page's would put it 200 points higher.
        let box = CGRect(x: 100, y: 300, width: 50, height: 10)
        controller.reveal(PageRect(page: 1, rect: box))
        let scale = 400.0 / 306.0
        XCTAssertTrue(inView(controller).contains(fitted(box, top: 530, scale: scale)))
    }

    func testRevealingNothingOrAPageThatIsNotThereDoesNothing() {
        let (controller, _) = makeTallController()
        controller.scrollView.contentOffset = CGPoint(x: 0, y: 300)
        let box = CGRect(x: 100, y: 2_800, width: 80, height: 20)
        for target in [PageRect(page: 1, rect: box), PageRect(page: -1, rect: box), PageRect(page: 0, rect: .null),
                       PageRect(page: 0, rect: CGRect(x: CGFloat.nan, y: 2_800, width: 80, height: 20)),
                       PageRect(page: 0, rect: CGRect(x: 100, y: CGFloat.infinity, width: 80, height: 20))] {
            controller.reveal(target)
            XCTAssertEqual(controller.scrollView.contentOffset, CGPoint(x: 0, y: 300), "\(target)")
        }
    }

    /// A box asked for before the view has a width waits for the first layout, as a page does.
    func testARevealedBoxAskedForBeforeTheFirstLayoutIsShownAfterIt() {
        let model = DocumentModel(bytes: Self.pages(1, size: CGSize(width: 612, height: 3_000)))
        let controller = PageScrollViewController(model: model)
        let box = CGRect(x: 100, y: 1_500, width: 80, height: 20)
        controller.scroll(to: 0)
        controller.reveal(PageRect(page: 0, rect: box))
        controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        controller.view.layoutIfNeeded()
        XCTAssertTrue(inView(controller).contains(fitted(box)))
        XCTAssertEqual(inView(controller).midY, fitted(box).midY, accuracy: 0.5)
    }

    /// The page views are made for what is in view afterwards, so the box's page has its view.
    func testTheViewOfARevealedBoxsPageExistsAfterwards() throws {
        let (controller, model) = makeTallController(count: 3)
        controller.reveal(PageRect(page: 2, rect: CGRect(x: 100, y: 1_000, width: 80, height: 20)))
        XCTAssertNotNil(controller.pageView(for: 2))
        XCTAssertEqual(model.currentPage, 2)
    }
}
