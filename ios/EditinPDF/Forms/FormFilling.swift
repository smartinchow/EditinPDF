import EditinPDFCore
import Foundation

/// What a tap on a form field's widget does (`FormFilling.action`).
enum FormAction: Equatable {
    /// Type the field's text: `current` to start from, on several lines or one, at most `maxLength`
    /// characters when the field has a limit.
    case editText(field: String, current: String, multiline: Bool, maxLength: Int?)
    /// Set the field at once: a check box turned on or off, a radio button chosen.
    case set(field: String, value: FieldValue)
    /// Choose among `options` (`selected`, their export values, are chosen now): one of them from a
    /// menu, or several in a sheet (`multiple`); `editable`, a value of the reader's own may be typed.
    case choose(field: String, options: [ChoiceOption], selected: [String], multiple: Bool, editable: Bool)
    /// Nothing: a read-only field, a push button, a signature field.
    case none
}

/// What a tap on a field does, and what a field's value is, worked out from the fields as the engine
/// lists them (`DocumentModel.formFields`). All pure.
enum FormFilling {
    /// The most characters a field's text may have, as the bridge takes it.
    static let maxTextLength = 10_000
    /// The most characters a chosen value (one typed into a drop-down list) may have, as the bridge
    /// takes it.
    static let maxChoiceLength = 1_000

    /// What a tap on `widget`, one of `field`'s, does: a check box turns over (on when it is off, off
    /// when it is on); a radio button is chosen (tapping the one chosen keeps it); a text field is
    /// typed in; a drop-down or list box offers its options. A read-only field, a push button, a
    /// signature field, a radio button with no state of its own, and a choice with nothing to choose
    /// do nothing.
    static func action(for field: FormField, widget: FormWidget) -> FormAction {
        guard !field.readOnly else { return .none }
        switch field.kind {
        case .text:
            return .editText(field: field.name, current: field.value.first ?? "", multiline: field.multiline,
                             maxLength: field.maxLen.map { Int(clamping: $0) })
        case .checkBox:
            return .set(field: field.name, value: .checked(on: !widget.isOn))
        case .radio:
            guard let state = widget.onState else { return .none }
            return .set(field: field.name, value: .radio(state: state))
        case .combo, .list:
            // A combo box takes typed text when its flag says so; only a list box takes several choices.
            let editable = field.kind == .combo && field.editableChoice
            guard !field.options.isEmpty || editable else { return .none }
            return .choose(field: field.name, options: field.options, selected: field.value,
                           multiple: field.kind == .list && field.multiSelect, editable: editable)
        case .pushButton, .signature:
            return .none
        }
    }

    /// The widgets of `fields` on `page`, each with its field, in the document's order. Scans every
    /// field: the overlays look them up in a `FormIndex`, made once per revision, instead.
    static func widgets(onPage page: Int, in fields: [FormField]) -> [(FormField, FormWidget)] {
        let index = FormIndex(fields)
        return index.spots(onPage: page).map { (index.fields[$0.field], index.fields[$0.field].widgets[$0.widget]) }
    }

    /// Whether `field` has `value` already, as it is shown: setting it would change nothing. A check
    /// box is on when one of its widgets shows on; a radio group has the state of the button that shows
    /// on, or none. A value of another kind than the field's is never had.
    static func holds(_ field: FormField, _ value: FieldValue) -> Bool {
        switch (field.kind, value) {
        case (.text, .text(let text)):
            return (field.value.first ?? "") == text
        case (.checkBox, .checked(let on)):
            return field.widgets.contains(where: \.isOn) == on
        case (.radio, .radio(let state)):
            return field.widgets.first(where: \.isOn)?.onState == state
        case (.combo, .choice(let values)), (.list, .choice(let values)):
            return field.value == values
        default:
            return false
        }
    }

    /// `field` as it will be once `value` is set: its value, and which of its widgets show on.
    static func filled(_ field: FormField, with value: FieldValue) -> FormField {
        var filled = field
        switch value {
        case .text(let text):
            filled.value = text.isEmpty ? [] : [text]
        case .checked(let on):
            for i in filled.widgets.indices { filled.widgets[i].isOn = on && filled.widgets[i].onState != nil }
            filled.value = on ? filled.widgets.compactMap(\.onState).prefix(1).map { $0 } : []
        case .radio(let state):
            for i in filled.widgets.indices { filled.widgets[i].isOn = state != nil && filled.widgets[i].onState == state }
            filled.value = state.map { [$0] } ?? []
        case .choice(let values):
            filled.value = values
        }
        return filled
    }

    /// `text` cut to at most `maxLength` characters (the bridge's `maxTextLength` when nil, and never
    /// more), counted as the engine counts them, in Unicode scalars, and cut between whole characters:
    /// a character that does not fit whole is left out with what follows it.
    static func limited(_ text: String, to maxLength: Int?) -> String {
        let most = max(0, min(maxLength ?? maxTextLength, maxTextLength))
        guard text.unicodeScalars.count > most else { return text }
        var kept = ""
        var count = 0
        for character in text {
            let size = character.unicodeScalars.count
            guard count + size <= most else { break }
            kept.append(character)
            count += size
        }
        return kept
    }

    /// The name VoiceOver gives a field: the last part of its full name (`parent.child`), which is what
    /// the form calls it; the bridge has no tooltip to offer instead. A radio button's says which of
    /// the group it is.
    static func label(of field: FormField, widget: FormWidget) -> String {
        let name = field.name.split(separator: ".").last.map(String.init) ?? field.name
        let shown = name.isEmpty ? field.name : name
        if field.kind == .radio, let state = widget.onState { return Strings.radioButtonLabel(field: shown, option: state) }
        return shown
    }

    /// What VoiceOver says a widget holds: a text field's text; whether a check box or radio button is
    /// on; the options a choice has chosen, by what they show. Nil for a push button or a signature field.
    static func accessibilityValue(of field: FormField, widget: FormWidget) -> String? {
        switch field.kind {
        case .text:
            return field.value.first ?? ""
        case .checkBox, .radio:
            return widget.isOn ? Strings.fieldChecked : Strings.fieldUnchecked
        case .combo, .list:
            let shown = field.value.map { value in field.options.first { $0.export == value }?.display ?? value }
            return ListFormatter.localizedString(byJoining: shown)
        case .pushButton, .signature:
            return nil
        }
    }
}

/// The document's form fields as listed at one revision, with each page's widgets looked up once: the
/// overlays ask for a page's without going through every field. Made off the main actor, with the
/// rest of the document's state (`DocumentModel`), after every change, undo and redo.
struct FormIndex: Equatable, Sendable {
    /// One widget: its field's place in `fields`, and its own among that field's widgets.
    struct Spot: Equatable, Hashable, Sendable {
        let field: Int
        let widget: Int
    }

    /// Tells one listing from another: a new one is made for every revision.
    let id = UUID()
    /// The fields, in the document's order.
    let fields: [FormField]
    private let byPage: [Int: [Spot]]
    private let byName: [String: Int]

    /// No fields.
    static let empty = FormIndex([])

    init(_ fields: [FormField]) {
        self.fields = fields
        var byPage: [Int: [Spot]] = [:]
        var byName: [String: Int] = [:]
        for (f, field) in fields.enumerated() {
            if byName[field.name] == nil { byName[field.name] = f }
            for (w, widget) in field.widgets.enumerated() {
                byPage[Int(widget.page), default: []].append(Spot(field: f, widget: w))
            }
        }
        self.byPage = byPage
        self.byName = byName
    }

    /// Whether the document has no fields (none that shows on a page).
    var isEmpty: Bool { fields.isEmpty }

    /// The widgets on `page`, in the document's order; none for a page without any.
    func spots(onPage page: Int) -> [Spot] {
        byPage[page] ?? []
    }

    /// The field named `name`; nil when the document has none listed by that name.
    func field(named name: String) -> FormField? {
        byName[name].map { fields[$0] }
    }

    static func == (a: FormIndex, b: FormIndex) -> Bool { a.id == b.id }
}

/// What the scroll view's form overlays show (`PageScrollViewController.forms`): the document's form,
/// and whether the document allows filling it in.
struct FormDisplay: Equatable {
    let index: FormIndex
    let canFill: Bool

    static let empty = FormDisplay(index: .empty, canFill: false)
}

/// The list box the sheet of options is up for (`DocumentModel.choiceDraft`): several of its options
/// may be checked, and Done fills it with them, once.
struct ChoiceDraft: Identifiable, Equatable {
    let id = UUID()
    /// The field's full name, which it is filled by.
    let field: String
    /// What the sheet calls it.
    let title: String
    let options: [ChoiceOption]
    /// The export values chosen when the sheet opened.
    let selected: [String]
}

/// A value handed to the engine for a field and not published yet (`DocumentModel.fillsOnTheirWay`).
struct FillOnItsWay {
    let id: UUID
    let value: FieldValue
}

// MARK: - Filling in

/// Filling in the document's form. A field is addressed by its name, which no change to the pages
/// alters, so a fill is never refused as stale: it is made on the document as it is when its turn
/// comes (`DocumentModel.enqueue`'s rebase rule).
extension DocumentModel {
    /// Whether the document allows its form to be filled in (once its permissions are read).
    var canFillForms: Bool { capabilities?.canFillForms == true }

    /// Sets field `field` to `value` (see `enqueueFill`), and says whether it changed.
    @discardableResult
    func fill(_ field: String, with value: FieldValue) async -> Bool {
        await enqueueFill(field, with: value).value
    }

    /// `fill`, handed over at once (registered with the undo manager before this returns): one change
    /// named `Strings.actionFillField`, which redraws the pages the field's widgets are on, and which
    /// one undo takes back.
    ///
    /// A value the field has already is no change, and leaves nothing to undo: as the model has it now
    /// (with the values handed over and not published yet, `fieldAsFilled`), and as the engine has it
    /// when the fill's turn comes. A document that does not allow its form to be filled in, and a
    /// read-only field, are refused at once, with our sentence.
    @discardableResult
    func enqueueFill(_ field: String, with value: FieldValue) -> Task<Bool, Never> {
        if capabilities != nil, !canFillForms { return refuse(Strings.formNotAllowed) }
        let listed = formIndex.field(named: field)
        if let listed {
            if listed.readOnly { return refuse(Strings.editNotAllowed) }
            if FormFilling.holds(fieldAsFilled(listed), value) { return Task { false } }
        }
        let pages = listed.map { Set($0.widgets.map { Int($0.page) }) }
        let id = UUID()
        fillsOnTheirWay[field] = FillOnItsWay(id: id, value: value)
        let made = enqueue([.setFieldValue(name: field, value: value)], named: Strings.actionFillField, touching: pages,
                           unless: { document in
                               document.formFields().first { $0.name == field }.map { FormFilling.holds($0, value) } ?? false
                           })
        return Task { [weak self] in
            let ok = await made.value
            if self?.fillsOnTheirWay[field]?.id == id { self?.fillsOnTheirWay[field] = nil }
            return ok
        }
    }

    /// `field` as it will be once the values handed over for it and not published yet are made: what a
    /// tap works out what to do from, so that a check box tapped twice before the engine has made the
    /// first turns back off.
    func fieldAsFilled(_ field: FormField) -> FormField {
        guard let onItsWay = fillsOnTheirWay[field.name] else { return field }
        return FormFilling.filled(field, with: onItsWay.value)
    }

    /// The sheet of options's Done: fills the list box `draft` is up for with the export values
    /// `values`, in the options' order, as one change, and puts the sheet away. Says whether it changed.
    @discardableResult
    func saveChoice(_ draft: ChoiceDraft, choosing values: Set<String>) async -> Bool {
        if choiceDraft?.id == draft.id { choiceDraft = nil }
        let chosen = draft.options.map(\.export).filter { values.contains($0) }
        return await fill(draft.field, with: .choice(values: chosen))
    }
}
