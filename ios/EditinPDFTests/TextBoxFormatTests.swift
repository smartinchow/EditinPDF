import EditinPDFCore
import UIKit
import XCTest
@testable import EditinPDF

/// A text box's look (`TextBoxFormat`): what it starts from, how its controls step, what Text Box
/// keeps of it, and the state the format bar shows (`TextBoxFormatState`).
@MainActor
final class TextBoxFormatTests: XCTestCase {
    private let black = RGBA(r: 0, g: 0, b: 0), red = RGBA(r: 0.9, g: 0.1, b: 0.1)

    func testANewBoxStartsFromTextBoxsStyle() {
        let style = ToolStyle(color: red, width: 2, fontSize: 18, fill: false, background: TextBoxFormat.backgrounds[1], border: true)
        let format = TextBoxFormat(style: style)
        XCTAssertEqual(format.fontSize, 18)
        XCTAssertEqual(format.color, red)
        XCTAssertEqual(format.background, TextBoxFormat.backgrounds[1])
        XCTAssertEqual(format.borderWidth, TextBoxFormat.borderOn)
        XCTAssertEqual(TextBoxFormat(style: ToolStyle.initial(for: .textBox)),
                       TextBoxFormat(fontSize: 14, color: black, background: nil, borderWidth: 0), "no background, no border at first")
    }

    /// A box on the page starts from its own look as the engine draws it; what the file does not say
    /// is Text Box's. Numbers the bridge would refuse are held to what it takes.
    func testABoxOnThePageStartsFromItsOwnLook() {
        var info = annotation(kind: .textBox)
        info.fontSize = 9.5
        info.color = RgbColor(red: 0, green: 0, blue: 1)
        info.fill = RgbColor(red: 1, green: 1, blue: 0.8)
        info.borderWidth = 2
        let style = ToolStyle(color: red, width: 2, fontSize: 30, fill: false)
        let format = TextBoxFormat(info, otherwise: style)
        XCTAssertEqual(format, TextBoxFormat(fontSize: 9.5, color: RGBA(r: 0, g: 0, b: 1), background: RGBA(r: 1, g: 1, b: 0.8), borderWidth: 2))
        let unknown = TextBoxFormat(annotation(kind: .textBox), otherwise: style)
        XCTAssertEqual(unknown, TextBoxFormat(fontSize: 30, color: red, background: nil, borderWidth: 0))
        info.fontSize = 300
        info.borderWidth = 0.2
        XCTAssertEqual(TextBoxFormat(info, otherwise: style).fontSize, 144, "held to what the bridge takes")
        XCTAssertEqual(TextBoxFormat(info, otherwise: style).borderWidth, 0.5)
        XCTAssertEqual(TextBoxFormat.heldBorder(.nan), 0)
        XCTAssertEqual(TextBoxFormat.heldBorder(40), 12)
        info.color = RgbColor(red: .nan, green: 7, blue: -.infinity)
        XCTAssertEqual(TextBoxFormat(info, otherwise: style).color, RGBA(r: 0, g: 1, b: 0), "a file's colour is held to what the bridge takes")
    }

    func testSmallerAndLargerStepThroughTheSizes() {
        var format = TextBoxFormat(fontSize: 12, color: black)
        format.grow()
        XCTAssertEqual(format.fontSize, 14)
        format.shrink(); format.shrink()
        XCTAssertEqual(format.fontSize, 11)
        format = TextBoxFormat(fontSize: 9.5, color: black)
        XCTAssertEqual(format.largerSize, 10, "a size between steps goes to the next")
        XCTAssertEqual(format.smallerSize, 9)
        format = TextBoxFormat(fontSize: 72, color: black)
        XCTAssertNil(format.largerSize)
        format.grow()
        XCTAssertEqual(format.fontSize, 72, "no larger than 72")
        format = TextBoxFormat(fontSize: 6, color: black)
        XCTAssertNil(format.smallerSize)
        format.shrink()
        XCTAssertEqual(format.fontSize, 6, "no smaller than 6")
    }

    func testBorderOnKeepsAWidthItHadAndOffIsNone() {
        var format = TextBoxFormat(fontSize: 12, color: black, borderWidth: 3)
        XCTAssertTrue(format.hasBorder)
        format.hasBorder = true
        XCTAssertEqual(format.borderWidth, 3)
        format.hasBorder = false
        XCTAssertEqual(format.borderWidth, 0)
        format.hasBorder = true
        XCTAssertEqual(format.borderWidth, TextBoxFormat.borderOn)
        XCTAssertEqual(format.textInset, ShapeGeometry.textInset + 1, "the engine sets the text in by the border too")
    }

    /// Text Box keeps the look picked for the next box; the other parts of its style stay.
    func testTheLookPickedIsKeptAsTextBoxsStyle() {
        let style = ToolStyle(color: black, width: 3, fontSize: 14, fill: true)
        let format = TextBoxFormat(fontSize: 24, color: red, background: TextBoxFormat.backgrounds[0], borderWidth: 1)
        let kept = format.applied(to: style)
        XCTAssertEqual(kept, ToolStyle(color: red, width: 3, fontSize: 24, fill: true, background: TextBoxFormat.backgrounds[0], border: true))
        XCTAssertEqual(TextBoxFormat(style: kept), format)
    }

    func testTheEditThatGivesABoxTheLook() {
        let format = TextBoxFormat(fontSize: 20, color: red, background: TextBoxFormat.backgrounds[2], borderWidth: 1)
        XCTAssertEqual(format.restyle(AnnotationRef(page: 2, index: 5)),
                       .restyleTextBox(page: 2, index: 5, fontSize: 20, color: red.rgbColor, fill: TextBoxFormat.backgrounds[2].rgbColor, borderWidth: 1))
        XCTAssertNil(format.restyle(AnnotationRef(page: -1, index: 0)))
    }

    /// A style kept by an earlier version (no background, no border) still reads.
    func testAStyleKeptBeforeBackgroundsAndBordersStillReads() throws {
        let old = #"{"color":{"r":1,"g":0,"b":0},"width":2,"fontSize":16,"fill":false}"#
        let style = try JSONDecoder().decode(ToolStyle.self, from: Data(old.utf8))
        XCTAssertEqual(style, ToolStyle(color: RGBA(r: 1, g: 0, b: 0), width: 2, fontSize: 16, fill: false))
        let new = ToolStyle(color: red, width: 2, fontSize: 16, fill: false, background: TextBoxFormat.backgrounds[3], border: true)
        XCTAssertEqual(try JSONDecoder().decode(ToolStyle.self, from: JSONEncoder().encode(new)), new)
    }

    /// The bar's state tells the box of each change, once, and says which swatch and which background
    /// are picked.
    func testTheBarsStateTellsTheBoxOfEachChange() {
        let state = TextBoxFormatState(TextBoxFormat(fontSize: 12, color: ToolStyleEditor.swatches[2]))
        var told: [TextBoxFormat] = []
        state.changed = { told.append($0) }
        XCTAssertEqual(state.swatch, 2)
        XCTAssertEqual(state.backgroundChoice, -1, "no background")
        state.format.grow()
        state.format.color = RGBA(r: 0.123, g: 0.4, b: 0.5)
        state.format.background = TextBoxFormat.backgrounds[4]
        state.format.hasBorder = true
        state.format = state.format
        XCTAssertEqual(told.count, 4, "one for each change, none for the same look")
        XCTAssertEqual(told.last?.fontSize, 14)
        XCTAssertNil(state.swatch, "a colour picked with More Colors… is no swatch")
        XCTAssertEqual(state.backgroundChoice, 4)
        state.format.color = RGBA(r: Double(Float(0.9)), g: Double(Float(0.1)), b: 0.1)
        XCTAssertEqual(state.swatch, 2, "a colour read back from the file, in single precision, is still its swatch")
    }

    /// Over a box on the page, the box keeps its width unless the size or the background changes, as
    /// the bridge does; then the room for the text grows with the size, up to the page's edge.
    func testARestyledBoxGrowsAcrossAsTheBridgeDoes() {
        let old = TextBoxFormat(fontSize: 12, color: black)
        XCTAssertEqual(ShapeGeometry.restyledWidth(100, from: old, to: TextBoxFormat(fontSize: 12, color: red, borderWidth: 1), room: 500), 100,
                       "a colour or a border alone is changed in place")
        XCTAssertEqual(ShapeGeometry.restyledWidth(100, from: old, to: TextBoxFormat(fontSize: 24, color: black), room: 500), 96 * 2 + 4, accuracy: 0.001)
        XCTAssertEqual(ShapeGeometry.restyledWidth(100, from: old, to: TextBoxFormat(fontSize: 24, color: black), room: 150), 150, "no further than the page's edge")
        XCTAssertEqual(ShapeGeometry.restyledWidth(100, from: old, to: TextBoxFormat(fontSize: 12, color: black, background: TextBoxFormat.backgrounds[0], borderWidth: 1),
                                                   room: 500), 102, accuracy: 0.001, "a new background adds it again, with the border's margins")
    }

    private func annotation(kind: AnnotationKind) -> AnnotationInfo {
        AnnotationInfo(page: 0, index: 0, kind: kind, rect: Rect(x: 0, y: 0, width: 10, height: 10), contents: nil, author: nil,
                       modified: nil, color: nil, locked: false, fontSize: nil, fill: nil, borderWidth: nil)
    }
}

/// The format bar while a text box is typed in, Select's Format, and the model's restyle, on a real
/// document.
extension AnnotationEditingTests {
    /// A new box is made with the look the bar picks, which Text Box keeps for the next one; the box
    /// being typed in shows it as it is picked.
    func testANewTextBoxIsMadeWithTheLookTheBarPicks() async throws {
        let (controller, model, undoManager) = await makeController(tool: .textBox)
        let markup = controller.markupInteraction
        markup.place(atContentPoint: try contentPoint(CGPoint(x: 100, y: 200), in: controller))
        let editor = try XCTUnwrap(markup.textBoxes.textEditor)
        let state = try XCTUnwrap(markup.textBoxes.formatState)
        XCTAssertNotNil(editor.inputAccessoryView, "the bar is over the keyboard")
        XCTAssertEqual(state.format, TextBoxFormat(style: ToolStyle.initial(for: .textBox)))
        type("Hello", into: editor)
        let before = editor.box
        state.format.grow(); state.format.grow()
        state.format.color = ToolStyleEditor.swatches[6]
        state.format.background = TextBoxFormat.backgrounds[0]
        state.format.hasBorder = true
        XCTAssertEqual(editor.format, state.format, "the box follows the bar")
        XCTAssertEqual(editor.fontSize, 18)
        XCTAssertGreaterThan(editor.box.height, before.height, "taller with larger text")
        XCTAssertEqual(editor.backgroundColor, TextBoxFormat.backgrounds[0].uiColor)
        XCTAssertGreaterThan(editor.layer.borderWidth, 0)
        XCTAssertEqual(model.toolStyles[.textBox].fontSize, 18, "Text Box keeps it")
        XCTAssertTrue(model.toolStyles[.textBox].border)
        markup.place(atContentPoint: try contentPoint(CGPoint(x: 400, y: 600), in: controller))
        await model.settle()
        let made = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first)
        XCTAssertEqual(made.fontSize, 18)
        XCTAssertEqual(made.borderWidth, 1)
        XCTAssertEqual(try XCTUnwrap(made.fill).red, TextBoxFormat.backgrounds[0].r, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(made.color).blue, ToolStyleEditor.swatches[6].b, accuracy: 0.01)
        XCTAssertEqual(undoManager.undoActionName, Strings.actionAddAnnotation)
        markup.place(atContentPoint: try contentPoint(CGPoint(x: 100, y: 500), in: controller))
        XCTAssertEqual(try XCTUnwrap(markup.textBoxes.formatState).format.fontSize, 18, "the next box starts from it")
    }

    /// Edit over a text box starts from its own size and colour (not Text Box's), and a new look picked
    /// as its words change is made with them: one step of Undo.
    func testEditingATextBoxStartsFromItsLookAndChangesWordsAndLookInOneStep() async throws {
        let (controller, model, undoManager) = await makeController()
        model.toolStyles[.textBox] = ToolStyle(color: RGBA(r: 0, g: 0.4, b: 1), width: 2, fontSize: 20, fill: false)
        _ = await model.addTextBox(page: 0, at: CGPoint(x: 100, y: 200), text: "Old")
        model.toolStyles[.textBox] = ToolStyle(color: RGBA(r: 0, g: 0, b: 0), width: 2, fontSize: 9, fill: false)
        let box = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first)
        let markup = controller.markupInteraction
        XCTAssertTrue(markup.textBoxes.beginEditing(box))
        let editor = try XCTUnwrap(markup.textBoxes.textEditor)
        XCTAssertEqual(editor.fontSize, 20, "the box's own size")
        XCTAssertEqual(editor.format.color.b, 1, accuracy: 0.01, "the box's own colour")
        let state = try XCTUnwrap(markup.textBoxes.formatState)
        state.format.background = TextBoxFormat.backgrounds[1]
        XCTAssertTrue(model.hasPendingText, "a new look alone is a change")
        XCTAssertEqual(model.pendingTextName, Strings.formatTextBox)
        type("New", into: editor)
        XCTAssertEqual(model.toolStyles[.textBox].fontSize, 9, "a box on the page does not change Text Box's style")
        markup.commitPendingText()
        await model.settle()
        let changed = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first)
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).count, 1)
        XCTAssertEqual(changed.contents, "New")
        XCTAssertNotNil(changed.fill)
        XCTAssertEqual(changed.fontSize, 20)
        XCTAssertEqual(undoManager.undoActionName, Strings.formatTextBox)
        undoManager.undo(); await model.settle()
        let undone = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first)
        XCTAssertEqual(undone.contents, "Old", "one Undo takes back the words and the look")
        XCTAssertNil(undone.fill)
    }

    /// Select's Format opens the sheet with the box's look; Apply gives it the look picked, one change
    /// named Format Text Box; a new size adds the box again, at the end of its page's list.
    func testFormatFromTheMenuRestylesTheTextBox() async throws {
        let (controller, model, undoManager) = await makeController()
        _ = await model.addShape(page: 0, draft: .rect(CGRect(x: 300, y: 300, width: 50, height: 50), oval: false))
        _ = await model.addTextBox(page: 0, at: CGPoint(x: 100, y: 200), text: "Box")
        _ = await model.addShape(page: 0, draft: .rect(CGRect(x: 300, y: 500, width: 50, height: 50), oval: false))
        let box = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first { $0.kind == .textBox })
        XCTAssertEqual(box.index, 1)
        let selecting = controller.markupInteraction.selecting
        XCTAssertEqual(selecting.actions(for: box), [.edit, .format, .delete])
        selecting.perform(.format, on: box)
        let draft = try XCTUnwrap(model.formatDraft)
        XCTAssertEqual(draft.ref, AnnotationRef(page: 0, index: 1))
        XCTAssertEqual(draft.format.fontSize, 14)
        var picked = draft.format
        picked.grow()
        picked.color = ToolStyleEditor.swatches[2]
        let made = await model.applyFormatDraft(picked)
        XCTAssertTrue(made)
        XCTAssertNil(model.formatDraft, "the sheet goes")
        let restyled = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first { $0.kind == .textBox })
        XCTAssertEqual(restyled.fontSize, 16)
        XCTAssertEqual(restyled.index, 2, "added again, at the end of its page's list")
        XCTAssertEqual(restyled.contents, "Box")
        XCTAssertEqual(undoManager.undoActionName, Strings.formatTextBox)
        undoManager.undo(); await model.settle()
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).first { $0.kind == .textBox }?.fontSize, 14)
        // Cancel, or Apply with the look it had, changes nothing.
        selecting.perform(.format, on: box)
        let unchanged = await model.applyFormatDraft(try XCTUnwrap(model.formatDraft).format)
        XCTAssertFalse(unchanged)
    }

    /// A text box the file locks is not formatted: the menu does not offer it, and the model refuses it.
    func testALockedTextBoxIsNotFormatted() async throws {
        let (controller, model, undoManager) = await makeController(pages: 1, data: try fixtureData("locked-markup"))
        let box = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first { $0.kind == .textBox })
        XCTAssertFalse(controller.markupInteraction.selecting.actions(for: box).contains(.format))
        let made = await model.enqueueRestyle(AnnotationRef(page: 0, index: box.index), to: TextBoxFormat(fontSize: 30, color: RGBA(r: 1, g: 0, b: 0))).value
        XCTAssertFalse(made)
        XCTAssertEqual(model.failure?.message, Strings.editNotAllowed)
        XCTAssertFalse(undoManager.canUndo)
    }
}
