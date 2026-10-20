import EditinPDFCore
import UIKit

/// Filling in the document's form in reading mode: the overlays over the pages' widgets
/// (`FormOverlay`), what a tap on one does, the editor a field's text is typed in, the menu and the
/// sheet of a choice's options, and the keyboard over the editor. It belongs to a
/// `PageScrollViewController`, like `MarkupInteraction`.
///
/// **The overlays** are shown while no Markup tool is picked (`markupTool == nil`), on the pages that
/// have a view (`loadedPages`): one is made as a page's view is, and dropped with it. The widgets of a
/// page are looked up in the model's `FormIndex`, made once per revision, never by going through every
/// field. They are made again whenever the form (`PageScrollViewController.forms`) or the tool changes.
///
/// **A tap** on a widget does what `FormFilling.action` says, worked out from the field as it will be
/// once the fills on their way are made (`DocumentModel.fieldAsFilled`): a check box turns over, a radio
/// button is chosen, a text field is typed in, a drop-down list opens its menu (with Other… for a value
/// of the reader's own, when it takes one), a list box of several choices opens the sheet with
/// checkmarks (`DocumentModel.choiceDraft`). In a document that does not allow its form to be filled in,
/// the tap says so (`Strings.formNotAllowed`) instead. A read-only field, a push button and a signature
/// field do nothing.
///
/// **The text typed** in a field's editor (`FormTextField`, `FormTextView` for several lines) lies in the
/// scroll view over the widget, laid out again at every scroll and zoom (`layoutEditor`), so its type is
/// sharp at any zoom; it is kept within the field's limit as it is typed. It fills the field
/// (`commitPendingField`) on Return (one line), when editing ends, on a tap anywhere on the pages, on a
/// tap on another field, with a Markup tool, on a new layout, and whenever strokes waiting are added
/// (`DocumentModel.commitPendingInk`: a finger outside the pages, such as on Back, any other change, Undo
/// and Redo, the scene leaving the screen). A field left as it was is no change. The keyboard is kept
/// off it (`KeyboardAvoidance`). What is typed is the reader's, and is never logged.
@MainActor
final class FormInteraction: NSObject {
    private weak var host: PageScrollViewController?
    private let model: DocumentModel

    /// The overlays of the pages that have a view, by page, while they are shown.
    private(set) var overlays: [Int: FormOverlay] = [:]
    /// The editor of the field being typed in, in the scroll view; nil while there is none.
    private(set) var editor: (any FormFieldEditing)?
    /// Pictures of fields' text on their way into the document, over their page, each until the page
    /// has been drawn again with it (or at once when it is refused).
    private(set) var previews: [UIView] = []
    /// A tap on the pages while a field is typed in: it fills the field in.
    let endTap = UITapGestureRecognizer()
    /// The tint of a widget that may be filled in.
    static let tint = UIColor.systemBlue.withAlphaComponent(0.12)

    /// Keeps the editor clear of the keyboard: in reading mode the page indicator stands over the
    /// keyboard, and the bar of a search's hits over it while a search has some.
    private lazy var keyboard = KeyboardAvoidance(
        scrollView: host?.scrollView,
        editedView: { [weak self] in self?.editor },
        clearance: { [weak self] in 48 + (self?.model.search?.hits.isEmpty == false ? 48 : 0) })

    init(host: PageScrollViewController, model: DocumentModel) {
        self.host = host
        self.model = model
        super.init()
    }

    /// Puts the tap that ends typing on the content view, listens to the keyboard, and becomes what the
    /// model asks to fill in what is typed.
    func install() {
        guard let host else { return }
        endTap.addTarget(self, action: #selector(endTapped(_:)))
        endTap.delegate = self
        host.contentView.addGestureRecognizer(endTap)
        keyboard.install()
        model.fieldHolder = self
    }

    // MARK: The overlays

    /// The form and whether it may be filled in, as the scroll view was last handed them.
    private var forms: FormDisplay { host?.forms ?? .empty }

    /// Whether the overlays are shown: in reading mode, over a form.
    private var isShown: Bool {
        guard let host else { return false }
        return host.markupTool == nil && !forms.index.isEmpty
    }

    /// The overlay of `page`; nil when it has none (no view, or not shown).
    func overlay(forPage page: Int) -> FormOverlay? { overlays[page] }

    /// The pages that have a view changed (a scroll, a zoom, a new layout): each gets its overlay, and
    /// those of pages that lost theirs go.
    func pagesDidChange() {
        guard let host, isShown else {
            removeOverlays()
            return
        }
        let loaded = Set(host.loadedPages)
        for (page, overlay) in overlays where !loaded.contains(page) {
            overlay.removeFromSuperview()
            overlays[page] = nil
        }
        for page in loaded where overlays[page] == nil {
            guard let view = host.pageView(for: page) else { continue }
            let overlay = FormOverlay(page: page, pointSize: view.pointSize)
            overlay.frame = view.frame
            overlay.show(buttons(onPage: page, reusing: []))
            host.contentView.insertSubview(overlay, aboveSubview: view)
            overlays[page] = overlay
        }
    }

    /// The form changed (a change, undo or redo; its first reading; what may be done with it): the
    /// overlays show it. A widget's button that stays the same (its field, place and way of acting) is
    /// kept and says what its field holds now: a finger on it as the change arrives is not let go of,
    /// so a second quick tap on a check box counts.
    func formsDidChange() {
        guard isShown else {
            removeOverlays()
            return
        }
        for (page, overlay) in overlays {
            overlay.show(buttons(onPage: page, reusing: overlay.buttons))
        }
        pagesDidChange()
    }

    /// The tool changed: a Markup tool fills in what is typed and takes the overlays away; reading
    /// brings them back.
    func toolDidChange() {
        if host?.markupTool != nil { commitPendingField() }
        removeOverlays()
        pagesDidChange()
    }

    /// The pages are about to be laid out again: what is typed fills its field, worked out for the
    /// layout it was typed on, and the overlays and pictures go with that layout (the new one gets its
    /// own overlays as its pages get views).
    func layoutWillChange() {
        commitPendingField()
        for preview in previews { preview.removeFromSuperview() }
        previews.removeAll()
        removeOverlays()
    }

    private func removeOverlays() {
        for overlay in overlays.values { overlay.removeFromSuperview() }
        overlays.removeAll()
    }

    /// The buttons over the widgets of `page`, as the form is now: tinted, and saying they act, when
    /// their field may be filled in; a drop-down list's opens its menu. A button of `old` that is the
    /// one a widget needs is kept, and says what its field holds now.
    private func buttons(onPage page: Int, reusing old: [FormWidgetButton]) -> [FormWidgetButton] {
        let index = forms.index
        let canFill = forms.canFill
        var unused = old
        return index.spots(onPage: page).compactMap { spot in
            let field = index.fields[spot.field]
            let widget = field.widgets[spot.widget]
            let box = CGRect(x: widget.rect.x, y: widget.rect.y, width: widget.rect.width, height: widget.rect.height)
            guard FormWidgetButton.isUsable(box) else { return nil }
            let action = FormFilling.action(for: field, widget: widget)
            var opensMenu = false
            if canFill, case .choose(_, _, _, false, _) = action { opensMenu = true }
            let button: FormWidgetButton
            if let reused = unused.firstIndex(where: { $0.isSame(spot: spot, field: field.name, box: box, opensMenu: opensMenu) }) {
                button = unused.remove(at: reused)
            } else {
                button = makeButton(spot: spot, field: field.name, box: box, opensMenu: opensMenu)
            }
            let fillable = action != .none
            button.backgroundColor = fillable && canFill ? Self.tint : .clear
            button.accessibilityLabel = FormFilling.label(of: field, widget: widget)
            button.accessibilityValue = FormFilling.accessibilityValue(of: field, widget: widget)
            var traits: UIAccessibilityTraits = fillable ? .button : .staticText
            if widget.isOn { traits.insert(.selected) }
            if !fillable || !canFill { traits.insert(.notEnabled) }
            button.accessibilityTraits = traits
            return button
        }
    }

    /// A button for the widget at `spot` of `field`, at `box`: a tap acts (`tapped`), or, for a
    /// drop-down list that may be filled in (`opensMenu`), opens a menu at the widget, made when it
    /// opens, from the field as it is then.
    private func makeButton(spot: FormIndex.Spot, field: String, box: CGRect, opensMenu: Bool) -> FormWidgetButton {
        let button = FormWidgetButton(spot: spot, field: field, box: box, opensMenu: opensMenu)
        if opensMenu {
            button.menu = UIMenu(title: Strings.chooseOption, children: [
                UIDeferredMenuElement.uncached { [weak self, weak button] completion in
                    guard let self, let button else { return completion([]) }
                    completion(self.menuElements(for: button))
                },
            ])
            button.showsMenuAsPrimaryAction = true
            button.addAction(UIAction { [weak self] _ in self?.commitPendingField() }, for: .menuActionTriggered)
        } else {
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let self, let button else { return }
                self.tapped(button)
            }, for: .primaryActionTriggered)
        }
        return button
    }

    // MARK: Taps

    /// The field of `button` and its widget, as they will be once the fills on their way are made; nil
    /// when the form has changed under it.
    private func fieldAndWidget(of button: FormWidgetButton) -> (FormField, FormWidget)? {
        let index = forms.index
        guard index.fields.indices.contains(button.spot.field) else { return nil }
        let field = model.fieldAsFilled(index.fields[button.spot.field])
        guard field.name == button.field, field.widgets.indices.contains(button.spot.widget) else { return nil }
        return (field, field.widgets[button.spot.widget])
    }

    /// A tap on `button`'s widget: see the type's description. What was typed in a field fills it first,
    /// and the tap is worked out from the form as it will then be: a second widget of the same field
    /// opens with the text just typed, and a tap on a widget that does nothing still ends the typing.
    func tapped(_ button: FormWidgetButton) {
        commitPendingField()
        guard let (field, widget) = fieldAndWidget(of: button) else { return }
        let action = FormFilling.action(for: field, widget: widget)
        guard action != .none else { return }
        guard model.canFillForms else {
            model.failure = EditFailure(message: Strings.formNotAllowed)
            return
        }
        let label = FormFilling.label(of: field, widget: widget)
        switch action {
        case .editText(let name, let current, let multiline, let maxLength):
            beginEditing(FieldEdit(field: name, page: Int(widget.page), rect: button.box, original: current,
                                   maxLength: maxLength ?? FormFilling.maxTextLength, multiline: multiline, asChoice: false, label: label))
        case .set(let name, let value):
            model.enqueueFill(name, with: value)
        case .choose(let name, let options, let selected, let multiple, _):
            // One choice is the button's menu; several, the sheet with checkmarks.
            if multiple { model.choiceDraft = ChoiceDraft(field: name, title: label, options: options, selected: selected) }
        case .none:
            break
        }
    }

    /// The items of the menu of `button`'s drop-down list: its options, the chosen one checked, and
    /// Other… when it takes a value of the reader's own.
    func menuElements(for button: FormWidgetButton) -> [UIMenuElement] {
        guard let (field, widget) = fieldAndWidget(of: button),
              case .choose(let name, let options, let selected, false, let editable) = FormFilling.action(for: field, widget: widget) else { return [] }
        var items: [UIMenuElement] = options.map { option in
            UIAction(title: option.display.isEmpty ? option.export : option.display,
                     state: selected.contains(option.export) ? .on : .off) { [weak self] _ in
                self?.pick([option.export], for: name)
            }
        }
        if editable {
            items.append(UIAction(title: Strings.otherChoice, image: UIImage(systemName: "pencil")) { [weak self, weak button] _ in
                guard let self, let button else { return }
                self.typeOwnChoice(for: button)
            })
        }
        return items
    }

    /// A choice of the menu: the field gets `values`.
    func pick(_ values: [String], for field: String) {
        commitPendingField()
        model.enqueueFill(field, with: .choice(values: values))
    }

    /// Other…: the editor comes up over `button`'s drop-down list with its value, for one of the reader's
    /// own.
    func typeOwnChoice(for button: FormWidgetButton) {
        guard model.canFillForms, let (field, widget) = fieldAndWidget(of: button) else { return }
        beginEditing(FieldEdit(field: field.name, page: Int(widget.page), rect: button.box, original: field.value.first ?? "",
                               maxLength: FormFilling.maxChoiceLength, multiline: false, asChoice: true,
                               label: FormFilling.label(of: field, widget: widget)))
    }

    @objc private func endTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        pagesTapped()
    }

    /// A tap on the pages, off the widgets: what is typed fills its field.
    func pagesTapped() {
        commitPendingField()
    }

    // MARK: Typing

    /// Puts an editor for `edit` over its widget, with the field's text, and brings up the keyboard;
    /// what was typed in another field fills it first.
    private func beginEditing(_ edit: FieldEdit) {
        guard let host else { return }
        commitPendingField()
        let editor: any FormFieldEditing
        if edit.multiline {
            let view = FormTextView(edit)
            view.delegate = self
            editor = view
        } else {
            let field = FormTextField(edit)
            field.delegate = self
            field.addTarget(self, action: #selector(textFieldChanged(_:)), for: .editingChanged)
            editor = field
        }
        host.scrollView.addSubview(editor)
        self.editor = editor
        layoutEditor()
        editor.becomeFirstResponder()
        keyboard.editingDidChange()
        keyboard.reveal()
    }

    /// Puts the editor over its widget, at the zoom the view is at, its type that size: the scroll view
    /// calls it as it scrolls and zooms.
    func layoutEditor() {
        guard let host, let editor, let widget = host.scrollViewRect(of: editor.edit.rect, onPage: editor.edit.page) else { return }
        let scale = host.screenScale(ofPage: editor.edit.page)
        editor.show(atScreenScale: scale)
        let frame = editor.editorFrame(over: widget, atScreenScale: scale)
        if editor.frame != frame { editor.frame = frame }
    }

    /// What was typed came or changed: it is kept within the field's limit (not while a character is
    /// being composed), and the model hears whether it differs from the field's text.
    private func typingDidChange(_ editor: any FormFieldEditing) {
        guard editor === self.editor else { return }
        let composing = (editor as? UITextInput)?.markedTextRange != nil
        if !composing {
            let limited = FormFilling.limited(editor.typedText, to: editor.edit.maxLength)
            if limited != editor.typedText { editor.typedText = limited }
        }
        model.pendingFieldTextDidChange(editor.typedText != editor.edit.original)
    }

    @objc private func textFieldChanged(_ field: UITextField) {
        guard let editor = field as? FormTextField else { return }
        typingDidChange(editor)
    }

    /// Ends the editor, if one is up: what was typed, held to the field's limit, fills the field when it
    /// differs from the field's text, handed over before this returns (a picture of it stays over the
    /// page until the page is drawn again with it, or goes at once when it is refused). The task says
    /// whether the field changed; nil with no editor, or nothing changed.
    @discardableResult
    func commitPendingField() -> Task<Bool, Never>? {
        guard let editor else { return nil }
        // Done with first, so that whatever this sets off (the end of editing; the fill handed over, which
        // adds what is waiting first) finds no editor to end again.
        self.editor = nil
        (editor as? UITextField)?.delegate = nil
        (editor as? UITextView)?.delegate = nil
        model.pendingFieldTextDidChange(false)
        let edit = editor.edit
        let text = FormFilling.limited(editor.typedText, to: edit.maxLength)
        editor.resignFirstResponder()
        let changed = text != edit.original
        let preview = changed ? showPreview(of: editor) : nil
        editor.removeFromSuperview()
        keyboard.editingDidChange()
        guard changed else { return nil }
        let value: FieldValue = edit.asChoice ? .choice(values: text.isEmpty ? [] : [text]) : .text(text: text)
        let made = model.enqueueFill(edit.field, with: value)
        return MarkupInteraction.settlePreview(of: made) { [weak self] in self?.removePreview(preview) }
    }

    /// A picture of the editor's text, without its line, where it is over the page, in the content view:
    /// what was typed, while it is on its way into the page.
    private func showPreview(of editor: any FormFieldEditing) -> UIView? {
        guard let host, editor.bounds.width > 0, editor.bounds.height > 0 else { return nil }
        editor.layer.borderWidth = 0
        let format = UIGraphicsImageRendererFormat(for: editor.traitCollection)
        let image = UIGraphicsImageRenderer(bounds: editor.bounds, format: format).image { context in
            editor.layer.render(in: context.cgContext)
        }
        let view = UIImageView(image: image)
        view.frame = host.contentView.convert(editor.frame, from: host.scrollView)
        view.isUserInteractionEnabled = false
        host.contentView.addSubview(view)
        previews.append(view)
        return view
    }

    private func removePreview(_ preview: UIView?) {
        guard let preview else { return }
        preview.removeFromSuperview()
        previews.removeAll { $0 === preview }
    }
}

// MARK: - PendingFieldHolder

extension FormInteraction: PendingFieldHolder {
    var isEditingField: Bool { editor != nil }
}

// MARK: - UITextFieldDelegate, UITextViewDelegate

extension FormInteraction: UITextFieldDelegate, UITextViewDelegate {
    /// Return fills a field of one line in.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === editor { commitPendingField() }
        return false
    }

    /// Editing ended (the keyboard put away, another field taking it): what was typed fills the field.
    func textFieldDidEndEditing(_ textField: UITextField) {
        if textField === editor { commitPendingField() }
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let editor = textView as? FormTextView else { return }
        typingDidChange(editor)
        keyboard.reveal()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if textView === editor { commitPendingField() }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension FormInteraction: UIGestureRecognizerDelegate {
    /// The tap that ends typing only listens while a field is typed in.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        editor != nil
    }

    /// It never keeps the selection's tap from ending a selection.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
