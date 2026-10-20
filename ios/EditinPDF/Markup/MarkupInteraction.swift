import EditinPDFCore
import PencilKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// What a finger on the pages does in Markup mode, for the tools that act on the page by touch:
/// Highlight, Underline and Strikethrough, which mark the text a finger drags across; Draw; the shape
/// tools, which draw a rectangle, an oval, a line or an arrow where a finger drags; Text Box, which
/// puts a box to type in where a finger taps; and Note, which opens a note there.
///
/// It belongs to a `PageScrollViewController`, like `SelectionInteraction`, and asks it where a touch
/// is on a page (`pageLocation(of:)`, `pagePoint(ofContentPoint:onPage:)`), so a touch becomes a point
/// in view space (PDF points of the page, origin top-left, y down, its rotation applied) exactly as the
/// selection's do: the content view's coordinates, which the zoom scales, through the layout's scale of
/// the page. The selecting is the model's `SelectionController`'s, and the marking `markSelection`'s.
///
/// **Which gesture has the finger** (the scroll view's pan and pinch, the selection's long press, this):
/// - One finger that goes down on text (within `screenHitSlop` points on screen of a glyph) while
///   Highlight, Underline or Strikethrough is picked, and may be used on that page
///   (`takesTouch(atContentPoint:)`), drags out text to mark: the scroll view's pan waits for this one to
///   fail, so that drag never scrolls. Anywhere else (the white of a page, the gap between pages, or
///   another tool, or none, or a tool that is refused) this pan takes no touch, or fails as it would
///   begin, and the scroll view scrolls: one finger scrolls a page from anywhere but its text.
/// - Whether a point is on text is decided at once, on the main actor, from the page's glyph boxes
///   (`isNearText`), which are read off the main actor (`PageTextBoxes`, which throttles the reading)
///   for the pages in view while a text tool is picked, and for a page a finger goes down on. Until
///   they have been read, a touch on the page is taken as on text, as if the page were all text: it
///   marks if it began on a word, and does not scroll.
/// - Two fingers always scroll and zoom: a second finger before the drag has begun fails it, wherever
///   it went down (`MarkupPanGestureRecognizer` counts every finger on the screen, and the pan takes
///   any touch while it has a finger already, so that it hears of it at once), and the scroll view's pan and
///   pinch take over. A second finger after it has begun is ignored: the drag goes on with the first.
/// - The selection's long press is off while any tool that annotates is picked
///   (`SelectionInteraction.isLongPressAllowed`): the tool has the finger. With Select, or in reading
///   mode, it selects as before, and its menu offers the marks.
///
/// A drag selects from the word under where the finger went down to where it is, on the page it went
/// down on (a point past that page's edge is the text nearest it), and marks it when the finger comes
/// up.
///
/// **Draw** (the ink tool) draws with PencilKit, on a canvas (`InkCaptureView`) over one page:
/// - The canvas covers the page the first touch lands on. The content view asks, before it finds the
///   view under a first finger (`PageContentView.touchWillLand`), and the canvas is put over that page
///   if Draw is picked and may be used there (`prepareToDraw`); the finger then lands on the canvas.
///   A second finger, while the first is down, never moves it, nor does anything while a stroke is
///   being drawn. Off the pages (the gap between two), and on a page where Draw is refused, nothing is
///   drawn.
/// - The canvas's drawing policy is `.anyInput`: the Apple Pencil draws, and so does one finger.
/// - Two fingers scroll and zoom: while Draw is picked the scroll view's pan needs two
///   (`toolDidChange`), and its pinch is two anyway; the canvas does not scroll or zoom itself. It
///   lies in the content view, so it scrolls and zooms with its page, strokes and all.
/// - The strokes wait on the canvas, off the document and its undo manager, and are added as one
///   drawing (`commitPendingInk`, the model's `addInk`) when the tool changes, when the reader taps
///   Done, when a touch starts on another page, before any other change and before Undo or Redo
///   (the model's), when the scene leaves the screen, when the pages are laid out again, when the
///   screen goes, and when a finger goes down anywhere outside the pages (`fingerWentDown`: the
///   toolbar, the palette, the back button). That last one is what keeps them when the document is
///   closed: the scene closes the file as soon as the back button is tapped, before the screen hears it
///   is going, and saves it only if a change has been registered by then. Each is worked out against
///   the revision it was drawn on: one drawn while a turn of its page was on its way is refused as
///   stale, and leaves nothing on the screen.
///
/// **Rectangle, Oval, Line and Arrow** take one finger on a page where the tool may be used, as the
/// text tools do on text (the same pan, `takesTouch`): the drag draws the shape, dashed over the page
/// (`PageOverlayView.draft`), from where the finger went down to where it is, kept to that page
/// (`ShapeGeometry.draft`), and adds it when the finger comes up; a drag shorter than
/// `ShapeGeometry.minimumSide` adds nothing. Anywhere else one finger scrolls; two fingers always
/// scroll and zoom, as for the text tools. The shape is worked out against the revision the drag
/// began on, and drawn solid until the page shows it; refused (stale, say), it goes at once.
///
/// **Text Box and Note** take a tap (`placeTap`), on a page where the tool may be used; a drag
/// scrolls. Note opens the note sheet (`DocumentModel.noteDraft`): for the note under the finger, or
/// a new one there. Text Box puts a box to type in there (`InlineTextEditor`), in the scroll view over
/// the page, laid out again at every zoom; the keyboard comes up, and the page scrolls to keep the box
/// clear of it. What is typed is added as a text box (`commitPendingText`), where it was typed, when
/// editing ends (the keyboard put away), on a tap anywhere on the pages (which starts no other box),
/// when the tool changes, and at every moment strokes waiting are added (`commitPendingInk` adds both:
/// a finger outside the pages, any other change, Undo and Redo, the scene leaving the screen, a new
/// layout). Nothing typed adds nothing. A text box is refused on a turned page: its text would read
/// sideways (`Strings.textBoxNeedsUprightPage`).
@MainActor
final class MarkupInteraction: NSObject {
    /// How far outside an annotation's box, in points on screen, a touch still lands on it: a finger is
    /// not a pointer.
    nonisolated static let screenHitSlop: CGFloat = 8

    let pan = MarkupPanGestureRecognizer()

    private weak var host: PageScrollViewController?
    private let model: DocumentModel
    /// The drag going on; nil between drags.
    private var stroke: Stroke?
    /// Counts drags, so that a drag's end that is still waiting for its selection does not finish the
    /// next one.
    private var strokeCount = 0

    /// The canvas Draw draws on: made when Draw is first picked, and in the content view, over its
    /// page, while Draw is picked.
    private(set) var ink: InkCaptureView?
    /// Pictures of strokes on their way into the document, over their page, each until the page has
    /// been drawn again with them (or at once when they are refused).
    private(set) var inkPreviews: [UIView] = []
    /// Hears of every finger going down in the screen's window, without taking it: see
    /// `fingerWentDown`. The scroll view's controller puts it on its window while it is on screen.
    let fingersDown = FingerDownObserver()
    /// How long a picture of strokes added stays: the page's cover while it is drawn again, and a
    /// little more for its tiles to come in.
    static let inkPreviewDuration: Duration = PageView.redrawCoverDuration + .milliseconds(250)

    /// The glyph boxes of the pages, read off the main actor: what `isNearText` looks at. A test may
    /// put another in its place, whose reader it sees.
    lazy var text: PageTextBoxes = {
        let document = model.document()
        return PageTextBoxes(revision: { [weak model] in model?.revision ?? 0 }) { page, revision in
            document.flatMap { PageTextBoxes.glyphBoxes(of: $0, page: page, at: revision) }
        }
    }()

    /// A drag of a text markup tool.
    private struct Stroke {
        let id: Int
        let tool: Tool
        let kind: MarkupKind
        let page: Int
    }

    /// The tap that puts a text box or a note on a page (Text Box, Note), and ends the text box being
    /// typed in.
    let placeTap = UITapGestureRecognizer()

    /// A drag of a shape tool: its tool and style as it began, the page, where on it the finger went
    /// down (view space), and the revision of the document the shape is worked out against.
    private struct ShapeDrag {
        let tool: Tool
        let style: ToolStyle
        let page: Int
        let start: CGPoint
        let revision: UInt64
    }
    /// The shape being dragged out; nil between drags.
    private var shapeDrag: ShapeDrag?

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

    /// Puts the pan on the content view, where touches on the pages land, and has the scroll view's pan
    /// wait for it to fail.
    func install() {
        guard let host else { return }
        pan.maximumNumberOfTouches = 1
        pan.addTarget(self, action: #selector(panned(_:)))
        pan.delegate = self
        host.contentView.addGestureRecognizer(pan)
        host.scrollView.panGestureRecognizer.require(toFail: pan)
        host.contentView.touchWillLand = { [weak self] point in self?.prepareToDraw(atContentPoint: point) }
        fingersDown.fingerWentDown = { [weak self] view in self?.fingerWentDown(on: view) }
        placeTap.numberOfTouchesRequired = 1
        placeTap.addTarget(self, action: #selector(placeTapped(_:)))
        placeTap.delegate = self
        host.contentView.addGestureRecognizer(placeTap)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
        model.inkHolder = self
        toolDidChange()
    }

    /// Whether a drag is going on, from the finger going down until its mark is made or refused.
    var isMarking: Bool { stroke != nil }

    /// The tool picked, when it marks text and may be used on `page`. The tool may stay picked when the
    /// reader goes on to a page, or the document to a state, where it is refused: it is checked again
    /// for every touch.
    private func textTool(onPage page: Int) -> (tool: Tool, kind: MarkupKind)? {
        guard let tool = model.tool, let kind = tool.markupKind,
              model.capabilities != nil, model.refusal(of: tool, onPage: page) == nil else { return nil }
        return (tool, kind)
    }

    /// Whether a finger going down at `point` (the content view's coordinates) drags: out a shape, when
    /// a shape tool is picked and may be used on the page under it; out text to mark, when a text markup
    /// tool is picked and may be used, and the point is on the page's text (or the page's text is not
    /// read yet: see `isNearText`). Otherwise the finger scrolls.
    func takesTouch(atContentPoint point: CGPoint) -> Bool {
        guard let location = host?.pageLocation(of: point) else { return false }
        if shapeTool(onPage: location.page) != nil { return true }
        guard textTool(onPage: location.page) != nil else { return false }
        return isNearText(location.point, onPage: location.page) != false
    }

    /// Whether `tool` may be used on `page`: once the document's permissions are read, when they and
    /// the page let it be.
    private func usable(_ tool: Tool, onPage page: Int) -> Bool {
        model.capabilities != nil && model.refusal(of: tool, onPage: page) == nil
    }

    /// The tool picked, when it draws a shape and may be used on `page`.
    private func shapeTool(onPage page: Int) -> Tool? {
        guard let tool = model.tool, tool.drawsShape, usable(tool, onPage: page) else { return nil }
        return tool
    }

    /// The tool picked, when a tap places what it makes (Text Box, Note) and it may be used on `page`.
    private func placeTool(onPage page: Int) -> Tool? {
        guard let tool = model.tool, tool.placesByTap, usable(tool, onPage: page) else { return nil }
        return tool
    }

    /// The size of `page` as shown, in PDF points; nil for a page the document does not have.
    private func pageSize(_ page: Int) -> CGSize? {
        guard model.pages.indices.contains(page) else { return nil }
        return CGSize(width: model.pages[page].widthPt, height: model.pages[page].heightPt)
    }

    // MARK: The pages' text

    /// Whether `point` (view space, PDF points of `page`) is within `screenHitSlop` points on screen of
    /// one of the page's glyphs. Nil while the page's glyph boxes are not read yet: they are asked for
    /// before any other page's, and the next touch knows.
    func isNearText(_ point: CGPoint, onPage page: Int) -> Bool? {
        guard let boxes = text.boxes(onPage: page) else {
            text.request(page)
            return nil
        }
        let slop = hitSlop(onPage: page)
        return boxes.contains { $0.insetBy(dx: -slop, dy: -slop).contains(point) }
    }

    /// Asks for the glyph boxes of the pages in view (`pages`) ahead of a touch: those a text tool may
    /// be used on, nearest the middle of the view first, at most `PageTextBoxes.pagesKept`; in place of
    /// those asked for before, so a page scrolled past is not read. With no text tool picked, nothing
    /// is asked for, and what was asked for and not started is not read. The scroll view calls it as it
    /// scrolls, when the document changes and when the tool does.
    func prefetchText(onPages pages: Range<Int>) {
        guard model.tool?.markupKind != nil else {
            text.want([])
            return
        }
        let middle = Double(pages.lowerBound + pages.upperBound - 1) / 2
        let nearestFirst = pages.sorted { (abs(Double($0) - middle), $0) < (abs(Double($1) - middle), $1) }
        text.want(nearestFirst.filter { textTool(onPage: $0) != nil })
    }

    /// Reads the glyph boxes of `page` before any other's, and returns once nothing more is being read.
    /// For tests.
    func loadText(onPage page: Int) async {
        text.request(page)
        await text.settle()
    }

    // MARK: The drag

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard let host else { return }
        let location = recognizer.location(in: host.contentView)
        switch recognizer.state {
        case .began:
            // The pan begins once the finger has moved a little: the drag starts where it went down.
            let start = panStart()
            if beginShape(atContentPoint: start) {
                moveShape(toContentPoint: location)
            } else {
                begin(atContentPoint: start)
                move(toContentPoint: location)
            }
        case .changed:
            if shapeDrag != nil { moveShape(toContentPoint: location) } else { move(toContentPoint: location) }
        case .ended:
            if shapeDrag != nil {
                endShape(atContentPoint: location)
            } else {
                Task { await self.end(atContentPoint: location) }
            }
        case .cancelled, .failed:
            cancelShape()
            cancel()
        default:
            break
        }
    }

    /// The finger went down at `point` (the content view's coordinates): the word there is selected, in
    /// place of any selection. Nothing happens off the pages, off their text (`takesTouch`), or without a
    /// text tool that may be used.
    func begin(atContentPoint point: CGPoint) {
        guard let host, let controller = model.selection, takesTouch(atContentPoint: point),
              let location = host.pageLocation(of: point), let found = textTool(onPage: location.page) else { return }
        strokeCount += 1
        stroke = Stroke(id: strokeCount, tool: found.tool, kind: found.kind, page: location.page)
        controller.clear()
        controller.beginWord(page: location.page, at: onText(location.point, onPage: location.page))
    }

    /// `point` (view space), or, when it is off the page's glyphs but within `hitSlop` of one (where a
    /// finger is taken as on the text: `isNearText`), a point inside the glyph nearest it: a drag that
    /// starts just off a word starts at that word. (The engine's word search alone finds no word for a
    /// point just before the first glyph of a line that runs down a turned page.)
    private func onText(_ point: CGPoint, onPage page: Int) -> CGPoint {
        guard let boxes = text.boxes(onPage: page), !boxes.contains(where: { $0.contains(point) }) else { return point }
        let slop = hitSlop(onPage: page)
        func distance(to box: CGRect) -> CGFloat {
            hypot(max(box.minX - point.x, 0, point.x - box.maxX), max(box.minY - point.y, 0, point.y - box.maxY))
        }
        guard let nearest = boxes.filter({ $0.insetBy(dx: -slop, dy: -slop).contains(point) })
            .min(by: { distance(to: $0) < distance(to: $1) }) else { return point }
        let inside = nearest.insetBy(dx: nearest.width / 4, dy: nearest.height / 4)
        return CGPoint(x: min(max(point.x, inside.minX), inside.maxX), y: min(max(point.y, inside.minY), inside.maxY))
    }

    /// The finger is at `point`: the selection runs from the first word to there, on the drag's page.
    /// Until the first word is found the selection cannot be extended; the end does it again.
    func move(toContentPoint point: CGPoint) {
        guard let stroke, let page = host?.pagePoint(ofContentPoint: point, onPage: stroke.page) else { return }
        model.selection?.extend(to: page)
    }

    /// The finger came up at `point`: once the selection has caught up with it, the text is marked, if
    /// the tool that began the drag is still picked and may still be used. Says whether a mark was made.
    /// A drag whose mark is not made leaves no selection behind.
    @discardableResult
    func end(atContentPoint point: CGPoint) async -> Bool {
        guard let stroke, let controller = model.selection else { return false }
        defer { if self.stroke?.id == stroke.id { self.stroke = nil } }
        await controller.waitUntilSettled()
        if let page = host?.pagePoint(ofContentPoint: point, onPage: stroke.page) {
            controller.extend(to: page)
            await controller.waitUntilSettled()
        }
        // Another drag may have begun meanwhile: that one owns the selection now.
        guard self.stroke?.id == stroke.id else { return false }
        guard model.tool == stroke.tool, textTool(onPage: stroke.page) != nil,
              let selected = controller.selection, Int(selected.page) == stroke.page else {
            controller.clear()
            return false
        }
        return await model.markSelection(stroke.kind)
    }

    /// The drag was cancelled (a call coming in, the system taking the touch): nothing is marked, and
    /// the selection made on the way goes.
    func cancel() {
        guard stroke != nil else { return }
        stroke = nil
        model.selection?.clear()
    }

    // MARK: Shapes

    /// The finger went down at `point` (the content view's coordinates) with a shape tool picked that
    /// may be used on the page under it: the shape is dragged out from there. Says whether it is.
    @discardableResult
    func beginShape(atContentPoint point: CGPoint) -> Bool {
        guard let location = host?.pageLocation(of: point), let tool = shapeTool(onPage: location.page) else { return false }
        if let drag = shapeDrag { clearDraft(onPage: drag.page) }
        shapeDrag = ShapeDrag(tool: tool, style: model.toolStyles[tool], page: location.page, start: location.point,
                              revision: model.revision)
        return true
    }

    /// The finger is at `point`: the shape from where it went down to there, kept to its page, is drawn
    /// dashed over the page; none while the drag is too short to be one.
    func moveShape(toContentPoint point: CGPoint) {
        guard let drag = shapeDrag, let end = host?.pagePoint(ofContentPoint: point, onPage: drag.page),
              let size = pageSize(drag.page) else { return }
        showDraft(ShapeGeometry.draft(of: drag.tool, from: drag.start, to: end, pageSize: size), of: drag, dashed: true)
    }

    /// The finger came up at `point`: the shape is added, if the tool that began the drag is still
    /// picked and may still be used, and the drag is long enough to be one; it is drawn solid until the
    /// page shows it, or goes at once when it is refused. The task says whether it was added; nil when
    /// nothing was handed over.
    @discardableResult
    func endShape(atContentPoint point: CGPoint) -> Task<Bool, Never>? {
        guard let drag = shapeDrag else { return nil }
        shapeDrag = nil
        guard model.tool == drag.tool, shapeTool(onPage: drag.page) != nil,
              let end = host?.pagePoint(ofContentPoint: point, onPage: drag.page), let size = pageSize(drag.page),
              let draft = ShapeGeometry.draft(of: drag.tool, from: drag.start, to: end, pageSize: size) else {
            clearDraft(onPage: drag.page)
            return nil
        }
        showDraft(draft, of: drag, dashed: false)
        let made = model.enqueueShape(page: drag.page, draft: draft, workedOutAt: drag.revision, style: drag.style)
        return Task { [weak self] in
            let ok = await made.value
            if ok {
                Task { [weak self] in
                    try? await Task.sleep(for: Self.inkPreviewDuration)
                    self?.clearDraft(draft, onPage: drag.page)
                }
            } else {
                self?.clearDraft(draft, onPage: drag.page)
            }
            return ok
        }
    }

    /// The drag was cancelled: nothing is added, and nothing of it stays on the page.
    func cancelShape() {
        guard let drag = shapeDrag else { return }
        shapeDrag = nil
        clearDraft(onPage: drag.page)
    }

    /// Draws `draft` over the drag's page, in the drag's style, dashed or solid.
    private func showDraft(_ draft: DraftShape?, of drag: ShapeDrag, dashed: Bool) {
        guard let overlay = host?.pageView(for: drag.page)?.overlay else { return }
        let style = drag.style
        overlay.draftStyle = DraftStyle(color: style.color.uiColor, width: CGFloat(InkGeometry.lineWidth(style.width)),
                                        fill: drag.tool.usesFill && style.fill ? ShapeGeometry.fill(for: style.color).uiColor : nil,
                                        dashed: dashed)
        overlay.draft = draft
    }

    /// Takes the shape drawn over `page` off it: `draft`, if it is still the one there (a later drag's
    /// stays), or whatever is there when nil.
    private func clearDraft(_ draft: DraftShape? = nil, onPage page: Int) {
        guard let overlay = host?.pageView(for: page)?.overlay else { return }
        if draft == nil || overlay.draft == draft { overlay.draft = nil }
    }

    // MARK: Text boxes and notes

    @objc private func placeTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let host else { return }
        place(atContentPoint: recognizer.location(in: host.contentView))
    }

    /// Whether a tap at `point` (the content view's coordinates) is the markup's: while a box is being
    /// typed in, any tap on the pages (it ends the box); otherwise one on a page where Text Box or Note
    /// is picked and may be used.
    func takesTap(atContentPoint point: CGPoint) -> Bool {
        if textEditor != nil { return true }
        guard let location = host?.pageLocation(of: point) else { return false }
        return placeTool(onPage: location.page) != nil
    }

    /// A tap at `point` (the content view's coordinates): it ends the box being typed in, if there is
    /// one (and starts no other); otherwise, with Text Box, it puts a box to type in there, and with
    /// Note, it opens the note sheet for the note under it or a new one there.
    func place(atContentPoint point: CGPoint) {
        if textEditor != nil {
            commitPendingText()
            return
        }
        guard let location = host?.pageLocation(of: point), let tool = placeTool(onPage: location.page) else { return }
        switch tool {
        case .textBox: beginTextBox(onPage: location.page, at: location.point)
        case .note: openNote(onPage: location.page, at: location.point)
        case .select, .highlight, .underline, .strikeout, .ink, .rectangle, .oval, .line, .arrow, .eraser: break
        }
    }

    /// Opens the note sheet for the note on `page` under `point` (view space), with its text, or for a
    /// new note there, its icon kept on the page.
    private func openNote(onPage page: Int, at point: CGPoint) {
        guard let size = pageSize(page) else { return }
        if let note = model.annotationIndex.hit(page: page, at: point, slop: hitSlop(onPage: page), matching: { $0.kind == .note }) {
            model.noteDraft = NoteDraft(page: page, point: CGPoint(x: note.rect.x, y: note.rect.y),
                                        existing: AnnotationRef(page: page, index: note.index), text: note.contents ?? "",
                                        revision: model.revision)
        } else {
            model.noteDraft = NoteDraft(page: page, point: ShapeGeometry.noteBox(at: point, pageSize: size), existing: nil,
                                        text: "", revision: model.revision)
        }
    }

    /// Puts a box to type in on `page` at `point` (view space; moved in from the page's edges as far as
    /// its least width and its first line need), in Text Box's style, and brings up the keyboard.
    private func beginTextBox(onPage page: Int, at point: CGPoint) {
        guard let host, let size = pageSize(page) else { return }
        let style = model.toolStyles[.textBox]
        let origin = ShapeGeometry.textBoxOrigin(at: point, fontSize: CGFloat(ShapeGeometry.fontSize(style.fontSize)), pageSize: size)
        let editor = InlineTextEditor(page: page, origin: origin, revision: model.revision, style: style, pageSize: size)
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
        let box = ShapeGeometry.textBoxRect(at: editor.origin, text: editor.text ?? "", fontSize: editor.fontSize, pageSize: editor.pageSize)
        guard let frame = host.scrollViewRect(of: box, onPage: editor.page) else { return }
        editor.show(atScreenScale: host.screenScale(ofPage: editor.page))
        if editor.frame != frame { editor.frame = frame }
    }

    /// Ends the box being typed in, if there is one: its text, if anything but spaces was typed, is
    /// added as a text box where it was typed, handed over before this returns, worked out against the
    /// revision the box was put there at. A picture of the text stays over the page meanwhile: once it
    /// is made, until the page has been drawn again with it; when it is refused (stale, say), it goes
    /// at once. The task says whether it was made; nil with no box.
    @discardableResult
    func commitPendingText() -> Task<Bool, Never>? {
        guard let editor = textEditor else { return nil }
        // Done with first, so that whatever this sets off (the end of editing; the change handed over,
        // which adds what is waiting first) finds no box to end again.
        textEditor = nil
        editor.delegate = nil
        model.pendingTextDidChange(false)
        let text = editor.text ?? ""
        editor.resignFirstResponder()
        let preview = ShapeGeometry.committedText(text).isEmpty ? nil : showPreview(of: editor)
        editor.removeFromSuperview()
        keyboardInsetDidChange()
        let made = model.enqueueTextBox(page: editor.page, at: editor.origin, text: text, workedOutAt: editor.revision, style: editor.style)
        return Task { [weak self] in
            let ok = await made.value
            if ok {
                Task { [weak self] in
                    try? await Task.sleep(for: Self.inkPreviewDuration)
                    self?.removeTextPreview(preview)
                }
            } else {
                self?.removeTextPreview(preview)
            }
            return ok
        }
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
        let box = ShapeGeometry.textBoxRect(at: editor.origin, text: editor.text ?? "", fontSize: editor.fontSize, pageSize: editor.pageSize)
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

    // MARK: Drawing

    /// Whether one finger on `page` draws: Draw is picked, the document's permissions are read, and
    /// they let it be used there.
    func drawsOn(page: Int) -> Bool {
        model.tool == .ink && model.capabilities != nil && model.refusal(of: .ink, onPage: page) == nil
    }

    /// A first finger is going down at `point` (the content view's coordinates): if it draws there
    /// (`drawsOn`), the canvas is put over the page under it, once the strokes waiting on another page,
    /// or drawn in another style, have been added. Says whether the canvas is there for the finger.
    /// While a stroke is being drawn the canvas stays where it is.
    @discardableResult
    func prepareToDraw(atContentPoint point: CGPoint) -> Bool {
        guard let host, let location = host.pageLocation(of: point), drawsOn(page: location.page) else { return false }
        let style = model.toolStyles[.ink]
        if let ink, ink.superview === host.contentView {
            if ink.isDrawing { return ink.page == location.page }
            if ink.page == location.page, ink.style == style { return true }
        }
        commitPendingInk()
        return placeCanvas(onPage: location.page, style: style)
    }

    /// A finger went down on `view`: anywhere but the pages (the toolbar, the palette, the back button,
    /// a bar over the pages), the strokes waiting are added. Going back to the documents closes the
    /// file at once, saving it only if it has a change by then; the finger going down on the back
    /// button is the last moment the strokes can become one.
    /// So is the text being typed in a text box: a finger on the box itself, or on the pages, is not
    /// outside them.
    func fingerWentDown(on view: UIView?) {
        guard let host, model.hasPendingInk || textEditor != nil else { return }
        if let view, view.isDescendant(of: host.scrollView) { return }
        model.commitPendingInk()
    }

    /// Puts the canvas, empty, over `page`, drawing in `style`. False without a layout for the page.
    private func placeCanvas(onPage page: Int, style: ToolStyle) -> Bool {
        guard let host, let place = host.layoutPlace(ofPage: page) else { return false }
        let canvas = ink ?? makeCanvas(page: page)
        canvas.page = page
        canvas.frame = place.frame
        canvas.canvasOrigin = .zero
        canvas.pointsPerCanvasPoint = 1 / place.scale
        canvas.style = style
        // As wide on screen as the line will be on the page: a canvas point is a layout point.
        canvas.tool = PKInkingTool(.monoline, color: UIColor(red: style.color.r, green: style.color.g, blue: style.color.b, alpha: 1),
                                   width: InkCaptureView.toolWidth(drawingLinesOf: InkGeometry.lineWidth(style.width) * place.scale))
        if !canvas.drawing.strokes.isEmpty { canvas.drawing = PKDrawing() }
        canvas.forgetStrokeHistory()
        if canvas.superview === host.contentView {
            host.contentView.bringSubviewToFront(canvas)
        } else {
            host.contentView.addSubview(canvas)
        }
        // Laid out at once: the finger it is put there for lands on it in this same hit test. (Made and
        // put there during the hit test without this, it drew nothing for that first finger on the
        // iOS 26.5 simulator; the next stroke drew.)
        canvas.layoutIfNeeded()
        return true
    }

    private func makeCanvas(page: Int) -> InkCaptureView {
        let canvas = InkCaptureView(page: page)
        canvas.delegate = self
        ink = canvas
        return canvas
    }

    /// Adds the strokes on the canvas, if any, to the document as one drawing, handed over before this
    /// returns: in page points (`InkGeometry.strokes`, sampled about every point on screen and kept
    /// within half a point on screen, half a page point at most), in the style they were drawn in,
    /// worked out against the revision they were drawn on. The canvas is cleared for the next strokes,
    /// and a picture of these stays over the page meanwhile: once they are made, until the page has
    /// been drawn again with them; when they are refused (stale, say), it goes at once, and nothing is
    /// left that looks drawn. The task says whether they were made; nil with none waiting.
    @discardableResult
    func commitPendingInk() -> Task<Bool, Never>? {
        guard let ink, !ink.drawing.strokes.isEmpty, let host else { return nil }
        let drawing = ink.drawing
        // A canvas point is a layout point: one on screen is 1 / zoom of it. Half a point on screen is
        // half a page point over the screen scale.
        let zoom = max(host.scrollView.zoomScale, 1)
        let screenScale = host.screenScale(ofPage: ink.page)
        let halfAScreenPoint = screenScale > 0 && screenScale.isFinite ? 0.5 / screenScale : 0.5
        let strokes = InkGeometry.strokes(of: drawing, canvasOrigin: ink.canvasOrigin, pointsPerCanvasPoint: ink.pointsPerCanvasPoint,
                                          spacing: 1 / zoom, tolerance: min(0.5, halfAScreenPoint))
        let revision = ink.drawnAt ?? model.revision
        let preview = showPreview(of: drawing, on: ink)
        // The canvas is emptied before the change is handed over: handing it over adds whatever strokes
        // are waiting first (`DocumentModel.enqueue`), which must then be none, or these would be added twice.
        ink.drawing = PKDrawing()
        ink.drawnAt = nil
        ink.forgetStrokeHistory()
        model.pendingInkDidChange(false)
        let made = model.enqueueInk(page: ink.page, strokes: strokes, drawnAt: revision, style: ink.style)
        return Task { [weak self] in
            let ok = await made.value
            if ok {
                Task { [weak self] in
                    try? await Task.sleep(for: Self.inkPreviewDuration)
                    self?.removePreview(preview)
                }
            } else {
                self?.removePreview(preview)
            }
            return ok
        }
    }

    /// A picture of `drawing` where it is on `canvas`, over the page, in the content view: what was
    /// drawn, while it is on its way into the page. Drawn at the zoom the view is at, up to some 8
    /// million pixels.
    private func showPreview(of drawing: PKDrawing, on canvas: InkCaptureView) -> UIView? {
        guard let host else { return nil }
        let area = drawing.bounds.intersection(canvas.bounds)
        guard !area.isNull, area.width > 0, area.height > 0 else { return nil }
        let wanted = max(canvas.traitCollection.displayScale, 1) * max(host.scrollView.zoomScale, 1)
        let scale = min(wanted, (8_000_000 / (area.width * area.height)).squareRoot())
        var image = UIImage()
        // In light colours, as on the canvas: PencilKit draws the current appearance's.
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: area, scale: scale)
        }
        let view = UIImageView(image: image)
        view.frame = canvas.convert(area, to: host.contentView)
        view.isUserInteractionEnabled = false
        host.contentView.insertSubview(view, belowSubview: canvas)
        inkPreviews.append(view)
        return view
    }

    private func removePreview(_ preview: UIView?) {
        guard let preview else { return }
        preview.removeFromSuperview()
        inkPreviews.removeAll { $0 === preview }
    }

    /// The tool changed (`PageScrollViewController.markupTool`): with Draw picked two fingers scroll
    /// (one draws), and the canvas is put over the page being read; with any other, or none, one
    /// finger scrolls again, and the canvas goes, once its strokes have been added (the model has
    /// added them as the tool changed). The box being typed in, if any, is ended (the model has ended
    /// it too), and a shape being dragged out with another tool is dropped.
    func toolDidChange() {
        guard let host else { return }
        commitPendingText()
        if let drag = shapeDrag, drag.tool != model.tool { cancelShape() }
        let drawing = model.tool == .ink
        host.scrollView.panGestureRecognizer.minimumNumberOfTouches = drawing ? 2 : 1
        guard !drawing else {
            // Over the page being read from the start, ready for the first finger.
            if ink?.superview !== host.contentView, drawsOn(page: model.currentPage) {
                _ = placeCanvas(onPage: model.currentPage, style: model.toolStyles[.ink])
            }
            return
        }
        commitPendingInk()
        ink?.removeFromSuperview()
    }

    /// The pages are about to be laid out again (a new width, a change to their number, size or
    /// rotation): the strokes waiting and the text being typed are added, worked out for the layout
    /// they were made on, and the canvas, the box typed in, a shape being dragged out and the pictures
    /// go with that layout.
    func layoutWillChange() {
        commitPendingInk()
        commitPendingText()
        cancelShape()
        ink?.removeFromSuperview()
        for preview in inkPreviews + textPreviews { preview.removeFromSuperview() }
        inkPreviews.removeAll()
        textPreviews.removeAll()
    }

    // MARK: Hitting annotations

    /// How far outside an annotation's box, in view space (PDF points of `page`), a touch still lands on
    /// it: `screenHitSlop` points on screen at the zoom the view is at, so it is the same under the
    /// finger zoomed in or out (`hitSlop(screenScale:)`).
    func hitSlop(onPage page: Int) -> CGFloat {
        Self.hitSlop(screenScale: host?.screenScale(ofPage: page) ?? 0)
    }

    /// `screenHitSlop` in PDF points, when a PDF point is `screenScale` points on screen (the layout's
    /// scale of the page times the zoom); the index's own 8 when there is no scale (no layout).
    nonisolated static func hitSlop(screenScale: CGFloat) -> CGFloat {
        screenScale > 0 && screenScale.isFinite ? screenHitSlop / screenScale : screenHitSlop
    }

    /// The annotation under `point` (the content view's coordinates), the one on top, with the slop
    /// on screen kept the same at every zoom; nil off the pages or on none.
    func annotation(atContentPoint point: CGPoint) -> AnnotationInfo? {
        guard let location = host?.pageLocation(of: point) else { return nil }
        return model.annotationIndex.hit(page: location.page, at: location.point, slop: hitSlop(onPage: location.page))
    }
}

// MARK: - UIGestureRecognizerDelegate

extension MarkupInteraction: UIGestureRecognizerDelegate {
    /// Whether the pan already has a finger: the touch being offered is a second one. (A first finger
    /// the pan did not take, on the white of the page, is counted by the pan itself, which sees every
    /// finger on the screen: `MarkupPanGestureRecognizer`. The scroll view's recognizers are not asked
    /// here: whether they count the touch being offered already is not said.)
    private var isAnotherFingerDown: Bool {
        pan.numberOfTouches > 0
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let host else { return false }
        if gestureRecognizer === placeTap { return takesTap(atContentPoint: touch.location(in: host.contentView)) }
        guard gestureRecognizer === pan else { return false }
        // With another finger down, the pan takes the touch, wherever it is, to hear of the second finger
        // and fail (`MarkupPanGestureRecognizer`): two fingers scroll and zoom.
        if isAnotherFingerDown { return true }
        // A pan that takes no touch is not waited for: the scroll view scrolls at once.
        return takesTouch(atContentPoint: touch.location(in: host.contentView))
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let host else { return false }
        if gestureRecognizer === placeTap { return takesTap(atContentPoint: placeTap.location(in: host.contentView)) }
        guard gestureRecognizer === pan else { return false }
        // Asked again where the finger went down: the page's text may have been read since it did. A pan
        // that does not begin fails, and the scroll view's pan, which has been waiting, scrolls.
        return takesTouch(atContentPoint: panStart())
    }

    /// Where the pan's finger went down, in the content view's coordinates (the pan is on it): as the
    /// pan heard it go down, or, when it did not (a test), where it is less how far it has moved.
    private func panStart() -> CGPoint {
        if let down = pan.touchDown { return down }
        guard let host else { return .zero }
        let moved = pan.translation(in: host.contentView)
        let location = pan.location(in: host.contentView)
        return CGPoint(x: location.x - moved.x, y: location.y - moved.y)
    }
}

/// A one-finger pan that fails when a second finger goes down before it has begun, so that two fingers
/// scroll and zoom however quickly the second follows the first. Every finger on the screen counts
/// (`event.allTouches`), not only those this pan was given: a second finger that went down where the
/// pan takes no touch (the white of the page, outside the pages) fails it too, at the latest when the
/// first finger moves. Once it has begun, more fingers are ignored.
final class MarkupPanGestureRecognizer: UIPanGestureRecognizer {
    /// Where the finger went down, in the coordinates of the view the pan is on; nil until one has. The
    /// pan begins once the finger has moved some way, and counts its translation from there: a drag
    /// that started from the translation began some 10 points off (seen on the iOS 26.5 simulator, a
    /// rectangle's corner short of where the finger went down).
    private(set) var touchDown: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if failsOnSecondFinger(event) { return }
        if touchDown == nil, let touch = touches.first { touchDown = touch.location(in: view) }
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        super.reset()
        touchDown = nil
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if failsOnSecondFinger(event) { return }
        super.touchesMoved(touches, with: event)
    }

    /// Fails the pan, and says so, when it has not begun and more than one finger is down.
    private func failsOnSecondFinger(_ event: UIEvent) -> Bool {
        guard state == .possible, Self.isMoreThanOneFinger((event.allTouches ?? []).map(\.phase)) else { return false }
        state = .failed
        return true
    }

    /// Whether touches in these `phases` are more than one finger down: those that have ended or been
    /// cancelled are not down.
    nonisolated static func isMoreThanOneFinger(_ phases: [UITouch.Phase]) -> Bool {
        phases.filter { $0 != .ended && $0 != .cancelled }.count > 1
    }
}

// MARK: - PKCanvasViewDelegate

extension MarkupInteraction: PKCanvasViewDelegate {
    /// Strokes came or went: the model hears whether some are waiting (the palette's Done), and the
    /// first of them records the revision they are drawn on.
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? InkCaptureView, canvas === ink else { return }
        if canvas.drawing.strokes.isEmpty {
            canvas.drawnAt = nil
        } else if canvas.drawnAt == nil {
            canvas.drawnAt = model.revision
        }
        model.pendingInkDidChange(!canvas.drawing.strokes.isEmpty)
    }

    /// A stroke begins: the canvas stays where it is until it ends. The first stroke on an empty
    /// canvas is drawn on the document as it is now.
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? InkCaptureView, canvas === ink else { return }
        canvas.isDrawing = true
        if canvas.drawing.strokes.isEmpty, canvas.drawnAt == nil { canvas.drawnAt = model.revision }
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? InkCaptureView, canvas === ink else { return }
        canvas.isDrawing = false
    }
}

extension MarkupInteraction: PendingInkHolder {}

// MARK: - UITextViewDelegate

extension MarkupInteraction: UITextViewDelegate {
    /// Text was typed in the box: it grows with it, is kept clear of the keyboard, and the model hears
    /// whether there is text waiting (the palette's Done). What is typed is never logged.
    func textViewDidChange(_ textView: UITextView) {
        guard let editor = textView as? InlineTextEditor, editor === textEditor else { return }
        model.pendingTextDidChange(!ShapeGeometry.committedText(editor.text ?? "").isEmpty)
        layoutTextEditor()
        revealTextEditor()
    }

    /// Editing ended (the keyboard put away, another field taking it): the text is added.
    func textViewDidEndEditing(_ textView: UITextView) {
        guard textView === textEditor else { return }
        commitPendingText()
    }
}

/// A gesture recognizer that only listens: it hears of each finger going down where it is attached
/// (the window) and says on which view (`fingerWentDown`). It never recognizes, so it never takes a
/// touch, delays one, or keeps another recognizer from recognizing; and no other one recognizing stops
/// it (`canBePrevented`).
///
/// It stays listening while any finger it heard of is down, and fails only once they have all lifted:
/// a recognizer that has failed hears nothing more until every touch has ended, and the back button
/// tapped while a palm, a finger or the Pencil rests on the page must still be heard.
final class FingerDownObserver: UIGestureRecognizer {
    /// Told the view each finger that goes down landed on.
    var fingerWentDown: ((UIView?) -> Void)?
    /// The fingers heard of that have not lifted yet.
    private var held = Set<ObjectIdentifier>()
    /// How many fingers it heard of are still down.
    var heldCount: Int { held.count }
    /// How many times it has given up on a sequence of touches (been set to failed). For tests: never
    /// before the last finger it heard of lifts. (Counted as the state is set: outside a real touch
    /// sequence UIKit does not keep the state it is given.)
    private(set) var failCount = 0

    override var state: UIGestureRecognizer.State {
        willSet { if newValue == .failed { failCount += 1 } }
    }

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        // Every kind of touch, together: a finger tapping Back while the Pencil rests on the page, and
        // the Pencil tapping it while a palm does. (By default a recognizer holding a touch of one type
        // ignores new touches of other types until it resets.)
        requiresExclusiveTouchType = false
        allowedTouchTypes = [UITouch.TouchType.direct, .pencil, .indirectPointer].map { NSNumber(value: $0.rawValue) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { touchWentDown(touch, on: touch.view) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { touchLifted(touch) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { touchLifted(touch) }
    }

    override func reset() {
        super.reset()
        held.removeAll()
    }

    /// `touch` went down on `view`: reported, and held until it lifts.
    private func touchWentDown(_ touch: UITouch, on view: UIView?) {
        held.insert(ObjectIdentifier(touch))
        fingerWentDown?(view)
    }

    /// `touch` lifted (or was cancelled): once none is held, the recognizer is done with these touches.
    private func touchLifted(_ touch: UITouch) {
        held.remove(ObjectIdentifier(touch))
        if held.isEmpty, state == .possible { state = .failed }
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
