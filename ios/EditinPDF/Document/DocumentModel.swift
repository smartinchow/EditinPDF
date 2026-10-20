import EditinPDFCore
import Foundation
import Observation

/// What SwiftUI shows for one document: whether it is open, locked behind a password or could not
/// be read; its pages; which page the reader is on; its search; and the text selected in it. And
/// the changes made to it: every edit, undo and redo goes through one serial queue (`EditQueue`),
/// off the main actor, and is registered with the scene's `UndoManager`; after each one the
/// document's state (pages, annotations, form fields, what may be edited) is read again, off the
/// main actor too, and published here with the revision it belongs to.
/// Everything lives on the main actor, since views read it directly.
@MainActor
@Observable
final class DocumentModel {
    enum State {
        /// Needs a password; the bytes are kept for the next try. `wrongPassword` is true once a
        /// password has been tried and refused.
        case locked(Data, wrongPassword: Bool)
        case open(PdfDocument)
        /// Could not be opened. `detail` is the engine's explanation, ready to show under
        /// `Strings.fileCouldNotBeOpened`; nil when there is none to show.
        case failed(detail: String?)
    }

    private(set) var state: State
    /// The geometry of every page, read once when the document opens (off the main actor, with the
    /// open: `OpenOutcome`); empty until then.
    private(set) var pages: [PageInfo]
    /// The page the reader is on, counting from 0; the scroll view keeps it current.
    var currentPage = 0
    /// The search of the document: made once, when the document opens, and the same one for as long as
    /// the model lives; nil unless the document is open. It holds the engine's document, not the
    /// model.
    private(set) var search: SearchController?
    /// The selected text: made with `search`, when the document opens, and the same one for as long as
    /// the model lives; nil unless the document is open. It holds the engine's document, not the model.
    private(set) var selection: SelectionController?

    /// Whether the document is password-protected, as the engine says (an owner password alone counts,
    /// though the file opens with none). Pages extracted from it are a new PDF without protection.
    var isEncrypted: Bool { capabilities?.isEncrypted == true }

    /// How many pages the document has; 0 unless it is open.
    var pageCount: Int { pages.count }

    // MARK: Editing state

    /// The engine's revision of the document that everything here was read from. Every change,
    /// undo and redo moves it on; caches of what the pages look like key off it.
    private(set) var revision: UInt64 = 0
    /// What may be changed in the document; nil unless it is open (and until its state is first
    /// read, a moment after it opens).
    private(set) var capabilities: EditCapabilities?
    /// The document's annotations, by page, and which one a touch lands on: read again with every
    /// revision.
    private(set) var annotationIndex = AnnotationIndex([])
    /// The document's annotations, by the page (counting from 0) they are on, in the engine's order.
    var annotationsByPage: [Int: [AnnotationInfo]] { annotationIndex.byPage }
    /// The document's form fields, in the document's order, and each page's widgets (`FormIndex`):
    /// read again with every revision.
    private(set) var formIndex = FormIndex.empty
    /// The document's form fields, in the document's order.
    var formFields: [FormField] { formIndex.fields }
    /// Whether the form has more fields, options or widgets than the engine lists: what is left out
    /// cannot be filled in, and the screen says so once.
    private(set) var formFieldsTruncated = false
    /// Values handed to the engine for fields, by the fields' names, and not published yet: what a tap
    /// works out its change from (`fieldAsFilled`). See `FormFilling.swift`.
    @ObservationIgnored private(set) var fillsOnTheirWay: [String: FillOnItsWay] = [:]
    /// The list box whose sheet of options is up, for several of them to be checked; nil while none is.
    var choiceDraft: ChoiceDraft?
    /// What the last change, undo or redo did: its revision, the pages it touched (nil: any of them
    /// may have moved), and whether the number of pages, or a page's size or rotation, changed.
    private(set) var lastChange: PageChange?
    /// A change that was not made, for the screen to show as an alert; the screen clears it.
    var failure: EditFailure?
    /// The annotation the reader has picked (Select, the Comments list). Every change clears it: its
    /// index may name another annotation afterwards. See `AnnotationEditing.swift`.
    var selectedAnnotation: AnnotationRef?

    // MARK: Markup

    /// What a touch on the page does: nil while the reader is only reading (touches scroll, zoom and
    /// select text); Markup in the toolbar sets `.select`, and the palette any other tool. Strokes drawn
    /// with Draw and text typed in a text box, not added yet, are added as soon as it changes
    /// (`commitPendingInk`). The annotation selected with Select is let go of with any other tool.
    var tool: Tool? {
        didSet {
            guard tool != oldValue else { return }
            commitPendingInk()
            if tool != .select { selectedAnnotation = nil }
        }
    }
    /// Each tool's colour and size, kept between documents and launches.
    let toolStyles: ToolStyleStore
    /// The reader's signature, which Sign places: the app's, shared by every document.
    let signatures: SignatureStore

    /// Picks `tool`, as the palette does. Sign picked with no signature saved opens the pad to draw
    /// one (`showsSignaturePad`), where Sign may be used; with one saved, the next tap places it.
    func pick(_ tool: Tool) {
        self.tool = tool
        guard tool == .signature, canUse(.signature) else { return }
        // Read again: the file may have been unreadable while the device was locked.
        signatures.reload()
        if signatures.saved == nil { showsSignaturePad = true }
    }

    /// Why `tool` cannot be used on the page being read, for the palette to show; nil when it can
    /// be (and while the document's permissions are not read yet).
    func refusal(of tool: Tool) -> String? {
        refusal(of: tool, onPage: currentPage)
    }

    /// Why `tool` cannot be used on `page`; nil when it can be (and while the document's permissions
    /// are not read yet).
    func refusal(of tool: Tool, onPage page: Int) -> String? {
        guard let capabilities else { return nil }
        let rotation = pages.indices.contains(page) ? pages[page].rotationDegrees : 0
        return tool.refusal(canAnnotate: capabilities.canAnnotate, pageRotation: rotation)
    }

    /// Marks the selected text with a highlight, an underline or a strikethrough (`kind`), in the colour
    /// of the tool that makes it (`Tool(markupKind:)`, whatever tool is picked: the selection's menu
    /// does it in reading mode too), over the selection's boxes, which are in view space like every
    /// edit's. Says whether the mark was made.
    ///
    /// The selection goes either way: once the mark is made, with every other change (`refresh`);
    /// when it is not (and the reader has not selected something else meanwhile), here, so that nothing is left on the page that looks marked when it is not. A
    /// refusal is told as every change's is (`failure`): the tool's own (`refusal(of:onPage:)`) at
    /// once, or the engine's, such as a mark queued behind a turn of its page, which is stale since its
    /// boxes were worked out for the page as it was (`enqueue`). With nothing selected, nothing happens.
    @discardableResult
    func markSelection(_ kind: MarkupKind) async -> Bool {
        guard let controller = selection, let selected = controller.selection else { return false }
        let page = Int(selected.page)
        let rects = SelectionController.rects(of: selected).map { Rect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }
        let tool = Tool(markupKind: kind)
        if let refusal = refusal(of: tool, onPage: page) {
            controller.clear()
            failure = EditFailure(message: refusal)
            return false
        }
        guard !rects.isEmpty else {
            controller.clear()
            return false
        }
        let edit = Edit.addTextMarkup(page: selected.page, kind: kind, rects: rects, color: toolStyles[tool].color.rgbColor, contents: "")
        let made = await perform(edit, named: Strings.actionAddAnnotation, touching: [page])
        // A selection the reader made while the mark was on its way is theirs: it stays.
        if !made, controller.selection == selected { controller.clear() }
        return made
    }

    /// Whether `tool` can be used on the page being read: not before the document's permissions are
    /// read, and not when they refuse it.
    func canUse(_ tool: Tool) -> Bool {
        capabilities != nil && refusal(of: tool) == nil
    }

    // MARK: Drawing

    /// Whether strokes drawn with Draw are on a page, waiting to be added as one drawing
    /// (`commitPendingInk`): the palette shows Done meanwhile.
    private(set) var hasPendingInk = false
    /// What holds those strokes: the page view's ink capture (`MarkupInteraction`), which tells
    /// `pendingInkDidChange` when it has some or none.
    @ObservationIgnored weak var inkHolder: (any PendingInkHolder)?

    /// The ink capture's strokes came or went.
    func pendingInkDidChange(_ pending: Bool) {
        if hasPendingInk != pending { hasPendingInk = pending }
    }

    /// Adds the strokes drawn with Draw and waiting, if any, as one change, the text typed in a text
    /// box and waiting, if any, as another, and the text typed in a form field, if any, as a third, each
    /// handed over before this returns: Done does it, and so does everything that must come after them
    /// (another tool, any other change, Undo and Redo, the scene leaving the screen). Nothing happens
    /// with none waiting.
    func commitPendingInk() {
        inkHolder?.commitPendingInk()
        inkHolder?.commitPendingText()
        fieldHolder?.commitPendingField()
    }

    // MARK: Form fields being typed in

    /// What holds the text being typed in a form field: the scroll view's forms (`FormInteraction`).
    @ObservationIgnored weak var fieldHolder: (any PendingFieldHolder)?

    /// Whether a form field is being typed in (its editor is up), changed or not.
    var isEditingField: Bool { fieldHolder?.isEditingField ?? false }

    /// Whether text other than the field's own is typed in a form field, waiting to be filled in: added
    /// with the strokes waiting (`commitPendingInk`).
    private(set) var hasPendingFieldText = false

    /// The text being typed in a form field came to differ from the field's, or back.
    func pendingFieldTextDidChange(_ pending: Bool) {
        if hasPendingFieldText != pending { hasPendingFieldText = pending }
    }

    /// Whether anything is waiting to be added (`hasPendingMarkup`, `hasPendingFieldText`): Undo adds
    /// it and takes it back, and Redo waits.
    var hasPendingEdit: Bool { hasPendingMarkup || hasPendingFieldText }

    /// `value` is handed to the engine for field `field`: a tap works out its change from it until it is
    /// published (`fillsOnTheirWay`). Says which hand-over it is, for `fillDidFinish`.
    func fillWillStart(_ field: String, value: FieldValue) -> UUID {
        let id = UUID()
        fillsOnTheirWay[field] = FillOnItsWay(id: id, value: value)
        return id
    }

    /// The value handed over as `id` for `field` is made and published, or refused: it is forgotten,
    /// unless another has been handed over for the field since.
    func fillDidFinish(_ field: String, id: UUID) {
        if fillsOnTheirWay[field]?.id == id { fillsOnTheirWay[field] = nil }
    }

    /// Adds `strokes` (view space: PDF points of `page`, each stroke the points it passed through) as
    /// one drawing in `style` (Draw's own when nil): one change named `Strings.actionAddAnnotation`,
    /// which one undo takes back. Says whether it was made.
    ///
    /// The strokes are kept within what the bridge takes (`InkGeometry`): a drawing too big for one
    /// annotation is several, made together. Like every placement in view space it is worked out
    /// against a revision: `drawnAt`, the one the strokes were drawn on (the model's now when nil), so
    /// that ink drawn before a turn of its page was published is refused as stale (`enqueue`), and
    /// the reader told, instead of landing turned. A tool that may not be used is refused at once.
    @discardableResult
    func addInk(page: Int, strokes: [[CGPoint]], drawnAt revision: UInt64? = nil, style: ToolStyle? = nil) async -> Bool {
        await enqueueInk(page: page, strokes: strokes, drawnAt: revision, style: style).value
    }

    /// `addInk`, handed over at once (registered with the undo manager before this returns), for
    /// whatever must come after it: the task says whether it was made.
    @discardableResult
    func enqueueInk(page: Int, strokes: [[CGPoint]], drawnAt revision: UInt64? = nil, style: ToolStyle? = nil) -> Task<Bool, Never> {
        if let refusal = refusal(of: .ink, onPage: page) {
            failure = EditFailure(message: refusal)
            return Task { false }
        }
        guard let pageNumber = UInt32(exactly: page) else { return Task { false } }
        let style = style ?? toolStyles[.ink]
        let width = InkGeometry.lineWidth(style.width)
        let edits = InkGeometry.drawings(strokes.flatMap(InkGeometry.withinLimits)).map { drawing in
            Edit.addInk(page: pageNumber, strokes: drawing.map { $0.map { Point(x: Double($0.x), y: Double($0.y)) } },
                        color: style.color.rgbColor, width: width)
        }
        return enqueue(edits, named: Strings.actionAddAnnotation, touching: [page], workedOutAt: revision)
    }

    // MARK: Signing

    /// Whether the pad the signature is drawn in is up: Sign picked or tapped with none saved opens it,
    /// so does Change Signature; Save (once the signature is kept) and Cancel put it away.
    var showsSignaturePad = false

    /// The saved signature as it would be placed on `page`, centred on `point` (view space), at its
    /// default width for the page as shown (`SignatureStore.defaultWidth`, `place`); nil with none saved,
    /// or for a page the document does not have.
    func signatureStrokes(onPage page: Int, centeredAt point: CGPoint) -> [[CGPoint]]? {
        guard let saved = signatures.saved, pages.indices.contains(page) else { return nil }
        let size = CGSize(width: pages[page].widthPt, height: pages[page].heightPt)
        let strokes = SignatureStore.place(saved, centeredAt: point, width: SignatureStore.defaultWidth(pageSize: size), pageSize: size)
        return strokes.isEmpty ? nil : strokes
    }

    /// Places the saved signature on `page`, centred on `point` (view space; see `enqueueSignature`),
    /// and says whether it was placed. Nothing happens with none saved.
    @discardableResult
    func addSignature(page: Int, at point: CGPoint) async -> Bool {
        guard let strokes = signatureStrokes(onPage: page, centeredAt: point) else { return false }
        return await enqueueSignature(page: page, strokes: strokes).value
    }

    /// Adds `strokes` (view space: PDF points of `page`) as a signature, black and
    /// `SignatureStore.lineWidth` wide: one change named `Strings.actionSign`, which one undo takes back,
    /// handed over at once. In the file it is ink, which Select moves and the eraser deletes like any
    /// drawing. `revision` as for `enqueueShape`: one worked out before a turn of its page is refused as
    /// stale. Where markup is refused, so is this, with the reason. The strokes are what
    /// `signatureStrokes` gives: within what the bridge takes for one drawing.
    @discardableResult
    func enqueueSignature(page: Int, strokes: [[CGPoint]], workedOutAt revision: UInt64? = nil) -> Task<Bool, Never> {
        if let refusal = refusal(of: .signature, onPage: page) { return refuse(refusal) }
        guard let pageNumber = UInt32(exactly: page), !strokes.isEmpty else { return Task { false } }
        let edit = Edit.addSignature(page: pageNumber, strokes: strokes.map { $0.map { Point(x: Double($0.x), y: Double($0.y)) } },
                                     color: SignatureStore.color.rgbColor, width: SignatureStore.lineWidth)
        return enqueue([edit], named: Strings.actionSign, touching: [page], workedOutAt: revision)
    }

    /// The pad's Save: keeps `signature` in place of any saved, and puts the pad away. When it cannot be
    /// written, `failure` says so and the pad stays up, with what was drawn. Says whether it was kept.
    @discardableResult
    func saveSignature(_ signature: SavedSignature) -> Bool {
        do {
            try signatures.save(signature)
        } catch {
            failure = EditFailure(message: Strings.signatureNotSaved)
            return false
        }
        showsSignaturePad = false
        return true
    }

    /// Delete Signature, once confirmed: forgets the saved signature (those placed stay on their
    /// pages). When its file cannot be removed, `failure` says so.
    func deleteSignature() {
        do {
            try signatures.delete()
        } catch {
            failure = EditFailure(message: Strings.signatureNotDeleted)
        }
    }

    // MARK: Text boxes, notes and shapes

    /// Whether text typed in a box on the page (Text Box) is waiting to be added as a text box: added
    /// with the strokes waiting (`commitPendingInk`). Only spaces and new lines are not waiting.
    private(set) var hasPendingText = false

    /// The text being typed in a text box came or went.
    func pendingTextDidChange(_ pending: Bool) {
        if hasPendingText != pending { hasPendingText = pending }
    }

    /// Whether strokes or text are waiting to be added (`hasPendingInk`, `hasPendingText`): the palette
    /// shows Done meanwhile, Undo adds them and takes them back, and Redo waits (adding them would
    /// leave nothing to redo).
    var hasPendingMarkup: Bool { hasPendingInk || hasPendingText }

    /// The note the note sheet is open for: one to add, where a tap with Note put it, or one on the page
    /// to read and change. Nil while the sheet is not up. Its text is the reader's, and never logged.
    var noteDraft: NoteDraft?

    /// Whether a text box may be put on `page`: the document allows markup (once its permissions are
    /// read) and the page is shown upright, as the file has it. The engine sets a text box's text
    /// upright in the file, so on a turned page it would read sideways.
    func canAddTextBox(onPage page: Int) -> Bool {
        guard let capabilities, capabilities.canAnnotate, pages.indices.contains(page) else { return false }
        return pages[page].rotationDegrees % 360 == 0
    }

    /// Adds `draft`, a rectangle, an oval, a line or an arrow in view space, in its tool's style (see
    /// `enqueueShape`), and says whether it was added.
    @discardableResult
    func addShape(page: Int, draft: DraftShape) async -> Bool {
        await enqueueShape(page: page, draft: draft).value
    }

    /// `addShape`, handed over at once (registered with the undo manager before this returns): one
    /// change named `Strings.actionAddAnnotation`. A rectangle or an oval is outlined in its tool's
    /// colour and width (held to what the bridge takes, as Draw's is) and, when its style says so,
    /// filled with that colour mixed toward white (`ShapeGeometry.fill`); a line has an arrow head at
    /// its end for Arrow. `style` is the tool's own when nil. Like every placement in view space it is
    /// worked out against a revision: `revision`, the one it was dragged out on (the model's now when
    /// nil), so that a shape dragged out before a turn of its page is refused as stale. A tool that may
    /// not be used is refused at once, with its reason; a box or a line the bridge would not take (a
    /// side under a point, a point out of its reach) is refused before it is asked, as it would be.
    @discardableResult
    func enqueueShape(page: Int, draft: DraftShape, workedOutAt revision: UInt64? = nil, style: ToolStyle? = nil) -> Task<Bool, Never> {
        let tool = draft.tool
        if let refusal = refusal(of: tool, onPage: page) { return refuse(refusal) }
        guard let pageNumber = UInt32(exactly: page) else { return Task { false } }
        let style = style ?? toolStyles[tool]
        let width = InkGeometry.lineWidth(style.width)
        let edit: Edit
        switch draft {
        case .rect(let box, let oval):
            guard ShapeGeometry.isDrawable(box) else {
                return refuseInvalid("a shape is a box at least \(ShapeGeometry.bridgeMinimumSide) point each way, within reach")
            }
            let fill = style.fill ? ShapeGeometry.fill(for: style.color).rgbColor : nil
            edit = .addShape(page: pageNumber, kind: oval ? .oval : .rectangle,
                             rect: Rect(x: box.minX, y: box.minY, width: box.width, height: box.height),
                             color: style.color.rgbColor, fill: fill, width: width)
        case .line(let from, let to, let arrow):
            guard ShapeGeometry.isDrawableLine(from: from, to: to) else {
                return refuseInvalid("a line joins two points at least \(ShapeGeometry.bridgeMinimumSide) point apart, within reach")
            }
            edit = .addLine(page: pageNumber, from: Point(x: from.x, y: from.y), to: Point(x: to.x, y: to.y), arrow: arrow,
                            color: style.color.rgbColor, width: width)
        }
        return enqueue([edit], named: Strings.actionAddAnnotation, touching: [page], workedOutAt: revision)
    }

    /// Adds a text box showing `text` with its top-left at `point` (view space), in Text Box's style
    /// (see `enqueueTextBox`), and says whether it was added.
    @discardableResult
    func addTextBox(page: Int, at point: CGPoint, text: String) async -> Bool {
        await enqueueTextBox(page: page, at: point, text: text).value
    }

    /// `addTextBox`, handed over at once: one change named `Strings.actionAddAnnotation`, of a box
    /// `ShapeGeometry.textBoxRect` gives, showing `text` without the spaces and new lines after its
    /// last character, in Text Box's colour and size (held to what the bridge takes). `style` is Text
    /// Box's own when nil; `revision` as for `enqueueShape`. Nothing typed is no text box, and no
    /// change. On a turned page it is refused (`Strings.textBoxNeedsUprightPage`), even before the
    /// permissions are read: its text would read sideways.
    @discardableResult
    func enqueueTextBox(page: Int, at point: CGPoint, text: String, workedOutAt revision: UInt64? = nil, style: ToolStyle? = nil) -> Task<Bool, Never> {
        let text = ShapeGeometry.committedText(text)
        guard !text.isEmpty else { return Task { false } }
        if let refusal = refusal(of: .textBox, onPage: page) { return refuse(refusal) }
        // Before the permissions are read, `refusal` says nothing: a turned page is still no place for one.
        if pages.indices.contains(page), pages[page].rotationDegrees % 360 != 0 { return refuse(Strings.textBoxNeedsUprightPage) }
        guard pages.indices.contains(page), let pageNumber = UInt32(exactly: page) else { return Task { false } }
        let style = style ?? toolStyles[.textBox]
        let fontSize = ShapeGeometry.fontSize(style.fontSize)
        let box = ShapeGeometry.textBoxRect(at: point, text: text, fontSize: fontSize,
                                            pageSize: CGSize(width: pages[page].widthPt, height: pages[page].heightPt))
        guard ShapeGeometry.isDrawable(box) else {
            return refuseInvalid("a text box is a box at least \(ShapeGeometry.bridgeMinimumSide) point each way, within reach")
        }
        let edit = Edit.addTextBox(page: pageNumber, rect: Rect(x: box.minX, y: box.minY, width: box.width, height: box.height),
                                   text: text, fontSize: fontSize, color: style.color.rgbColor)
        return enqueue([edit], named: Strings.actionAddAnnotation, touching: [page], workedOutAt: revision)
    }

    /// Adds a note whose icon's top-left is at `point` (view space), with `contents`, in Note's colour
    /// (see `enqueueNote`), and says whether it was added.
    @discardableResult
    func addNote(page: Int, at point: CGPoint, contents: String) async -> Bool {
        await enqueueNote(page: page, at: point, contents: contents).value
    }

    /// `addNote`, handed over at once: one change named `Strings.actionAddAnnotation`; `revision` as
    /// for `enqueueShape`. A point out of the bridge's reach is refused before it is asked.
    @discardableResult
    func enqueueNote(page: Int, at point: CGPoint, contents: String, workedOutAt revision: UInt64? = nil) -> Task<Bool, Never> {
        if let refusal = refusal(of: .note, onPage: page) { return refuse(refusal) }
        guard let pageNumber = UInt32(exactly: page) else { return Task { false } }
        guard ShapeGeometry.isInReach(point) else { return refuseInvalid("a note goes at a point within reach") }
        let edit = Edit.addNote(page: pageNumber, at: Point(x: point.x, y: point.y), contents: contents,
                                color: toolStyles[.note].color.rgbColor)
        return enqueue([edit], named: Strings.actionAddAnnotation, touching: [page], workedOutAt: revision)
    }

    /// What the note sheet's Save does with `text`: a new note (`draft.existing` nil) is added where
    /// `draft` puts it, unless nothing but spaces was written; a note on the page gets `text`, unless it
    /// is the text it had (one change named `Strings.actionEditAnnotation`). Either is worked out
    /// against the revision the sheet was opened on: a note another change has numbered again since is
    /// refused as stale rather than changing another one. Says whether a change was made.
    @discardableResult
    func saveNote(_ draft: NoteDraft, text: String) async -> Bool {
        guard let existing = draft.existing else {
            guard !ShapeGeometry.committedText(text).isEmpty else { return false }
            return await enqueueNote(page: draft.page, at: draft.point, contents: text, workedOutAt: draft.revision).value
        }
        guard text != draft.text else { return false }
        return await enqueueContents(of: existing, to: text, workedOutAt: draft.revision).value
    }

    /// The note sheet's Save: saves the note the sheet is open for (`noteDraft`) with `text`
    /// (`saveNote`). The sheet goes (`noteDraft` nil) once the note is saved. A save that is refused
    /// (stale, say, or a note the file forbids changing) leaves the sheet up, with what was written in
    /// it, and `failure` says why: the reader's words are not lost with the change. Says whether it saved.
    @discardableResult
    func saveNoteDraft(text: String) async -> Bool {
        guard let draft = noteDraft else { return false }
        let saved = await saveNote(draft, text: text)
        if saved, noteDraft?.id == draft.id { noteDraft = nil }
        return saved
    }

    /// Tells the reader why a change is not made (`message`, one of our sentences), and makes none.
    func refuse(_ message: String) -> Task<Bool, Never> {
        failure = EditFailure(message: message)
        return Task { false }
    }

    /// Tells the reader a change is not made, as the engine's refusal of it would (`EditError.Invalid`,
    /// whose `why` goes to the private log: it never has the reader's text in it), and makes none.
    func refuseInvalid(_ why: String) -> Task<Bool, Never> {
        failure = EditFailure(EditError.Invalid(message: why))
        return Task { false }
    }

    /// The scene's undo manager, which the screen hands over (`@Environment(\.undoManager)`). With
    /// none, changes are still made, and cannot be undone.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// Whether a change, undo or redo is waiting or running.
    var isApplying: Bool { queue.isBusy }

    /// Where every change, undo, redo and reading of the document's state runs, one at a time.
    private let queue = EditQueue()
    /// The revision made by the last change that can make a page or annotation index name something
    /// else: a page deleted, moved or inserted, an annotation deleted or moved, any undo or redo.
    /// An edit worked out before it is refused (see `enqueue`).
    @ObservationIgnored private var lastIndexShift: UInt64 = 0
    /// The later of `lastIndexShift` and the revision made by the last rotation: after it, a point
    /// in view space worked out before it is somewhere else on the page.
    @ObservationIgnored private var lastGeometryShift: UInt64 = 0

    /// Whether a page or annotation index worked out at `revision` still names what it named then: no
    /// change made since has numbered them again (`lastIndexShift`).
    func stillNamesTheSame(workedOutAt revision: UInt64) -> Bool {
        revision >= lastIndexShift
    }

    /// Every change whose entries the undo manager may still hold (they are the entries' targets),
    /// so they can all be taken off it when the two histories no longer match. Weak: a change goes
    /// when the undo manager lets go of its entries.
    @ObservationIgnored private let liveChanges = NSHashTable<EditToken>.weakObjects()

    /// Opens `bytes` with no password. Blocks for as long as the engine takes, so the document
    /// scene does not use it: that opens the file off the main actor and calls `init(outcome:)`.
    convenience init(bytes: Data) {
        self.init(outcome: OpenOutcome(bytes: bytes))
    }

    /// The engine document of the file, for saving: the model puts the document there when it is
    /// open, here and on `unlock`.
    let engine: EngineHandle

    /// `engine` is the file's handle; a model with no file of its own (a test's) gets a handle of its own.
    /// `toolStyles` defaults to the styles kept in the standard user defaults, and `signatures` to the
    /// app's store (`SignatureStore.shared`).
    init(outcome: OpenOutcome, engine: EngineHandle = EngineHandle(), toolStyles: ToolStyleStore? = nil, signatures: SignatureStore? = nil) {
        self.engine = engine
        self.toolStyles = toolStyles ?? ToolStyleStore()
        self.signatures = signatures ?? .shared
        (state, pages) = Self.resolve(outcome)
        search = document().map(SearchController.init(document:))
        selection = document().map(SelectionController.init(document:))
        if let document = document() { engine.adopt(document) }
        loadState()
    }

    /// Tries `password` on a locked document, and says whether the document is open afterwards. A
    /// refused password leaves it locked with `wrongPassword` set, so the next try can show that.
    ///
    /// The engine's open can take hundreds of milliseconds on a big file, so it runs off the main
    /// actor (`open` is what runs there; it is a parameter so that a test can see where) and only its
    /// outcome comes back to be applied here. If another unlock opened the document while this one
    /// was away, that document stays as it is.
    @discardableResult
    func unlock(password: String, opening open: @escaping @Sendable (Data, String) -> OpenOutcome = { OpenOutcome(bytes: $0, password: $1) }) async -> Bool {
        guard case .locked(let bytes, _) = state else { return document() != nil }
        let outcome = await Task.detached(priority: .userInitiated) { open(bytes, password) }.value
        guard case .locked = state else { return document() != nil }
        install(outcome)
        return document() != nil
    }

    /// Takes what opening the file came to: the state, the pages, and a search and a selection for an
    /// open document.
    private func install(_ outcome: OpenOutcome) {
        (state, pages) = Self.resolve(outcome)
        search = document().map(SearchController.init(document:))
        selection = document().map(SelectionController.init(document:))
        if let document = document() { engine.adopt(document) }
        loadState()
    }

    /// The open document, to draw and search; nil unless it is open.
    func document() -> PdfDocument? {
        if case .open(let document) = state { return document }
        return nil
    }

    private static func resolve(_ outcome: OpenOutcome) -> (State, [PageInfo]) {
        switch outcome {
        case .open(let document, let pages):
            return (.open(document), pages)
        case .locked(let bytes, let wrongPassword):
            return (.locked(bytes, wrongPassword: wrongPassword), [])
        case .failed(let detail):
            return (.failed(detail: detail), [])
        }
    }

    // MARK: Changing the document

    /// Hands `edits` to the engine, after every change already handed over, as one change named
    /// `actionName` that touches `pages` (nil: it may move any page). One edit is applied as it is;
    /// several are applied together, all or nothing, as one step of the engine's history.
    ///
    /// The undo manager's entry is registered here, at once, before the engine is asked, so the
    /// undo manager and the engine's history stay in the same order however fast the reader taps
    /// (see `registerStep`).
    ///
    /// The edit was worked out against the revision the model has now, the one the reader was
    /// looking at. Changes handed over before it may have run by the time it does. If none of them
    /// can have made its indexes or points mean something else (see `canRebase`), it is applied to
    /// the document as it then is, so edits tapped quickly one after the other all happen;
    /// otherwise it is checked against the revision it was worked out for, and the engine refuses
    /// it (`Stale`) instead of changing the wrong page or annotation. The task says whether the
    /// change was made; when it was not, `failure` says why, and the change leaves nothing on the
    /// undo manager. `base` is the revision it was worked out against, when that is not the model's
    /// now: strokes drawn with Draw are worked out against the one they were drawn on.
    ///
    /// Strokes drawn with Draw and not added yet are added first (`commitPendingInk`): they were drawn
    /// on the document as it is, before this change.
    ///
    /// `atItsTurn`, when given, is asked when the change's turn comes, on the main actor, just before
    /// the engine is: what the model publishes then is the document as the engine has it, since every
    /// change, undo and redo before this one has published what it did before the next one runs. It
    /// says whether the document is already as the edits would make it (a field filled with the value it
    /// has: nothing is done, the entry is taken off the undo manager again, and the task says no change
    /// was made, with no failure), or which pages the change touches as the document is then, in place
    /// of `pages`: what the change, its undo and its redo redraw. (A field's widgets may be on other
    /// pages than when the fill was handed over: pages inserted, deleted or moved before it.)
    @discardableResult
    func enqueue(_ edits: [Edit], named actionName: String, touching pages: Set<Int>?, workedOutAt base: UInt64? = nil,
                 atItsTurn: (@MainActor (DocumentModel) -> ChangeAtItsTurn)? = nil) -> Task<Bool, Never> {
        guard !edits.isEmpty else { return Task { false } }
        commitPendingInk()
        let token = EditToken(pages: pages)
        registerStep(.undo, token: token, named: actionName)
        liveChanges.add(token)
        let base = base ?? revision
        let engine = engine
        engine.editWillStart()
        return queue.submit { [weak self] in
            defer { engine.editDidFinish() }
            return await self?.apply(edits, label: actionName, base: base, token: token, atItsTurn: atItsTurn) ?? false
        }
    }

    /// Makes `edit` (see `enqueue`) and says whether it was made.
    @discardableResult
    func perform(_ edit: Edit, named actionName: String, touching pages: Set<Int>?) async -> Bool {
        await enqueue([edit], named: actionName, touching: pages).value
    }

    /// Makes `edits` as one change (see `enqueue`) and says whether it was made.
    @discardableResult
    func performAll(_ edits: [Edit], named actionName: String, touching pages: Set<Int>?) async -> Bool {
        await enqueue(edits, named: actionName, touching: pages).value
    }

    /// Takes back the last change: the toolbar's Undo. Through the undo manager, so its stack and
    /// the engine's history move together. Strokes drawn with Draw and waiting are added first, so
    /// Undo then takes back the whole drawing.
    func undo() {
        commitPendingInk()
        undoManager?.undo()
    }

    /// Makes again the change last taken back: the toolbar's Redo. Strokes drawn with Draw and waiting
    /// are added first (they are the latest change, and the screen does not offer Redo meanwhile).
    func redo() {
        commitPendingInk()
        undoManager?.redo()
    }

    /// Returns once every change, undo and redo handed over so far has run and been published. For
    /// tests.
    func settle() async {
        await queue.settle()
    }

    /// Which way an undo manager entry moves the engine's history.
    private enum Step: Sendable {
        case undo, redo

        var opposite: Step { self == .undo ? .redo : .undo }
    }

    /// Registers the undo manager entry that moves the change of `token` one `step`. Running the
    /// entry registers the opposite one at once (so an undo can be redone, and that redo undone),
    /// then hands the engine's undo or redo to the queue, behind everything handed over before it:
    /// an undo tapped while its edit is still waiting or running undoes that edit once it is made.
    /// Whether the change is in the engine's history is only known then, so the queued step looks
    /// at `token.applied` when it runs, and does nothing for a change the engine refused. The pages it
    /// redraws are the change's as it was made (`token.pages`), read when it runs too.
    private func registerStep(_ step: Step, token: EditToken, named actionName: String) {
        guard let undoManager else { return }
        // The change is the target, so a refused one's entry can be taken off again on its own; the
        // handler holds it (the undo manager does not keep its targets).
        undoManager.registerUndo(withTarget: token) { [weak self, token] _ in
            guard let self else { return }
            self.registerStep(step.opposite, token: token, named: actionName)
            let engine = self.engine
            engine.editWillStart()
            self.queue.submit { [weak self] in
                defer { engine.editDidFinish() }
                await self?.move(step, token: token)
            }
        }
        undoManager.setActionName(actionName)
    }

    /// A queued edit: asks the engine for it off the main actor and, once made, publishes the
    /// document's new state. `atItsTurn` as for `enqueue`.
    private func apply(_ edits: [Edit], label: String, base: UInt64, token: EditToken,
                       atItsTurn: (@MainActor (DocumentModel) -> ChangeAtItsTurn)?) async -> Bool {
        guard let document = document() else {
            undoManager?.removeAllActions(withTarget: token)
            return false
        }
        if let atItsTurn {
            switch atItsTurn(self) {
            case .alreadyMade:
                // Already as the edits would make it: no change, and nothing to undo.
                undoManager?.removeAllActions(withTarget: token)
                return false
            case .touching(let pages):
                token.pages = pages
            }
        }
        let base = Self.canRebase(edits, workedOutAt: base, indexShift: lastIndexShift, geometryShift: lastGeometryShift)
            ? revision : base
        let result = await EditQueue.offMain { () throws -> EngineState in
            if edits.count == 1, let edit = edits.first {
                _ = try document.apply(edit: edit, baseRevision: base)
            } else {
                _ = try document.applyAll(label: label, edits: edits, baseRevision: base)
            }
            return EngineState.read(document)
        }
        switch result {
        case .success(let state):
            token.applied = true
            // The reader stays on the page they were reading when pages before it go, move or arrive.
            // (An undo or redo does not say where pages went: there, the index is only kept in range.)
            currentPage = OrganizeMath.readerPage(currentPage, after: edits, pagesAdded: state.pages.count - self.pages.count)
            refresh(state, touching: token.pages, shift: Self.shift(of: edits))
            return true
        case .failure(let error):
            failure = EditFailure(error)
            undoManager?.removeAllActions(withTarget: token)
            await refreshIfMoved(document)
            return false
        }
    }

    /// A queued undo or redo of the change of `token`: nothing for a change the engine refused.
    /// One the engine cannot make means its history and the undo manager's stack no longer match,
    /// so the stack is emptied, and the reader told. It redraws the pages the change touched as it was
    /// made: every change after it has been undone by then, so they are where they were.
    private func move(_ step: Step, token: EditToken) async {
        guard token.applied, let document = document() else { return }
        let result = await EditQueue.offMain { () throws -> EngineState in
            switch step {
            case .undo: _ = try document.undo()
            case .redo: _ = try document.redo()
            }
            return EngineState.read(document)
        }
        switch result {
        case .success(let state):
            refresh(state, touching: token.pages, shift: .index)
        case .failure(let error):
            failure = EditFailure(error)
            for change in liveChanges.allObjects { undoManager?.removeAllActions(withTarget: change) }
            await refreshIfMoved(document)
        }
    }

    /// After a refused change: an undo, a redo or a change that failed half way can still have moved
    /// the revision on, and then the document is read again.
    private func refreshIfMoved(_ document: PdfDocument) async {
        guard case .success(let state) = await EditQueue.offMain({ EngineState.read(document) }),
              state.revision != revision else { return }
        refresh(state, touching: nil, shift: .index)
    }

    /// What a change can do to the indexes and points of edits worked out before it.
    private enum Shift {
        /// Nothing: indexes and points still name the same things.
        case none
        /// Pages turned: points in view space have moved, indexes have not.
        case geometry
        /// Page or annotation indexes may name something else.
        case index
    }

    /// What `edits` do to edits worked out before them. Adding an annotation appends it to its
    /// page's list (`pdfcraft_annot::add_annotation` pushes onto `/Annots`), so the indexes before
    /// it keep naming the same annotations.
    private static func shift(of edits: [Edit]) -> Shift {
        var shift = Shift.none
        for edit in edits {
            switch edit {
            case .deletePages, .movePages, .insertBlankPage, .insertPagesFrom, .deleteAnnotation, .deleteAnnotations,
                 .moveAnnotation:
                return .index
            case .rotatePages:
                shift = .geometry
            case .setInfo, .addTextMarkup, .addNote, .setAnnotationContents, .addInk, .addSignature, .addTextBox,
                 .addShape, .addLine, .setFieldValue:
                break
            }
        }
        return shift
    }

    /// Whether `edits` has a point or a box in view space, which a rotation of its page moves.
    private static func hasViewSpaceGeometry(_ edits: [Edit]) -> Bool {
        edits.contains { edit in
            switch edit {
            case .rotatePages, .deletePages, .movePages, .insertBlankPage, .insertPagesFrom, .setInfo,
                 .deleteAnnotation, .deleteAnnotations, .setAnnotationContents, .setFieldValue:
                false
            case .addTextMarkup, .addNote, .addInk, .addSignature, .addTextBox, .addShape, .addLine, .moveAnnotation:
                true
            }
        }
    }

    /// Whether `edits`, worked out at revision `base`, still mean the same on the document as it is
    /// now: no change since `base` has shifted an index, and none has turned a page, or the edits
    /// have no point in view space for a turn to move. Fills of form fields always do: a field is
    /// addressed by its name, which no change to the pages or the annotations alters.
    private static func canRebase(_ edits: [Edit], workedOutAt base: UInt64, indexShift: UInt64, geometryShift: UInt64) -> Bool {
        if edits.allSatisfy(isAddressedByName) { return true }
        return base >= indexShift && (base >= geometryShift || !hasViewSpaceGeometry(edits))
    }

    /// Whether `edit` addresses what it changes by a name, not by a page or an index: a form field's fill.
    private static func isAddressedByName(_ edit: Edit) -> Bool {
        if case .setFieldValue = edit { true } else { false }
    }

    /// Publishes the document as it is after a change, undo or redo: its pages, with the current
    /// page kept on one of them (`apply` has moved it with its page first); nothing selected (an index into the old pages or annotations may
    /// name something else now); its annotations, fields and capabilities; the search run again;
    /// and what changed.
    private func refresh(_ state: EngineState, touching pagesTouched: Set<Int>?, shift: Shift) {
        switch shift {
        case .none: break
        case .geometry: lastGeometryShift = max(lastGeometryShift, state.revision)
        case .index:
            lastIndexShift = max(lastIndexShift, state.revision)
            lastGeometryShift = max(lastGeometryShift, state.revision)
        }
        let geometryChanged = state.pages.count != pages.count
            || zip(state.pages, pages).contains { new, old in
                new.widthPt != old.widthPt || new.heightPt != old.heightPt || new.rotationDegrees != old.rotationDegrees
            }
        pages = state.pages
        currentPage = min(max(currentPage, 0), max(pages.count - 1, 0))
        selection?.clear()
        selectedAnnotation = nil
        adopt(state)
        search?.documentDidChange()
        lastChange = PageChange(revision: state.revision, pages: pagesTouched, geometryChanged: geometryChanged)
    }

    /// Takes the revision, annotations, fields and capabilities of `state`.
    private func adopt(_ state: EngineState) {
        revision = state.revision
        annotationIndex = AnnotationIndex(state.annotations)
        formIndex = state.formIndex
        formFieldsTruncated = state.formFieldsTruncated
        capabilities = state.capabilities
        // A document that no longer allows annotations (or never did) leaves a tool that makes them.
        if let tool, tool.annotates, !state.capabilities.canAnnotate { self.tool = .select }
    }

    /// Reads the state of a document that has just opened, off the main actor, through the queue,
    /// so a change handed over meanwhile comes after it.
    private func loadState() {
        guard let document = document() else { return }
        queue.submit { [weak self] in
            guard case .success(let state) = await EditQueue.offMain({ EngineState.read(document) }) else { return }
            self?.adopt(state)
        }
    }
}

/// What holds strokes drawn with Draw, and text typed in a text box, that are not added to the
/// document yet: the page view's markup (`MarkupInteraction`).
@MainActor
protocol PendingInkHolder: AnyObject {
    /// Adds the strokes waiting, if any, as one change, handed over before this returns; the task says
    /// whether it was made. Nil with none waiting.
    @discardableResult
    func commitPendingInk() -> Task<Bool, Never>?

    /// Ends the text box being typed in, if any, adding its text as a text box (handed over before this
    /// returns); the task says whether it was made. Nil with none being typed in.
    @discardableResult
    func commitPendingText() -> Task<Bool, Never>?
}

/// What a change handed over with `DocumentModel.enqueue(..., atItsTurn:)` finds when its turn comes.
enum ChangeAtItsTurn {
    /// The document is already as the change would make it: nothing is done.
    case alreadyMade
    /// The change is made, and touches these pages (nil: any page may have moved).
    case touching(Set<Int>?)
}

/// What holds the text being typed in a form field, not filled in yet: the scroll view's forms
/// (`FormInteraction`).
@MainActor
protocol PendingFieldHolder: AnyObject {
    /// Whether a field's editor is up.
    var isEditingField: Bool { get }

    /// Ends the field's editor, if one is up, filling the field with what was typed when it differs
    /// from the field's text (handed over before this returns); the task says whether it changed. Nil
    /// with no editor up, or nothing changed.
    @discardableResult
    func commitPendingField() -> Task<Bool, Never>?
}

/// A note the note sheet is open for (`DocumentModel.noteDraft`): on `page`, its icon's top-left at
/// `point` (view space); a note on the page (`existing`) or one to add (nil); its text when the sheet
/// opened; and the revision of the document it was worked out on, which its save is checked against.
struct NoteDraft: Identifiable, Equatable {
    let id = UUID()
    let page: Int
    let point: CGPoint
    let existing: AnnotationRef?
    let text: String
    let revision: UInt64
}

/// What one change, undo or redo did, for the views that redraw pages: its revision, the pages it
/// touched (nil when any page may have moved), and whether the number of pages, or a page's size or
/// rotation, changed.
struct PageChange: Equatable {
    let revision: UInt64
    let pages: Set<Int>?
    let geometryChanged: Bool
}

/// One annotation of the document: its page, counting from 0, and its index among that page's.
struct AnnotationRef: Hashable {
    let page: Int
    let index: UInt32
}

/// Everything the model shows that the engine has to be asked for, read in one go off the main
/// actor after each change.
private struct EngineState: Sendable {
    let revision: UInt64
    let pages: [PageInfo]
    let annotations: [AnnotationInfo]
    /// The form's fields, each page's widgets looked up once here, off the main actor.
    let formIndex: FormIndex
    let formFieldsTruncated: Bool
    let capabilities: EditCapabilities

    static func read(_ document: PdfDocument) -> EngineState {
        EngineState(revision: document.revision(),
                    pages: (0..<document.pageCount()).compactMap { document.pageInfo(page: $0) },
                    annotations: document.annotations(),
                    formIndex: FormIndex(document.formFields()),
                    formFieldsTruncated: document.formFieldsTruncated(),
                    capabilities: document.capabilities())
    }
}
