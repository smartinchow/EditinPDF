import EditinPDFCore
import SwiftUI
import UIKit

/// **Text Box**: the box a text box is typed in (`InlineTextEditor`), from the tap that puts it on a
/// page to the text box it becomes, and the keyboard over it. It belongs to the scroll view's
/// `MarkupInteraction`, which routes the tap here (`beginTextBox`) and hands it the tool's changes and
/// the layout's.
///
/// The box lies in the scroll view over its page, laid out again at every scroll and zoom
/// (`layoutTextEditor`); the keyboard comes up, and the page scrolls to keep the box clear of it. What
/// is typed is added as a text box (`commitPendingText`), where it was typed, when editing ends (the
/// keyboard put away), on a tap anywhere on the pages (which starts no other box), when the tool
/// changes, and at every moment strokes waiting are added (`DocumentModel.commitPendingInk` adds both:
/// a finger outside the pages, any other change, Undo and Redo, the scene leaving the screen, a new
/// layout). Nothing typed adds nothing. What is typed is the reader's, and is never logged.
///
/// The same box changes the text of a text box already on the page (`beginEditing`, Select's Edit): put
/// over it, with its text, it ends the same ways, and its text replaces the text box's, in place; all
/// of it taken away deletes the text box, and left as it was, nothing changes.
///
/// Over the keyboard, the format bar (`TextBoxFormatBar`, the box's `inputAccessoryView`) changes the
/// box's look: the text's size and colour, the background and the border. The box shows each change at
/// once. A new text box is made with the look picked, and Text Box keeps it for the next one
/// (`ToolStyleStore`); a text box on the page is given it (`DocumentModel.enqueueRestyle`) as its
/// text is changed, the two one step of Undo. More Colors… opens the system's colour picker over the
/// page, while the box waits for it (`isPickingColor`).
@MainActor
final class TextBoxInteraction: NSObject {
    private weak var host: PageScrollViewController?
    private let model: DocumentModel

    /// The box being typed in with Text Box, in the scroll view over its page; nil while there is none.
    private(set) var textEditor: InlineTextEditor?
    /// The look the format bar over the keyboard shows and changes, for the box being typed in.
    private(set) var formatState: TextBoxFormatState?
    /// The format bar, the box's `inputAccessoryView`.
    private var formatBar: UIHostingController<TextBoxFormatBar>?
    /// Whether the system's colour picker is up for the box being typed in (More Colors…): the box
    /// waits for it, and the keyboard going, or a finger or focus on the picker, does not end the box.
    private(set) var isPickingColor = false
    /// Pictures of text boxes on their way into the document, over their page, each until the page has
    /// been drawn again with it (or at once when it is refused).
    private(set) var textPreviews: [UIView] = []
    /// Keeps the box being typed in clear of the keyboard. The palette's bar and the page indicator
    /// stand over the keyboard on a compact width; the page indicator alone on a regular one. With the
    /// format bar over the keyboard they stand as much higher again (seen on the iOS 27 simulator: the
    /// box's second line was under the palette), so its height is added.
    private lazy var keyboard = KeyboardAvoidance(
        scrollView: host?.scrollView,
        editedView: { [weak self] in self?.textEditor },
        clearance: { [weak self] in
            let bars: CGFloat = self?.host?.traitCollection.horizontalSizeClass == .regular ? 48 : 116
            return bars + (self?.textEditor?.inputAccessoryView?.bounds.height ?? 0)
        })

    init(host: PageScrollViewController, model: DocumentModel) {
        self.host = host
        self.model = model
        super.init()
    }

    /// Listens to the keyboard coming, moving and going.
    func install() {
        keyboard.install()
    }

    /// Puts a box to type in on `page` (`pageSize` in size, as shown) at `point` (view space; moved in
    /// from the page's edges as far as its least width and its first line need), in Text Box's style,
    /// and brings up the keyboard.
    func beginTextBox(onPage page: Int, at point: CGPoint, pageSize size: CGSize) {
        guard host != nil else { return }
        let format = TextBoxFormat(style: model.toolStyles[.textBox])
        let origin = ShapeGeometry.textBoxOrigin(at: point, fontSize: CGFloat(format.fontSize), pageSize: size)
        show(InlineTextEditor(page: page, origin: origin, revision: model.revision, format: format, pageSize: size))
    }

    /// Puts the box to type in over `info`, a text box on a page shown upright, with its text, in its
    /// own look (`TextBoxFormat(_:otherwise:)`: its size, colour, background and border, Text Box's
    /// for what the file does not say), and brings up the keyboard; the box
    /// being typed in before, if any, is ended first. Says whether it is there: not for another kind,
    /// nor on a turned page, where the text would be typed sideways. What is typed is worked out
    /// against `revision`, the one `info` was read at (the model's now when nil).
    @discardableResult
    func beginEditing(_ info: AnnotationInfo, workedOutAt revision: UInt64? = nil) -> Bool {
        let page = Int(info.page)
        guard info.kind == .textBox, model.pages.indices.contains(page), model.pages[page].rotationDegrees % 360 == 0 else { return false }
        commitPendingText()
        let format = TextBoxFormat(info, otherwise: model.toolStyles[.textBox])
        let size = CGSize(width: model.pages[page].widthPt, height: model.pages[page].heightPt)
        let editor = InlineTextEditor(page: page, origin: CGPoint(x: info.rect.x, y: info.rect.y), revision: revision ?? model.revision, format: format,
                                      pageSize: size, existing: AnnotationRef(page: page, index: info.index),
                                      originalText: info.contents ?? "", existingBox: info.box)
        editor.text = info.contents ?? ""
        show(editor)
        return true
    }

    /// Puts `editor` in the scroll view over its place, with the format bar over the keyboard, and
    /// brings up the keyboard.
    private func show(_ editor: InlineTextEditor) {
        guard let host else { return }
        editor.delegate = self
        let state = TextBoxFormatState(editor.format)
        state.changed = { [weak self, weak editor] format in
            guard let self, let editor else { return }
            self.formatDidChange(to: format, in: editor)
        }
        state.pickColor = { [weak self] in self?.pickColor() }
        let bar = UIHostingController(rootView: TextBoxFormatBar(state: state))
        bar.view.backgroundColor = .clear
        bar.view.frame = CGRect(x: 0, y: 0, width: host.view.bounds.width, height: 52)
        bar.view.autoresizingMask = [.flexibleWidth]
        editor.inputAccessoryView = bar.view
        formatState = state
        formatBar = bar
        host.scrollView.addSubview(editor)
        textEditor = editor
        layoutTextEditor()
        editor.becomeFirstResponder()
    }

    /// The format bar changed the look of `editor`, the box being typed in: the box shows it, grown or
    /// shrunk with the text, the palette's Done follows (over a text box on the page, another look is
    /// a change to make), and, for a new text box, Text Box keeps the look for the next one.
    private func formatDidChange(to format: TextBoxFormat, in editor: InlineTextEditor) {
        guard editor === textEditor else { return }
        editor.format = format
        if editor.existing == nil {
            model.toolStyles[.textBox] = format.applied(to: model.toolStyles[.textBox])
        }
        model.pendingTextDidChange(editor.isWaiting, named: editor.actionName)
        layoutTextEditor()
        keyboard.reveal()
    }

    /// More Colors…: the system's colour picker, over the page, for the text of the box being typed in.
    /// The box waits for it (`isPickingColor`), follows each colour picked, and takes the keyboard
    /// back when it goes.
    private func pickColor() {
        guard let host, let editor = textEditor, host.presentedViewController == nil else { return }
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        picker.selectedColor = editor.format.color.uiColor
        picker.title = Strings.textColor
        picker.delegate = self
        isPickingColor = true
        host.present(picker, animated: true)
        // A swipe down puts it away too.
        picker.presentationController?.delegate = self
    }

    /// Puts the box being typed in over its place on its page, as big as the text box will be at the
    /// zoom the view is at, its type drawn at that size: the scroll view calls it as it scrolls and
    /// zooms, and it is called as the text grows.
    func layoutTextEditor() {
        guard let host, let editor = textEditor else { return }
        guard let frame = host.scrollViewRect(of: editor.box, onPage: editor.page) else { return }
        editor.show(atScreenScale: host.screenScale(ofPage: editor.page))
        if editor.frame != frame { editor.frame = frame }
    }

    /// Ends the box being typed in, if there is one: its text, if anything but spaces was typed, is
    /// added as a text box where it was typed, handed over before this returns, worked out against the
    /// revision the box was put there at. A picture of the text stays over the page meanwhile: once it
    /// is made, until the page has been drawn again with it; when it is refused (stale, say), it goes
    /// at once. The task says whether it was made; nil with no box.
    ///
    /// Over a text box on the page, its text, changed, replaces the text box's (all of it taken away,
    /// the text box is deleted, unless the file locks it: that is refused, `enqueueDelete`); unchanged,
    /// nothing is handed over, and the task is nil.
    ///
    /// What was typed is not lost to a change made meanwhile: refused as stale, a new text box whose
    /// page is the same is handed over again, and otherwise, like changed text for a text box the
    /// change numbered again, the text is kept on the pasteboard and the reader told so
    /// (`DocumentModel.enqueueTextBox`, `keepTypedText`).
    @discardableResult
    func commitPendingText() -> Task<Bool, Never>? {
        guard let editor = textEditor else { return nil }
        // Done with first, so that whatever this sets off (the end of editing; the change handed over,
        // which adds what is waiting first) finds no box to end again.
        textEditor = nil
        editor.delegate = nil
        formatState = nil
        formatBar = nil
        if isPickingColor {
            isPickingColor = false
            host?.presentedViewController.flatMap { $0 as? UIColorPickerViewController }?.dismiss(animated: true)
        }
        model.pendingTextDidChange(false)
        // Held to the limit again: a character being composed when the box ended was not cut yet.
        let text = ShapeGeometry.limitedText(editor.text ?? "")
        let committed = ShapeGeometry.committedText(text)
        let changes = editor.isWaiting
        editor.resignFirstResponder()
        let preview = committed.isEmpty || !changes ? nil : showPreview(of: editor)
        editor.removeFromSuperview()
        editor.inputAccessoryView = nil
        keyboard.editingDidChange()
        let made: Task<Bool, Never>
        if let existing = editor.existing {
            guard changes else { return nil }
            if committed.isEmpty {
                made = model.enqueueDelete(existing, workedOutAt: editor.revision)
            } else {
                // New words first (the engine fits the box to them), then the new look: handed over in
                // the same turn, they are one step of Undo.
                let words = editor.wordsChanged
                    ? model.enqueueContents(of: existing, to: committed, workedOutAt: editor.revision, keepingText: true) : nil
                let look = editor.formatChanged ? model.enqueueRestyle(existing, to: editor.format, workedOutAt: editor.revision) : nil
                made = Task {
                    let wordsMade = await words?.value ?? true
                    let lookMade = await look?.value ?? true
                    return wordsMade && lookMade
                }
            }
        } else {
            made = model.enqueueTextBox(page: editor.page, at: editor.origin, text: text, workedOutAt: editor.revision, format: editor.format)
        }
        return MarkupInteraction.settlePreview(of: made) { [weak self] in self?.removeTextPreview(preview) }
    }

    /// The pages are about to be laid out again: the text being typed is added, worked out for the
    /// layout it was typed on, and the pictures go with that layout.
    func layoutWillChange() {
        commitPendingText()
        for preview in textPreviews { preview.removeFromSuperview() }
        textPreviews.removeAll()
    }

    /// A picture of the text in `editor`, without its tint, where it is over the page, in the content
    /// view: what was typed, while it is on its way into the page.
    private func showPreview(of editor: InlineTextEditor) -> UIView? {
        guard let host, let place = host.layoutPlace(ofPage: editor.page), editor.bounds.width > 0, editor.bounds.height > 0 else { return nil }
        editor.showAsAdded()
        let format = UIGraphicsImageRendererFormat(for: editor.traitCollection)
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: editor.bounds, format: format).image { context in
            editor.layer.render(in: context.cgContext)
        }
        let box = editor.box
        let view = UIImageView(image: image)
        view.frame = CGRect(x: place.frame.minX + box.minX * place.scale, y: place.frame.minY + box.minY * place.scale,
                            width: box.width * place.scale, height: box.height * place.scale)
        view.isUserInteractionEnabled = false
        host.contentView.addSubview(view)
        textPreviews.append(view)
        return view
    }

    private func removeTextPreview(_ preview: UIView?) {
        guard let preview else { return }
        preview.removeFromSuperview()
        textPreviews.removeAll { $0 === preview }
    }
}

// MARK: - UITextViewDelegate

extension TextBoxInteraction: UITextViewDelegate {
    /// Text was typed in the box: it is kept within what a text box takes (`holdToTextLimit`), grows
    /// with it, is kept clear of the keyboard, and the model hears whether there is text waiting (the
    /// palette's Done). What is typed is never logged.
    func textViewDidChange(_ textView: UITextView) {
        guard let editor = textView as? InlineTextEditor, editor === textEditor else { return }
        editor.holdToTextLimit()
        model.pendingTextDidChange(editor.isWaiting, named: editor.actionName)
        layoutTextEditor()
        keyboard.reveal()
    }

    /// Editing ended (the keyboard put away, another field taking it): the text is added. Not while the
    /// colour picker is up for it: the box waits for it.
    func textViewDidEndEditing(_ textView: UITextView) {
        guard textView === textEditor, !isPickingColor else { return }
        commitPendingText()
    }
}

// MARK: - UIColorPickerViewControllerDelegate

extension TextBoxInteraction: UIColorPickerViewControllerDelegate {
    /// A colour picked: the box being typed in takes it, as a swatch of the bar would.
    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        guard isPickingColor, let state = formatState else { return }
        state.format.color = RGBA(Color(uiColor: color))
    }

    /// The picker is going (its close button): once it has gone, the box takes the keyboard back.
    /// Until then the box still waits: focus moving off the picker as it goes does not end it.
    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        if let coordinator = viewController.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.colorPickerWent() }
        } else {
            // Not on its way yet: it goes as the run loop turns.
            Task { @MainActor [weak self] in self?.colorPickerWent() }
        }
    }

    private func colorPickerWent() {
        guard isPickingColor else { return }
        if let host, host.presentedViewController is UIColorPickerViewController { return }
        isPickingColor = false
        textEditor?.becomeFirstResponder()
    }
}

// MARK: - UIAdaptivePresentationControllerDelegate

extension TextBoxInteraction: UIAdaptivePresentationControllerDelegate {
    /// The colour picker was swiped away.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        colorPickerWent()
    }
}
