import EditinPDFCore
import UIKit
import XCTest
@testable import EditinPDF

// Text selection through the scroll view controller: what is selected reaches the page views that
// exist and every one made later, the handles stand at its ends at every zoom, and what the gestures
// do is done (the touches themselves are for the simulator: here the gestures' handlers are called
// the way the recognizers call them). The controller is never put in a window, as in
// `PageScrollViewControllerTests`, so the menu cannot come up; the handlers still run.
@MainActor
final class PageSelectionTests: XCTestCase {
    /// `pages` US Letter pages in a 400 x 800 view: page `n` starts at `n * 530`, 518 tall, and a PDF
    /// point is `400 / 612` layout points. Each page says "Page n" at its top left, in 24-point type.
    func makeController(pages: Int = 12, size: CGSize = CGSize(width: 400, height: 800)) -> (PageScrollViewController, DocumentModel) {
        let model = DocumentModel(bytes: PageScrollViewControllerTests.letterPages(pages))
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.layoutIfNeeded()
        return (controller, model)
    }

    let scale: CGFloat = 400.0 / 612.0
    let box = CGRect(x: 72, y: 72, width: 100, height: 24)

    /// The centre of glyph `index` of `page`, in PDF points.
    func glyphCentre(_ index: Int, page: Int, in model: DocumentModel) throws -> CGPoint {
        let glyphs = try XCTUnwrap(model.document()).pageText(page: UInt32(page)).glyphs
        let glyph = try XCTUnwrap(glyphs.indices.contains(index) ? glyphs[index] : nil)
        return CGPoint(x: glyph.rect.x + glyph.rect.width / 2, y: glyph.rect.y + glyph.rect.height / 2)
    }

    /// Where `point` (PDF points on `page`) is in the content view: layout points at zoom 1, 400 across.
    func contentPoint(_ point: CGPoint, page: Int) -> CGPoint {
        CGPoint(x: point.x * scale, y: CGFloat(page) * 530 + point.y * scale)
    }

    /// What a long press on glyph `index` of `page` does, and the hand-over to the view that SwiftUI makes.
    func select(glyph index: Int, page: Int, controller: PageScrollViewController, model: DocumentModel) async throws {
        let point = contentPoint(try glyphCentre(index, page: page, in: model), page: page)
        controller.selectionInteraction.beginWord(atContentPoint: point)
        await model.selection?.waitUntilSettled()
        controller.selection = model.selection?.pageRects
    }

    // MARK: The boxes reach the page views

    func testTheSelectionReachesTheOverlayOfItsPageOnly() throws {
        let (controller, _) = makeController()
        XCTAssertEqual(controller.loadedPages, [0, 1, 2, 3])
        controller.selection = (page: 1, rects: [box])
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 1)).overlay.selection, [box])
        for page in [0, 2, 3] {
            XCTAssertEqual(try XCTUnwrap(controller.pageView(for: page)).overlay.selection, [], "page \(page)")
        }
    }

    func testClearingTheSelectionClearsTheOverlay() throws {
        let (controller, _) = makeController()
        controller.selection = (page: 0, rects: [box])
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 0)).overlay.selection, [box])
        controller.selection = nil
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 0)).overlay.selection, [])
    }

    func testMovingTheSelectionToAnotherPageMovesTheBoxes() throws {
        let (controller, _) = makeController()
        controller.selection = (page: 0, rects: [box])
        controller.selection = (page: 2, rects: [box, box.offsetBy(dx: 0, dy: 30)])
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 0)).overlay.selection, [])
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 2)).overlay.selection, [box, box.offsetBy(dx: 0, dy: 30)])
    }

    /// The window of page views moves with the reader, and a page that comes back gets a new view: it has
    /// to have its selection again, and a page that is new to the window gets its own.
    func testTheSelectionSurvivesAPageViewBeingDroppedAndMadeAgain() throws {
        let (controller, _) = makeController()
        controller.selection = (page: 0, rects: [box])

        // 4_770 ... 5_570 shows pages 9 and 10: pages 0 to 3 are gone.
        controller.scrollView.contentOffset = CGPoint(x: 0, y: 4_770)
        XCTAssertNil(controller.pageView(for: 0))
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 9)).overlay.selection, [], "page 9 has none")

        controller.scrollView.contentOffset = .zero
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 0)).overlay.selection, [box],
                       "the new view of page 0 has the selection again")
    }

    func testASelectionOnAPageThatComesIntoTheWindowIsDrawnWhenItGetsItsView() throws {
        let (controller, _) = makeController()
        controller.selection = (page: 9, rects: [box])
        XCTAssertNil(controller.pageView(for: 9), "page 9 has no view yet")
        controller.scrollView.contentOffset = CGPoint(x: 0, y: 4_770)
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 9)).overlay.selection, [box])
    }

    func testTheSelectionSurvivesARelayout() throws {
        let (controller, _) = makeController()
        controller.selection = (page: 0, rects: [box])
        let before = try XCTUnwrap(controller.pageView(for: 0))
        controller.view.frame = CGRect(x: 0, y: 0, width: 300, height: 800)
        controller.view.layoutIfNeeded()
        let after = try XCTUnwrap(controller.pageView(for: 0))
        XCTAssertFalse(before === after, "the layout made the view again")
        XCTAssertEqual(after.overlay.selection, [box])
    }

    func testTheOverlayStillTakesNoTouches() throws {
        let (controller, _) = makeController()
        XCTAssertFalse(try XCTUnwrap(controller.pageView(for: 0)).overlay.isUserInteractionEnabled,
                       "touches are for the scroll view and the selection's gestures, not for the overlay")
    }

    // MARK: The handles

    func testThereAreNoHandlesToSeeWithoutASelection() {
        let (controller, _) = makeController()
        let interaction = controller.selectionInteraction
        XCTAssertTrue(interaction.startHandle.isHidden)
        XCTAssertTrue(interaction.endHandle.isHidden)
        controller.selection = (page: 0, rects: [box])
        XCTAssertFalse(interaction.startHandle.isHidden)
        XCTAssertFalse(interaction.endHandle.isHidden)
        controller.selection = nil
        XCTAssertTrue(interaction.startHandle.isHidden)
        XCTAssertTrue(interaction.endHandle.isHidden)
    }

    func testTheHandlesAreNamedForUITestsAndVoiceOver() {
        let (controller, _) = makeController()
        let interaction = controller.selectionInteraction
        XCTAssertEqual(interaction.startHandle.accessibilityIdentifier, "selectionHandleStart")
        XCTAssertEqual(interaction.endHandle.accessibilityIdentifier, "selectionHandleEnd")
        XCTAssertTrue(interaction.startHandle.isAccessibilityElement)
        XCTAssertTrue(interaction.endHandle.isAccessibilityElement)
        XCTAssertEqual(interaction.startHandle.accessibilityLabel, Strings.selectionStart)
        XCTAssertEqual(interaction.endHandle.accessibilityLabel, Strings.selectionEnd)
    }

    /// Above the pages, beside them in the scroll view rather than inside the zooming view.
    func testTheHandlesAreAboveThePageViewsInTheScrollView() {
        let (controller, _) = makeController()
        let interaction = controller.selectionInteraction
        let subviews = controller.scrollView.subviews
        XCTAssertTrue(interaction.startHandle.superview === controller.scrollView)
        XCTAssertTrue(interaction.endHandle.superview === controller.scrollView)
        let content = subviews.firstIndex(of: controller.contentView)
        XCTAssertNotNil(content)
        for handle in [interaction.startHandle, interaction.endHandle] {
            let index = subviews.firstIndex(of: handle)
            XCTAssertNotNil(index)
            XCTAssertGreaterThan(index ?? -1, content ?? .max, "the handle is above the content, and so the pages")
        }
    }

    /// The handle at the start has its line along the first line's left edge, with the knob above it;
    /// the one at the end along the last line's right edge, with the knob below it.
    func testTheHandlesStandAtTheEndsOfTheSelection() {
        let (controller, _) = makeController()
        controller.selection = (page: 0, rects: [box])
        let start = controller.selectionInteraction.startHandle
        let end = controller.selectionInteraction.endHandle

        // The box is 72 ... 172 across and 72 ... 96 down, in PDF points.
        XCTAssertEqual(start.stemFrame.midX, 72 * scale, accuracy: 0.01)
        XCTAssertEqual(start.stemFrame.minY, 72 * scale, accuracy: 0.01)
        XCTAssertEqual(start.stemFrame.maxY, 96 * scale, accuracy: 0.01)
        XCTAssertEqual(start.knobFrame.midX, 72 * scale, accuracy: 0.01)
        XCTAssertEqual(start.knobFrame.maxY, 72 * scale, accuracy: 0.01, "the knob is above the line: its bottom meets the line's top")

        XCTAssertEqual(end.stemFrame.midX, 172 * scale, accuracy: 0.01)
        XCTAssertEqual(end.stemFrame.minY, 72 * scale, accuracy: 0.01)
        XCTAssertEqual(end.stemFrame.maxY, 96 * scale, accuracy: 0.01)
        XCTAssertEqual(end.knobFrame.midX, 172 * scale, accuracy: 0.01)
        XCTAssertEqual(end.knobFrame.minY, 96 * scale, accuracy: 0.01, "the knob is below the line: its top meets the line's bottom")
    }

    func testTheHandlesAreTheSizeTheBriefSays() {
        let (controller, _) = makeController()
        controller.selection = (page: 0, rects: [box])
        let start = controller.selectionInteraction.startHandle
        XCTAssertEqual(start.knobFrame.width, 10, "a circle 10 points across")
        XCTAssertEqual(start.knobFrame.height, 10)
        XCTAssertLessThanOrEqual(start.stemFrame.width, 2, "with a thin line")
    }

    /// A handle is worth touching: a disc 44 points across the knob, which its frame holds, however short the
    /// line is.
    func testTheHandlesAreBigEnoughToTouch() {
        let (controller, _) = makeController()
        for height in [24.0, 4.0] {
            controller.selection = (page: 0, rects: [CGRect(x: 72, y: 72, width: 100, height: height)])
            for handle in [controller.selectionInteraction.startHandle, controller.selectionInteraction.endHandle] {
                XCTAssertGreaterThanOrEqual(handle.frame.width, 44)
                let reachAroundTheKnob = handle.knobFrame.insetBy(dx: -17, dy: -17)
                XCTAssertTrue(handle.frame.insetBy(dx: -0.01, dy: -0.01).contains(reachAroundTheKnob),
                              "\(handle.frame) does not hold a 44-point square round the knob (a \(height)-point line)")
                let knob = handle.convert(CGPoint(x: handle.knobFrame.midX, y: handle.knobFrame.midY), from: handle.superview)
                for (dx, dy) in [(0.0, 0.0), (15.0, 15.0), (-15.0, 15.0), (15.0, -15.0), (-15.0, -15.0), (21.0, 0.0), (0.0, 21.0), (0.0, -21.0)] {
                    XCTAssertTrue(handle.point(inside: CGPoint(x: knob.x + dx, y: knob.y + dy), with: nil), "\(dx), \(dy) from the knob")
                }
            }
        }
    }

    /// The box round a handle is bigger than what it takes touches on, and a touch on the page inside the
    /// box but off the knob and the line is the page's: a long press on text next to a handle selects it.
    func testAHandleTakesTouchesOnItsKnobAndLineAndLeavesTheRestOfItsBoxToThePage() throws {
        let (controller, _) = makeController()
        controller.selection = (page: 0, rects: [box])
        let scrollView = controller.scrollView
        let start = controller.selectionInteraction.startHandle
        let end = controller.selectionInteraction.endHandle

        let endKnob = CGPoint(x: end.knobFrame.midX, y: end.knobFrame.midY)
        XCTAssertTrue(scrollView.hitTest(endKnob, with: nil) === end, "on the knob")
        XCTAssertTrue(scrollView.hitTest(CGPoint(x: end.stemFrame.midX, y: end.stemFrame.midY), with: nil) === end, "on the line")
        let startKnob = CGPoint(x: start.knobFrame.midX, y: start.knobFrame.midY)
        XCTAssertTrue(scrollView.hitTest(startKnob, with: nil) === start)

        // The corners of the end handle's box are off its disc and its line.
        let corner = CGPoint(x: end.frame.maxX - 1, y: end.frame.maxY - 1)
        XCTAssertTrue(end.frame.contains(corner))
        let page = try XCTUnwrap(controller.pageView(for: 0))
        let cornerHit = scrollView.hitTest(corner, with: nil)
        XCTAssertFalse(cornerHit is SelectionHandleView, "the corner of the box is the page's, not the handle's")
        XCTAssertTrue(cornerHit === page, "the page view, which is what the content view's recognizers watch")

        // Between the two lines, on the text, far from both knobs.
        let between = CGPoint(x: (start.stemFrame.midX + end.stemFrame.midX) / 2, y: start.stemFrame.midY)
        XCTAssertTrue(scrollView.hitTest(between, with: nil) === page, "on the text between the handles")
    }

    /// A short selection has handles close enough for their rooms to overlap: each knob is still its own
    /// handle's, though the other's room is there too and the other is on top.
    func testWhereTwoHandlesHaveRoomForATouchTheNearerOneTakesIt() throws {
        let (controller, _) = makeController()
        // A short word in 11-point type: 6.5 layout points across.
        controller.selection = (page: 0, rects: [CGRect(x: 72, y: 74.2, width: 10, height: 11)])
        let start = controller.selectionInteraction.startHandle
        let end = controller.selectionInteraction.endHandle
        let startKnob = CGPoint(x: start.knobFrame.midX, y: start.knobFrame.midY)
        let endKnob = CGPoint(x: end.knobFrame.midX, y: end.knobFrame.midY)
        XCTAssertLessThan(hypot(startKnob.x - endKnob.x, startKnob.y - endKnob.y), 22, "each knob is in the other's room")

        XCTAssertTrue(controller.scrollView.hitTest(startKnob, with: nil) === start, "the start knob is the start handle's")
        XCTAssertTrue(controller.scrollView.hitTest(endKnob, with: nil) === end, "the end knob is the end handle's")
        // Just short of each knob's edge, toward the other.
        XCTAssertTrue(controller.scrollView.hitTest(CGPoint(x: startKnob.x - 3, y: startKnob.y - 3), with: nil) === start)
        XCTAssertTrue(controller.scrollView.hitTest(CGPoint(x: endKnob.x + 3, y: endKnob.y + 3), with: nil) === end)
        // On each line.
        XCTAssertTrue(controller.scrollView.hitTest(CGPoint(x: start.stemFrame.midX, y: start.stemFrame.midY), with: nil) === start)
        XCTAssertTrue(controller.scrollView.hitTest(CGPoint(x: end.stemFrame.midX, y: end.stemFrame.midY), with: nil) === end)
    }

    /// No selection, no handle to touch.
    func testHiddenHandlesTakeNoTouches() {
        let (controller, _) = makeController()
        controller.selection = (page: 0, rects: [box])
        let knob = CGPoint(x: controller.selectionInteraction.endHandle.knobFrame.midX, y: controller.selectionInteraction.endHandle.knobFrame.midY)
        controller.selection = nil
        XCTAssertFalse(controller.scrollView.hitTest(knob, with: nil) is SelectionHandleView)
    }

    /// The selection of several lines: the start is where it starts, on the first line, and the end where
    /// it ends, on the last.
    func testTheHandlesOfSeveralLinesAreOnTheFirstAndLastLines() {
        let (controller, _) = makeController()
        let first = CGRect(x: 300, y: 72, width: 240, height: 24)
        let middle = CGRect(x: 72, y: 100, width: 468, height: 24)
        let last = CGRect(x: 72, y: 128, width: 120, height: 24)
        controller.selection = (page: 0, rects: [first, middle, last])
        let start = controller.selectionInteraction.startHandle
        let end = controller.selectionInteraction.endHandle
        XCTAssertEqual(start.stemFrame.midX, 300 * scale, accuracy: 0.01)
        XCTAssertEqual(start.stemFrame.minY, 72 * scale, accuracy: 0.01)
        XCTAssertEqual(end.stemFrame.midX, 192 * scale, accuracy: 0.01)
        XCTAssertEqual(end.stemFrame.maxY, 152 * scale, accuracy: 0.01)
    }

    /// On a later page they are lower down, where that page is.
    func testTheHandlesFollowTheSelectionToItsPage() {
        let (controller, _) = makeController()
        controller.selection = (page: 3, rects: [box])
        let start = controller.selectionInteraction.startHandle
        XCTAssertEqual(start.stemFrame.minY, 3 * 530 + 72 * scale, accuracy: 0.01)
        XCTAssertEqual(start.stemFrame.midX, 72 * scale, accuracy: 0.01)
    }

    /// Zoomed, the text is bigger and the handles follow it, but they stay the size they were: a line as long
    /// as the text's, a knob as big as before.
    func testTheHandlesFollowTheZoomAndStayTheSameSize() {
        let (controller, _) = makeController()
        controller.selection = (page: 0, rects: [box])
        let end = controller.selectionInteraction.endHandle
        let knob = end.knobFrame.size
        let stemWidth = end.stemFrame.width

        controller.scrollView.zoomScale = 2
        XCTAssertEqual(end.stemFrame.midX, 172 * scale * 2, accuracy: 0.01, "the line is along the text's edge")
        XCTAssertEqual(end.stemFrame.minY, 72 * scale * 2, accuracy: 0.01)
        XCTAssertEqual(end.stemFrame.height, 24 * scale * 2, accuracy: 0.01, "and as long as the text's line is tall")
        XCTAssertEqual(end.knobFrame.size, knob, "the knob is not magnified")
        XCTAssertEqual(end.stemFrame.width, stemWidth, "nor the line thickened")

        controller.scrollView.zoomScale = 8
        XCTAssertEqual(end.stemFrame.midX, 172 * scale * 8, accuracy: 0.01)
        XCTAssertEqual(end.stemFrame.height, 24 * scale * 8, accuracy: 0.01)
        XCTAssertEqual(end.knobFrame.size, knob)

        controller.scrollView.zoomScale = 1
        XCTAssertEqual(end.stemFrame.midX, 172 * scale, accuracy: 0.01, "back where they were")
    }

    /// They are in the scroll view's own coordinates, so scrolling does not move them in it: the scroll
    /// view moves them across the screen with the pages.
    func testScrollingDoesNotMoveTheHandlesInTheScrollView() {
        let (controller, _) = makeController()
        controller.selection = (page: 1, rects: [box])
        let start = controller.selectionInteraction.startHandle
        let before = start.frame
        controller.scrollView.contentOffset = CGPoint(x: 0, y: 300)
        XCTAssertEqual(start.frame, before)
    }

    func testTheHandlesFollowARelayout() {
        let (controller, _) = makeController()
        controller.selection = (page: 0, rects: [box])
        controller.view.frame = CGRect(x: 0, y: 0, width: 300, height: 800)
        controller.view.layoutIfNeeded()
        let end = controller.selectionInteraction.endHandle
        let narrower: CGFloat = 300.0 / 612.0
        XCTAssertEqual(end.stemFrame.midX, 172 * narrower, accuracy: 0.01)
        XCTAssertEqual(end.stemFrame.minY, 72 * narrower, accuracy: 0.01)
    }

    func testASelectionWithNoBoxHasNoHandles() {
        let (controller, _) = makeController()
        controller.selection = (page: 0, rects: [])
        XCTAssertTrue(controller.selectionInteraction.startHandle.isHidden)
        XCTAssertTrue(controller.selectionInteraction.endHandle.isHidden)
    }

    func testASelectionOnAPageTheDocumentLacksHasNoHandles() {
        let (controller, _) = makeController()
        controller.selection = (page: 40, rects: [box])
        XCTAssertTrue(controller.selectionInteraction.startHandle.isHidden)
    }

    // MARK: Where things are

    func testAPointOnAPageIsFoundInPDFPoints() throws {
        let (controller, _) = makeController()
        // Page 1 is at 530 ... 1048; 200 across and 70 down it is 306 and 107.1 PDF points.
        let found = try XCTUnwrap(controller.pageLocation(of: CGPoint(x: 200, y: 600)))
        XCTAssertEqual(found.page, 1)
        XCTAssertEqual(found.point.x, 200 / scale, accuracy: 0.001)
        XCTAssertEqual(found.point.y, 70 / scale, accuracy: 0.001)
    }

    func testAPointInAGapOrOffTheColumnIsNotOnAPage() {
        let (controller, _) = makeController()
        XCTAssertNil(controller.pageLocation(of: CGPoint(x: 200, y: 524)), "page 0 ends at 518, page 1 starts at 530: 524 is the gap")
        XCTAssertNil(controller.pageLocation(of: CGPoint(x: 200, y: 1_052)), "and the next gap is 1048 ... 1060")
        XCTAssertNil(controller.pageLocation(of: CGPoint(x: 450, y: 100)), "right of the column")
        XCTAssertNil(controller.pageLocation(of: CGPoint(x: 200, y: -4)), "above the first page")
    }

    func testANarrowPageIsScaledByItsOwnWidth() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage(withBounds: CGRect(x: 0, y: 0, width: 612, height: 792), pageInfo: [:])
            context.beginPage(withBounds: CGRect(x: 0, y: 0, width: 306, height: 396), pageInfo: [:])
        }
        let model = DocumentModel(bytes: data)
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 1_200)
        controller.view.layoutIfNeeded()
        // Page 1 is 400 wide by 518 tall too, at 530; it is half as wide in PDF points, so twice the scale.
        let found = try XCTUnwrap(controller.pageLocation(of: CGPoint(x: 200, y: 530 + 100)))
        XCTAssertEqual(found.page, 1)
        XCTAssertEqual(found.point.x, 200 / (400.0 / 306), accuracy: 0.001)
        XCTAssertEqual(found.point.y, 100 / (400.0 / 306), accuracy: 0.001)
        XCTAssertEqual(controller.screenScale(ofPage: 1), 400.0 / 306, accuracy: 0.0001)
        XCTAssertEqual(controller.screenScale(ofPage: 0), 400.0 / 612, accuracy: 0.0001)
    }

    func testABoxIsFoundInTheScrollViewsCoordinatesAtTheZoom() throws {
        let (controller, _) = makeController()
        let at1 = try XCTUnwrap(controller.scrollViewRect(of: box, onPage: 2))
        XCTAssertEqual(at1.minX, 72 * scale, accuracy: 0.001)
        XCTAssertEqual(at1.minY, 2 * 530 + 72 * scale, accuracy: 0.001)
        XCTAssertEqual(at1.width, 100 * scale, accuracy: 0.001)
        XCTAssertEqual(at1.height, 24 * scale, accuracy: 0.001)
        controller.scrollView.zoomScale = 3
        let at3 = try XCTUnwrap(controller.scrollViewRect(of: box, onPage: 2))
        XCTAssertEqual(at3.minX, 72 * scale * 3, accuracy: 0.001)
        XCTAssertEqual(at3.width, 100 * scale * 3, accuracy: 0.001)
        XCTAssertNil(controller.scrollViewRect(of: box, onPage: 12), "a page the document does not have")
        XCTAssertEqual(controller.screenScale(ofPage: 2), scale * 3, accuracy: 0.0001)
        XCTAssertEqual(controller.screenScale(ofPage: 40), 0)
    }

    func testNothingIsFoundBeforeTheFirstLayout() {
        let model = DocumentModel(bytes: PageScrollViewControllerTests.letterPages(2))
        let controller = PageScrollViewController(model: model)
        _ = controller.view
        XCTAssertNil(controller.pageLocation(of: CGPoint(x: 10, y: 10)))
        XCTAssertNil(controller.scrollViewRect(of: box, onPage: 0))
        XCTAssertEqual(controller.screenScale(ofPage: 0), 0)
        controller.selection = (page: 0, rects: [box])
        XCTAssertTrue(controller.selectionInteraction.startHandle.isHidden, "no layout, no place to put them")
    }

    // MARK: The gestures

    func testTheGesturesAreOnTheContentView() {
        let (controller, _) = makeController()
        let interaction = controller.selectionInteraction
        XCTAssertEqual(interaction.longPress.minimumPressDuration, 0.4)
        XCTAssertEqual(interaction.longPress.numberOfTouchesRequired, 1)
        XCTAssertTrue(controller.contentView.gestureRecognizers?.contains(interaction.longPress) == true)
        XCTAssertTrue(controller.contentView.gestureRecognizers?.contains(interaction.tap) == true)
        XCTAssertTrue(controller.scrollView.interactions.contains { $0 is UIEditMenuInteraction }, "the menu")
        for handle in [interaction.startHandle, interaction.endHandle] {
            let pans = handle.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer } ?? []
            XCTAssertEqual(pans.count, 1, "a pan on each handle")
            XCTAssertEqual(pans.first?.maximumNumberOfTouches, 1)
        }
    }

    /// The recognizers do nothing until there is something for them: the tap and the handles' pans need
    /// a selection, the long press a page under the finger.
    func testTheRecognizersBeginOnlyWhenTheyHaveSomethingToDo() {
        let (controller, _) = makeController()
        let interaction = controller.selectionInteraction
        XCTAssertFalse(interaction.gestureRecognizerShouldBegin(interaction.tap), "no selection to tap")
        let pan = interaction.startHandle.gestureRecognizers?.first { $0 is UIPanGestureRecognizer }
        XCTAssertFalse(pan.map { interaction.gestureRecognizerShouldBegin($0) } ?? true, "no selection, no handle to drag")
        controller.selection = (page: 0, rects: [box])
        XCTAssertTrue(interaction.gestureRecognizerShouldBegin(interaction.tap))
        XCTAssertTrue(pan.map { interaction.gestureRecognizerShouldBegin($0) } ?? false)
    }

    /// Before the document's permissions are read, marking is not offered (see `TextMarkupTests`).
    func testBeforeThePermissionsAreReadTheMenuHasOnlyCopy() throws {
        let (controller, _) = makeController()
        let interaction = controller.selectionInteraction
        let menuInteraction = try XCTUnwrap(controller.scrollView.interactions.compactMap { $0 as? UIEditMenuInteraction }.first)
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero)
        let menu = try XCTUnwrap(interaction.editMenuInteraction(menuInteraction, menuFor: configuration, suggestedActions: []))
        XCTAssertEqual(menu.children.count, 1)
        XCTAssertEqual(menu.children.first?.title, "Copy")
        XCTAssertEqual(menu.children.first?.title, Strings.copy)
    }

    func testTheMenuPointsAtTheSelection() {
        let (controller, _) = makeController()
        let interaction = controller.selectionInteraction
        let menuInteraction = controller.scrollView.interactions.compactMap { $0 as? UIEditMenuInteraction }.first
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero)
        guard let menuInteraction else { return XCTFail("no menu") }
        XCTAssertEqual(interaction.editMenuInteraction(menuInteraction, targetRectFor: configuration), .zero, "nothing selected, nothing to point at")
        controller.selection = (page: 0, rects: [box, box.offsetBy(dx: 0, dy: 30)])
        let target = interaction.editMenuInteraction(menuInteraction, targetRectFor: configuration)
        XCTAssertEqual(target.minX, 72 * scale, accuracy: 0.01)
        XCTAssertEqual(target.minY, 72 * scale, accuracy: 0.01)
        XCTAssertEqual(target.maxY, 126 * scale, accuracy: 0.01, "both lines")
    }

    // MARK: What the gestures do

    func testALongPressSelectsTheWordUnderTheFinger() async throws {
        let (controller, model) = makeController()
        let selection = try XCTUnwrap(model.selection)
        try await select(glyph: 1, page: 0, controller: controller, model: model)
        XCTAssertEqual(selection.text, "Page")
        XCTAssertEqual(selection.selection?.page, 0)
        XCTAssertNotNil(controller.selection, "it reaches the view")
        XCTAssertFalse(controller.selectionInteraction.startHandle.isHidden)
    }

    func testALongPressOnALaterPageSelectsOnThatPage() async throws {
        let (controller, model) = makeController()
        try await select(glyph: 1, page: 2, controller: controller, model: model)
        XCTAssertEqual(model.selection?.text, "Page")
        XCTAssertEqual(model.selection?.selection?.page, 2, "the point is found on its page, not the first")
        XCTAssertEqual(controller.selection?.page, 2)
    }

    func testALongPressBetweenPagesOrOffThemSelectsNothing() async throws {
        let (controller, model) = makeController()
        controller.selectionInteraction.beginWord(atContentPoint: CGPoint(x: 100, y: 524))
        controller.selectionInteraction.beginWord(atContentPoint: CGPoint(x: 900, y: 100))
        await model.selection?.waitUntilSettled()
        XCTAssertNil(model.selection?.selection)
    }

    func testALongPressOnBlankPaperSelectsNothing() async throws {
        let (controller, model) = makeController()
        controller.selectionInteraction.beginWord(atContentPoint: CGPoint(x: 300, y: 400))
        await model.selection?.waitUntilSettled()
        XCTAssertNil(model.selection?.selection)
    }

    func testATapOnTheSelectedTextKeepsTheSelection() async throws {
        let (controller, model) = makeController()
        try await select(glyph: 1, page: 0, controller: controller, model: model)
        let on = contentPoint(try glyphCentre(2, page: 0, in: model), page: 0)
        controller.selectionInteraction.tap(atContentPoint: on)
        await model.selection?.waitUntilSettled()
        XCTAssertEqual(model.selection?.text, "Page", "a tap on the text is for the menu, which it brings back")
    }

    func testATapElsewhereEndsTheSelection() async throws {
        let (controller, model) = makeController()
        try await select(glyph: 1, page: 0, controller: controller, model: model)
        XCTAssertNotNil(controller.selection)
        controller.selectionInteraction.tap(atContentPoint: CGPoint(x: 300, y: 400))
        XCTAssertNil(model.selection?.selection, "gone at once")
        controller.selection = model.selection?.pageRects
        XCTAssertTrue(controller.selectionInteraction.startHandle.isHidden)
        XCTAssertEqual(try XCTUnwrap(controller.pageView(for: 0)).overlay.selection, [])
    }

    func testATapOnAnotherPageEndsTheSelection() async throws {
        let (controller, model) = makeController()
        try await select(glyph: 1, page: 0, controller: controller, model: model)
        // The same place on the next page.
        controller.selectionInteraction.tap(atContentPoint: contentPoint(try glyphCentre(1, page: 1, in: model), page: 1))
        XCTAssertNil(model.selection?.selection)
    }

    func testDraggingTheEndHandleExtendsTheSelectionAndStopsTheScrolling() async throws {
        let (controller, model) = makeController()
        let interaction = controller.selectionInteraction
        try await select(glyph: 1, page: 0, controller: controller, model: model)
        XCTAssertEqual(model.selection?.text, "Page")
        XCTAssertTrue(controller.scrollView.isScrollEnabled)

        // The handle is at the right edge of "Page", level with its middle. The finger goes down below
        // it, on the knob, and moves right as far as the middle of the "1" ("Page 1": glyphs 0 ... 5).
        let rect = try XCTUnwrap(controller.selection?.rects.last)
        let hotSpot = CGPoint(x: rect.maxX, y: rect.midY)
        let target = try glyphCentre(5, page: 0, in: model)
        let zoom = controller.screenScale(ofPage: 0)
        let down = controller.selectionInteraction.endHandle.knobFrame
        let touch = CGPoint(x: down.midX, y: down.midY)
        interaction.beginDrag(of: .end, touchAt: touch)
        XCTAssertTrue(interaction.isDraggingHandle)
        XCTAssertFalse(controller.scrollView.isScrollEnabled, "the page must not scroll under the handle")

        interaction.updateDrag(touchAt: CGPoint(x: touch.x + (target.x - hotSpot.x) * zoom, y: touch.y + (target.y - hotSpot.y) * zoom))
        await model.selection?.waitUntilSettled()
        XCTAssertEqual(model.selection?.text, "Page 1")
        XCTAssertEqual(model.selection?.selection?.start, 0, "the start did not move")

        interaction.endDrag()
        XCTAssertFalse(interaction.isDraggingHandle)
        XCTAssertTrue(controller.scrollView.isScrollEnabled, "and the page scrolls again")
    }

    func testDraggingTheStartHandleMovesTheStart() async throws {
        let (controller, model) = makeController()
        let interaction = controller.selectionInteraction
        // "1", the last glyph of "Page 1", which is a word of its own.
        try await select(glyph: 5, page: 0, controller: controller, model: model)
        XCTAssertEqual(model.selection?.text, "1")

        let rect = try XCTUnwrap(controller.selection?.rects.first)
        let hotSpot = CGPoint(x: rect.minX, y: rect.midY)
        let target = try glyphCentre(1, page: 0, in: model)
        let zoom = controller.screenScale(ofPage: 0)
        let touch = CGPoint(x: 100, y: 100)
        interaction.beginDrag(of: .start, touchAt: touch)
        interaction.updateDrag(touchAt: CGPoint(x: touch.x + (target.x - hotSpot.x) * zoom, y: touch.y + (target.y - hotSpot.y) * zoom))
        await model.selection?.waitUntilSettled()
        // The centre of "a" is the gap after it: "ge 1".
        XCTAssertEqual(model.selection?.text, "ge 1")
        XCTAssertEqual(model.selection?.selection?.end, 6, "the end did not move")
        interaction.endDrag()
    }

    /// Zoomed in, the same finger travel is less text: a drag is measured in the page's own points.
    func testADragIsMeasuredInThePagesPointsAtAnyZoom() async throws {
        let (controller, model) = makeController()
        let interaction = controller.selectionInteraction
        try await select(glyph: 1, page: 0, controller: controller, model: model)
        controller.scrollView.zoomScale = 4
        let rect = try XCTUnwrap(controller.selection?.rects.last)
        let hotSpot = CGPoint(x: rect.maxX, y: rect.midY)
        let target = try glyphCentre(5, page: 0, in: model)
        let zoom = controller.screenScale(ofPage: 0)
        XCTAssertEqual(zoom, scale * 4, accuracy: 0.0001)
        let touch = CGPoint(x: 300, y: 300)
        interaction.beginDrag(of: .end, touchAt: touch)
        interaction.updateDrag(touchAt: CGPoint(x: touch.x + (target.x - hotSpot.x) * zoom, y: touch.y + (target.y - hotSpot.y) * zoom))
        await model.selection?.waitUntilSettled()
        XCTAssertEqual(model.selection?.text, "Page 1")
        interaction.endDrag()
    }

    func testADragWithNoSelectionDoesNothing() async throws {
        let (controller, model) = makeController()
        let interaction = controller.selectionInteraction
        interaction.beginDrag(of: .end, touchAt: CGPoint(x: 10, y: 10))
        XCTAssertFalse(interaction.isDraggingHandle)
        XCTAssertTrue(controller.scrollView.isScrollEnabled)
        interaction.updateDrag(touchAt: CGPoint(x: 100, y: 10))
        await model.selection?.waitUntilSettled()
        XCTAssertNil(model.selection?.selection)
    }

    /// The selection ended while a handle was held (a tap with a second finger, say): scrolling must not
    /// stay off.
    func testScrollingIsBackWhenTheSelectionGoesWhileAHandleIsHeld() async throws {
        let (controller, model) = makeController()
        let interaction = controller.selectionInteraction
        try await select(glyph: 1, page: 0, controller: controller, model: model)
        interaction.beginDrag(of: .end, touchAt: CGPoint(x: 100, y: 100))
        XCTAssertFalse(controller.scrollView.isScrollEnabled)
        model.selection?.clear()
        controller.selection = model.selection?.pageRects
        XCTAssertTrue(controller.scrollView.isScrollEnabled)
        XCTAssertFalse(interaction.isDraggingHandle)
    }

    /// The view changed width while a handle was held (an iPhone Duo folded, the device turned): the
    /// finger's travel no longer means what it did on the page, so the drag ends, scrolling is back, and
    /// the selection stays, with its handles at its new place.
    func testANewWidthLetsGoOfAHeldHandleAndKeepsTheSelection() async throws {
        let (controller, model) = makeController()
        let interaction = controller.selectionInteraction
        try await select(glyph: 1, page: 0, controller: controller, model: model)
        let selected = model.selection?.text
        interaction.beginDrag(of: .end, touchAt: CGPoint(x: 100, y: 100))
        XCTAssertFalse(controller.scrollView.isScrollEnabled)

        controller.view.frame = CGRect(x: 0, y: 0, width: 744, height: 1_000)
        controller.view.layoutIfNeeded()
        XCTAssertFalse(interaction.isDraggingHandle)
        XCTAssertTrue(controller.scrollView.isScrollEnabled)
        XCTAssertEqual(model.selection?.text, selected)
        XCTAssertFalse(interaction.endHandle.isHidden)
        let rect = try XCTUnwrap(controller.selection?.rects.last)
        let wider: CGFloat = 744.0 / 612.0
        XCTAssertEqual(interaction.endHandle.stemFrame.midX, rect.maxX * wider, accuracy: 0.01, "at the text on the wider page")

        // The rest of the gesture, after the relayout, moves nothing.
        interaction.updateDrag(touchAt: CGPoint(x: 300, y: 300))
        await model.selection?.waitUntilSettled()
        XCTAssertEqual(model.selection?.text, selected)
        interaction.endDrag()
        XCTAssertTrue(controller.scrollView.isScrollEnabled)
    }

    func testCopyingFromTheMenuPutsTheTextOnThePasteboard() async throws {
        let (controller, model) = makeController()
        try await select(glyph: 1, page: 0, controller: controller, model: model)
        UIPasteboard.general.string = "something else"
        controller.selectionInteraction.copySelection()
        XCTAssertEqual(UIPasteboard.general.string, "Page")
    }

    // MARK: Ownership

    /// The gestures and the menu belong to the controller, and hold nothing that keeps it alive.
    func testTheControllerIsReleasedWithItsSelectionInteraction() {
        weak var released: PageScrollViewController?
        weak var interaction: SelectionInteraction?
        autoreleasepool {
            let (controller, _) = makeController()
            controller.selection = (page: 0, rects: [box])
            released = controller
            interaction = controller.selectionInteraction
            XCTAssertNotNil(interaction)
        }
        XCTAssertNil(released)
        XCTAssertNil(interaction)
    }
}
