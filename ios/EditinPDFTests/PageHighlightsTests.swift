import UIKit
import XCTest
@testable import EditinPDF

// Highlights through the scroll view controller: they reach the page views that exist, and every
// page view made later, so they survive pages being dropped as they scroll away. The controller is
// never put in a window, as in `PageScrollViewControllerTests`.
@MainActor
final class PageHighlightsTests: XCTestCase {
    /// `pages` US Letter pages in a 400 x 800 view: page `n` starts at `n * 530`, 518 tall.
    func makeController(pages: Int = 12) -> (PageScrollViewController, DocumentModel) {
        let model = DocumentModel(bytes: PageScrollViewControllerTests.letterPages(pages))
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        controller.view.layoutIfNeeded()
        return (controller, model)
    }

    let box = CGRect(x: 72, y: 72, width: 100, height: 24)

    func testEveryPageViewHasAnOverlayTheSizeOfThePage() throws {
        let (controller, _) = makeController()
        XCTAssertEqual(controller.loadedPages, [0, 1, 2, 3])
        for page in controller.loadedPages {
            let view = try XCTUnwrap(controller.pageView(for: page))
            XCTAssertTrue(view.overlay.superview === view, "page \(page): the overlay is a subview of the page view")
            XCTAssertEqual(view.overlay.frame, view.bounds, "page \(page)")
            XCTAssertEqual(view.overlay.pointSize, view.pointSize)
            XCTAssertTrue(view.subviews.last === view.overlay, "above the tiles")
        }
    }

    func testHighlightsReachThePageViewsThatExist() throws {
        let (controller, _) = makeController()
        controller.highlightsByPage = [0: [box], 2: [box, box.offsetBy(dx: 0, dy: 100)], 9: [box]]
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 0)).overlay.highlights, [box])
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 1)).overlay.highlights, [])
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 2)).overlay.highlights, [box, box.offsetBy(dx: 0, dy: 100)])
        XCTAssertNil(controller.pageView(for: 9), "page 9 has no view yet")

        controller.highlightsByPage = [:]
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 0)).overlay.highlights, [])
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 2)).overlay.highlights, [])
    }

    /// The window of page views moves with the reader, and a page that comes back gets a new view:
    /// it has to have its highlights again, and a page that is new to the window gets its own.
    func testHighlightsSurviveAPageViewBeingDroppedAndMadeAgain() throws {
        let (controller, _) = makeController()
        controller.highlightsByPage = [0: [box], 9: [box.offsetBy(dx: 5, dy: 5)]]
        controller.activeHighlight = ActiveHighlight(page: 0, rects: [box])

        // 4_770 ... 5_570 shows pages 9 and 10: pages 0 to 3 are gone.
        controller.scrollView.contentOffset = CGPoint(x: 0, y: 4_770)
        XCTAssertNil(controller.pageView(for: 0))
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 9)).overlay.highlights, [box.offsetBy(dx: 5, dy: 5)],
                       "a page that comes into the window is given its highlights")
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 9)).overlay.activeHighlights, [])

        controller.scrollView.contentOffset = .zero
        let back = try XCTUnwrap(controller.pageView(for: 0))
        XCTAssertEqual(back.overlay.highlights, [box], "the new view of page 0 has its highlights again")
        XCTAssertEqual(back.overlay.activeHighlights, [box], "and the active one")
    }

    func testTheActiveHighlightReachesOnlyItsPage() throws {
        let (controller, _) = makeController()
        let boxes = [box, box.offsetBy(dx: 0, dy: 30)]
        controller.highlightsByPage = [1: boxes]
        controller.activeHighlight = ActiveHighlight(page: 1, rects: boxes)
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 1)).overlay.activeHighlights, boxes, "every box of the hit, not only the first")
        for page in [0, 2, 3] {
            XCTAssertEqual(try XCTUnwrap(controller.pageView(for: page)).overlay.activeHighlights, [], "page \(page)")
        }

        // Moving to another hit moves it.
        controller.activeHighlight = ActiveHighlight(page: 2, rects: [box])
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 1)).overlay.activeHighlights, [])
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 2)).overlay.activeHighlights, [box])

        controller.activeHighlight = nil
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 2)).overlay.activeHighlights, [])
    }

    /// Re-laying the pages out (a new width) makes every page view again, and they come with their
    /// highlights.
    func testHighlightsSurviveARelayout() throws {
        let (controller, _) = makeController()
        controller.highlightsByPage = [0: [box]]
        let before = try XCTUnwrap(controller.pageView(for: 0))
        controller.view.frame = CGRect(x: 0, y: 0, width: 300, height: 800)
        controller.view.layoutIfNeeded()
        let after = try XCTUnwrap(controller.pageView(for: 0))
        XCTAssertFalse(before === after, "the layout made the view again")
        XCTAssertEqual(after.overlay.highlights, [box])
        XCTAssertEqual(after.overlay.frame, after.bounds)
    }

    /// Each page is fitted to the width on its own, so a narrow page is magnified more than a wide
    /// one; the overlay scales its boxes by its own page's width, so a box lands on the same place
    /// of the page whatever the page's size.
    func testBoxesAreScaledByTheirOwnPagesWidth() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage(withBounds: CGRect(x: 0, y: 0, width: 612, height: 792), pageInfo: [:])
            context.beginPage(withBounds: CGRect(x: 0, y: 0, width: 306, height: 396), pageInfo: [:])
        }
        let model = DocumentModel(bytes: data)
        XCTAssertEqual(model.pageCount, 2)
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 1_200)
        controller.view.layoutIfNeeded()
        let wide = try XCTUnwrap(controller.pageView(for: 0)).overlay
        let narrow = try XCTUnwrap(controller.pageView(for: 1)).overlay
        // The same box, 50 points across: 400/612 layout points to a PDF point on the first page, twice that on the second.
        wide.highlights = [CGRect(x: 100, y: 100, width: 50, height: 10)]
        narrow.highlights = [CGRect(x: 100, y: 100, width: 50, height: 10)]
        XCTAssertEqual(try XCTUnwrap(wide.highlightLayer.path).boundingBoxOfPath.width, 50 * 400 / 612, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(narrow.highlightLayer.path).boundingBoxOfPath.width, 50 * 400 / 306, accuracy: 0.001)
    }
}
