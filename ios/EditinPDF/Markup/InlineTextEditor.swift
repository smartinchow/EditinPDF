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

    init(page: Int, origin: CGPoint, revision: UInt64, style: ToolStyle, pageSize: CGSize) {
        self.page = page
        self.origin = origin
        self.revision = revision
        self.style = style
        self.fontSize = CGFloat(ShapeGeometry.fontSize(style.fontSize))
        self.pageSize = pageSize
        super.init(frame: .zero, textContainer: nil)
        // It grows with its text (`MarkupInteraction.layoutTextEditor`), and never scrolls itself: the
        // pages do.
        isScrollEnabled = false
        scrollsToTop = false
        textContainer.lineFragmentPadding = 0
        // A tint shows where the box is while it is typed in; it goes when the text is added.
        backgroundColor = UIColor.systemBlue.withAlphaComponent(0.08)
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

    /// Takes the tint off, for the picture of the text shown while it is added.
    func showAsAdded() {
        backgroundColor = .clear
    }
}

extension RGBA {
    /// The colour for UIKit.
    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }
}
