import EditinPDFCore
import PencilKit
import UIKit
import XCTest
@testable import EditinPDF

/// The shape tools, Text Box and Note on the page: which touches they take, what they show while a
/// shape is dragged out or text typed, and when what they make is added. As in `InkDrawingTests`,
/// the touches themselves are for the simulator: here the hooks are called the way the gestures
/// call them.
@MainActor
final class ShapeDrawingTests: XCTestCase {
    /// `pages` US Letter pages in a 400 x 800 view, `tool` picked, with an undo manager.
    func makeController(pages: Int = 3, tool: Tool? = .rectangle, data: Data? = nil) async -> (PageScrollViewController, DocumentModel, UndoManager) {
        let model = DocumentModel(outcome: OpenOutcome(bytes: data ?? PageScrollViewControllerTests.letterPages(pages)),
                                  toolStyles: isolatedToolStyles())
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

    /// How many layout points a PDF point is: a US Letter page is fitted to the 400-point width.
    let scale: CGFloat = 400.0 / 612.0

    /// `point` (PDF points on `page`) in the content view's coordinates.
    func contentPoint(_ point: CGPoint, page: Int = 0, in controller: PageScrollViewController) throws -> CGPoint {
        let frame = try XCTUnwrap(controller.pageView(for: page)).frame
        let scale = frame.width / CGFloat(controller.model.pages[page].widthPt)
        return CGPoint(x: frame.minX + point.x * scale, y: frame.minY + point.y * scale)
    }

    /// Drags out a shape from `start` to `end` (PDF points on `page`), as the pan does, and waits for
    /// what it made: nil when it made nothing.
    @discardableResult
    func drag(from start: CGPoint, to end: CGPoint, page: Int = 0, in controller: PageScrollViewController) async throws -> Bool? {
        let markup = controller.markupInteraction
        XCTAssertTrue(markup.beginShape(atContentPoint: try contentPoint(start, page: page, in: controller)))
        markup.moveShape(toContentPoint: try contentPoint(end, page: page, in: controller))
        guard let made = markup.endShape(atContentPoint: try contentPoint(end, page: page, in: controller)) else { return nil }
        return await made.value
    }

    /// Types `text` into the text box being edited, as the keyboard does.
    func type(_ text: String, into editor: InlineTextEditor) {
        editor.text = text
        editor.delegate?.textViewDidChange?(editor)
    }

    // MARK: Which touches they take

    /// One finger on a page draws a shape while a shape tool is picked and may be used there; in the
    /// gap between pages, or before the permissions are read, it scrolls. Text Box and Note take a
    /// tap, not a drag.
    func testShapeToolsTakeOneFingerOnAPage() async throws {
        let (controller, model, _) = await makeController()
        let markup = controller.markupInteraction
        let onPage = try contentPoint(CGPoint(x: 300, y: 400), in: controller)
        let gap = try contentPoint(CGPoint(x: 300, y: 795), in: controller)
        for tool in [Tool.rectangle, .oval, .line, .arrow] {
            pick(tool, in: model, controller)
            XCTAssertTrue(markup.takesTouch(atContentPoint: onPage), "\(tool)")
            XCTAssertFalse(markup.takesTouch(atContentPoint: gap), "\(tool) in the gap")
            XCTAssertFalse(markup.takesTap(atContentPoint: onPage), "\(tool) takes no tap")
        }
        for tool in [Tool.textBox, .note] {
            pick(tool, in: model, controller)
            XCTAssertFalse(markup.takesTouch(atContentPoint: onPage), "\(tool) drags nothing")
            XCTAssertTrue(markup.takesTap(atContentPoint: onPage), "\(tool)")
            XCTAssertFalse(markup.takesTap(atContentPoint: gap), "\(tool) in the gap")
        }
        for tool in [nil, Tool.select, .ink, .eraser] {
            pick(tool, in: model, controller)
            XCTAssertFalse(markup.takesTap(atContentPoint: onPage), "\(String(describing: tool))")
            XCTAssertFalse(markup.beginShape(atContentPoint: onPage), "\(String(describing: tool))")
        }
        XCTAssertEqual(controller.scrollView.panGestureRecognizer.minimumNumberOfTouches, 1, "one finger off the pages scrolls")

        // Before the permissions are read, nothing is taken.
        let fresh = DocumentModel(bytes: PageScrollViewControllerTests.letterPages(2))
        let other = PageScrollViewController(model: fresh)
        other.view.frame = CGRect(origin: .zero, size: CGSize(width: 400, height: 800))
        other.view.layoutIfNeeded()
        fresh.tool = .rectangle
        other.markupTool = .rectangle
        XCTAssertFalse(other.markupInteraction.takesTouch(atContentPoint: CGPoint(x: 200, y: 200)))
        fresh.tool = .note
        other.markupTool = .note
        XCTAssertFalse(other.markupInteraction.takesTap(atContentPoint: CGPoint(x: 200, y: 200)))
        await fresh.settle()
        XCTAssertTrue(other.markupInteraction.takesTap(atContentPoint: CGPoint(x: 200, y: 200)))
    }

    /// The tap is on the content view, one finger, and asks the interaction before it takes a touch.
    func testTheTapIsOneFingerOnTheContentView() async {
        let (controller, _, _) = await makeController()
        let tap = controller.markupInteraction.placeTap
        XCTAssertTrue(tap.view === controller.contentView)
        XCTAssertEqual(tap.numberOfTouchesRequired, 1)
        XCTAssertTrue(tap.delegate === controller.markupInteraction)
    }

    // MARK: Shapes

    /// While the finger drags, the shape is drawn dashed over the page, in its tool's colour; when it
    /// comes up the shape is added where it was dragged, drawn solid until the page shows it, and
    /// then goes.
    func testDraggingOutARectangleShowsItThenAddsIt() async throws {
        let (controller, model, undoManager) = await makeController()
        let markup = controller.markupInteraction
        let overlay = try XCTUnwrap(controller.pageView(for: 0)).overlay
        XCTAssertTrue(markup.beginShape(atContentPoint: try contentPoint(CGPoint(x: 300, y: 300), in: controller)))
        markup.moveShape(toContentPoint: try contentPoint(CGPoint(x: 100, y: 200), in: controller))
        let box = CGRect(x: 100, y: 200, width: 200, height: 100)
        try assertDraft(overlay.draft, is: .rect(box, oval: false))
        XCTAssertTrue(overlay.draftStyle.dashed)
        XCTAssertNotNil(overlay.draftLayer.path)
        XCTAssertFalse(overlay.draftLayer.lineDashPattern?.isEmpty ?? true, "dashed while dragged")

        let made = try XCTUnwrap(markup.endShape(atContentPoint: try contentPoint(CGPoint(x: 100, y: 200), in: controller)))
        XCTAssertFalse(overlay.draftStyle.dashed, "solid while it is added")
        XCTAssertNotNil(overlay.draft)
        let ok = await made.value
        XCTAssertTrue(ok)
        let shape = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first)
        XCTAssertEqual(shape.kind, .rectangle)
        XCTAssertEqual(shape.rect.x, 100, accuracy: 2); XCTAssertEqual(shape.rect.y, 200, accuracy: 2)
        XCTAssertEqual(shape.rect.width, 200, accuracy: 4); XCTAssertEqual(shape.rect.height, 100, accuracy: 4)
        XCTAssertEqual(undoManager.undoActionName, Strings.actionAddAnnotation)
        try await Task.sleep(for: MarkupInteraction.inkPreviewDuration + .milliseconds(200))
        XCTAssertNil(overlay.draft, "the drawn shape goes once the page shows it")
    }

    func testEachShapeToolAddsItsShape() async throws {
        let (controller, model, _) = await makeController()
        for (tool, y) in [(Tool.oval, 100.0), (.line, 300), (.arrow, 500)] {
            pick(tool, in: model, controller)
            let made = try await drag(from: CGPoint(x: 100, y: y), to: CGPoint(x: 300, y: y + 80), in: controller)
            XCTAssertEqual(made, true, "\(tool)")
        }
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).map(\.kind), [.oval, .line, .line])
    }

    /// The arrow is drawn with its head while it is dragged out.
    func testAnArrowIsDrawnWithItsHead() async throws {
        let (controller, model, _) = await makeController()
        pick(.arrow, in: model, controller)
        let markup = controller.markupInteraction
        let overlay = try XCTUnwrap(controller.pageView(for: 0)).overlay
        XCTAssertTrue(markup.beginShape(atContentPoint: try contentPoint(CGPoint(x: 100, y: 100), in: controller)))
        markup.moveShape(toContentPoint: try contentPoint(CGPoint(x: 300, y: 100), in: controller))
        try assertDraft(overlay.draft, is: .line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100), arrow: true))
        XCTAssertEqual(subpaths(of: overlay.draftLayer), 2, "the line and its head")
        markup.cancelShape()
        XCTAssertNil(overlay.draft, "a cancelled drag leaves nothing")
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
    }

    /// A drag shorter than `ShapeGeometry.minimumSide` either way is no shape: nothing is added.
    func testATinyDragAddsNothing() async throws {
        let (controller, model, undoManager) = await makeController()
        let made = try await drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 104, y: 160), in: controller)
        XCTAssertNil(made)
        XCTAssertNil(try XCTUnwrap(controller.pageView(for: 0)).overlay.draft)
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
        XCTAssertFalse(undoManager.canUndo)
    }

    /// A drag that runs off its page keeps to it: the shape stops at the page's edge.
    func testADragOffThePageStopsAtItsEdge() async throws {
        let (controller, model, _) = await makeController()
        let markup = controller.markupInteraction
        XCTAssertTrue(markup.beginShape(atContentPoint: try contentPoint(CGPoint(x: 100, y: 700), in: controller)))
        let below = try contentPoint(CGPoint(x: 200, y: 100), page: 1, in: controller)
        markup.moveShape(toContentPoint: below)
        let made = try XCTUnwrap(markup.endShape(atContentPoint: below))
        let ok = await made.value
        XCTAssertTrue(ok)
        let shape = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first)
        XCTAssertEqual(shape.rect.y + shape.rect.height, 792, accuracy: 3)
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 1).isEmpty)
    }

    /// A drag whose tool was changed before the finger came up adds nothing.
    func testADragWhoseToolChangedAddsNothing() async throws {
        let (controller, model, _) = await makeController()
        let markup = controller.markupInteraction
        XCTAssertTrue(markup.beginShape(atContentPoint: try contentPoint(CGPoint(x: 100, y: 100), in: controller)))
        markup.moveShape(toContentPoint: try contentPoint(CGPoint(x: 300, y: 300), in: controller))
        pick(.select, in: model, controller)
        XCTAssertNil(markup.endShape(atContentPoint: try contentPoint(CGPoint(x: 300, y: 300), in: controller)))
        XCTAssertNil(try XCTUnwrap(controller.pageView(for: 0)).overlay.draft)
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
    }

    /// A shape is placed in view space: one dragged out while a turn of its page was on its way is
    /// refused as stale, and nothing that looks drawn is left.
    func testAShapeRefusedAsStaleLeavesNoGhost() async throws {
        let (controller, model, undoManager) = await makeController()
        let markup = controller.markupInteraction
        // Something to take back, then a drag begun before it is taken back behind the toolbar's back
        // (a shake, say): the page's annotations are numbered again under the drag.
        _ = await model.addNote(page: 0, at: CGPoint(x: 500, y: 700), contents: "x")
        XCTAssertTrue(markup.beginShape(atContentPoint: try contentPoint(CGPoint(x: 100, y: 100), in: controller)))
        undoManager.undo(); await model.settle()
        markup.moveShape(toContentPoint: try contentPoint(CGPoint(x: 300, y: 300), in: controller))
        let made = try XCTUnwrap(markup.endShape(atContentPoint: try contentPoint(CGPoint(x: 300, y: 300), in: controller)))
        let ok = await made.value
        XCTAssertFalse(ok)
        XCTAssertEqual(model.failure?.message, Strings.documentChangedTryAgain)
        XCTAssertNil(try XCTUnwrap(controller.pageView(for: 0)).overlay.draft, "no ghost of the refused shape")
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
    }

    /// The same, with the page turned: the drag is refused and the page shows nothing of it.
    func testAShapeDraggedWhileItsPageTurnedIsRefused() async throws {
        let (controller, model, _) = await makeController()
        let markup = controller.markupInteraction
        XCTAssertTrue(markup.beginShape(atContentPoint: try contentPoint(CGPoint(x: 100, y: 100), in: controller)))
        let rotate = model.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        markup.moveShape(toContentPoint: try contentPoint(CGPoint(x: 300, y: 300), in: controller))
        let made = try XCTUnwrap(markup.endShape(atContentPoint: try contentPoint(CGPoint(x: 300, y: 300), in: controller)))
        let rotated = await rotate.value
        let ok = await made.value
        XCTAssertTrue(rotated); XCTAssertFalse(ok)
        XCTAssertEqual(model.failure?.message, Strings.documentChangedTryAgain)
        for page in controller.loadedPages {
            XCTAssertNil(controller.pageView(for: page)?.overlay.draft)
        }
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
    }

    /// Strokes drawn with Draw and waiting are added when a shape tool, Text Box or Note is picked.
    func testPickingAnotherToolAddsTheStrokesWaiting() async throws {
        for next in [Tool.rectangle, .textBox, .note] {
            let (controller, model, _) = await makeController(tool: .ink)
            let ink = try XCTUnwrap(controller.markupInteraction.drawing.ink)
            let points = (0...10).map { CGPoint(x: 100 + 10 * Double($0), y: 100) }
            ink.drawing = PKDrawing(strokes: [InkGeometryTests.stroke(points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) })])
            XCTAssertTrue(model.hasPendingInk)
            pick(next, in: model, controller)
            await model.settle()
            XCTAssertFalse(model.hasPendingInk, "\(next)")
            XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).map(\.kind), [.ink], "\(next)")
        }
    }

    // MARK: Notes

    /// A tap with Note picked opens the note sheet for a new note there, its icon kept on the page;
    /// a tap on a note opens that one, with its text.
    func testATapWithNoteOpensTheNoteThere() async throws {
        let (controller, model, _) = await makeController(tool: .note)
        let markup = controller.markupInteraction
        markup.place(atContentPoint: try contentPoint(CGPoint(x: 200, y: 300), in: controller))
        let draft = try XCTUnwrap(model.noteDraft)
        XCTAssertEqual(draft.page, 0)
        XCTAssertEqual(draft.point.x, 200, accuracy: 0.01); XCTAssertEqual(draft.point.y, 300, accuracy: 0.01)
        XCTAssertNil(draft.existing)
        XCTAssertEqual(draft.text, "")
        XCTAssertEqual(draft.revision, model.revision)
        let saved = await model.saveNote(draft, text: "Look")
        XCTAssertTrue(saved)
        model.noteDraft = nil

        // On the note's icon: that note, with its text.
        markup.place(atContentPoint: try contentPoint(CGPoint(x: 210, y: 310), in: controller))
        let open = try XCTUnwrap(model.noteDraft)
        XCTAssertEqual(open.existing, AnnotationRef(page: 0, index: 0))
        XCTAssertEqual(open.text, "Look")
        model.noteDraft = nil

        // At the page's corner: the icon is kept on it.
        markup.place(atContentPoint: try contentPoint(CGPoint(x: 611, y: 791), in: controller))
        XCTAssertEqual(model.noteDraft?.point, CGPoint(x: 592, y: 772))
    }

    // MARK: Text boxes

    /// A tap with Text Box picked puts a box to type in there, over the page at the zoom the view is
    /// at: its text as big on screen as it will be on the page. Its undo manager is its own.
    func testATapWithTextBoxPutsABoxToTypeInThere() async throws {
        let (controller, model, undoManager) = await makeController(tool: .textBox)
        let markup = controller.markupInteraction
        markup.place(atContentPoint: try contentPoint(CGPoint(x: 100, y: 200), in: controller))
        let editor = try XCTUnwrap(markup.textBoxes.textEditor)
        XCTAssertTrue(editor.superview === controller.scrollView, "in the scroll view, sharp at any zoom")
        XCTAssertEqual(editor.page, 0)
        XCTAssertEqual(editor.origin.x, 100, accuracy: 0.001); XCTAssertEqual(editor.origin.y, 200, accuracy: 0.001)
        XCTAssertFalse(editor.undoManager === undoManager, "typing is not a change to the document")
        XCTAssertNotNil(editor.undoManager)
        let box = ShapeGeometry.textBoxRect(at: editor.origin, text: "", fontSize: 14, pageSize: CGSize(width: 612, height: 792))
        try assertFrame(of: editor, is: box, in: controller)
        XCTAssertEqual(try XCTUnwrap(editor.font).pointSize, 14 * scale, accuracy: 0.01)

        // Zoomed in twice: twice as big, still over the same place.
        controller.scrollView.zoomScale = 2
        controller.view.layoutIfNeeded()
        try assertFrame(of: editor, is: box, in: controller)
        XCTAssertEqual(try XCTUnwrap(editor.font).pointSize, 14 * scale * 2, accuracy: 0.01)

        // It grows with what is typed.
        type("A first line\nand a second", into: editor)
        XCTAssertTrue(model.hasPendingText)
        try assertFrame(of: editor, is: ShapeGeometry.textBoxRect(at: editor.origin, text: "A first line\nand a second", fontSize: 14,
                                                                   pageSize: CGSize(width: 612, height: 792)), in: controller)
    }

    /// What is typed lands where it was typed: a text box at the box the editor showed, with its text,
    /// in Text Box's style, once another tool is picked.
    func testTypedTextLandsWhereItWasTyped() async throws {
        let (controller, model, undoManager) = await makeController(tool: .textBox)
        model.toolStyles[.textBox] = ToolStyle(color: RGBA(r: 0.9, g: 0.1, b: 0.1), width: 2, fontSize: 20, fill: false)
        let markup = controller.markupInteraction
        markup.place(atContentPoint: try contentPoint(CGPoint(x: 120, y: 240), in: controller))
        let editor = try XCTUnwrap(markup.textBoxes.textEditor)
        type("Two\nlines", into: editor)
        pick(.select, in: model, controller)
        XCTAssertNil(markup.textBoxes.textEditor)
        XCTAssertNil(editor.superview)
        XCTAssertFalse(model.hasPendingText)
        XCTAssertEqual(markup.textBoxes.textPreviews.count, 1, "what was typed stays on screen while it is added")
        await model.settle()
        let box = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first)
        XCTAssertEqual(box.kind, .textBox)
        XCTAssertEqual(box.contents, "Two\nlines")
        let expected = ShapeGeometry.textBoxRect(at: CGPoint(x: 120, y: 240), text: "Two\nlines", fontSize: 20, pageSize: CGSize(width: 612, height: 792))
        XCTAssertEqual(box.rect.x, expected.minX, accuracy: 0.5); XCTAssertEqual(box.rect.y, expected.minY, accuracy: 0.5)
        XCTAssertEqual(box.rect.width, expected.width, accuracy: 0.5); XCTAssertEqual(box.rect.height, expected.height, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(box.color).red, 0.9, accuracy: 0.01)
        XCTAssertEqual(undoManager.undoActionName, Strings.actionAddAnnotation)
        try await Task.sleep(for: MarkupInteraction.inkPreviewDuration + .milliseconds(200))
        XCTAssertTrue(markup.textBoxes.textPreviews.isEmpty)
    }

    /// A tap on the page while a box is being typed in ends it (its text is added) and starts none.
    func testATapWhileTypingEndsTheTextBox() async throws {
        let (controller, model, _) = await makeController(tool: .textBox)
        let markup = controller.markupInteraction
        markup.place(atContentPoint: try contentPoint(CGPoint(x: 100, y: 100), in: controller))
        type("Hello", into: try XCTUnwrap(markup.textBoxes.textEditor))
        XCTAssertTrue(markup.takesTap(atContentPoint: try contentPoint(CGPoint(x: 300, y: 795), in: controller)), "in the gap too")
        markup.place(atContentPoint: try contentPoint(CGPoint(x: 300, y: 500), in: controller))
        XCTAssertNil(markup.textBoxes.textEditor, "no new box on the same tap")
        await model.settle()
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).map(\.contents), ["Hello"])
        // The next tap starts one.
        markup.place(atContentPoint: try contentPoint(CGPoint(x: 300, y: 500), in: controller))
        XCTAssertNotNil(markup.textBoxes.textEditor)
    }

    /// The end of editing (the keyboard put away), Markup turned off, the pages laid out again, a
    /// finger outside the pages, any other change: each adds the text being typed.
    func testTheTextBeingTypedIsAddedWhenEditingEnds() async throws {
        let triggers: [(String, (PageScrollViewController, DocumentModel, InlineTextEditor) -> Void)] = [
            ("end of editing", { _, _, editor in editor.delegate?.textViewDidEndEditing?(editor) }),
            ("Markup off", { controller, model, _ in model.tool = nil; controller.markupTool = nil }),
            ("a finger outside the pages", { controller, _, _ in controller.markupInteraction.fingerWentDown(on: UIView()) }),
            ("the model's commit", { _, model, _ in model.commitPendingInk() }),
            ("another change", { _, model, _ in model.enqueue([.rotatePages(pages: [1], degrees: 90)], named: Strings.actionRotate, touching: [1]) }),
            ("a new layout", { controller, _, _ in controller.markupInteraction.layoutWillChange() }),
        ]
        for (name, trigger) in triggers {
            let (controller, model, _) = await makeController(tool: .textBox)
            let markup = controller.markupInteraction
            markup.place(atContentPoint: try contentPoint(CGPoint(x: 100, y: 100), in: controller))
            let editor = try XCTUnwrap(markup.textBoxes.textEditor)
            type("Kept", into: editor)
            trigger(controller, model, editor)
            await model.settle()
            XCTAssertNil(markup.textBoxes.textEditor, name)
            XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).map(\.contents), ["Kept"], name)
        }
    }

    /// A finger on the pages, or on the box itself, does not end it.
    func testAFingerOnThePagesOrTheBoxDoesNotEndIt() async throws {
        let (controller, _, _) = await makeController(tool: .textBox)
        let markup = controller.markupInteraction
        markup.place(atContentPoint: try contentPoint(CGPoint(x: 100, y: 100), in: controller))
        let editor = try XCTUnwrap(markup.textBoxes.textEditor)
        type("Still typing", into: editor)
        markup.fingerWentDown(on: editor)
        markup.fingerWentDown(on: controller.contentView)
        XCTAssertTrue(markup.textBoxes.textEditor === editor)
    }

    /// Nothing typed: no text box, no change, nothing left on the page.
    func testAnEmptyTextBoxAddsNothing() async throws {
        let (controller, model, undoManager) = await makeController(tool: .textBox)
        let markup = controller.markupInteraction
        markup.place(atContentPoint: try contentPoint(CGPoint(x: 100, y: 100), in: controller))
        type("  \n", into: try XCTUnwrap(markup.textBoxes.textEditor))
        XCTAssertFalse(model.hasPendingText, "only spaces are nothing to add")
        pick(.note, in: model, controller)
        await model.settle()
        XCTAssertNil(markup.textBoxes.textEditor)
        XCTAssertTrue(markup.textBoxes.textPreviews.isEmpty)
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
        XCTAssertFalse(undoManager.canUndo)
        XCTAssertNil(model.failure)
    }

    /// On a turned page Text Box is refused: a tap puts no box there.
    func testNoTextBoxIsPutOnATurnedPage() async throws {
        let (controller, model, _) = await makeController(tool: .textBox, data: PageScrollViewControllerTests.letterPages(1, landscape: false).rotated())
        XCTAssertEqual(model.pages.first?.rotationDegrees, 90)
        let markup = controller.markupInteraction
        let point = try contentPoint(CGPoint(x: 100, y: 100), in: controller)
        XCTAssertFalse(markup.takesTap(atContentPoint: point))
        markup.place(atContentPoint: point)
        XCTAssertNil(markup.textBoxes.textEditor)
        XCTAssertFalse(model.canUse(.textBox))
        XCTAssertEqual(model.refusal(of: .textBox), Strings.textBoxNeedsUprightPage)
    }

    /// Text typed on a box placed before the page's annotations were numbered again (an undo behind
    /// the toolbar's back) is refused as stale; nothing of it is left on the page.
    func testATextBoxRefusedAsStaleLeavesNothing() async throws {
        let (controller, model, undoManager) = await makeController(tool: .textBox)
        let markup = controller.markupInteraction
        _ = await model.addNote(page: 0, at: CGPoint(x: 500, y: 700), contents: "x")
        markup.place(atContentPoint: try contentPoint(CGPoint(x: 100, y: 100), in: controller))
        type("Late", into: try XCTUnwrap(markup.textBoxes.textEditor))
        undoManager.undo(); await model.settle()
        let made = try XCTUnwrap(markup.commitPendingText())
        let ok = await made.value
        XCTAssertFalse(ok)
        XCTAssertEqual(model.failure?.message, Strings.documentChangedTryAgain)
        XCTAssertTrue(markup.textBoxes.textPreviews.isEmpty, "no ghost of the refused text")
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
    }

    // MARK: The overlay's draft

    /// A draft is drawn in PDF points scaled to the overlay, as the boxes are; a rectangle's line lies
    /// inside its box, as the engine draws it.
    func testTheDraftIsScaledToTheOverlay() {
        let overlay = PageOverlayView(pointSize: CGSize(width: 612, height: 792))
        overlay.frame = CGRect(x: 0, y: 0, width: 306, height: 396)
        overlay.layoutIfNeeded()
        XCTAssertNil(overlay.draftLayer.path)
        overlay.draftStyle = DraftStyle(color: .red, width: 4, fill: nil, dashed: true)
        overlay.draft = .rect(CGRect(x: 100, y: 100, width: 200, height: 100), oval: false)
        XCTAssertEqual(overlay.draftLayer.path?.boundingBox ?? .null, CGRect(x: 51, y: 51, width: 98, height: 48))
        XCTAssertEqual(overlay.draftLayer.lineWidth, 2, "4 points at half scale")
        XCTAssertNil(overlay.draftLayer.fillColor)
        overlay.draftStyle = DraftStyle(color: .red, width: 4, fill: .blue, dashed: false)
        XCTAssertEqual(overlay.draftLayer.fillColor, UIColor.blue.cgColor)
        XCTAssertTrue(overlay.draftLayer.lineDashPattern?.isEmpty ?? true)
        overlay.draft = nil
        XCTAssertNil(overlay.draftLayer.path)
    }

    // MARK: Helpers

    /// Whether `draft` is `expected`, within a hundredth of a point (the content view's coordinates
    /// round-trip through the layout's scale).
    func assertDraft(_ draft: DraftShape?, is expected: DraftShape, file: StaticString = #filePath, line: UInt = #line) throws {
        switch (try XCTUnwrap(draft, file: file, line: line), expected) {
        case let (.rect(a, ovalA), .rect(b, ovalB)):
            XCTAssertEqual(ovalA, ovalB, file: file, line: line)
            for (x, y) in [(a.minX, b.minX), (a.minY, b.minY), (a.width, b.width), (a.height, b.height)] {
                XCTAssertEqual(x, y, accuracy: 0.01, "\(a) \(b)", file: file, line: line)
            }
        case let (.line(fromA, toA, arrowA), .line(fromB, toB, arrowB)):
            XCTAssertEqual(arrowA, arrowB, file: file, line: line)
            for (x, y) in [(fromA.x, fromB.x), (fromA.y, fromB.y), (toA.x, toB.x), (toA.y, toB.y)] {
                XCTAssertEqual(x, y, accuracy: 0.01, file: file, line: line)
            }
        default:
            XCTFail("\(String(describing: draft)) is not \(expected)", file: file, line: line)
        }
    }

    /// Whether `editor` covers `box` (PDF points on page 0) in the scroll view, at its zoom.
    func assertFrame(of editor: InlineTextEditor, is box: CGRect, in controller: PageScrollViewController,
                     file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try XCTUnwrap(controller.scrollViewRect(of: box, onPage: 0), file: file, line: line)
        for (a, b) in [(editor.frame.minX, expected.minX), (editor.frame.minY, expected.minY),
                       (editor.frame.width, expected.width), (editor.frame.height, expected.height)] {
            XCTAssertEqual(a, b, accuracy: 0.01, "\(editor.frame) \(expected)", file: file, line: line)
        }
    }

    /// How many lines a layer's path starts (move-tos).
    func subpaths(of layer: CAShapeLayer) -> Int {
        var count = 0
        layer.path?.applyWithBlock { if $0.pointee.type == .moveToPoint { count += 1 } }
        return count
    }
}

private extension Data {
    /// This PDF with its first page turned a quarter (`/Rotate 90`), through the engine.
    @MainActor
    func rotated() -> Data {
        let model = DocumentModel(bytes: self)
        guard let document = model.document(),
              (try? document.apply(edit: .rotatePages(pages: [0], degrees: 90), baseRevision: document.revision())) != nil,
              let saved = try? document.save(mode: .full) else { return self }
        return saved
    }
}
