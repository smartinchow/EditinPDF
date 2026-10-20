import EditinPDFCore
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// What a finger on the pages does in Markup mode, for the tools that act on the page by touch:
/// Select, which picks an annotation already there, drags it and offers its menu; Highlight,
/// Underline and Strikethrough, which mark the text a finger drags across; Draw; the shape tools,
/// which draw a rectangle, an oval, a line or an arrow where a finger drags; Text Box, which puts a
/// box to type in where a finger taps; Note, which opens a note there; Sign, which places the saved
/// signature there; and the eraser, which deletes the annotations it touches.
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
/// **Draw** (the ink tool) draws with PencilKit on a canvas over one page: `InkInteraction`, which the
/// first finger on the pages is handed to before it lands (`PageContentView.touchWillLand`).
///
/// **Rectangle, Oval, Line and Arrow** take one finger on a page where the tool may be used, as the
/// text tools do on text (the same pan, `takesTouch`): the drag draws the shape, dashed over the page
/// (`PageOverlayView.draft`), from where the finger went down to where it is, kept to that page
/// (`ShapeGeometry.draft`), and adds it when the finger comes up; a drag shorter than
/// `ShapeGeometry.minimumSide` adds nothing. Anywhere else one finger scrolls; two fingers always
/// scroll and zoom, as for the text tools. The shape is worked out against the revision the drag
/// began on, and drawn solid until the page shows it; refused (stale, say), it goes at once.
///
/// **Select** (`AnnotationSelectInteraction`) takes a tap on an annotation, or anywhere while one is
/// selected, and one finger that goes down on the selected annotation, which it drags; elsewhere one
/// finger scrolls. **The eraser** (`EraserInteraction`) takes one finger, and a tap, anywhere on a page
/// where it may be used. Both share this pan and this tap; two fingers scroll and zoom, as for the
/// others.
///
/// **Text Box, Note and Sign** take a tap (`placeTap`), on a page where the tool may be used; a drag
/// scrolls. Note opens the note sheet (`DocumentModel.noteDraft`): for the note under the finger, or
/// a new one there. Text Box puts a box to type in there: `TextBoxInteraction`, which has the box and
/// the keyboard. A text box is refused on a turned page: its text would read sideways
/// (`Strings.textBoxNeedsUprightPage`). Sign places the saved signature there, centred on the tap, as
/// one change (`placeSignature`); with none saved, the tap opens the pad to draw one.
///
/// Strokes waiting and text being typed are added (`commitPendingInk`, `commitPendingText`, which the
/// model calls together) whenever a finger goes down anywhere outside the pages (`fingerWentDown`).
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

    /// Draw: its canvas over a page, and the strokes on their way into the document.
    let drawing: InkInteraction
    /// Text Box: the box being typed in, and the keyboard over it.
    let textBoxes: TextBoxInteraction
    /// Select: the annotation picked, dragged, and its menu.
    let selecting: AnnotationSelectInteraction
    /// The eraser: its strokes and taps.
    let eraser: EraserInteraction
    /// Hears of every finger going down in the screen's window, without taking it: see
    /// `fingerWentDown`. The scroll view's controller puts it on its window while it is on screen.
    let fingersDown = FingerDownObserver()
    /// How long a picture of strokes added stays: the page's cover while it is drawn again, and a
    /// little more for its tiles to come in.
    static let inkPreviewDuration: Duration = PageView.redrawCoverDuration + .milliseconds(250)

    /// The answer of `made`, a change handed over while a picture of what it adds is shown over the page
    /// (a shape, strokes, text), once that picture has been seen to: when the change is made it stays
    /// `inkPreviewDuration` more, until the page has been drawn again with it; when it is refused (stale,
    /// say), `removePicture` takes it away at once, and nothing is left that looks made.
    static func settlePreview(of made: Task<Bool, Never>, removePicture: @escaping @MainActor () -> Void) -> Task<Bool, Never> {
        Task {
            let ok = await made.value
            if ok {
                Task {
                    try? await Task.sleep(for: inkPreviewDuration)
                    removePicture()
                }
            } else {
                removePicture()
            }
            return ok
        }
    }

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

    init(host: PageScrollViewController, model: DocumentModel) {
        self.host = host
        self.model = model
        drawing = InkInteraction(host: host, model: model)
        textBoxes = TextBoxInteraction(host: host, model: model)
        selecting = AnnotationSelectInteraction(host: host, model: model, textBoxes: textBoxes)
        eraser = EraserInteraction(host: host, model: model)
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
        host.contentView.touchWillLand = { [weak self] point in self?.drawing.prepareToDraw(atContentPoint: point) }
        fingersDown.fingerWentDown = { [weak self] view in self?.fingerWentDown(on: view) }
        placeTap.numberOfTouchesRequired = 1
        placeTap.addTarget(self, action: #selector(placeTapped(_:)))
        placeTap.delegate = self
        host.contentView.addGestureRecognizer(placeTap)
        textBoxes.install()
        selecting.install()
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

    /// Whether a finger going down at `point` (the content view's coordinates) drags: the selected
    /// annotation, with Select, when the point is on it; an eraser stroke; out a shape, when a shape
    /// tool is picked and may be used on the page under it; out text to mark, when a text markup tool
    /// is picked and may be used, and the point is on the page's text (or the page's text is not read
    /// yet: see `isNearText`). Otherwise the finger scrolls.
    func takesTouch(atContentPoint point: CGPoint) -> Bool {
        if selecting.takesTouch(atContentPoint: point) || eraser.takesTouch(atContentPoint: point) { return true }
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
            if selecting.beginMove(atContentPoint: start) {
                selecting.move(toContentPoint: location)
            } else if eraser.begin(atContentPoint: start) {
                eraser.move(toContentPoint: location)
            } else if beginShape(atContentPoint: start) {
                moveShape(toContentPoint: location)
            } else {
                begin(atContentPoint: start)
                move(toContentPoint: location)
            }
        case .changed:
            if selecting.isMoving {
                selecting.move(toContentPoint: location)
            } else if eraser.isErasing {
                eraser.move(toContentPoint: location)
            } else if shapeDrag != nil {
                moveShape(toContentPoint: location)
            } else {
                move(toContentPoint: location)
            }
        case .ended:
            if selecting.isMoving {
                selecting.endMove(atContentPoint: location)
            } else if eraser.isErasing {
                eraser.end(atContentPoint: location)
            } else if shapeDrag != nil {
                endShape(atContentPoint: location)
            } else {
                Task { await self.end(atContentPoint: location) }
            }
        case .cancelled, .failed:
            selecting.cancelMove()
            eraser.cancel()
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
        return Self.settlePreview(of: made) { [weak self] in self?.clearDraft(draft, onPage: drag.page) }
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
    /// typed in, any tap on the pages (it ends the box); otherwise Select's (`AnnotationSelectInteraction
    /// .takesTap`), the eraser's, or one on a page where Text Box or Note is picked and may be used.
    func takesTap(atContentPoint point: CGPoint) -> Bool {
        if textBoxes.textEditor != nil { return true }
        if selecting.takesTap(atContentPoint: point) || eraser.takesTap(atContentPoint: point) { return true }
        guard let location = host?.pageLocation(of: point) else { return false }
        return placeTool(onPage: location.page) != nil
    }

    /// A tap at `point` (the content view's coordinates): it ends the box being typed in, if there is
    /// one (and starts no other); otherwise, with Select, it selects the annotation under it or none;
    /// with the eraser, it deletes the one under it; with Text Box, it puts a box to type in there;
    /// with Note, it opens the note sheet for the note under it or a new one there; and with Sign, it
    /// places the saved signature there.
    func place(atContentPoint point: CGPoint) {
        if textBoxes.textEditor != nil {
            commitPendingText()
            return
        }
        if selecting.tap(atContentPoint: point) || eraser.tap(atContentPoint: point) != nil { return }
        guard let location = host?.pageLocation(of: point), let tool = placeTool(onPage: location.page) else { return }
        switch tool {
        case .textBox:
            guard let size = pageSize(location.page) else { return }
            textBoxes.beginTextBox(onPage: location.page, at: location.point, pageSize: size)
        case .note: openNote(onPage: location.page, at: location.point)
        case .signature: placeSignature(onPage: location.page, at: location.point)
        case .select, .highlight, .underline, .strikeout, .ink, .rectangle, .oval, .line, .arrow, .eraser: break
        }
    }

    /// Places the saved signature on `page`, centred on `point` (view space), as one change worked out
    /// against the document as it is now; it is drawn over the page until the page shows it, or goes at
    /// once when it is refused (stale, say). With no signature saved, the pad opens to draw one, and
    /// nothing is placed. The task says whether it was placed; nil when nothing was handed over.
    @discardableResult
    func placeSignature(onPage page: Int, at point: CGPoint) -> Task<Bool, Never>? {
        guard model.signatures.saved != nil else {
            model.askForSignature()
            return nil
        }
        guard let strokes = model.signatureStrokes(onPage: page, centeredAt: point) else { return nil }
        let draft = SignatureDraft(strokes: strokes)
        host?.pageView(for: page)?.overlay.signatures.append(draft)
        let made = model.enqueueSignature(page: page, strokes: strokes, workedOutAt: model.revision)
        return Self.settlePreview(of: made) { [weak self] in
            self?.host?.pageView(for: page)?.overlay.signatures.removeAll { $0 == draft }
        }
    }

    /// Opens the note sheet for the note on `page` under `point` (view space), with its text, or for a
    /// new note there, its icon kept on the page.
    private func openNote(onPage page: Int, at point: CGPoint) {
        guard let size = pageSize(page) else { return }
        if let note = model.annotationIndex.hit(page: page, at: point, slop: hitSlop(onPage: page), matching: { $0.kind == .note }) {
            model.editNote(note)
        } else {
            model.noteDraft = NoteDraft(page: page, point: ShapeGeometry.noteBox(at: point, pageSize: size), existing: nil,
                                        text: "", revision: model.revision)
        }
    }

    // MARK: What waits to be added

    /// A finger went down on `view`: anywhere but the pages (the toolbar, the palette, the back button,
    /// a bar over the pages), the strokes waiting are added. Going back to the documents closes the
    /// file at once, saving it only if it has a change by then; the finger going down on the back
    /// button is the last moment the strokes can become one.
    /// So is the text being typed in a text box, or in a form field: a finger on the box or the field's
    /// editor itself, or on the pages, is not outside them.
    func fingerWentDown(on view: UIView?) {
        guard let host, model.hasPendingInk || textBoxes.textEditor != nil || model.isEditingField else { return }
        if let view, view.isDescendant(of: host.scrollView) { return }
        model.commitPendingInk()
    }

    /// Adds the strokes drawn with Draw and waiting, if any (`InkInteraction.commitPendingInk`).
    @discardableResult
    func commitPendingInk() -> Task<Bool, Never>? {
        drawing.commitPendingInk()
    }

    /// Ends the box being typed in, if any, adding its text (`TextBoxInteraction.commitPendingText`).
    @discardableResult
    func commitPendingText() -> Task<Bool, Never>? {
        textBoxes.commitPendingText()
    }

    /// The tool changed (`PageScrollViewController.markupTool`): the box being typed in, if any, is
    /// ended (the model has ended it too), a shape being dragged out with another tool is dropped, so are
    /// an annotation being dragged and an eraser stroke, and Draw sets up its gestures and its canvas for
    /// the new tool (`InkInteraction.toolDidChange`).
    func toolDidChange() {
        guard host != nil else { return }
        textBoxes.commitPendingText()
        if let drag = shapeDrag, drag.tool != model.tool { cancelShape() }
        selecting.toolDidChange()
        if model.tool != .eraser { eraser.cancel() }
        drawing.toolDidChange()
    }

    /// The pages are about to be laid out again (a new width, a change to their number, size or
    /// rotation): the strokes waiting and the text being typed are added, worked out for the layout
    /// they were made on, and the canvas, the box typed in, a shape or an annotation being dragged, an
    /// eraser stroke, the selection's menu and the pictures go with that layout.
    func layoutWillChange() {
        drawing.layoutWillChange()
        textBoxes.layoutWillChange()
        cancelShape()
        selecting.layoutWillChange()
        eraser.cancel()
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

extension MarkupInteraction: PendingInkHolder {}

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
