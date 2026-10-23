import EditinPDFCore
import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

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

    /// Why nothing in the document may be changed, when it is because a change would break its
    /// signatures: it is signed, and its file is damaged, so saving would rewrite it
    /// (`EditCapabilities.rewritesOnSave`), and the bridge allows no change. What the markup tools,
    /// Organize and the form say in place of their own refusals; nil otherwise, and while the
    /// capabilities are not read yet.
    var signatureLock: String? {
        guard let capabilities, capabilities.isSigned, capabilities.rewritesOnSave, !capabilities.canEdit else { return nil }
        return Strings.signedDocumentDamaged
    }

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
            if tool != .note, showsAddCommentHint { showsAddCommentHint = false }
        }
    }
    /// Each tool's colour and size, kept between documents and launches.
    let toolStyles: ToolStyleStore
    /// The reader's signature, which Sign places: the app's, shared by every document.
    let signatures: SignatureStore

    /// Picks `tool`, as the palette does. Sign picked with no signature saved opens the pad to draw
    /// one (`askForSignature`), where Sign may be used; with one saved, the next tap places it.
    /// Highlight, Underline or Strikethrough picked while text is selected also marks that text, or
    /// takes the mark off it when all of it has the mark (`markSelection`), as the selection's menu
    /// does: on a phone the menu shows Copy and Highlight and keeps Underline and Strikethrough behind
    /// its arrow, so the reader reaches for the palette. So does the tool picked again while it is the
    /// current one. The task says whether the change was made; nil when there was nothing selected.
    /// The selection goes with the change, at once: the same tool tapped twice, or another right after
    /// it, finds nothing left to mark, so a change on its way is never asked for twice.
    @discardableResult
    func pick(_ tool: Tool) -> Task<Bool, Never>? {
        self.tool = tool
        if tool == .signature, canUse(.signature) { askForSignature() }
        guard let kind = tool.markupKind, let controller = selection, let selected = controller.selection else { return nil }
        controller.clear()
        return toggle(selected, as: kind, in: controller)
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
        if tool.annotates, let signatureLock { return signatureLock }
        let rotation = pages.indices.contains(page) ? pages[page].rotationDegrees : 0
        return tool.refusal(canAnnotate: capabilities.canAnnotate, pageRotation: rotation)
    }

    /// What a change over selected text is asked to do (`markSelection`).
    enum MarkIntent: Sendable {
        /// Take the mark off when all of the selection has it, otherwise mark it: the palette, and the
        /// current tool picked again.
        case toggle
        /// Only ever mark (the glyphs without the mark), and take nothing off: a drag with a text tool,
        /// and the selection menu's Highlight, Underline and Strikethrough.
        case add
        /// Only ever take the mark off: the selection menu's Remove Highlight, Remove Underline and Remove
        /// Strikethrough.
        case remove
    }

    /// Marks the selected text with a highlight, an underline or a strikethrough (`kind`), in the colour
    /// of the tool that makes it (`Tool(markupKind:)`, whatever tool is picked: the selection's menu
    /// does it in reading mode too), over the selection's boxes, which are in view space like every
    /// edit's; or takes that mark off the selected glyphs (`MarkupToggle`), as one change named
    /// `Strings.removeMarkup(kind)`, as `intent` says:
    ///
    /// - `toggle`: takes the mark off when every selected glyph already has it, otherwise marks the
    ///   glyphs without it (marks already on some of the selection are not marked over again).
    /// - `add`: marks the glyphs without it, and nothing when all of them have it (no change, nothing
    ///   told). A reader dragging the highlighter over highlighted text means more highlight.
    /// - `remove`: takes the mark off when every selected glyph has it, and nothing otherwise.
    ///
    /// A change that might take a mark off is never made from less than its plan: when the page's text
    /// cannot be read, `toggle` and `remove` change nothing (only `add` marks the selection as it is),
    /// and a selection too large to work out (`MarkupToggle.Plan.tooMuch`) is marked as it is by `add`
    /// and `toggle` and refused by `remove`. Says whether the change was made.
    ///
    /// The selection goes at once, as when a tool is picked (`pick`): a menu item tapped twice finds
    /// nothing left. A refusal is told as every change's is (`failure`): the tool's own
    /// (`refusal(of:onPage:)`), `Strings.editNotAllowed` for text whose marks the file locks,
    /// `Strings.markHasReplies` for a mark with replies that would be cut short, or the engine's, such as a
    /// change queued behind a turn of its page or a delete of a mark on it, which is stale since it was
    /// worked out for the page as it was (`enqueue`). With nothing selected, nothing happens.
    ///
    /// One change of this kind waits for the one before it to be made: each works out what is marked from
    /// the document as the one before left it.
    @discardableResult
    func markSelection(_ kind: MarkupKind, intent: MarkIntent = .toggle) async -> Bool {
        guard let controller = selection, let selected = controller.selection else { return false }
        controller.clear()
        return await toggle(selected, as: kind, in: controller, intent: intent).value
    }

    /// The last change asked of `toggle`, which the next one waits for.
    @ObservationIgnored private var lastToggle: Task<Bool, Never>?

    /// Marks `selected`, or takes the mark off it, as `intent` says (see `markSelection`), once the change
    /// asked before it is made.
    private func toggle(_ selected: TextSelection, as kind: MarkupKind, in controller: SelectionController,
                        intent: MarkIntent = .toggle) -> Task<Bool, Never> {
        let before = lastToggle
        let selectedAt = revision
        let task = Task { [weak self] in
            _ = await before?.value
            guard let self else { return false }
            return await self.mark(selected, as: kind, in: controller, selectedAt: selectedAt, intent: intent)
        }
        lastToggle = task
        return task
    }

    /// Marks `selected`, text selected with `controller` at revision `selectedAt`, as `kind`, or takes
    /// the mark off it, as `intent` says (see `markSelection`).
    private func mark(_ selected: TextSelection, as kind: MarkupKind, in controller: SelectionController, selectedAt: UInt64,
                      intent: MarkIntent) async -> Bool {
        let page = Int(selected.page)
        let rects = SelectionController.rects(of: selected).map { Rect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }
        let tool = Tool(markupKind: kind)
        /// Refuses the change: the selection goes, unless the reader has made another meanwhile.
        func refuse(_ message: String?) -> Bool {
            if controller.selection == selected { controller.clear() }
            if let message { failure = EditFailure(message: message) }
            return false
        }
        if let refusal = refusal(of: tool, onPage: page) { return refuse(refusal) }
        guard !rects.isEmpty else { return refuse(nil) }
        // A change before this one (the one it waited for) moved or turned the page: the glyphs may be
        // others now.
        guard pageIsUnchanged(page, since: selectedAt) else { return refuse(Strings.documentChangedTryAgain) }
        let base = revision
        let color = toolStyles[tool].color.rgbColor
        let annotations = annotationIndex.annotations(onPage: page)
        var edits = [Edit.addTextMarkup(page: selected.page, kind: kind, rects: rects, color: color, contents: "")]
        var name = Strings.actionAddAnnotation
        // Whether the edits were worked out from the page's marks as they are now: if a change queued
        // before them deletes one, they are stale.
        var readTheMarks = false
        if !MarkupToggle.hasMarks(of: kind, in: annotations) {
            // Nothing of that kind on the page: nothing to take off.
            if intent == .remove { return refuse(nil) }
        } else {
            guard let document = document() else { return refuse(nil) }
            let range = Int(selected.start)..<Int(max(selected.start, selected.end))
            let worked = await EditQueue.offMain { () throws -> MarkupToggle.Step in
                let glyphs = try document.pageText(page: selected.page).glyphs
                return try MarkupToggle.Step(MarkupToggle.plan(kind, selection: range, glyphs: glyphs, annotations: annotations),
                                      page: selected.page, document: document)
            }
            readTheMarks = true
            switch (worked, intent) {
            case (.failure, .add):
                // The page's text could not be read again: a mark that only adds is made over the selection.
                break
            case (.failure, _):
                // It might have been a removal: nothing is added in its place.
                return refuse(nil)
            case (.success(.markSelection), .remove), (.success(.mark), .remove):
                // Not all of it has the mark: nothing to take off.
                return refuse(nil)
            case (.success(.markSelection), _):
                break
            case (.success(.mark(let boxes)), _):
                guard !boxes.isEmpty else { return refuse(nil) }
                edits = [.addTextMarkup(page: selected.page, kind: kind, rects: boxes, color: color, contents: "")]
            case (.success(.remove), .add), (.success(.locked), .add), (.success(.replies), .add):
                // All of it has the mark already: none is added over it.
                return refuse(nil)
            case (.success(.remove(let deleting, let pieces)), _):
                if let tooMany = pieces.lazy.compactMap({ Self.markupRefusal(boxes: $0.boxes.count) }).first { return refuse(tooMany) }
                edits = [.deleteAnnotations(page: selected.page, indices: deleting)] + pieces.map { piece in
                    .addTextMarkup(page: selected.page, kind: kind, rects: piece.boxes, color: piece.source.color ?? color,
                                   contents: piece.keepsContents ? ShapeGeometry.limitedText(piece.source.contents ?? "") : "",
                                   opacityOf: piece.source.index)
                }
                name = Strings.removeMarkup(kind)
            case (.success(.locked), _):
                return refuse(Strings.editNotAllowed)
            case (.success(.replies), _):
                return refuse(Strings.markHasReplies)
            case (.success(.tooMuch), .remove):
                return refuse(Strings.selectLessText)
            case (.success(.tooMuch), _):
                // Too much to tell what is marked: the selection is marked as it is, as before.
                break
            }
        }
        for edit in edits {
            if case .addTextMarkup(_, _, let boxes, _, _, _) = edit, let tooMany = Self.markupRefusal(boxes: boxes.count) {
                return refuse(tooMany)
            }
        }
        var atItsTurn: (@MainActor (DocumentModel) -> ChangeAtItsTurn)?
        if readTheMarks {
            atItsTurn = { model -> ChangeAtItsTurn in
                model.stillNamesTheSame(workedOutAt: base) ? ChangeAtItsTurn.touching([page]) : ChangeAtItsTurn.stale
            }
        }
        let made = await enqueue(edits, named: name, touching: [page], workedOutAt: base, atItsTurn: atItsTurn).value
        // A selection the reader made while the change was on its way is theirs: it stays.
        if !made, controller.selection == selected { controller.clear() }
        return made
    }

    /// The kinds of mark the selection's menu offers to take off `selected` (`MarkupToggle.covers`), when
    /// that is known without reading the page's text: none when its page has no highlight, underline or
    /// strikethrough. Nil when the text has to be read (`markedKinds`).
    func knownMarkedKinds(of selected: TextSelection) -> Set<MarkupKind>? {
        let annotations = annotationIndex.annotations(onPage: Int(selected.page))
        let any = [MarkupKind.highlight, .underline, .strikeOut].contains { MarkupToggle.hasMarks(of: $0, in: annotations) }
        return any ? nil : []
    }

    /// The kinds of mark every glyph of `selected` that counts already has (`MarkupToggle.covers`): those
    /// the selection's menu offers to take off. Reads the page's text off the main actor; none when it
    /// cannot be read, or the document changed meanwhile.
    func markedKinds(of selected: TextSelection) async -> Set<MarkupKind> {
        let annotations = annotationIndex.annotations(onPage: Int(selected.page))
        let kinds = [MarkupKind.highlight, .underline, .strikeOut].filter { MarkupToggle.hasMarks(of: $0, in: annotations) }
        guard !kinds.isEmpty, let document = document() else { return [] }
        let base = revision
        let range = Int(selected.start)..<Int(max(selected.start, selected.end))
        let worked = await EditQueue.offMain { () throws -> Set<MarkupKind> in
            let glyphs = try document.pageText(page: selected.page).glyphs
            return Set(kinds.filter { MarkupToggle.covers($0, selection: range, glyphs: glyphs, annotations: annotations) == true })
        }
        guard case .success(let marked) = worked, revision == base else { return [] }
        return marked
    }

    /// The most boxes one mark takes: the bridge's cap on a text markup's boxes (`MAX_MARKUP_RECTS` in
    /// `edit.rs`), one for each line of the selection on its page.
    static let maxMarkupBoxes = 10_000

    /// Why a mark over a selection of `boxes` boxes (lines) is not made: past the bridge's cap, it
    /// would be refused, so the reader is asked for less at once. Nil when it can be made.
    static func markupRefusal(boxes: Int) -> String? {
        boxes > maxMarkupBoxes ? Strings.selectLessText : nil
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
    /// with none waiting. Says whether a change was handed over.
    ///
    /// Strokes on a canvas a stroke is being drawn on wait for it to be over, and are added with it
    /// then (`InkInteraction.commitPendingInk`), unless `closing`: the paths after which the document or
    /// the screen may go before then (Back touched, the scene leaving the screen, the screen going, focus
    /// leaving the pages) add the strokes drawn at once, and the stroke being drawn may be cut. Losing
    /// strokes drawn would be worse.
    @discardableResult
    func commitPendingInk(closing: Bool = false) -> Bool {
        let before = changesHandedOver
        inkHolder?.commitPendingInk(closing: closing)
        inkHolder?.commitPendingText()
        fieldHolder?.commitPendingField()
        return changesHandedOver != before
    }

    /// Whether a stroke is being drawn with Draw (the finger or Pencil is down): what waits cannot be
    /// added until it is over, short of cutting it (`InkInteraction.commitPendingInk`).
    var isDrawingStroke: Bool { inkHolder?.isDrawingStroke ?? false }

    /// How many changes have been handed over (`enqueue`) since the model was made.
    @ObservationIgnored private(set) var changesHandedOver = 0

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
    ///
    /// Strokes refused as stale are not lost. When their page is still the page they were drawn on, as
    /// it was (`pageIsUnchanged`: no page before it or it moved, it not turned), `putBack` is asked to
    /// put them back where they were drawn, waiting to be added again (the canvas's
    /// `InkInteraction.putBack`), and when it cannot, they are handed over again, worked out for the
    /// page as it is now, which is the same. Otherwise the reader is told they were not added, and why
    /// (`Strings.drawingNotAdded`).
    @discardableResult
    func enqueueInk(page: Int, strokes: [[CGPoint]], drawnAt revision: UInt64? = nil, style: ToolStyle? = nil,
                    putBack: (@MainActor () -> Bool)? = nil) -> Task<Bool, Never> {
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
        let drawnAt = revision ?? self.revision
        return enqueue(edits, named: Strings.actionAddAnnotation, touching: [page], workedOutAt: drawnAt, whenStale: { [weak self] in
            guard let self else { return nil }
            guard self.pageIsUnchanged(page, since: drawnAt) else { return EditFailure(message: Strings.drawingNotAdded) }
            if putBack?() != true {
                self.enqueueInk(page: page, strokes: strokes, style: style)
            }
            return nil
        })
    }

    // MARK: Signing

    /// Whether the pad the signature is drawn in is up: Sign picked or tapped with none saved opens it,
    /// so does Change Signature; Save (once the signature is kept) and Cancel put it away.
    var showsSignaturePad = false

    /// Sign picked, or a page tapped with Sign, and no signature saved: the pad opens to draw one. Not
    /// while the device is locked: its file cannot be read then, so "none saved" may only mean "none
    /// read", and Sign stays picked without the pad (the next pick, unlocked, reads it). The file is
    /// read again first: it may have been unreadable when the store first read it.
    func askForSignature() {
        guard signatures.isProtectedDataAvailable() else { return }
        signatures.reload()
        if signatures.saved == nil { showsSignaturePad = true }
    }

    /// Change Signature, in Sign's menu: the pad opens to draw the signature again; Save keeps the new
    /// one in place of the old (`saveSignature`), and the next tap places it.
    func changeSignature() {
        showsSignaturePad = true
    }

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
    /// The name of the change that text makes (`InlineTextEditor.actionName`): a new text box is added;
    /// over one on the page, its text is changed, or it is deleted.
    private(set) var pendingTextName = Strings.actionAddAnnotation

    /// The text being typed in a text box came or went, or changed what it makes (`actionName`).
    func pendingTextDidChange(_ pending: Bool, named actionName: String = Strings.actionAddAnnotation) {
        if hasPendingText != pending { hasPendingText = pending }
        if pendingTextName != actionName { pendingTextName = actionName }
    }

    /// Whether strokes or text are waiting to be added (`hasPendingInk`, `hasPendingText`): the palette
    /// shows Done meanwhile, Undo adds them and takes them back, and Redo waits (adding them would
    /// leave nothing to redo).
    var hasPendingMarkup: Bool { hasPendingInk || hasPendingText }

    /// The text box the format sheet is open for (Select's Format), with the look it has; nil while the
    /// sheet is not up.
    var formatDraft: TextBoxFormatDraft?

    /// The dates the file writes for its comments, with their time zones, read for the list of
    /// comments (`readCommentDates`) at a revision.
    var commentDates: CommentDates?

    /// The note the note sheet is open for: one to add, where a tap with Note put it, or one on the page
    /// to read and change. Nil while the sheet is not up. Its text is the reader's, and never logged.
    var noteDraft: NoteDraft? {
        didSet {
            if noteDraft?.id != oldValue?.id { noteText = nil }
            if noteDraft != nil, showsAddCommentHint { showsAddCommentHint = false }
        }
    }

    /// Whether the page says where the comment Add Comment puts goes (`Strings.addCommentHint`): from
    /// Add Comment until the note is placed, or another tool picked.
    private(set) var showsAddCommentHint = false

    /// The list of comments' Add Comment: Note is picked, and the page says to tap where the comment
    /// goes. The next tap puts a note there and opens its sheet, as Note does.
    func startAddingComment() {
        tool = .note
        showsAddCommentHint = true
    }
    /// What is written in the note sheet, once it has been changed there (`noteTextDidChange`); nil
    /// until then, and while the sheet is not up. Kept here so that the scene leaving the screen can
    /// save it (`saveNoteDraftOnLeaving`). The reader's, and never logged.
    @ObservationIgnored private(set) var noteText: String?

    /// The note sheet's text changed to `text`.
    func noteTextDidChange(_ text: String) {
        if noteDraft != nil { noteText = text }
    }

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
    /// last character, in `format` (its size held to what the bridge takes): Text Box's own look
    /// (`TextBoxFormat(style:)`) when nil. `revision` as for `enqueueShape`. Nothing typed is no text box, and no
    /// change. On a turned page it is refused (`Strings.textBoxNeedsUprightPage`), even before the
    /// permissions are read: its text would read sideways.
    @discardableResult
    func enqueueTextBox(page: Int, at point: CGPoint, text: String, workedOutAt revision: UInt64? = nil,
                        format: TextBoxFormat? = nil) -> Task<Bool, Never> {
        let text = ShapeGeometry.committedText(text)
        guard !text.isEmpty else { return Task { false } }
        if let refusal = refusal(of: .textBox, onPage: page) { return refuse(refusal) }
        // Before the permissions are read, `refusal` says nothing: a turned page is still no place for one.
        if pages.indices.contains(page), pages[page].rotationDegrees % 360 != 0 { return refuse(Strings.textBoxNeedsUprightPage) }
        guard pages.indices.contains(page), let pageNumber = UInt32(exactly: page) else { return Task { false } }
        let format = format ?? TextBoxFormat(style: toolStyles[.textBox])
        let fontSize = format.fontSize
        let box = ShapeGeometry.textBoxRect(at: point, text: text, fontSize: fontSize,
                                            pageSize: CGSize(width: pages[page].widthPt, height: pages[page].heightPt))
        guard ShapeGeometry.isDrawable(box) else {
            return refuseInvalid("a text box is a box at least \(ShapeGeometry.bridgeMinimumSide) point each way, within reach")
        }
        let edit = Edit.addTextBox(page: pageNumber, rect: Rect(x: box.minX, y: box.minY, width: box.width, height: box.height),
                                   text: text, fontSize: fontSize, color: format.color.rgbColor,
                                   fill: format.background?.rgbColor, borderWidth: format.borderWidth)
        // Refused as stale, the text is not lost: on its page as it was, it is handed over again, for
        // the page as it is now (the same); otherwise it is kept on the pasteboard.
        let typedAt = revision ?? self.revision
        return enqueue([edit], named: Strings.actionAddAnnotation, touching: [page], workedOutAt: typedAt, whenStale: { [weak self] in
            guard let self else { return nil }
            guard self.pageIsUnchanged(page, since: typedAt) else { return self.keepTypedText(text) }
            self.enqueueTextBox(page: page, at: point, text: text, format: format)
            return nil
        })
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
        await enqueueSave(of: draft, text: text)?.value ?? false
    }

    /// `saveNote`, handed over at once (registered with the undo manager before this returns); nil
    /// when there is nothing to save.
    func enqueueSave(of draft: NoteDraft, text: String) -> Task<Bool, Never>? {
        guard let existing = draft.existing else {
            guard !ShapeGeometry.committedText(text).isEmpty else { return nil }
            return enqueueNote(page: draft.page, at: draft.point, contents: text, workedOutAt: draft.revision)
        }
        guard text != draft.text else { return nil }
        return enqueueContents(of: existing, to: text, workedOutAt: draft.revision,
                               named: draft.isComment ? Strings.actionEditComment : Strings.actionEditAnnotation)
    }

    /// The scene is going to the background with the note sheet up: what is written in it, when it was
    /// changed, is saved as Save would save it (`saveNote`), handed over before this returns, so the
    /// save the system makes as the scene goes has it. The app may not come back to the sheet. The
    /// sheet goes once the note is saved; a save refused leaves it up, with the text, as Save's does.
    func saveNoteDraftOnLeaving() {
        guard let draft = noteDraft, let text = noteText,
              let saving = enqueueSave(of: draft, text: ShapeGeometry.limitedText(text)) else { return }
        Task {
            if await saving.value, noteDraft?.id == draft.id { noteDraft = nil }
        }
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

    /// Where text the reader typed is kept when it cannot be added where it was typed: the general
    /// pasteboard, on this device only (`keepLocally`). A test puts its own in its place.
    @ObservationIgnored var keepOnPasteboard: @MainActor (String) -> Void = { DocumentModel.keepLocally($0, on: UIPasteboard.general) }

    /// Puts `text` on `pasteboard` as plain text that stays on this device: the reader's own typing,
    /// which they did not copy themselves, is not handed to their other devices (Universal Clipboard).
    /// It pastes as text in this app and in others here.
    static func keepLocally(_ text: String, on pasteboard: some ItemPasteboard) {
        pasteboard.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
    }

    /// Text the reader typed that could not be added where it was typed (its page, or the text box it
    /// was for, changed while it was on its way): it is put on the pasteboard, so it is not lost, and
    /// what is returned tells the reader so (`Strings.typedTextCopied`).
    func keepTypedText(_ text: String) -> EditFailure {
        keepOnPasteboard(text)
        return EditFailure(message: Strings.typedTextCopied)
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
    /// none, changes are still made, and cannot be undone. It keeps as many steps as the engine does
    /// (`undoLimit`), so an Undo past them is never a tap that does nothing.
    @ObservationIgnored weak var undoManager: UndoManager? {
        didSet { undoManager?.levelsOfUndo = Self.undoLimit }
    }
    /// How many changes the undo manager keeps: the engine's history, `MAX_UNDO` (100) in the pinned
    /// PdfCraft release (`PdfDocument.undo`). A group of the undo manager can hold more than one change
    /// (typing in a field, then a tap on a checkbox, in one turn of the run loop): then it holds more
    /// than the engine, and an undo past the engine's history is quiet (`move`).
    static let undoLimit = 100
    /// Whether the undo manager has a change to take back, and one to make again, and their names
    /// (`Strings.actionRotate`, ...; empty for none), as last read (`undoStackDidChange`): it is not
    /// observable itself.
    private(set) var undoManagerCanUndo = false
    private(set) var undoManagerCanRedo = false
    private(set) var undoManagerUndoName = ""
    private(set) var undoManagerRedoName = ""

    /// The screen read the undo manager's stacks again.
    func undoStackDidChange(canUndo: Bool, canRedo: Bool, undoName: String, redoName: String) {
        if undoManagerCanUndo != canUndo { undoManagerCanUndo = canUndo }
        if undoManagerCanRedo != canRedo { undoManagerCanRedo = canRedo }
        if undoManagerUndoName != undoName { undoManagerUndoName = undoName }
        if undoManagerRedoName != redoName { undoManagerRedoName = redoName }
    }

    /// Whether Undo and Redo may be chosen now, in the toolbar and in the Edit menu, and what the
    /// menu calls them.
    var undoAvailability: UndoAvailability {
        UndoAvailability(canUndo: undoManagerCanUndo, canRedo: undoManagerCanRedo, hasPendingEdit: hasPendingEdit,
                         undoName: undoManagerUndoName, redoName: undoManagerRedoName, pendingName: pendingEditName)
    }

    /// The name of the change what waits makes, nil with nothing waiting: Undo adds it, then takes it
    /// back. The strokes, the text box's text and the field's text are added in that order
    /// (`commitPendingInk`), in one turn of the run loop, so in one step of the undo manager, which
    /// bears the last name given.
    var pendingEditName: String? {
        if hasPendingFieldText { return Strings.actionFillField }
        if hasPendingText { return pendingTextName }
        if hasPendingInk { return Strings.actionAddAnnotation }
        return nil
    }

    /// Whether a change, undo or redo is waiting or running.
    var isApplying: Bool { queue.isBusy }

    /// Where every change, undo, redo and reading of the document's state runs, one at a time.
    private let queue = EditQueue()
    /// The revisions made by the last change, undo or redo that can make an edit worked out before it
    /// mean something else (`EditShift`): page numbers, annotations' places, points in view space. An
    /// edit that depends on one of them, worked out before, is refused (see `enqueue`).
    @ObservationIgnored private var lastShifts = Shifts()
    /// What changes made to the pages since the document opened did to which pages: whether a page is
    /// still the page it was (`pageIsUnchanged`).
    @ObservationIgnored private var pageMoves = PageMoves()

    /// Whether a page or annotation index worked out at `revision` still names what it named then: no
    /// change made since has numbered the pages or a page's annotations again.
    func stillNamesTheSame(workedOutAt revision: UInt64) -> Bool {
        revision >= lastShifts.pages && revision >= lastShifts.annotations
    }

    /// Whether `page` is the page it was at `revision`, as it was then: no change, undo or redo since has
    /// deleted, moved or inserted it or a page before it, or turned it. A point in view space worked out
    /// on it then is the same point now.
    func pageIsUnchanged(_ page: Int, since revision: UInt64) -> Bool {
        pageMoves.leaves(page, unchangedSince: revision)
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
    ///
    /// `whenStale`, when given, is asked when the engine refuses the change as stale, in place of
    /// telling the reader the document changed: what is waiting can then be kept (strokes put back on
    /// the canvas, text handed over again or kept on the pasteboard). It says what the reader is told,
    /// nil for nothing.
    @discardableResult
    func enqueue(_ edits: [Edit], named actionName: String, touching pages: Set<Int>?, workedOutAt base: UInt64? = nil,
                 atItsTurn: (@MainActor (DocumentModel) -> ChangeAtItsTurn)? = nil,
                 whenStale: (@MainActor () -> EditFailure?)? = nil) -> Task<Bool, Never> {
        guard !edits.isEmpty else { return Task { false } }
        commitPendingInk()
        changesHandedOver += 1
        let token = EditToken(pages: pages, shift: Self.undoShift(of: edits), pageEffect: PageEffect(of: edits))
        registerStep(.undo, token: token, named: actionName)
        liveChanges.add(token)
        let base = base ?? revision
        let engine = engine
        engine.editWillStart()
        return queue.submit { [weak self] in
            defer { engine.editDidFinish() }
            return await self?.apply(edits, label: actionName, base: base, token: token, atItsTurn: atItsTurn,
                                     whenStale: whenStale) ?? false
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

    /// Takes back the last change: the toolbar's Undo, and the Edit menu's (⌘Z). Through the undo
    /// manager, so its stack and the engine's history move together. Strokes drawn with Draw and
    /// waiting are added first, so Undo then takes back the whole drawing.
    ///
    /// Nothing happens while a stroke is being drawn (`isDrawingStroke`: ⌘Z, or the toolbar's Undo
    /// tapped with another finger, as the Pencil draws). The strokes waiting cannot be added before the
    /// stroke is over without cutting it (`InkInteraction.commitPendingInk`), so an undo then would take
    /// back the change before them, and the strokes, added once the stroke lands, would clear Redo.
    /// Adding them at once, as the closing paths do, would cut the stroke the reader is still drawing,
    /// and the undo would then take away the drawing under their pen. Doing nothing loses nothing: once
    /// the stroke is over, Undo adds the drawing and takes it back.
    func undo() {
        guard !isDrawingStroke else { return }
        commitPendingInk()
        undoManager?.undo()
    }

    /// Makes again the change last taken back: the toolbar's Redo, and the Edit menu's (⇧⌘Z). Strokes
    /// drawn with Draw and waiting are added first (they are the latest change, and the screen does not
    /// offer Redo meanwhile). Nothing happens while a stroke is being drawn, as for `undo`: the stroke
    /// is a change on its way.
    func redo() {
        guard !isDrawingStroke else { return }
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
    /// document's new state. `atItsTurn` and `whenStale` as for `enqueue`.
    ///
    /// A document whose capabilities lock it for its signatures (`signatureLock`) is refused here,
    /// with that sentence, before the engine is asked: a change handed over before the capabilities
    /// were first read (the tools could not tell yet) comes after that read, in the queue.
    private func apply(_ edits: [Edit], label: String, base: UInt64, token: EditToken,
                       atItsTurn: (@MainActor (DocumentModel) -> ChangeAtItsTurn)?,
                       whenStale: (@MainActor () -> EditFailure?)?) async -> Bool {
        guard let document = document() else {
            undoManager?.removeAllActions(withTarget: token)
            return false
        }
        if let signatureLock {
            failure = EditFailure(message: signatureLock)
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
            case .stale:
                if let whenStale {
                    if let told = whenStale() { failure = told }
                } else {
                    failure = EditFailure(message: Strings.documentChangedTryAgain)
                }
                undoManager?.removeAllActions(withTarget: token)
                return false
            }
        }
        let base = Self.canRebase(edits, workedOutAt: base, shifts: lastShifts) ? revision : base
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
            refresh(state, touching: token.pages, shift: Self.shift(of: edits), pageEffect: token.pageEffect)
            return true
        case .failure(let error):
            if let whenStale, case .Stale? = error as? EditError {
                if let told = whenStale() { failure = told }
            } else {
                failure = EditFailure(error)
            }
            if Self.mayHaveChanged(after: error) {
                // The engine may have changed the document all the same (the revision has moved on), so
                // its history and the undo manager's stack may no longer match: the stack is emptied,
                // as when an undo or redo fails.
                takeEveryChangeOffTheUndoManager()
            } else {
                undoManager?.removeAllActions(withTarget: token)
            }
            await refreshIfMoved(document)
            return false
        }
    }

    /// Whether a change the engine refused with `error` may have changed the document all the same:
    /// `Failed` (the engine failed half way, and the bridge moved the revision on), or an error that is
    /// not the bridge's at all. Every other refusal leaves the document as it was.
    private static func mayHaveChanged(after error: Error) -> Bool {
        guard let error = error as? EditError else { return true }
        if case .Failed = error { return true }
        return false
    }

    /// Takes the entries of every change still known off the undo manager: what it does when its stack
    /// and the engine's history may no longer match.
    private func takeEveryChangeOffTheUndoManager() {
        for change in liveChanges.allObjects { undoManager?.removeAllActions(withTarget: change) }
    }

    /// A queued undo or redo of the change of `token`: nothing for a change the engine refused. It
    /// shifts what the change's undo does (`token.shift`): an undo of a mark leaves pages and points
    /// where they were, so strokes drawn meanwhile are still added.
    ///
    /// The engine keeps only the last 100 changes (`PdfDocument.undo`), so the undo manager can hold
    /// older ones it has no step for any more: undoing one of those finds nothing to undo. That is no
    /// failure: that change's entries are taken off, quietly, and the rest of the history (what can be
    /// redone, above all) stays. Any other undo or redo the engine cannot make means its history and
    /// the undo manager's stack no longer match, so the stack is emptied, and the reader told. It
    /// redraws the pages the change touched as it was made: every change after it has been undone by
    /// then, so they are where they were.
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
            refresh(state, touching: token.pages, shift: token.shift, pageEffect: token.pageEffect)
        case .failure(EditError.NothingToUndo), .failure(EditError.NothingToRedo):
            // Past the engine's history: this change has no step there any more. The document is as it
            // was, so there is nothing to read again.
            undoManager?.removeAllActions(withTarget: token)
        case .failure(let error):
            failure = EditFailure(error)
            takeEveryChangeOffTheUndoManager()
            await refreshIfMoved(document)
        }
    }

    /// After a refused change: an undo, a redo or a change that failed half way can still have moved
    /// the revision on, and then the document is read again.
    private func refreshIfMoved(_ document: PdfDocument) async {
        guard case .success(let state) = await EditQueue.offMain({ EngineState.read(document) }),
              state.revision != revision else { return }
        refresh(state, touching: nil, shift: .all, pageEffect: .everything)
    }

    /// The revisions made by the last change, undo or redo of each kind of `EditShift`.
    struct Shifts {
        var pages: UInt64 = 0
        var annotations: UInt64 = 0
        var geometry: UInt64 = 0

        /// `shift`, made by the change at `revision`, recorded.
        mutating func record(_ shift: EditShift, at revision: UInt64) {
            if shift.contains(.pages) { pages = max(pages, revision) }
            if shift.contains(.annotations) { annotations = max(annotations, revision) }
            if shift.contains(.geometry) { geometry = max(geometry, revision) }
        }
    }

    /// What `edits` do to edits worked out before them. Adding an annotation appends it to its
    /// page's list (`pdfcraft_annot::add_annotation` pushes onto `/Annots`), so the places before
    /// it keep naming the same annotations.
    static func shift(of edits: [Edit]) -> EditShift {
        var shift: EditShift = []
        for edit in edits {
            switch edit {
            case .deletePages, .movePages, .insertBlankPage, .insertPagesFrom:
                shift.insert(.pages)
            // A text box given a new size or background is deleted and added again at the end of its
            // page's list (`restyleTextBox`): the places after its old one move down.
            case .deleteAnnotation, .deleteAnnotations, .moveAnnotation, .restyleTextBox:
                shift.insert(.annotations)
            case .rotatePages:
                shift.insert(.geometry)
            case .setInfo, .addTextMarkup, .addNote, .setAnnotationContents, .addInk, .addSignature, .addTextBox,
                 .addShape, .addLine, .setFieldValue:
                break
            }
        }
        return shift
    }

    /// What an undo or a redo of `edits` does to edits worked out before it: what the edits do (the
    /// other way), and, when they add an annotation, the places of its page's annotations, since the
    /// undo takes it off the end of the list (and every change after it has been undone by then).
    /// Nothing else: an undo of a mark leaves the pages, their numbers and their points where they were.
    static func undoShift(of edits: [Edit]) -> EditShift {
        var shift = shift(of: edits)
        if edits.contains(where: addsAnAnnotation) { shift.insert(.annotations) }
        return shift
    }

    /// Whether `edit` adds an annotation to a page.
    private static func addsAnAnnotation(_ edit: Edit) -> Bool {
        switch edit {
        case .addTextMarkup, .addNote, .addInk, .addSignature, .addTextBox, .addShape, .addLine:
            true
        case .rotatePages, .deletePages, .movePages, .insertBlankPage, .insertPagesFrom, .setInfo, .deleteAnnotation,
             .deleteAnnotations, .setAnnotationContents, .restyleTextBox, .moveAnnotation, .setFieldValue:
            false
        }
    }

    /// What `edits` need to mean, worked out earlier, what they meant then: the page numbers they name,
    /// the places of the annotations they name, the points in view space they carry.
    static func dependence(of edits: [Edit]) -> EditShift {
        var needs: EditShift = []
        for edit in edits {
            switch edit {
            case .setInfo, .setFieldValue:
                break
            case .rotatePages, .deletePages, .movePages, .insertBlankPage, .insertPagesFrom:
                needs.insert(.pages)
            case .deleteAnnotation, .deleteAnnotations, .setAnnotationContents, .restyleTextBox:
                needs.formUnion([.pages, .annotations])
            case .moveAnnotation:
                needs.formUnion([.pages, .annotations, .geometry])
            case .addTextMarkup, .addNote, .addInk, .addSignature, .addTextBox, .addShape, .addLine:
                needs.formUnion([.pages, .geometry])
            }
        }
        return needs
    }

    /// Whether `edits`, worked out at revision `base`, still mean the same on the document as it is
    /// now: no change since `base` has shifted what they depend on (`dependence`, the last of each
    /// kind in `shifts`). Fills of form fields always do: a field is addressed by its name, which no
    /// change to the pages or the annotations alters.
    static func canRebase(_ edits: [Edit], workedOutAt base: UInt64, shifts: Shifts) -> Bool {
        if edits.allSatisfy(isAddressedByName) { return true }
        let needs = dependence(of: edits)
        return !(needs.contains(.pages) && base < shifts.pages)
            && !(needs.contains(.annotations) && base < shifts.annotations)
            && !(needs.contains(.geometry) && base < shifts.geometry)
    }

    /// Whether `edit` addresses what it changes by a name, not by a page or an index: a form field's fill.
    private static func isAddressedByName(_ edit: Edit) -> Bool {
        if case .setFieldValue = edit { true } else { false }
    }

    /// Publishes the document as it is after a change, undo or redo: its pages, with the current
    /// page kept on one of them (`apply` has moved it with its page first); nothing selected (an index into the old pages or annotations may
    /// name something else now); its annotations, fields and capabilities; the search run again;
    /// and what changed.
    private func refresh(_ state: EngineState, touching pagesTouched: Set<Int>?, shift: EditShift, pageEffect: PageEffect) {
        lastShifts.record(shift, at: state.revision)
        pageMoves.record(pageEffect, at: state.revision)
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
    /// Whether a stroke is being drawn on the canvas: from its start until it is on the drawing.
    var isDrawingStroke: Bool { get }

    /// Adds the strokes waiting, if any, as one change, handed over before this returns; the task says
    /// whether it was made. Nil with none waiting. While a stroke is being drawn, only when `closing`
    /// (`DocumentModel.commitPendingInk`); otherwise they wait for it, and this is nil.
    @discardableResult
    func commitPendingInk(closing: Bool) -> Task<Bool, Never>?

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
    /// What the change was worked out from has changed since (an annotation it read was deleted or moved
    /// before its turn): it is refused as the engine refuses a stale change, and nothing is done.
    case stale
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
    /// Whether it is the comment of a mark (a highlight, a drawing, a shape…: Select's Comment, a row
    /// of the list of comments), rather than a sticky note: the sheet is called Comment, and its change
    /// Edit Comment.
    let isComment: Bool

    init(page: Int, point: CGPoint, existing: AnnotationRef?, text: String, revision: UInt64, isComment: Bool = false) {
        self.page = page
        self.point = point
        self.existing = existing
        self.text = text
        self.revision = revision
        self.isComment = isComment
    }

    /// The sheet's title: Comment for a mark's comment, Note for a sticky note.
    var title: String { isComment ? Strings.comment : Strings.noteTitle }
    /// What the sheet's empty text says.
    var placeholder: String { isComment ? Strings.addACommentPlaceholder : Strings.notePlaceholder }
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

/// The dates a file writes for its comments (`PdfDocument.annotationDates`), by page and place, at
/// the revision they were read at.
struct CommentDates: Equatable {
    let revision: UInt64
    let byRef: [AnnotationRef: String]
}

/// What a change, undo or redo can make an edit worked out before it mean (`DocumentModel.canRebase`):
/// each kind is a part of the document such an edit can depend on (`DocumentModel.dependence`).
struct EditShift: OptionSet, Sendable {
    let rawValue: UInt8

    /// Page numbers may name other pages: pages deleted, moved or inserted.
    static let pages = EditShift(rawValue: 1 << 0)
    /// The places of a page's annotations may name other annotations, or none: annotations deleted
    /// or moved, or one taken off again (the undo of its adding).
    static let annotations = EditShift(rawValue: 1 << 1)
    /// Points in view space are somewhere else on the page: pages turned.
    static let geometry = EditShift(rawValue: 1 << 2)
    /// Any of them: what a change the engine failed half way, or one not known, may have done.
    static let all: EditShift = [.pages, .annotations, .geometry]
}

/// What a change, or its undo or redo, does to the pages (`DocumentModel.pageIsUnchanged`): from which
/// page on the pages may be others than before, and which pages it turns. An undo or a redo does the
/// same to the same pages: an undone delete puts the pages back from the same place on, an undone
/// turn turns the same pages back.
struct PageEffect: Equatable, Sendable {
    /// The first page that may be another after the change (the pages after it are renumbered); nil
    /// when no page is.
    var renumbersFrom: Int?
    /// The pages the change turns, by their numbers before it.
    var turns: Set<Int> = []

    /// Nothing done to the pages.
    static let none = PageEffect()
    /// Any page may be another, or turned: a change that failed half way, or one not known.
    static let everything = PageEffect(renumbersFrom: 0)

    init(renumbersFrom: Int? = nil, turns: Set<Int> = []) {
        self.renumbersFrom = renumbersFrom
        self.turns = turns
    }

    /// What `edits` do to the pages. A turn after a renumbering in the same step names pages by their
    /// new numbers: every page from the renumbering on counts as another then, which is the case
    /// already.
    init(of edits: [Edit]) {
        self.init()
        func from(_ page: Int) { renumbersFrom = min(renumbersFrom ?? page, page) }
        for edit in edits {
            switch edit {
            case .deletePages(let pages):
                if let first = pages.min() { from(Int(first)) }
            case .movePages(let pages, let to):
                if let first = pages.min() { from(min(Int(first), Int(to))) }
            case .insertBlankPage(let at, _, _):
                from(Int(at))
            case .insertPagesFrom(_, _, _, let at):
                from(Int(at))
            case .rotatePages(let pages, _):
                turns.formUnion(pages.map(Int.init))
            case .setInfo, .addTextMarkup, .addNote, .setAnnotationContents, .addInk, .addSignature, .addTextBox,
                 .addShape, .addLine, .setFieldValue, .deleteAnnotation, .deleteAnnotations, .restyleTextBox, .moveAnnotation:
                break
            }
        }
    }

    /// Whether `page` is another page, or turned, after the change.
    func changes(_ page: Int) -> Bool {
        (renumbersFrom.map { $0 <= page } ?? false) || turns.contains(page)
    }
}

/// What the changes, undos and redos made since the document opened did to its pages, by the
/// revision each made: enough to tell whether a page is still the page it was at a revision, as it
/// was (`leaves(_:unchangedSince:)`). Only changes that do something to the pages are kept, the last
/// `limit` of them; a revision older than those forgotten is answered "changed".
struct PageMoves {
    /// How many are kept.
    static let limit = 256

    private var moves: [(revision: UInt64, effect: PageEffect)] = []
    /// The latest revision whose change has been forgotten; 0 while none has.
    private var forgottenThrough: UInt64 = 0

    /// The change that made `revision` did `effect` to the pages.
    mutating func record(_ effect: PageEffect, at revision: UInt64) {
        guard effect != .none else { return }
        moves.append((revision, effect))
        if moves.count > Self.limit {
            forgottenThrough = max(forgottenThrough, moves.removeFirst().revision)
        }
    }

    /// Whether `page` is the page it was at `revision`, as it was then: no change since moved it, put
    /// another in its place, or turned it.
    func leaves(_ page: Int, unchangedSince revision: UInt64) -> Bool {
        guard revision >= forgottenThrough else { return false }
        return !moves.contains { $0.revision > revision && $0.effect.changes(page) }
    }
}

/// What `DocumentModel.keepLocally` writes to: `UIPasteboard`, or a test's own, which records it.
@MainActor
protocol ItemPasteboard: AnyObject {
    func setItems(_ items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any])
}

extension UIPasteboard: ItemPasteboard {}
