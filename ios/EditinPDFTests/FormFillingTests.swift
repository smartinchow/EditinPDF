import EditinPDFCore
import UIKit
import XCTest
@testable import EditinPDF

/// Filling in forms: what a tap on each kind of field does (`FormFilling`), the model's fill
/// (`DocumentModel.fill`), and the overlays over the pages with the text being typed in a field
/// (`FormInteraction`). As in the markup tests, the touches themselves are for the simulator: here the
/// hooks are called the way the buttons, the keyboard and the gestures call them.
@MainActor
final class FormFillingTests: XCTestCase {
    // MARK: Helpers

    /// The field named `name` of `fields`.
    func field(_ name: String, in fields: [FormField]) throws -> FormField {
        try XCTUnwrap(fields.first { $0.name == name }, "no field \(name)")
    }

    /// A model of `fixture`, its state read, with an undo manager.
    func settledModel(_ fixture: String = "form") async throws -> (DocumentModel, UndoManager) {
        let (m, u) = try makeModel(fixture: fixture)
        await m.settle()
        return (m, u)
    }

    /// A 400 x 800 scroll view of `fixture`, in reading mode, its form handed over as SwiftUI does.
    func makeController(_ fixture: String = "form", data: Data? = nil) async throws -> (PageScrollViewController, DocumentModel, UndoManager) {
        let model = isolatedModel(bytes: try data ?? fixtureData(fixture))
        let undoManager = UndoManager()
        model.undoManager = undoManager
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(origin: .zero, size: CGSize(width: 400, height: 800))
        controller.view.layoutIfNeeded()
        await model.settle()
        sync(model, controller)
        return (controller, model, undoManager)
    }

    /// Hands the controller what SwiftUI's update of the scroll view does: the last change, the tool
    /// and the form.
    func sync(_ model: DocumentModel, _ controller: PageScrollViewController) {
        if let change = model.lastChange { controller.apply(change) }
        controller.markupTool = model.tool
        controller.forms = FormDisplay(index: model.formIndex, canFill: model.canFillForms)
    }

    /// Picks `tool` (nil: reading), as the toolbar and SwiftUI's update of the scroll view do.
    func pick(_ tool: Tool?, _ model: DocumentModel, _ controller: PageScrollViewController) {
        model.tool = tool
        sync(model, controller)
    }

    /// The overlay button of widget `widget` of field `name`.
    func button(_ name: String, _ widget: Int = 0, in controller: PageScrollViewController, file: StaticString = #filePath, line: UInt = #line) throws -> FormWidgetButton {
        let all = controller.formInteraction.overlays.values.flatMap(\.buttons)
        return try XCTUnwrap(all.first { $0.accessibilityIdentifier == "formField-\(name)-\(widget)" }, "no button for \(name) \(widget)", file: file, line: line)
    }

    /// Types `text` over what the field editor holds, as the keyboard does.
    func type(_ text: String, into editor: (any FormFieldEditing)?) throws {
        let editor = try XCTUnwrap(editor, "no field editor")
        editor.typedText = text
        if let field = editor as? UITextField { field.sendActions(for: .editingChanged) }
        if let view = editor as? UITextView { view.delegate?.textViewDidChange?(view) }
    }

    /// The value of field `name` as the model has it now.
    func value(_ name: String, _ model: DocumentModel) -> [String]? {
        model.formFields.first { $0.name == name }?.value
    }

    /// How many steps the undo manager takes back before it has none.
    func undoSteps(_ undoManager: UndoManager, _ model: DocumentModel) async -> Int {
        var steps = 0
        while undoManager.canUndo {
            undoManager.undo()
            await model.settle()
            steps += 1
        }
        return steps
    }

    // MARK: What a tap does

    func testTapDecisions() throws {
        let fields = try PdfDocument.open(bytes: fixtureData("form"), password: nil).formFields()
        let f = { (n: String) in try XCTUnwrap(fields.first { $0.name == n }) }
        XCTAssertEqual(FormFilling.action(for: try f("agree"), widget: try f("agree").widgets[0]), .set(field: "agree", value: .checked(on: true)))
        let size = try f("size"); let large = try XCTUnwrap(size.widgets.first { $0.onState == "L" })
        XCTAssertEqual(FormFilling.action(for: size, widget: large), .set(field: "size", value: .radio(state: "L")))
        XCTAssertEqual(FormFilling.action(for: try f("read_only_note"), widget: try f("read_only_note").widgets[0]), .none)
        guard case .choose(_, let options, _, false, _) = FormFilling.action(for: try f("color"), widget: try f("color").widgets[0]) else { return XCTFail() }
        XCTAssertEqual(options.map(\.display), ["Red", "Green", "Blue"])
        XCTAssertEqual(FormFilling.action(for: try f("name"), widget: try f("name").widgets[0]),
                       .editText(field: "name", current: "", multiline: false, maxLength: nil))
    }

    /// The other kinds: a text field's limit and lines, a combo box that takes typed text, a list box
    /// of several choices, and the fields a tap does nothing to.
    func testEveryKindOfFieldDecidesWhatATapDoes() throws {
        let fields = try PdfDocument.open(bytes: fixtureData("form-kinds"), password: nil).formFields()
        func action(_ name: String) throws -> FormAction {
            let f = try field(name, in: fields)
            return FormFilling.action(for: f, widget: f.widgets[0])
        }
        XCTAssertEqual(try action("zip"), .editText(field: "zip", current: "", multiline: false, maxLength: 5))
        XCTAssertEqual(try action("notes"), .editText(field: "notes", current: "", multiline: true, maxLength: nil))
        XCTAssertEqual(try action("city"), .choose(field: "city", options: [ChoiceOption(export: "Paris", display: "Paris"), ChoiceOption(export: "Rome", display: "Rome")],
                                                 selected: [], multiple: false, editable: true))
        guard case .choose("toppings", let options, [], true, false) = try action("toppings") else { return XCTFail("toppings") }
        XCTAssertEqual(options.map(\.export), ["Cheese", "Olives", "Peppers"])
        XCTAssertEqual(try action("submit"), .none, "a push button")
        XCTAssertEqual(try action("sign"), .none, "a signature field")
    }

    /// A check box that is on turns off; the radio button that is on stays on; a radio button without
    /// a state of its own, a read-only field, and a choice with nothing to choose do nothing.
    func testTogglesAndTheOddOnes() {
        let box = Rect(x: 0, y: 0, width: 10, height: 10)
        let on = FormWidget(page: 0, rect: box, onState: "Yes", isOn: true)
        let checkBox = FormField(name: "c", kind: .checkBox, value: ["Yes"], options: [], readOnly: false, multiline: false,
                                 multiSelect: false, editableChoice: false, maxLen: nil, widgets: [on])
        XCTAssertEqual(FormFilling.action(for: checkBox, widget: on), .set(field: "c", value: .checked(on: false)))
        let selected = FormWidget(page: 0, rect: box, onState: "A", isOn: true)
        let radio = FormField(name: "r", kind: .radio, value: ["A"], options: [], readOnly: false, multiline: false,
                              multiSelect: false, editableChoice: false, maxLen: nil, widgets: [selected])
        XCTAssertEqual(FormFilling.action(for: radio, widget: selected), .set(field: "r", value: .radio(state: "A")))
        let stateless = FormWidget(page: 0, rect: box, onState: nil, isOn: false)
        XCTAssertEqual(FormFilling.action(for: radio, widget: stateless), .none)
        var readOnly = checkBox
        readOnly.readOnly = true
        XCTAssertEqual(FormFilling.action(for: readOnly, widget: on), .none)
        let empty = FormField(name: "e", kind: .combo, value: [], options: [], readOnly: false, multiline: false,
                              multiSelect: false, editableChoice: false, maxLen: nil, widgets: [stateless])
        XCTAssertEqual(FormFilling.action(for: empty, widget: stateless), .none)
        // The multi-select flag only means several choices on a list box.
        let combo = FormField(name: "k", kind: .combo, value: [], options: [ChoiceOption(export: "a", display: "A")], readOnly: false,
                              multiline: false, multiSelect: true, editableChoice: false, maxLen: nil, widgets: [stateless])
        XCTAssertEqual(FormFilling.action(for: combo, widget: stateless),
                       .choose(field: "k", options: [ChoiceOption(export: "a", display: "A")], selected: [], multiple: false, editable: false))
    }

    /// The widgets of each page are looked up in a map made once per revision, in the document's order.
    func testWidgetsAreLookedUpByPage() throws {
        let fields = try PdfDocument.open(bytes: fixtureData("form-kinds"), password: nil).formFields()
        let index = FormIndex(fields)
        XCTAssertEqual(index.spots(onPage: 1).map { index.fields[$0.field].name }, ["second"])
        XCTAssertEqual(index.spots(onPage: 0).map { index.fields[$0.field].name }, ["zip", "city", "toppings", "submit", "sign", "notes"])
        XCTAssertTrue(index.spots(onPage: 2).isEmpty)
        XCTAssertEqual(FormFilling.widgets(onPage: 1, in: fields).map(\.0.name), ["second"])
        XCTAssertEqual(index.field(named: "notes")?.multiline, true)
        XCTAssertNil(index.field(named: "nope"))

        let form = try PdfDocument.open(bytes: fixtureData("form"), password: nil).formFields()
        let spots = FormIndex(form).spots(onPage: 0).filter { form[$0.field].name == "size" }
        XCTAssertEqual(spots.map(\.widget), [0, 1], "each radio button of the group is a widget of its own")
    }

    /// What is typed is held to the field's limit, and to the bridge's, in whole characters counted
    /// as the engine counts them (Unicode scalars).
    func testTypedTextIsHeldToTheLimit() {
        XCTAssertEqual(FormFilling.limited("1234567", to: 5), "12345")
        XCTAssertEqual(FormFilling.limited("123", to: 5), "123")
        // "👍🏽" is one character of two scalars: it does not fit in what is left of 3.
        XCTAssertEqual(FormFilling.limited("ab👍🏽c", to: 3), "ab")
        XCTAssertEqual(FormFilling.limited(String(repeating: "x", count: 10_005), to: nil).count, FormFilling.maxTextLength)
        XCTAssertEqual(FormFilling.limited("abc", to: 0), "")
    }

    // MARK: The model's fill

    func testFillingATextFieldPersists() async throws {
        let (m, u) = try makeModel(fixture: "form")
        let made1 = await m.fill("name", with: .text(text: "Ada"))
        XCTAssertTrue(made1)
        let made2 = await m.fill("name", with: .text(text: "Ada"))
        XCTAssertFalse(made2)          // unchanged: no undo step
        XCTAssertEqual(u.undoActionName, Strings.actionFillField)
        let saved = try XCTUnwrap(m.document()).save(mode: .incremental)
        XCTAssertEqual(try PdfDocument.open(bytes: saved, password: nil).formFields().first { $0.name == "name" }?.value, ["Ada"])
    }

    /// Setting a check box, a radio group or a choice to what it has is no change, and leaves nothing
    /// to undo; each change is one step, which redraws the widget's page and is named Fill Form.
    func testFillingWithTheCurrentValueIsNoChange() async throws {
        let (m, u) = try await settledModel()
        let made3 = await m.fill("agree", with: .checked(on: true))
        XCTAssertTrue(made3)
        XCTAssertEqual(m.lastChange?.pages, [0], "the widget's page is redrawn")
        let made4 = await m.fill("agree", with: .checked(on: true))
        XCTAssertFalse(made4)
        let made5 = await m.fill("size", with: .radio(state: "L"))
        XCTAssertTrue(made5)
        let made6 = await m.fill("size", with: .radio(state: "L"))
        XCTAssertFalse(made6)
        let made7 = await m.fill("color", with: .choice(values: ["Green"]))
        XCTAssertTrue(made7)
        let made8 = await m.fill("color", with: .choice(values: ["Green"]))
        XCTAssertFalse(made8)
        let made9 = await m.fill("name", with: .text(text: ""))
        XCTAssertFalse(made9, "empty is what it has")
        let made10 = await m.fill("agree", with: .checked(on: true))
        XCTAssertFalse(made10)
        XCTAssertNil(m.failure)
        XCTAssertEqual(u.undoActionName, Strings.actionFillField)

        u.undo()
        await m.settle()
        XCTAssertEqual(value("color", m), [])
        XCTAssertEqual(m.lastChange?.pages, [0], "undo redraws the widget's page")
        let steps1 = await undoSteps(u, m)
        XCTAssertEqual(steps1, 2, "one step for each change made")
        XCTAssertEqual(value("agree", m), [])
    }

    /// Two fills of the same value handed over before the first is made: the second finds it made,
    /// and is no change rather than an empty step.
    func testAFillMadeWhileTheSameOneWaitedLeavesNoEmptyStep() async throws {
        let (m, u) = try await settledModel()
        let first = m.enqueueFill("name", with: .text(text: "Ada"))
        let second = m.enqueueFill("name", with: .text(text: "Ada"))
        let (a, b) = await (first.value, second.value)
        XCTAssertTrue(a)
        XCTAssertFalse(b)
        XCTAssertNil(m.failure)
        XCTAssertEqual(m.revision, 1, "the engine made one change, not an empty second one")
        let steps2 = await undoSteps(u, m)
        XCTAssertEqual(steps2, 1)
    }

    /// A check box tapped twice before the engine has made the first: the second tap turns it back
    /// off, as the reader meant, in a step of its own.
    func testACheckBoxTappedTwiceQuicklyTurnsBackOff() async throws {
        let (m, u) = try await settledModel()
        // As the overlay's button does: the field as the model has it now, with what is on its way.
        let tap = { () throws -> Task<Bool, Never> in
            let filled = m.fieldAsFilled(try self.field("agree", in: m.formFields))
            guard case .set(let name, let value) = FormFilling.action(for: filled, widget: filled.widgets[0]) else {
                XCTFail("a check box sets"); return Task { false }
            }
            return m.enqueueFill(name, with: value)
        }
        let first = try tap()
        let second = try tap()
        let (on, off) = await (first.value, second.value)
        XCTAssertTrue(on)
        XCTAssertTrue(off)
        XCTAssertEqual(try field("agree", in: m.formFields).widgets[0].isOn, false)
        // Two changes made, one after the other (both taps in one event are one undo group here).
        XCTAssertEqual(m.revision, 2)
        XCTAssertTrue(u.canUndo)
    }

    /// A field is addressed by its name, which no page change alters: a fill worked out before pages
    /// were inserted (or deleted, moved, turned) is made on the document as it then is, never refused
    /// as stale.
    func testAFillWorkedOutBeforeAPageChangeIsStillMade() async throws {
        let (m, _) = try await settledModel()
        let before = m.revision
        let insert = m.enqueue([.insertBlankPage(at: 0, widthPt: 612, heightPt: 792)], named: Strings.actionInsertBlank, touching: nil)
        let fill = m.enqueue([.setFieldValue(name: "name", value: .text(text: "Ada"))], named: Strings.actionFillField,
                             touching: [0], workedOutAt: before)
        let (inserted, filled) = await (insert.value, fill.value)
        XCTAssertTrue(inserted)
        XCTAssertTrue(filled)
        XCTAssertNil(m.failure)
        XCTAssertEqual(value("name", m), ["Ada"])
        XCTAssertEqual(m.formFields.first { $0.name == "name" }?.widgets[0].page, 1)
    }

    /// A document whose security settings forbid filling: the fill is refused with our sentence, never
    /// a blank one, and a read-only field is refused too.
    func testAFillTheDocumentForbidsSaysWhy() async throws {
        let (m, u) = try await settledModel("restricted-form")
        XCTAssertFalse(m.canFillForms)
        XCTAssertFalse(m.formFields.isEmpty, "its fields are listed")
        let made11 = await m.fill("name", with: .text(text: "x"))
        XCTAssertFalse(made11)
        XCTAssertEqual(m.failure?.message, Strings.formNotAllowed)
        XCTAssertFalse(u.canUndo)

        let (open, _) = try await settledModel()
        let made12 = await open.fill("read_only_note", with: .text(text: "x"))
        XCTAssertFalse(made12)
        XCTAssertEqual(open.failure?.message, Strings.editNotAllowed)
    }

    // MARK: The overlays

    /// In reading mode each loaded page has an overlay with a button over each widget, tinted when it
    /// may be filled in; a Markup tool takes them away, and reading brings them back.
    func testOverlaysAreShownInReadingModeOverTheWidgets() async throws {
        let (controller, model, _) = try await makeController()
        let overlay = try XCTUnwrap(controller.formInteraction.overlay(forPage: 0))
        XCTAssertEqual(overlay.buttons.count, 6, "name, agree, two radio buttons, color, read_only_note")
        XCTAssertEqual(overlay.frame, try XCTUnwrap(controller.pageView(for: 0)).frame)
        overlay.layoutIfNeeded()
        let scale = 400.0 / 612.0
        let name = try button("name", in: controller)
        XCTAssertEqual(name.frame.minX, 150 * scale, accuracy: 0.5)
        XCTAssertEqual(name.frame.minY, 72 * scale, accuracy: 0.5)
        XCTAssertEqual(name.frame.width, 250 * scale, accuracy: 0.5)
        XCTAssertEqual(name.frame.height, 20 * scale, accuracy: 0.5)
        XCTAssertNotEqual(name.backgroundColor, .clear, "a field to fill is tinted")
        XCTAssertEqual(try button("read_only_note", in: controller).backgroundColor, .clear, "a read-only one is not")

        pick(.select, model, controller)
        XCTAssertNil(controller.formInteraction.overlay(forPage: 0), "no overlays with a Markup tool")
        XCTAssertTrue(controller.contentView.subviews.allSatisfy { !($0 is FormOverlay) })
        pick(nil, model, controller)
        XCTAssertEqual(controller.formInteraction.overlay(forPage: 0)?.buttons.count, 6)
    }

    /// A change keeps the buttons of the widgets it leaves where they were, so a finger on one as it
    /// arrives is not let go of; they say what their fields hold now. A page change makes new ones.
    func testAFillKeepsTheButtonsAndTellsThemTheNewValues() async throws {
        let (controller, model, _) = try await makeController()
        let agree = try button("agree", in: controller)
        let name = try button("name", in: controller)
        let made = await model.fill("agree", with: .checked(on: true))
        XCTAssertTrue(made)
        sync(model, controller)
        XCTAssertTrue(try button("agree", in: controller) === agree)
        XCTAssertTrue(try button("name", in: controller) === name)
        XCTAssertTrue(agree.superview === controller.formInteraction.overlay(forPage: 0))
        XCTAssertEqual(agree.accessibilityValue, Strings.fieldChecked)
        XCTAssertTrue(agree.accessibilityTraits.contains(.selected))

        let turned = await model.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        XCTAssertTrue(turned)
        sync(model, controller)
        XCTAssertFalse(try button("agree", in: controller) === agree, "a turned page moves its widgets")
        XCTAssertNil(agree.superview?.superview, "its overlay went with the old layout")
    }

    /// Only the pages that have a view have an overlay: one far down the document gets its own once
    /// it is scrolled to, and loses it when it is scrolled away.
    func testOnlyLoadedPagesHaveOverlays() async throws {
        let (controller, model, _) = try await makeController()
        for _ in 0..<6 {
            let made13 = await model.performAll([.insertBlankPage(at: 0, widthPt: 612, heightPt: 792)], named: Strings.actionInsertBlank, touching: nil)
            XCTAssertTrue(made13)
        }
        model.currentPage = 0
        sync(model, controller)
        controller.scroll(to: 0)
        XCTAssertFalse(controller.loadedPages.contains(6))
        XCTAssertNil(controller.formInteraction.overlay(forPage: 6))
        XCTAssertEqual(Set(controller.formInteraction.overlays.keys), Set(controller.loadedPages))
        XCTAssertTrue(controller.formInteraction.overlays.values.allSatisfy { $0.buttons.isEmpty }, "blank pages have no widgets")

        controller.scroll(to: 6)
        XCTAssertEqual(controller.formInteraction.overlay(forPage: 6)?.buttons.count, 6)
        controller.scroll(to: 0)
        XCTAssertNil(controller.formInteraction.overlay(forPage: 6))
    }

    /// Each widget's button says what it is to VoiceOver and the UI tests: its identifier, its field's
    /// name, its value and how it acts.
    func testWidgetsSayWhatTheyAre() async throws {
        let (controller, model, _) = try await makeController()
        let name = try button("name", in: controller)
        XCTAssertEqual(name.accessibilityLabel, "name")
        XCTAssertEqual(name.accessibilityValue, "")
        XCTAssertTrue(name.accessibilityTraits.contains(.button))
        XCTAssertEqual(try button("agree", in: controller).accessibilityValue, Strings.fieldUnchecked)
        XCTAssertEqual(try button("size", 1, in: controller).accessibilityLabel, Strings.radioButtonLabel(field: "size", option: "L"))
        XCTAssertTrue(try button("read_only_note", in: controller).accessibilityTraits.contains(.notEnabled))

        let made14 = await model.fill("name", with: .text(text: "Ada"))
        XCTAssertTrue(made14)
        let made15 = await model.fill("agree", with: .checked(on: true))
        XCTAssertTrue(made15)
        let made16 = await model.fill("size", with: .radio(state: "L"))
        XCTAssertTrue(made16)
        let made17 = await model.fill("color", with: .choice(values: ["Green"]))
        XCTAssertTrue(made17)
        sync(model, controller)
        XCTAssertEqual(try button("name", in: controller).accessibilityValue, "Ada")
        XCTAssertEqual(try button("agree", in: controller).accessibilityValue, Strings.fieldChecked)
        XCTAssertTrue(try button("size", 1, in: controller).accessibilityTraits.contains(.selected))
        XCTAssertEqual(try button("size", 0, in: controller).accessibilityValue, Strings.fieldUnchecked)
        XCTAssertEqual(try button("color", in: controller).accessibilityValue, "Green")
    }

    /// On a turned page the widgets arrive in view space, turned with the page: the buttons, and the
    /// field editor at any zoom, lie where the page shows them.
    func testOverlaysAndTheEditorLieWhereTheWidgetsAreOnATurnedPage() async throws {
        let (controller, model, _) = try await makeController()
        let made18 = await model.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        XCTAssertTrue(made18)
        sync(model, controller)
        let page = try XCTUnwrap(controller.pageView(for: 0))
        XCTAssertEqual(page.pointSize, CGSize(width: 792, height: 612))
        let scale = page.bounds.width / 792
        let overlay = try XCTUnwrap(controller.formInteraction.overlay(forPage: 0))
        overlay.layoutIfNeeded()
        // A quarter clockwise: `name`, user [150 700 400 720], is shown at x 700, y 150, 20 x 250.
        let name = try button("name", in: controller)
        XCTAssertEqual(name.frame.minX, 700 * scale, accuracy: 0.5)
        XCTAssertEqual(name.frame.minY, 150 * scale, accuracy: 0.5)
        XCTAssertEqual(name.frame.width, 20 * scale, accuracy: 0.5)
        XCTAssertEqual(name.frame.height, 250 * scale, accuracy: 0.5)

        controller.scrollView.zoomScale = 2
        controller.formInteraction.tapped(name)
        let editor = try XCTUnwrap(controller.formInteraction.editor)
        let place = try XCTUnwrap(controller.scrollViewRect(of: CGRect(x: 700, y: 150, width: 20, height: 250), onPage: 0))
        XCTAssertEqual(editor.frame.midX, place.midX, accuracy: 0.5)
        XCTAssertEqual(editor.frame.midY, place.midY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(editor.frame.width, place.width - 0.5)
        XCTAssertGreaterThanOrEqual(editor.frame.height, place.height - 0.5)
    }

    // MARK: Typing in a field

    /// A tap on a text field puts an editor over it with its text, typed on an undo manager of its own;
    /// Return adds what was typed as one change named Fill Form, and the editor goes.
    func testTypingInATextFieldIsAddedOnReturn() async throws {
        let (controller, model, undoManager) = try await makeController()
        controller.formInteraction.tapped(try button("name", in: controller))
        let editor = try XCTUnwrap(controller.formInteraction.editor as? FormTextField)
        XCTAssertTrue(editor.superview === controller.scrollView, "beside the zoomed pages, sharp at any zoom")
        XCTAssertNotIdentical(editor.undoManager, undoManager)
        XCTAssertEqual(editor.accessibilityIdentifier, "formFieldEditor")
        XCTAssertTrue(model.isEditingField)
        try type("Ada", into: editor)
        XCTAssertTrue(model.hasPendingFieldText)
        XCTAssertTrue(model.hasPendingEdit, "Undo adds it, then takes it back")
        XCTAssertFalse(undoManager.canUndo, "typing is not a change to the document")

        XCTAssertFalse(controller.formInteraction.textFieldShouldReturn(editor))
        XCTAssertNil(controller.formInteraction.editor)
        XCTAssertNil(editor.superview)
        XCTAssertFalse(model.hasPendingFieldText)
        await model.settle()
        XCTAssertEqual(value("name", model), ["Ada"])
        XCTAssertEqual(undoManager.undoActionName, Strings.actionFillField)
        let steps4 = await undoSteps(undoManager, model)
        XCTAssertEqual(steps4, 1)
    }

    /// What is typed is added by every way out of the field: the end of editing, a tap on the pages, a
    /// Markup tool, a finger outside the pages (Back, the toolbar), Undo (which then takes it back), a
    /// new layout, and the scene leaving the screen.
    func testWhatIsTypedIsAddedByEveryWayOut() async throws {
        let ways: [(String, (PageScrollViewController, DocumentModel) -> Void)] = [
            ("end of editing", { c, _ in if let e = c.formInteraction.editor as? UITextField { c.formInteraction.textFieldDidEndEditing(e) } }),
            ("tap on the pages", { c, _ in c.formInteraction.pagesTapped() }),
            ("Markup", { c, m in m.tool = .select; c.markupTool = .select }),
            ("finger outside the pages", { c, _ in c.markupInteraction.fingerWentDown(on: nil) }),
            ("new layout", { c, _ in c.formInteraction.layoutWillChange() }),
            ("scene leaving", { _, m in m.commitPendingInk() }),
        ]
        for (way, leave) in ways {
            let (controller, model, _) = try await makeController()
            controller.formInteraction.tapped(try button("name", in: controller))
            try type("Ada", into: controller.formInteraction.editor)
            leave(controller, model)
            XCTAssertNil(controller.formInteraction.editor, way)
            await model.settle()
            XCTAssertEqual(value("name", model), ["Ada"], way)
        }

        let (controller, model, undoManager) = try await makeController()
        controller.formInteraction.tapped(try button("name", in: controller))
        try type("Ada", into: controller.formInteraction.editor)
        model.undo()
        await model.settle()
        XCTAssertNil(controller.formInteraction.editor)
        XCTAssertEqual(value("name", model), [], "Undo added it, then took it back")
        XCTAssertTrue(undoManager.canRedo)
    }

    /// A finger on the editor, or on the pages (a scroll), does not end the typing; a tap on another
    /// field adds what was typed and goes on to it.
    func testATapOnAnotherFieldAddsWhatWasTypedAndGoesOn() async throws {
        let (controller, model, _) = try await makeController()
        let markup = controller.markupInteraction
        controller.formInteraction.tapped(try button("name", in: controller))
        let editor = try XCTUnwrap(controller.formInteraction.editor)
        try type("Ada", into: editor)
        markup.fingerWentDown(on: editor)
        markup.fingerWentDown(on: controller.contentView)
        XCTAssertTrue(controller.formInteraction.editor === editor)

        controller.formInteraction.tapped(try button("agree", in: controller))
        XCTAssertNil(controller.formInteraction.editor)
        await model.settle()
        XCTAssertEqual(value("name", model), ["Ada"])
        XCTAssertEqual(try field("agree", in: model.formFields).widgets[0].isOn, true)
    }

    /// Leaving a field as it was is no change.
    func testAFieldLeftAsItWasIsNoChange() async throws {
        let (controller, model, undoManager) = try await makeController()
        let made19 = await model.fill("name", with: .text(text: "Ada"))
        XCTAssertTrue(made19)
        sync(model, controller)
        controller.formInteraction.tapped(try button("name", in: controller))
        XCTAssertEqual(controller.formInteraction.editor?.typedText, "Ada", "the editor starts with the field's text")
        try type("Ada", into: controller.formInteraction.editor)
        XCTAssertFalse(model.hasPendingFieldText)
        XCTAssertNil(controller.formInteraction.commitPendingField())
        await model.settle()
        let steps5 = await undoSteps(undoManager, model)
        XCTAssertEqual(steps5, 1, "only the first fill")
    }

    /// A field with a limit takes no more than it: what is typed past it is cut, and what is added is
    /// within it.
    func testTypingStopsAtTheFieldsLimit() async throws {
        let (controller, model, _) = try await makeController("form-kinds")
        controller.formInteraction.tapped(try button("zip", in: controller))
        try type("1234567", into: controller.formInteraction.editor)
        XCTAssertEqual(controller.formInteraction.editor?.typedText, "12345")
        controller.formInteraction.commitPendingField()
        await model.settle()
        XCTAssertEqual(value("zip", model), ["12345"])
        XCTAssertNil(model.failure)
    }

    /// A field of several lines is typed in a text view, where Return starts a new line.
    func testAFieldOfSeveralLinesHasTheMultilineEditor() async throws {
        let (controller, model, _) = try await makeController("form-kinds")
        controller.formInteraction.tapped(try button("notes", in: controller))
        let editor = try XCTUnwrap(controller.formInteraction.editor as? FormTextView)
        try type("one\ntwo", into: editor)
        XCTAssertNotNil(controller.formInteraction.editor, "Return is a new line")
        controller.formInteraction.textViewDidEndEditing(editor)
        await model.settle()
        XCTAssertEqual(value("notes", model), ["one\ntwo"])
    }

    // MARK: Choices

    /// A combo box's menu lists its options, the chosen one checked; picking one fills the field. One
    /// that takes typed text offers Other…, which opens the editor with its value.
    func testAComboBoxIsChosenFromItsMenu() async throws {
        let (controller, model, _) = try await makeController()
        let color = try button("color", in: controller)
        XCTAssertTrue(color.showsMenuAsPrimaryAction, "a single choice is a menu at the widget")
        controller.formInteraction.pick(["Green"], for: "color")
        await model.settle()
        XCTAssertEqual(value("color", model), ["Green"])
        sync(model, controller)
        let items = controller.formInteraction.menuElements(for: try button("color", in: controller)).compactMap { $0 as? UIAction }
        XCTAssertEqual(items.map(\.title), ["Red", "Green", "Blue"])
        XCTAssertEqual(items.map(\.state), [.off, .on, .off])

        let (kinds, kindsModel, _) = try await makeController("form-kinds")
        let city = try button("city", in: kinds)
        let cityItems = kinds.formInteraction.menuElements(for: city).compactMap { $0 as? UIAction }
        XCTAssertEqual(cityItems.map(\.title), ["Paris", "Rome", Strings.otherChoice])
        kinds.formInteraction.typeOwnChoice(for: city)
        let editor = try XCTUnwrap(kinds.formInteraction.editor as? FormTextField)
        XCTAssertEqual(editor.typedText, "")
        try type("Oslo", into: editor)
        _ = kinds.formInteraction.textFieldShouldReturn(editor)
        await kindsModel.settle()
        XCTAssertEqual(value("city", kindsModel), ["Oslo"])
    }

    /// A list box of several choices opens the sheet with checkmarks; Done fills it once, with what is
    /// checked, in the options' order. Cancel changes nothing.
    func testAListOfSeveralChoicesIsFilledOnceOnDone() async throws {
        let (controller, model, undoManager) = try await makeController("form-kinds")
        controller.formInteraction.tapped(try button("toppings", in: controller))
        let draft = try XCTUnwrap(model.choiceDraft)
        XCTAssertEqual(draft.field, "toppings")
        XCTAssertEqual(draft.options.map(\.display), ["Cheese", "Olives", "Peppers"])
        XCTAssertEqual(draft.selected, [])
        let made20 = await model.saveChoice(draft, choosing: ["Peppers", "Cheese"])
        XCTAssertTrue(made20)
        XCTAssertNil(model.choiceDraft)
        XCTAssertEqual(value("toppings", model), ["Cheese", "Peppers"])
        let steps6 = await undoSteps(undoManager, model)
        XCTAssertEqual(steps6, 1)

        sync(model, controller)
        controller.formInteraction.tapped(try button("toppings", in: controller))
        XCTAssertNotNil(model.choiceDraft)
        model.choiceDraft = nil
        await model.settle()
        XCTAssertFalse(undoManager.canUndo)
    }

    // MARK: Permissions and the form's size

    /// A document that forbids filling still shows its fields, untinted: a tap on one says why, every
    /// time, and opens nothing; a read-only field says nothing.
    func testAFormThatMayNotBeFilledShowsItsFieldsAndATapSaysWhy() async throws {
        let (controller, model, undoManager) = try await makeController("restricted-form")
        let name = try button("name", in: controller)
        XCTAssertEqual(name.backgroundColor, .clear)
        XCTAssertTrue(name.accessibilityTraits.contains(.notEnabled))
        XCTAssertFalse(name.showsMenuAsPrimaryAction)
        controller.formInteraction.tapped(name)
        XCTAssertNil(controller.formInteraction.editor)
        XCTAssertEqual(model.failure?.message, Strings.formNotAllowed)
        model.failure = nil
        controller.formInteraction.tapped(try button("color", in: controller))
        XCTAssertEqual(model.failure?.message, Strings.formNotAllowed)
        model.failure = nil
        controller.formInteraction.tapped(try button("read_only_note", in: controller))
        XCTAssertNil(model.failure)
        await model.settle()
        XCTAssertFalse(undoManager.canUndo)
    }

    /// The model says when the form has more than the engine lists (here a drop-down list of 1,001
    /// options, of which 1,000 are listed), for the screen's note; the listed part can still be filled.
    func testAFormListedShortIsSaid() async throws {
        let (m, _) = try await settledModel()
        XCTAssertFalse(m.formFieldsTruncated)
        let (big, _) = try await settledModel("truncated-form")
        XCTAssertTrue(big.formFieldsTruncated)
        XCTAssertEqual(big.formFields.first?.options.count, 1_000)
        let made = await big.fill("big", with: .choice(values: ["o999"]))
        XCTAssertTrue(made)
        XCTAssertTrue(big.formFieldsTruncated, "read again with the revision")
    }
}
