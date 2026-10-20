import UIKit

/// The text of one form field being typed (`FormInteraction`): which field, where its widget is, what
/// it held, and how it is filled in.
struct FieldEdit: Equatable {
    /// The field's full name, which it is filled by.
    let field: String
    /// The page its widget is on, counting from 0, and the widget's box there (view space).
    let page: Int
    let rect: CGRect
    /// The text the field had when the editor came up: an unchanged field is no change.
    let original: String
    /// The most characters the field takes (the bridge's own limit when it has none).
    let maxLength: Int
    let multiline: Bool
    /// The text is a drop-down list's value of the reader's own (`FieldValue.choice`), not a text
    /// field's text.
    let asChoice: Bool
    /// What VoiceOver calls the field.
    let label: String
}

/// A form field's editor, over its widget in the scroll view: a text field for one line, a text view
/// for several. Its typing is undone on an undo manager of its own, never the scene's, where it would
/// come between the document's changes. What is typed is the reader's, and is never logged.
@MainActor
protocol FormFieldEditing: UIView {
    var edit: FieldEdit { get }
    /// What is typed in it now.
    var typedText: String { get set }
    /// Sets its type for `scale` points on screen per PDF point of the page.
    func show(atScreenScale scale: CGFloat)
}

extension FormFieldEditing {
    /// The type's size in PDF points: about as big as the widget is tall for one line (a field fitted
    /// to its box, as forms usually are), 12 points for several lines.
    var fontSize: CGFloat {
        edit.multiline ? 12 : min(max(edit.rect.height * 0.65, 6), 18)
    }

    /// The smallest type shown on screen, in points, however small the widget is at the zoom.
    static var smallestScreenFont: CGFloat { 13 }

    /// The editor's frame in the scroll view for its widget's box there (`widget`), at `scale`: the
    /// widget's box, at least as tall as a line of its type and a little more, and 60 points wide,
    /// grown about the widget's middle.
    func editorFrame(over widget: CGRect, atScreenScale scale: CGFloat) -> CGRect {
        let type = max(fontSize * scale, Self.smallestScreenFont)
        let lines: CGFloat = edit.multiline ? 2.5 : 1
        let height = max(widget.height, type * 1.3 * lines + 6)
        let width = max(widget.width, 60)
        return CGRect(x: widget.midX - width / 2, y: widget.midY - height / 2, width: width, height: height)
    }

    /// The look every field editor has: on white, as paper, so the field's old text does not show
    /// through, with a line around it, light whatever the appearance.
    func applyLook() {
        backgroundColor = .white
        layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.6).cgColor
        layer.borderWidth = 1
        overrideUserInterfaceStyle = .light
        accessibilityLabel = edit.label
        // For UI tests; not shown or spoken.
        accessibilityIdentifier = "formFieldEditor"
    }
}

/// The editor of a field of one line.
final class FormTextField: UITextField, FormFieldEditing {
    private let localUndo = UndoManager()
    override var undoManager: UndoManager? { localUndo }

    let edit: FieldEdit
    private var screenScale: CGFloat = 0

    init(_ edit: FieldEdit) {
        self.edit = edit
        super.init(frame: .zero)
        applyLook()
        textColor = .black
        text = edit.original
        borderStyle = .none
        autocorrectionType = .no
        returnKeyType = .done
        clearButtonMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var typedText: String {
        get { text ?? "" }
        set { text = newValue }
    }

    func show(atScreenScale scale: CGFloat) {
        guard scale > 0, scale.isFinite, scale != screenScale else { return }
        screenScale = scale
        font = .systemFont(ofSize: max(fontSize * scale, Self.smallestScreenFont))
    }

    // A little room between the line around it and the text.
    override func textRect(forBounds bounds: CGRect) -> CGRect { bounds.insetBy(dx: 4, dy: 0) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { bounds.insetBy(dx: 4, dy: 0) }
}

/// The editor of a field of several lines: Return starts a new line, and it scrolls itself when its
/// text is taller than the widget.
final class FormTextView: UITextView, FormFieldEditing {
    private let localUndo = UndoManager()
    override var undoManager: UndoManager? { localUndo }

    let edit: FieldEdit
    private var screenScale: CGFloat = 0

    init(_ edit: FieldEdit) {
        self.edit = edit
        super.init(frame: .zero, textContainer: nil)
        applyLook()
        textColor = .black
        text = edit.original
        autocorrectionType = .no
        textContainerInset = UIEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var typedText: String {
        get { text ?? "" }
        set { text = newValue }
    }

    func show(atScreenScale scale: CGFloat) {
        guard scale > 0, scale.isFinite, scale != screenScale else { return }
        screenScale = scale
        font = .systemFont(ofSize: max(fontSize * scale, Self.smallestScreenFont))
    }
}
