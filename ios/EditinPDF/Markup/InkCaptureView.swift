import PencilKit
import UIKit

/// The canvas Draw's strokes are drawn on, by the Apple Pencil and by a finger: added over one
/// `PageView` while the ink tool is active (`MarkupInteraction` puts it over the page a finger goes
/// down on), in the content view the scroll view zooms, so it scrolls and zooms with its page and a
/// point of it is the same point of the page at every zoom.
///
/// It only holds the strokes until they are added to the document as one ink annotation
/// (`MarkupInteraction.commitPendingInk`): they never land on the document's `UndoManager`, so the
/// toolbar's Undo and Redo, and the document's history, know nothing of them until then.
final class InkCaptureView: PKCanvasView {
    /// The canvas's own undo manager: a stroke drawn is registered there by PencilKit, not on the
    /// scene's, where it would come between the document's changes.
    private let localUndo = UndoManager()
    override var undoManager: UndoManager? { localUndo }

    /// The page the canvas is over, counting from 0.
    var page: Int
    /// The canvas's top-left in page points (view space): `InkGeometry.pagePoints`.
    var canvasOrigin: CGPoint = .zero
    /// How many page points one point of the canvas is: the page's layout scale, inverted. The canvas
    /// zooms with the page, so the zoom does not come into it.
    var pointsPerCanvasPoint: CGFloat = 1
    /// The revision of the document the strokes on the canvas were drawn on: the one they are worked
    /// out against when they are added (a turn of the page since makes them stale). Nil while the
    /// canvas has none.
    var drawnAt: UInt64?
    /// Whether a stroke is being drawn: from PencilKit's beginning to use the tool to its ending.
    var isDrawing = false
    /// The style the strokes are drawn in (Draw's when the canvas was put over the page): they are
    /// added in it. Another picked meanwhile is used from the next first finger on, once these are added.
    var style: ToolStyle?

    init(page: Int) {
        self.page = page
        super.init(frame: .zero)
        // The Pencil draws, and so does a finger: two fingers scroll and zoom the pages.
        drawingPolicy = .anyInput
        backgroundColor = .clear
        isOpaque = false
        // The pages scroll and zoom, not the canvas: it is the page's size, at the page's zoom.
        isScrollEnabled = false
        // A tap on the status bar scrolls the pages to the top, not the canvas.
        scrollsToTop = false
        minimumZoomScale = 1
        maximumZoomScale = 1
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        // Ink on white paper: PencilKit would show dark ink light in dark mode, but the page stays
        // white, and the line is drawn in the colour picked.
        overrideUserInterfaceStyle = .light
        // VoiceOver passes touches on the canvas straight to it, so a stroke is drawn, not read out,
        // as on the signature pad.
        isAccessibilityElement = true
        accessibilityLabel = Strings.toolInk
        accessibilityTraits = .allowsDirectInteraction
        // For UI tests; not shown or spoken.
        accessibilityIdentifier = "inkCanvas"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Forgets the canvas's own history of strokes: they have been added to the document, or the canvas
    /// has moved to another page, and undoing them on the canvas would mean nothing.
    func forgetStrokeHistory() {
        localUndo.removeAllActions()
    }

    /// The width of a monoline `PKInkingTool` whose strokes are `lineWidth` canvas points wide. PencilKit
    /// draws a monoline stroke twice as wide as its tool's width (measured on iOS 26: a tool 2.63 wide
    /// records points 4.63 across and draws a line 5.3 wide), so the line on the canvas is as wide as
    /// the one the annotation will have. The tool's width is not held to its ink's `validWidthRange`
    /// (0.5 to 4), which would make a thin or a thick line wider or thinner on the canvas than on the page.
    nonisolated static func toolWidth(drawingLinesOf lineWidth: CGFloat) -> CGFloat {
        lineWidth / 2
    }
}
