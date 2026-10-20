import UIKit

/// The box a text box's text is typed in, over the page where the text box will be
/// (`MarkupInteraction` puts it there for a tap with Text Box). It lies in the scroll view, beside
/// the pages rather than in the view the scroll view zooms, and is laid out again at every zoom
/// (`show(atScreenScale:)`): its type is drawn at the size it has on screen, sharp at any zoom, as big
/// as the text box's will be, set in the engine's face (Helvetica) with the engine's spacing and
/// margins, so the text lands where it was typed.
///
/// Its text is only on its way to the document: typing is registered on its own undo manager, never
/// on the scene's, where it would come between the document's changes and dirty the document. It is
/// the reader's text, and is never logged.
///
/// It also changes the text of a text box on the page (`existing`, Select's Edit): it is put over that
/// box, with its text, on white, so the text as it was does not show through; it keeps the box's width
/// (the engine wraps the new text in it) and grows down as the text does.
final class InlineTextEditor: UITextView {
    /// The box's own undo manager: what is typed is undone here, not in the document's history.
    private let localUndo = UndoManager()
    override var undoManager: UndoManager? { localUndo }

    /// The page the text box goes on, counting from 0.
    let page: Int
    /// The text box's top-left, in view space (PDF points of the page).
    let origin: CGPoint
    /// The revision of the document the box was put on the page at: the text box is worked out
    /// against it, so that one placed before a turn of its page is refused as stale.
    let revision: UInt64
    /// The style it is typed and added in: Text Box's when the box was put there.
    let style: ToolStyle
    /// The text's size, in PDF points: the style's, held to what the bridge takes.
    let fontSize: CGFloat
    /// The size of its page as shown, in PDF points: the text box keeps to it.
    let pageSize: CGSize
    /// How many points on screen a PDF point is at the layout it was last given; 0 before the first.
    private(set) var screenScale: CGFloat = 0
    /// The text box on the page whose text this changes; nil for a new text box.
    let existing: AnnotationRef?
    /// The text that text box had when this was put over it; empty for a new one.
    let originalText: String
    /// That text box's box (view space), when this changes one.
    let existingBox: CGRect?

    init(page: Int, origin: CGPoint, revision: UInt64, style: ToolStyle, pageSize: CGSize,
         existing: AnnotationRef? = nil, originalText: String = "", existingBox: CGRect? = nil) {
        self.page = page
        self.origin = origin
        self.revision = revision
        self.style = style
        self.fontSize = CGFloat(ShapeGeometry.fontSize(style.fontSize))
        self.pageSize = pageSize
        self.existing = existing
        self.originalText = originalText
        self.existingBox = existingBox
        super.init(frame: .zero, textContainer: nil)
        // It grows with its text (`MarkupInteraction.layoutTextEditor`), and never scrolls itself: the
        // pages do.
        isScrollEnabled = false
        scrollsToTop = false
        textContainer.lineFragmentPadding = 0
        // A tint shows where the box is while it is typed in; it goes when the text is added. Over a text
        // box on the page, white hides the text as it was, and a line shows the box.
        if existing == nil {
            backgroundColor = UIColor.systemBlue.withAlphaComponent(0.08)
        } else {
            backgroundColor = .white
            layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.5).cgColor
            layer.borderWidth = 1
        }
        // Text on white paper, in the colour picked, whatever the appearance.
        overrideUserInterfaceStyle = .light
        accessibilityLabel = Strings.toolTextBox
        // For UI tests; not shown or spoken.
        accessibilityIdentifier = "inlineTextEditor"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The colour of the text: the style's.
    private var color: UIColor { style.color.uiColor }

    /// Sets the type, its spacing and its margins for `scale` points on screen per PDF point, as the
    /// engine draws a text box: the text `ShapeGeometry.textInset` in from the box's left and right,
    /// its lines `ShapeGeometry.lineSpacing` sizes apart, the first line's baseline 0.9 of the size
    /// below that inset from the top.
    func show(atScreenScale scale: CGFloat) {
        guard scale > 0, scale.isFinite, scale != screenScale else { return }
        screenScale = scale
        let font = ShapeGeometry.textFont(ofSize: fontSize * scale)
        let spacing = fontSize * ShapeGeometry.lineSpacing * scale
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = spacing
        paragraph.maximumLineHeight = spacing
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let selection = selectedRange
        self.font = font
        textStorage.setAttributes(attributes, range: NSRange(location: 0, length: textStorage.length))
        typingAttributes = attributes
        selectedRange = selection
        // A line as tall as `spacing` has its baseline `spacing + descender` below its top (the room
        // over the face's own height goes above it).
        let baseline = (ShapeGeometry.textInset + 0.9 * fontSize) * scale
        let inset = ShapeGeometry.textInset * scale
        textContainerInset = UIEdgeInsets(top: max(0, baseline - (spacing + font.descender)), left: inset, bottom: 0, right: inset)
    }

    /// Cuts what is typed to the most a text box takes (`ShapeGeometry.maxTextLength`), as a form
    /// field's editor is cut to its field's limit: what goes past it is let go of, so the reader is
    /// never refused. Not while a character is being composed, which the cut could break up. Cut at the
    /// end, which keeps the type's look; the box's own undo history is let go of with it, since it
    /// may name text that is no longer there.
    func holdToTextLimit() {
        guard markedTextRange == nil else { return }
        let typed = text ?? ""
        let limited = ShapeGeometry.limitedText(typed)
        guard limited != typed else { return }
        // `limited` is the start of `typed`, so its length in UTF-16 is where the cut goes.
        let end = (limited as NSString).length
        let selected = selectedRange
        textStorage.deleteCharacters(in: NSRange(location: end, length: textStorage.length - end))
        let start = min(selected.location, end)
        selectedRange = NSRange(location: start, length: min(selected.location + selected.length, end) - start)
        localUndo.removeAllActions()
    }

    /// Takes the tint off, for the picture of the text shown while it is added (over a text box on the
    /// page, the white stays: it hides the text as it was until the page shows the new).
    func showAsAdded() {
        if existing == nil { backgroundColor = .clear }
        layer.borderWidth = 0
    }

    /// The box the text box will have, in view space: for a new one, `ShapeGeometry.textBoxRect` of
    /// what is typed; over one on the page, that box's width, and as tall as what is typed wrapped in
    /// it, the box's own height at least.
    var box: CGRect {
        let text = self.text ?? ""
        guard let existingBox else {
            return ShapeGeometry.textBoxRect(at: origin, text: text, fontSize: fontSize, pageSize: pageSize)
        }
        let fitted = ShapeGeometry.textBoxRect(at: origin, text: text, fontSize: fontSize,
                                               pageSize: CGSize(width: origin.x + existingBox.width, height: pageSize.height))
        return CGRect(x: origin.x, y: origin.y, width: existingBox.width, height: max(existingBox.height, fitted.height))
    }

    /// Whether what is typed would change the page: for a new text box, anything but spaces and new
    /// lines; over one on the page, text other than it had (spaces and new lines after the last
    /// character aside).
    var isWaiting: Bool {
        let typed = ShapeGeometry.committedText(text ?? "")
        return existing == nil ? !typed.isEmpty : typed != ShapeGeometry.committedText(originalText)
    }
}

extension RGBA {
    /// The colour for UIKit.
    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }
}
