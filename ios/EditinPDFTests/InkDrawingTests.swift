import EditinPDFCore
import PencilKit
import UIKit
import XCTest
@testable import EditinPDF

/// Draw, on the page: the canvas `MarkupInteraction` puts over the page a finger goes down on, and
/// when what is drawn there is added to the document. As in `TextMarkupTests`, the touches themselves
/// are for the simulator: here the canvas is given a drawing the way PencilKit would record one, and
/// the hooks are called the way the views call them.
@MainActor
final class InkDrawingTests: XCTestCase {
    /// `pages` US Letter pages in a 400 x 800 view, Draw picked, with an undo manager.
    func makeController(pages: Int = 3, tool: Tool? = .ink) async -> (PageScrollViewController, DocumentModel, UndoManager) {
        let model = isolatedModel(bytes: PageScrollViewControllerTests.letterPages(pages))
        let undoManager = UndoManager()
        model.undoManager = undoManager
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(origin: .zero, size: CGSize(width: 400, height: 800))
        controller.view.layoutIfNeeded()
        await model.settle()
        pick(tool, in: model, controller)
        return (controller, model, undoManager)
    }

    /// Picks `tool`, as the palette and SwiftUI's update of the scroll view do.
    func pick(_ tool: Tool?, in model: DocumentModel, _ controller: PageScrollViewController) {
        model.tool = tool
        controller.markupTool = tool
    }

    /// How many layout points a PDF point is: the page is fitted to the 400-point width.
    let scale: CGFloat = 400.0 / 612.0

    /// `point` (PDF points on `page`) in the content view's coordinates.
    func contentPoint(_ point: CGPoint, page: Int, in controller: PageScrollViewController) throws -> CGPoint {
        let frame = try XCTUnwrap(controller.pageView(for: page)).frame
        return CGPoint(x: frame.minX + point.x * scale, y: frame.minY + point.y * scale)
    }

    /// Draws on the canvas, as PencilKit records a finger's strokes, the lines through `strokes`
    /// (PDF points of the canvas's page).
    func draw(_ strokes: [[CGPoint]], on ink: InkCaptureView) {
        let canvasStrokes = strokes.map { points in
            InkGeometryTests.stroke(points.map { CGPoint(x: ($0.x - ink.canvasOrigin.x) / ink.pointsPerCanvasPoint,
                                                         y: ($0.y - ink.canvasOrigin.y) / ink.pointsPerCanvasPoint) })
        }
        ink.drawing = PKDrawing(strokes: ink.drawing.strokes + canvasStrokes)
    }

    /// A line across from (100, 100) to (200, 150), in many points, and the box it spans.
    let line = (0...20).map { CGPoint(x: 100 + 5 * Double($0), y: 100 + 2.5 * Double($0)) }
    let span = CGRect(x: 100, y: 100, width: 100, height: 50)

    // MARK: Where the canvas is

    /// Picking Draw puts the canvas over the page being read, ready for the first finger (the UI test
    /// `testDrawingWithAFingerAddsInkThatUndoTakesBack` draws with it at once).
    func testPickingDrawPutsTheCanvasOverThePageBeingRead() async throws {
        let (controller, model, _) = await makeController(tool: .highlight)
        XCTAssertNil(controller.markupInteraction.drawing.ink, "no canvas without Draw")
        pick(.ink, in: model, controller)
        let ink = try XCTUnwrap(controller.markupInteraction.drawing.ink)
        XCTAssertEqual(ink.page, model.currentPage)
        XCTAssertTrue(ink.superview === controller.contentView)
        XCTAssertEqual(ink.frame, try XCTUnwrap(controller.pageView(for: 0)).frame)
    }

    func testAFirstFingerOnAPageWithDrawPickedPutsTheCanvasOverThatPage() async throws {
        let (controller, _, _) = await makeController()
        let markup = controller.markupInteraction
        XCTAssertEqual(markup.drawing.ink?.page, 0, "over the page being read")
        XCTAssertTrue(markup.drawing.prepareToDraw(atContentPoint: try contentPoint(CGPoint(x: 300, y: 400), page: 1, in: controller)))
        let ink = try XCTUnwrap(markup.drawing.ink)
        XCTAssertEqual(ink.page, 1)
        XCTAssertTrue(ink.superview === controller.contentView)
        XCTAssertEqual(ink.frame, try XCTUnwrap(controller.pageView(for: 1)).frame)
        XCTAssertEqual(ink.canvasOrigin, .zero)
        XCTAssertEqual(ink.pointsPerCanvasPoint, 1 / scale, accuracy: 0.0001)
        XCTAssertEqual(ink.drawingPolicy, .anyInput, "Pencil and finger draw")
        XCTAssertFalse(ink.isScrollEnabled, "two fingers scroll the pages, not the canvas")
        XCTAssertTrue(controller.contentView.subviews.last === ink, "over the pages")
    }

    /// One finger draws only with Draw picked, on a page, once the document's permissions are read.
    func testTheCanvasTakesNoFingerWithoutDrawOrOffThePages() async throws {
        let (controller, model, _) = await makeController(tool: .highlight)
        let markup = controller.markupInteraction
        let onPage = try contentPoint(CGPoint(x: 300, y: 400), page: 0, in: controller)
        for tool in [nil, Tool.select, .highlight, .eraser] {
            pick(tool, in: model, controller)
            XCTAssertFalse(markup.drawing.prepareToDraw(atContentPoint: onPage), "\(String(describing: tool))")
        }
        pick(.ink, in: model, controller)
        let gap = try contentPoint(CGPoint(x: 300, y: 795), page: 0, in: controller)
        XCTAssertNil(controller.pageLocation(of: gap), "the gap between two pages")
        XCTAssertFalse(markup.drawing.prepareToDraw(atContentPoint: gap))
        XCTAssertEqual(markup.drawing.ink?.page, 0, "the canvas stays where it was")

        // Before the permissions are read, nothing may be drawn.
        let fresh = isolatedModel(bytes: PageScrollViewControllerTests.letterPages(2))
        let other = PageScrollViewController(model: fresh)
        other.view.frame = CGRect(origin: .zero, size: CGSize(width: 400, height: 800))
        other.view.layoutIfNeeded()
        fresh.tool = .ink
        other.markupTool = .ink
        XCTAssertFalse(other.markupInteraction.drawing.prepareToDraw(atContentPoint: CGPoint(x: 200, y: 200)))
        await fresh.settle()
        XCTAssertTrue(other.markupInteraction.drawing.prepareToDraw(atContentPoint: CGPoint(x: 200, y: 200)))
    }

    /// Two fingers scroll and zoom while Draw is picked; one finger draws. With any other tool, or
    /// none, one finger scrolls again.
    func testWithDrawPickedTwoFingersScroll() async {
        let (controller, model, _) = await makeController()
        let pan = controller.scrollView.panGestureRecognizer
        XCTAssertEqual(pan.minimumNumberOfTouches, 2)
        pick(.highlight, in: model, controller)
        XCTAssertEqual(pan.minimumNumberOfTouches, 1)
        pick(.ink, in: model, controller)
        XCTAssertEqual(pan.minimumNumberOfTouches, 2)
        pick(nil, in: model, controller)
        XCTAssertEqual(pan.minimumNumberOfTouches, 1)
    }

    /// Only the first finger of a touch puts the canvas under it: a second one, while the first is on
    /// the screen, leaves it where it is (the two fingers scroll or zoom).
    func testOnlyAFirstFingerMovesTheCanvas() {
        XCTAssertTrue(PageContentView.isFirstFinger(otherTouches: []))
        XCTAssertTrue(PageContentView.isFirstFinger(otherTouches: [(isPlaced: false, phase: .began)]), "the touch itself, not placed yet")
        XCTAssertTrue(PageContentView.isFirstFinger(otherTouches: [(isPlaced: true, phase: .ended)]), "a finger that has lifted")
        XCTAssertTrue(PageContentView.isFirstFinger(otherTouches: [(isPlaced: true, phase: .cancelled)]))
        XCTAssertFalse(PageContentView.isFirstFinger(otherTouches: [(isPlaced: true, phase: .moved)]))
        XCTAssertFalse(PageContentView.isFirstFinger(otherTouches: [(isPlaced: true, phase: .stationary)]))
    }

    /// The content view asks the markup where a finger lands before it finds the view under it, so the
    /// finger lands on the canvas, wherever the canvas was.
    func testTheContentViewHandsAFingerToTheCanvas() async throws {
        let (controller, _, _) = await makeController()
        let onPage1 = try contentPoint(CGPoint(x: 300, y: 400), page: 1, in: controller)
        XCTAssertNotNil(controller.contentView.touchWillLand)
        controller.contentView.touchWillLand?(onPage1)
        let ink = try XCTUnwrap(controller.markupInteraction.drawing.ink)
        XCTAssertEqual(ink.page, 1)
        let hit = try XCTUnwrap(controller.contentView.hitTest(onPage1, with: nil))
        XCTAssertTrue(hit.isDescendant(of: ink), "the finger lands on the canvas")
    }

    func testTheStrokesNeverLandOnTheDocumentsUndoManager() async throws {
        let (controller, _, undoManager) = await makeController()
        XCTAssertTrue(controller.markupInteraction.drawing.prepareToDraw(atContentPoint: CGPoint(x: 200, y: 200)))
        let ink = try XCTUnwrap(controller.markupInteraction.drawing.ink)
        XCTAssertNotNil(ink.undoManager)
        XCTAssertFalse(ink.undoManager === undoManager)
        draw([line], on: ink)
        XCTAssertFalse(undoManager.canUndo, "a stroke on the canvas is not a change to the document")
    }

    /// The canvas draws in Draw's colour, as wide on screen as the line will be on the page, and in
    /// the same colours in dark mode (it is ink on paper).
    func testTheCanvasDrawsInDrawsStyle() async throws {
        let (controller, model, _) = await makeController()
        model.toolStyles[.ink] = ToolStyle(color: RGBA(r: 0, g: 0.4, b: 1), width: 3, fontSize: 14, fill: false)
        XCTAssertTrue(controller.markupInteraction.drawing.prepareToDraw(atContentPoint: CGPoint(x: 200, y: 200)))
        let ink = try XCTUnwrap(controller.markupInteraction.drawing.ink)
        let tool = try XCTUnwrap(ink.tool as? PKInkingTool)
        XCTAssertEqual(tool.inkType, .monoline)
        XCTAssertEqual(tool.width, 3 * scale / 2, accuracy: 0.01, "PencilKit draws a monoline twice its tool's width")
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        tool.color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertEqual(green, 0.4, accuracy: 0.01)
        XCTAssertEqual(blue, 1, accuracy: 0.01)
        XCTAssertEqual(ink.overrideUserInterfaceStyle, .light)
    }

    // MARK: What is drawn, and where it lands

    /// Review Focus 4: the drawing lands where it was drawn, zoomed out or in: the canvas zooms with
    /// the page, so a canvas point is the same page point at every zoom.
    func testWhatIsDrawnLandsWhereItWasDrawnAtAnyZoom() async throws {
        for zoom in [CGFloat(1), 3] {
            let (controller, model, _) = await makeController()
            controller.scrollView.zoomScale = zoom
            let markup = controller.markupInteraction
            XCTAssertTrue(markup.drawing.prepareToDraw(atContentPoint: try contentPoint(CGPoint(x: 150, y: 120), page: 0, in: controller)))
            let ink = try XCTUnwrap(markup.drawing.ink)
            draw([line], on: ink)
            XCTAssertTrue(model.hasPendingInk)
            let made = await markup.commitPendingInk()?.value
            XCTAssertEqual(made, true)
            let a = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first, "zoom \(zoom)")
            XCTAssertEqual(a.kind, .ink)
            InkGeometryTests.assertBox(a.rect, isAround: span, width: 2)
            XCTAssertFalse(model.hasPendingInk)
            XCTAssertTrue(ink.drawing.strokes.isEmpty, "the canvas is clear for the next strokes")
        }
    }

    /// On the page turned by `/Rotate 90` the drawing comes back where it was drawn on screen.
    func testWhatIsDrawnOnATurnedPageLandsWhereItWasDrawn() async throws {
        let model = isolatedModel(bytes: try fixtureData("rotated"))
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(origin: .zero, size: CGSize(width: 400, height: 800))
        controller.view.layoutIfNeeded()
        await model.settle()
        pick(.ink, in: model, controller)
        XCTAssertEqual(model.pages[0].rotationDegrees, 90)
        let markup = controller.markupInteraction
        XCTAssertTrue(markup.drawing.prepareToDraw(atContentPoint: CGPoint(x: 100, y: 100)))
        let ink = try XCTUnwrap(markup.drawing.ink)
        XCTAssertEqual(ink.pointsPerCanvasPoint, 792 / 400, accuracy: 0.001, "the turned page is 792 points wide as shown")
        draw([line], on: ink)
        let made = await markup.commitPendingInk()?.value
        XCTAssertEqual(made, true)
        let a = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first)
        InkGeometryTests.assertBox(a.rect, isAround: span, width: 2)
    }

    /// Done: every stroke drawn since the last is added as one drawing, one step to undo.
    func testDoneAddsThePendingStrokesAsOneChange() async throws {
        let (controller, model, undoManager) = await makeController()
        let markup = controller.markupInteraction
        XCTAssertFalse(model.hasPendingInk)
        XCTAssertTrue(markup.drawing.prepareToDraw(atContentPoint: CGPoint(x: 200, y: 200)))
        let ink = try XCTUnwrap(markup.drawing.ink)
        draw([line], on: ink)
        draw([line.map { CGPoint(x: $0.x, y: $0.y + 100) }], on: ink)
        XCTAssertTrue(model.hasPendingInk, "the palette shows Done")
        model.commitPendingInk()
        await model.settle()
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).map(\.kind), [.ink])
        XCTAssertEqual(undoManager.undoActionName, Strings.actionAddAnnotation)
        XCTAssertFalse(model.hasPendingInk)
        model.undo(); await model.settle()
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty, "Undo removes the whole drawing")
    }

    /// Nothing drawn, nothing added.
    func testDoneWithNothingDrawnChangesNothing() async throws {
        let (controller, model, undoManager) = await makeController()
        XCTAssertTrue(controller.markupInteraction.drawing.prepareToDraw(atContentPoint: CGPoint(x: 200, y: 200)))
        model.commitPendingInk()
        await model.settle()
        XCTAssertFalse(undoManager.canUndo)
        XCTAssertNil(controller.markupInteraction.commitPendingInk())
    }

    /// A finger going down on another page adds what was drawn on the first, and the canvas moves
    /// under it; one on the same page draws on.
    func testAFingerOnAnotherPageAddsTheStrokesAndTakesTheCanvasThere() async throws {
        let (controller, model, _) = await makeController()
        let markup = controller.markupInteraction
        XCTAssertTrue(markup.drawing.prepareToDraw(atContentPoint: try contentPoint(CGPoint(x: 300, y: 400), page: 0, in: controller)))
        let ink = try XCTUnwrap(markup.drawing.ink)
        draw([line], on: ink)
        XCTAssertTrue(markup.drawing.prepareToDraw(atContentPoint: try contentPoint(CGPoint(x: 300, y: 600), page: 0, in: controller)))
        XCTAssertTrue(model.hasPendingInk, "the same page: still drawing")
        XCTAssertTrue(markup.drawing.prepareToDraw(atContentPoint: try contentPoint(CGPoint(x: 300, y: 400), page: 1, in: controller)))
        XCTAssertFalse(model.hasPendingInk)
        XCTAssertEqual(ink.page, 1)
        XCTAssertEqual(ink.frame, try XCTUnwrap(controller.pageView(for: 1)).frame)
        XCTAssertTrue(ink.drawing.strokes.isEmpty)
        await model.settle()
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).map(\.kind), [.ink], "on the page it was drawn on")
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 1).isEmpty)
    }

    /// While a stroke is being drawn the canvas stays where it is, whatever else touches the pages: until
    /// PencilKit has put the stroke on the drawing, a moment after it ends.
    func testTheCanvasDoesNotMoveWhileAStrokeIsDrawn() async throws {
        let (controller, model, _) = await makeController()
        let markup = controller.markupInteraction
        XCTAssertTrue(markup.drawing.prepareToDraw(atContentPoint: try contentPoint(CGPoint(x: 300, y: 400), page: 0, in: controller)))
        let ink = try XCTUnwrap(markup.drawing.ink)
        draw([line], on: ink)
        markup.drawing.canvasViewDidBeginUsingTool(ink)
        XCTAssertFalse(markup.drawing.prepareToDraw(atContentPoint: try contentPoint(CGPoint(x: 300, y: 400), page: 1, in: controller)))
        XCTAssertEqual(ink.page, 0)
        XCTAssertTrue(model.hasPendingInk)
        markup.drawing.canvasViewDidEndUsingTool(ink)
        XCTAssertFalse(markup.drawing.prepareToDraw(atContentPoint: try contentPoint(CGPoint(x: 300, y: 400), page: 1, in: controller)),
                       "ended, but not on the canvas yet")
        // PencilKit puts the stroke on the drawing a moment after it ends: it is over then.
        draw([line.map { CGPoint(x: $0.x, y: $0.y + 100) }], on: ink)
        markup.drawing.canvasViewDrawingDidChange(ink)
        XCTAssertTrue(markup.drawing.prepareToDraw(atContentPoint: try contentPoint(CGPoint(x: 300, y: 400), page: 1, in: controller)))
        XCTAssertEqual(ink.page, 1)
    }

    /// Picking another tool, or turning Markup off, adds the strokes and takes the canvas away.
    func testPickingAnotherToolAddsTheStrokes() async throws {
        for next in [Tool.highlight, nil] {
            let (controller, model, _) = await makeController()
            let markup = controller.markupInteraction
            XCTAssertTrue(markup.drawing.prepareToDraw(atContentPoint: CGPoint(x: 200, y: 200)))
            let ink = try XCTUnwrap(markup.drawing.ink)
            draw([line], on: ink)
            pick(next, in: model, controller)
            XCTAssertFalse(model.hasPendingInk)
            await model.settle()
            XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).map(\.kind), [.ink], "\(String(describing: next))")
            XCTAssertNil(ink.superview, "no canvas without Draw")
        }
    }

    /// Undo with strokes waiting adds them first, then takes them back: the whole drawing goes, and
    /// Redo brings it back.
    func testUndoAddsThePendingStrokesThenTakesThemBack() async throws {
        let (controller, model, undoManager) = await makeController()
        XCTAssertTrue(controller.markupInteraction.drawing.prepareToDraw(atContentPoint: CGPoint(x: 200, y: 200)))
        draw([line], on: try XCTUnwrap(controller.markupInteraction.drawing.ink))
        model.undo()
        await model.settle()
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
        XCTAssertFalse(model.hasPendingInk)
        XCTAssertTrue(undoManager.canRedo)
        model.redo()
        await model.settle()
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).map(\.kind), [.ink])
    }

    /// Any other change waits for the strokes on the canvas: they were drawn on the document as it
    /// was, and are added first, where they were drawn.
    func testAnotherChangeAddsThePendingStrokesFirst() async throws {
        let (controller, model, _) = await makeController()
        XCTAssertTrue(controller.markupInteraction.drawing.prepareToDraw(atContentPoint: CGPoint(x: 200, y: 200)))
        draw([line], on: try XCTUnwrap(controller.markupInteraction.drawing.ink))
        let rotated = await model.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        XCTAssertTrue(rotated)
        XCTAssertNil(model.failure)
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).map(\.kind), [.ink], "added before the turn")
    }

    /// Ink is placed in view space: strokes drawn while a turn of their page was on its way are
    /// refused as stale. The reader is told the standard reason, and nothing that looks drawn stays
    /// on the page: neither the strokes on the canvas nor the picture of them shown while they were added.
    func testInkRefusedAsStaleLeavesNoGhost() async throws {
        let (controller, model, undoManager) = await makeController()
        let markup = controller.markupInteraction
        let rotate = model.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        XCTAssertTrue(markup.drawing.prepareToDraw(atContentPoint: CGPoint(x: 200, y: 200)))
        let ink = try XCTUnwrap(markup.drawing.ink)
        draw([line], on: ink)
        let commit = try XCTUnwrap(markup.commitPendingInk())
        XCTAssertEqual(markup.drawing.inkPreviews.count, 1, "what was drawn stays on screen while it is added")
        let rotated = await rotate.value
        let made = await commit.value
        XCTAssertTrue(rotated); XCTAssertFalse(made)
        XCTAssertEqual(model.failure?.message, Strings.drawingNotAdded)
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
        XCTAssertTrue(ink.drawing.strokes.isEmpty)
        XCTAssertTrue(markup.drawing.inkPreviews.isEmpty, "no ghost of the refused strokes")
        undoManager.undo(); await model.settle()
        XCTAssertFalse(undoManager.canUndo, "the refused drawing left nothing to undo")
    }

    /// A turn of the page published while strokes are on the canvas (one handed over before they
    /// were drawn) lays the pages out again: the strokes are added first, against the page as it was
    /// when they were drawn, and so refused, and the canvas goes.
    func testALayoutWhileStrokesArePendingLeavesNoGhost() async throws {
        let (controller, model, _) = await makeController()
        let markup = controller.markupInteraction
        let rotate = model.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        XCTAssertTrue(markup.drawing.prepareToDraw(atContentPoint: CGPoint(x: 200, y: 200)))
        let ink = try XCTUnwrap(markup.drawing.ink)
        draw([line], on: ink)
        _ = await rotate.value
        controller.apply(try XCTUnwrap(model.lastChange))
        await model.settle()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(model.failure?.message, Strings.drawingNotAdded)
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
        XCTAssertNil(ink.superview, "the canvas of the old layout is gone")
        XCTAssertTrue(markup.drawing.inkPreviews.isEmpty)
        XCTAssertFalse(model.hasPendingInk)
    }

    /// The canvas stays over its page when that page's view is made again (scrolled away and back).
    func testTheCanvasStaysOverItsPageWhenThePageIsMadeAgain() async throws {
        let (controller, _, _) = await makeController(pages: 12)
        XCTAssertTrue(controller.markupInteraction.drawing.prepareToDraw(atContentPoint: CGPoint(x: 200, y: 200)))
        let ink = try XCTUnwrap(controller.markupInteraction.drawing.ink)
        controller.scrollView.contentOffset = CGPoint(x: 0, y: 4_000)
        XCTAssertNil(controller.pageView(for: 0))
        controller.scrollView.contentOffset = .zero
        XCTAssertNotNil(controller.pageView(for: 0))
        XCTAssertTrue(controller.contentView.subviews.last === ink, "the page's new view is under the canvas")
    }

    // MARK: Strokes refused as stale, focus, VoiceOver

    /// Strokes refused as stale while their page stayed as it was (another page's turn was on its way
    /// as they were drawn) go back on the canvas, waiting, where they were drawn: no alert, no ghost,
    /// and Done adds them.
    func testInkRefusedWhileItsPageStayedGoesBackOnTheCanvas() async throws {
        let (controller, model, undoManager) = await makeController()
        let markup = controller.markupInteraction
        let turn = model.enqueue([.rotatePages(pages: [1], degrees: 90)], named: Strings.actionRotate, touching: [1])
        XCTAssertTrue(markup.drawing.prepareToDraw(atContentPoint: CGPoint(x: 200, y: 200)))
        let ink = try XCTUnwrap(markup.drawing.ink)
        draw([line], on: ink)
        let drawn = ink.drawing.bounds
        let commit = try XCTUnwrap(markup.commitPendingInk())
        _ = await turn.value
        let made = await commit.value
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(made)
        XCTAssertNil(model.failure)
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
        XCTAssertTrue(markup.drawing.inkPreviews.isEmpty, "no picture of them on their way")
        XCTAssertTrue(model.hasPendingInk, "waiting again")
        XCTAssertTrue(ink.superview === controller.contentView)
        XCTAssertEqual(ink.page, 0)
        XCTAssertEqual(ink.drawing.bounds.minX, drawn.minX, accuracy: 0.5, "where they were drawn")
        XCTAssertEqual(ink.drawing.bounds.minY, drawn.minY, accuracy: 0.5)

        let again = try XCTUnwrap(markup.commitPendingInk())
        let added = await again.value
        XCTAssertTrue(added)
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).map(\.kind), [.ink])
        undoManager.undo(); await model.settle()
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
    }

    /// Strokes refused as stale and handed over again while a stroke is being drawn do not add the
    /// strokes waiting on the canvas then, nor empty it, which would cut the stroke: what waits is added
    /// once the stroke is on the canvas (PencilKit puts it there a moment after it ends), with it. Every
    /// stroke is kept.
    func testStrokesHandedOverAgainMidStrokeLeaveTheStrokeBeingDrawn() async throws {
        let (controller, model, _) = await makeController()
        let markup = controller.markupInteraction
        let drawing = markup.drawing
        let turn = model.enqueue([.rotatePages(pages: [1], degrees: 90)], named: Strings.actionRotate, touching: [1])
        XCTAssertTrue(drawing.prepareToDraw(atContentPoint: CGPoint(x: 200, y: 200)))
        let ink = try XCTUnwrap(drawing.ink)
        draw([line], on: ink)
        // Refused as stale (the turn was on its way as it was drawn); its page stays as it was.
        let first = try XCTUnwrap(markup.commitPendingInk())
        // Another line waits on the canvas, and a stroke is being drawn as the refusal comes: the
        // canvas cannot take the refused strokes back, so they are handed over again.
        let lower = line.map { CGPoint(x: $0.x, y: $0.y + 200) }
        draw([lower], on: ink)
        drawing.canvasViewDrawingDidChange(ink)
        drawing.canvasViewDidBeginUsingTool(ink)
        _ = await turn.value
        let made = await first.value
        await model.settle()
        XCTAssertFalse(made)
        XCTAssertNil(model.failure)
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).map(\.kind), [.ink], "the refused strokes, handed over again")
        XCTAssertTrue(ink.isDrawing)
        XCTAssertEqual(ink.drawing.strokes.count, 1, "the line waiting is still on the canvas: not added, not emptied, mid-stroke")
        XCTAssertTrue(ink.superview === controller.contentView)
        XCTAssertTrue(model.hasPendingInk)

        // The stroke ends; PencilKit puts it on the drawing a moment later, and only then is what waits added.
        drawing.canvasViewDidEndUsingTool(ink)
        await Task.yield()
        XCTAssertEqual(ink.drawing.strokes.count, 1, "not before the stroke is on the canvas")
        draw([line.map { CGPoint(x: $0.x, y: $0.y + 400) }], on: ink)
        drawing.canvasViewDrawingDidChange(ink)
        for _ in 0..<5 { await Task.yield() }
        await model.settle()
        XCTAssertFalse(ink.isDrawing)
        // The line waiting was drawn while the turn was on its way: it and the stroke, as one drawing,
        // are refused as stale too, and go back on the canvas, waiting, both.
        XCTAssertEqual(ink.drawing.strokes.count, 2, "both strokes kept")
        XCTAssertTrue(model.hasPendingInk)
        let again = try XCTUnwrap(markup.commitPendingInk())
        let added = await again.value
        XCTAssertTrue(added)
        let inks = model.annotationIndex.annotations(onPage: 0)
        XCTAssertEqual(inks.map(\.kind), [.ink, .ink])
        XCTAssertGreaterThan(try XCTUnwrap(inks.last).rect.height, 200, "the line waiting and the stroke, as one drawing")
    }

    /// Draw put down while a stroke is being drawn: the canvas stays, with its strokes, until the stroke
    /// is over, then they are added and it goes. A stroke that never comes on the drawing (a touch
    /// cancelled) is over a moment after it ends.
    func testDrawPutDownMidStrokeWaitsForTheStroke() async throws {
        let (controller, model, _) = await makeController()
        let drawing = controller.markupInteraction.drawing
        XCTAssertTrue(drawing.prepareToDraw(atContentPoint: CGPoint(x: 200, y: 200)))
        let ink = try XCTUnwrap(drawing.ink)
        draw([line], on: ink)
        drawing.canvasViewDrawingDidChange(ink)
        drawing.canvasViewDidBeginUsingTool(ink)
        pick(.highlight, in: model, controller)
        XCTAssertTrue(ink.superview === controller.contentView, "the canvas stays while the stroke is drawn")
        XCTAssertEqual(ink.drawing.strokes.count, 1)
        XCTAssertTrue(model.hasPendingInk)
        drawing.canvasViewDidEndUsingTool(ink)
        try await Task.sleep(for: .seconds(1))
        await model.settle()
        XCTAssertFalse(ink.isDrawing, "over, though no stroke came")
        XCTAssertNil(ink.superview, "put away once the stroke was over")
        XCTAssertFalse(model.hasPendingInk)
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).map(\.kind), [.ink], "what waited was added")
    }

    /// The paths after which the document or the screen may go before a stroke being drawn is over
    /// (Back touched, the scene leaving the screen, the screen going, focus leaving the pages) add the
    /// strokes drawn at once, even mid-stroke: they are not lost with the document. The stroke being
    /// drawn may be cut.
    func testAClosingPathMidStrokeAddsTheStrokesDrawnAtOnce() async throws {
        let lower = line.map { CGPoint(x: $0.x, y: $0.y + 200) }
        let routes: [(String, @MainActor (PageScrollViewController, DocumentModel) -> Void)] = [
            ("a finger on Back", { controller, _ in controller.markupInteraction.fingerWentDown(on: UIView()) }),
            ("the scene leaving, the screen going", { _, model in model.commitPendingInk(closing: true) }),
            ("the scroll view dismantled", { controller, _ in PageScrollView.dismantleUIViewController(controller, coordinator: ()) }),
            ("focus leaving the pages", { controller, _ in
                let back = UIButton()
                controller.view.window?.addSubview(back)
                controller.markupInteraction.focusMoved(to: back)
            }),
        ]
        for (route, close) in routes {
            let (controller, model, _) = await makeController()
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 900))
            window.addSubview(controller.view)
            controller.view.layoutIfNeeded()
            await model.settle()
            let drawing = controller.markupInteraction.drawing
            XCTAssertTrue(drawing.prepareToDraw(atContentPoint: CGPoint(x: 200, y: 200)), route)
            let ink = try XCTUnwrap(drawing.ink)
            draw([line, lower], on: ink)
            drawing.canvasViewDrawingDidChange(ink)
            drawing.canvasViewDidBeginUsingTool(ink)
            close(controller, model)
            XCTAssertFalse(model.hasPendingInk, "\(route): handed over at once")
            XCTAssertTrue(ink.drawing.strokes.isEmpty, route)
            await model.settle()
            XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).map(\.kind), [.ink], "\(route): both strokes, as one drawing")
            window.isHidden = true
        }
    }

    /// The canvas is one element to VoiceOver that takes touches straight away, as the signature pad's
    /// is: a stroke is drawn, not read out.
    func testTheCanvasTakesTouchesDirectlyUnderVoiceOver() async throws {
        let (controller, _, _) = await makeController()
        let ink = try XCTUnwrap(controller.markupInteraction.drawing.ink)
        XCTAssertTrue(ink.isAccessibilityElement)
        XCTAssertTrue(ink.accessibilityTraits.contains(.allowsDirectInteraction))
        XCTAssertEqual(ink.accessibilityLabel, Strings.toolInk)
    }

    /// Focus leaving the pages for something else in their window (Back, reached with VoiceOver, Switch
    /// Control or a keyboard) adds the strokes waiting, as a finger going down there does. Focus on the
    /// pages, or in another window (the keyboard's), does not.
    func testFocusLeavingThePagesAddsTheStrokesWaiting() async throws {
        let (controller, model, _) = await makeController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 900))
        window.addSubview(controller.view)
        let back = UIButton(frame: CGRect(x: 0, y: 820, width: 80, height: 40))
        window.addSubview(back)
        controller.view.layoutIfNeeded()
        await model.settle()
        let elsewhere = UIWindow(frame: window.frame)
        let key = UIView()
        elsewhere.addSubview(key)
        let markup = controller.markupInteraction
        let pages = controller.scrollView

        XCTAssertFalse(MarkupInteraction.focusLeavesPages(nil, pages: pages))
        XCTAssertFalse(MarkupInteraction.focusLeavesPages(controller.contentView, pages: pages), "on the pages")
        XCTAssertFalse(MarkupInteraction.focusLeavesPages(key, pages: pages), "another window")
        XCTAssertTrue(MarkupInteraction.focusLeavesPages(back, pages: pages))
        let element = UIAccessibilityElement(accessibilityContainer: back)
        XCTAssertTrue(MarkupInteraction.focusLeavesPages(element, pages: pages), "an element followed up to its view")
        XCTAssertTrue(MarkupInteraction.view(holding: element) === back)

        XCTAssertTrue(markup.drawing.prepareToDraw(atContentPoint: CGPoint(x: 200, y: 200)))
        let ink = try XCTUnwrap(markup.drawing.ink)
        draw([line], on: ink)
        model.pendingInkDidChange(true)
        markup.focusMoved(to: ink)
        XCTAssertTrue(model.hasPendingInk, "focus on the canvas: still waiting")
        markup.focusMoved(to: key)
        XCTAssertTrue(model.hasPendingInk, "the keyboard's window: still waiting")
        markup.focusMoved(to: element)
        XCTAssertFalse(model.hasPendingInk, "added as focus left the pages")
        await model.settle()
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).map(\.kind), [.ink])
        window.isHidden = true
        elsewhere.isHidden = true
    }
}
