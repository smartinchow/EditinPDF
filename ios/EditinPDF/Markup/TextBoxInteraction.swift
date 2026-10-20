import EditinPDFCore
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
@MainActor
final class TextBoxInteraction: NSObject {
    private weak var host: PageScrollViewController?
    private let model: DocumentModel

    /// The box being typed in with Text Box, in the scroll view over its page; nil while there is none.
    private(set) var textEditor: InlineTextEditor?
    /// Pictures of text boxes on their way into the document, over their page, each until the page has
    /// been drawn again with it (or at once when it is refused).
    private(set) var textPreviews: [UIView] = []
    /// The scroll view's bottom inset before the keyboard came up over a box being typed in, to put
    /// back when the box goes; nil while the keyboard has not moved it.
    private var insetBeforeKeyboard: CGFloat?
    /// How far the keyboard reaches up over the scroll view, in its points; 0 while it is down.
    private var keyboardCover: CGFloat = 0

    init(host: PageScrollViewController, model: DocumentModel) {
        self.host = host
        self.model = model
        super.init()
    }

    /// Listens to the keyboard coming, moving and going.
    func install() {
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// Puts a box to type in on `page` (`pageSize` in size, as shown) at `point` (view space; moved in
    /// from the page's edges as far as its least width and its first line need), in Text Box's style,
    /// and brings up the keyboard.
    func beginTextBox(onPage page: Int, at point: CGPoint, pageSize size: CGSize) {
        guard host != nil else { return }
        let style = model.toolStyles[.textBox]
        let origin = ShapeGeometry.textBoxOrigin(at: point, fontSize: CGFloat(ShapeGeometry.fontSize(style.fontSize)), pageSize: size)
        show(InlineTextEditor(page: page, origin: origin, revision: model.revision, style: style, pageSize: size))
    }

    /// Puts the box to type in over `info`, a text box on a page shown upright, with its text, in its
    /// colour (Text Box's when it has none) at Text Box's size, and brings up the keyboard; the box
    /// being typed in before, if any, is ended first. Says whether it is there: not for another kind,
    /// nor on a turned page, where the text would be typed sideways.
    @discardableResult
    func beginEditing(_ info: AnnotationInfo) -> Bool {
        let page = Int(info.page)
        guard info.kind == .textBox, model.pages.indices.contains(page), model.pages[page].rotationDegrees % 360 == 0 else { return false }
        commitPendingText()
        var style = model.toolStyles[.textBox]
        if let color = info.color { style.color = RGBA(r: color.red, g: color.green, b: color.blue) }
        let size = CGSize(width: model.pages[page].widthPt, height: model.pages[page].heightPt)
        let editor = InlineTextEditor(page: page, origin: CGPoint(x: info.rect.x, y: info.rect.y), revision: model.revision, style: style,
                                      pageSize: size, existing: AnnotationRef(page: page, index: info.index),
                                      originalText: info.contents ?? "", existingBox: info.box)
        editor.text = info.contents ?? ""
        show(editor)
        return true
    }

    /// Puts `editor` in the scroll view over its place, and brings up the keyboard.
    private func show(_ editor: InlineTextEditor) {
        guard let host else { return }
        editor.delegate = self
        host.scrollView.addSubview(editor)
        textEditor = editor
        layoutTextEditor()
        editor.becomeFirstResponder()
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
    /// the text box is deleted); unchanged, nothing is handed over, and the task is nil.
    @discardableResult
    func commitPendingText() -> Task<Bool, Never>? {
        guard let editor = textEditor else { return nil }
        // Done with first, so that whatever this sets off (the end of editing; the change handed over,
        // which adds what is waiting first) finds no box to end again.
        textEditor = nil
        editor.delegate = nil
        model.pendingTextDidChange(false)
        let text = editor.text ?? ""
        let committed = ShapeGeometry.committedText(text)
        let changes = editor.isWaiting
        editor.resignFirstResponder()
        let preview = committed.isEmpty || !changes ? nil : showPreview(of: editor)
        editor.removeFromSuperview()
        keyboardInsetDidChange()
        let made: Task<Bool, Never>
        if let existing = editor.existing {
            guard changes else { return nil }
            made = committed.isEmpty ? model.enqueueDelete(existing, workedOutAt: editor.revision)
                : model.enqueueContents(of: existing, to: committed, workedOutAt: editor.revision)
        } else {
            made = model.enqueueTextBox(page: editor.page, at: editor.origin, text: text, workedOutAt: editor.revision, style: editor.style)
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

    // MARK: The keyboard

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let host, let window = host.scrollView.window,
              let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let keyboard = host.scrollView.convert(window.convert(end, from: window.screen.coordinateSpace), from: window)
        keyboardCover = max(0, host.scrollView.bounds.maxY - keyboard.minY)
        keyboardInsetDidChange()
        revealTextEditor()
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        keyboardCover = 0
        keyboardInsetDidChange()
    }

    /// How much more than the keyboard covers the bottom of the view has over it while a box is typed
    /// in, in points: the palette's bar and the page indicator stand over the keyboard on a compact
    /// width; the page indicator alone on a regular one.
    private var keyboardClearance: CGFloat {
        host?.traitCollection.horizontalSizeClass == .regular ? 48 : 116
    }

    /// While a box is typed in and the keyboard is up, the scroll view's bottom inset leaves room for
    /// the keyboard (beyond what the safe area already does), so the pages can scroll the box clear of
    /// it, down to the end of the document; otherwise the inset is put back.
    private func keyboardInsetDidChange() {
        guard let scrollView = host?.scrollView else { return }
        if textEditor != nil, keyboardCover > 0 {
            let before = insetBeforeKeyboard ?? scrollView.contentInset.bottom
            insetBeforeKeyboard = before
            let wanted = max(before, keyboardCover + keyboardClearance - scrollView.safeAreaInsets.bottom)
            if scrollView.contentInset.bottom != wanted { scrollView.contentInset.bottom = wanted }
        } else if let before = insetBeforeKeyboard {
            insetBeforeKeyboard = nil
            if scrollView.contentInset.bottom != before { scrollView.contentInset.bottom = before }
        }
    }

    /// Scrolls the pages, if need be, so the box being typed in is in the part of the view the bars and
    /// the keyboard leave: its bottom, where the text grows, without scrolling its top out of view.
    private func revealTextEditor() {
        guard let scrollView = host?.scrollView, let editor = textEditor, editor.window != nil else { return }
        let visible = scrollView.bounds.inset(by: scrollView.adjustedContentInset)
        let box = editor.frame.insetBy(dx: -8, dy: -8)
        var offset = scrollView.contentOffset
        if box.maxY > visible.maxY {
            offset.y += max(0, min(box.maxY - visible.maxY, box.minY - visible.minY))
        } else if box.minY < visible.minY {
            offset.y -= visible.minY - box.minY
        }
        if box.maxX > visible.maxX {
            offset.x += max(0, min(box.maxX - visible.maxX, box.minX - visible.minX))
        } else if box.minX < visible.minX {
            offset.x -= visible.minX - box.minX
        }
        let insets = scrollView.adjustedContentInset
        let highest = CGPoint(x: max(-insets.left, scrollView.contentSize.width + insets.right - scrollView.bounds.width),
                              y: max(-insets.top, scrollView.contentSize.height + insets.bottom - scrollView.bounds.height))
        offset = CGPoint(x: min(max(offset.x, -insets.left), highest.x), y: min(max(offset.y, -insets.top), highest.y))
        if offset != scrollView.contentOffset { scrollView.setContentOffset(offset, animated: true) }
    }
}

// MARK: - UITextViewDelegate

extension TextBoxInteraction: UITextViewDelegate {
    /// Text was typed in the box: it grows with it, is kept clear of the keyboard, and the model hears
    /// whether there is text waiting (the palette's Done). What is typed is never logged.
    func textViewDidChange(_ textView: UITextView) {
        guard let editor = textView as? InlineTextEditor, editor === textEditor else { return }
        model.pendingTextDidChange(editor.isWaiting)
        layoutTextEditor()
        revealTextEditor()
    }

    /// Editing ended (the keyboard put away, another field taking it): the text is added.
    func textViewDidEndEditing(_ textView: UITextView) {
        guard textView === textEditor else { return }
        commitPendingText()
    }
}
