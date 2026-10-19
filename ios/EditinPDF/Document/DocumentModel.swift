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
    /// The document's form fields.
    private(set) var formFields: [FormField] = []
    /// What the last change, undo or redo did: its revision, the pages it touched (nil: any of them
    /// may have moved), and whether the number of pages, or a page's size or rotation, changed.
    private(set) var lastChange: PageChange?
    /// A change that was not made, for the screen to show as an alert; the screen clears it.
    var failure: EditFailure?
    /// The annotation the reader has picked. Every change clears it: its index may name another
    /// annotation afterwards.
    var selectedAnnotation: AnnotationRef?

    // MARK: Markup

    /// What a touch on the page does: nil while the reader is only reading (touches scroll, zoom and
    /// select text); Markup in the toolbar sets `.select`, and the palette any other tool.
    var tool: Tool?
    /// Each tool's colour and size, kept between documents and launches.
    let toolStyles: ToolStyleStore

    /// Why `tool` cannot be used on the page being read, for the palette to show; nil when it can
    /// be (and while the document's permissions are not read yet).
    func refusal(of tool: Tool) -> String? {
        guard let capabilities else { return nil }
        let rotation = pages.indices.contains(currentPage) ? pages[currentPage].rotationDegrees : 0
        return tool.refusal(canAnnotate: capabilities.canAnnotate, pageRotation: rotation)
    }

    /// Whether `tool` can be used on the page being read: not before the document's permissions are
    /// read, and not when they refuse it.
    func canUse(_ tool: Tool) -> Bool {
        capabilities != nil && refusal(of: tool) == nil
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
    /// `toolStyles` defaults to the styles kept in the standard user defaults.
    init(outcome: OpenOutcome, engine: EngineHandle = EngineHandle(), toolStyles: ToolStyleStore? = nil) {
        self.engine = engine
        self.toolStyles = toolStyles ?? ToolStyleStore()
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
    /// undo manager.
    @discardableResult
    func enqueue(_ edits: [Edit], named actionName: String, touching pages: Set<Int>?) -> Task<Bool, Never> {
        guard !edits.isEmpty else { return Task { false } }
        let token = EditToken()
        registerStep(.undo, token: token, named: actionName, touching: pages)
        liveChanges.add(token)
        let base = revision
        return queue.submit { [weak self] in
            await self?.apply(edits, label: actionName, base: base, token: token, touching: pages) ?? false
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
    /// the engine's history move together.
    func undo() {
        undoManager?.undo()
    }

    /// Makes again the change last taken back: the toolbar's Redo.
    func redo() {
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
    /// at `token.applied` when it runs, and does nothing for a change the engine refused.
    private func registerStep(_ step: Step, token: EditToken, named actionName: String, touching pages: Set<Int>?) {
        guard let undoManager else { return }
        // The change is the target, so a refused one's entry can be taken off again on its own; the
        // handler holds it (the undo manager does not keep its targets).
        undoManager.registerUndo(withTarget: token) { [weak self, token] _ in
            guard let self else { return }
            self.registerStep(step.opposite, token: token, named: actionName, touching: pages)
            self.queue.submit { [weak self] in
                await self?.move(step, token: token, touching: pages)
            }
        }
        undoManager.setActionName(actionName)
    }

    /// A queued edit: asks the engine for it off the main actor and, once made, publishes the
    /// document's new state.
    private func apply(_ edits: [Edit], label: String, base: UInt64, token: EditToken, touching pages: Set<Int>?) async -> Bool {
        guard let document = document() else {
            undoManager?.removeAllActions(withTarget: token)
            return false
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
            refresh(state, touching: pages, shift: Self.shift(of: edits))
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
    /// so the stack is emptied, and the reader told.
    private func move(_ step: Step, token: EditToken, touching pages: Set<Int>?) async {
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
            refresh(state, touching: pages, shift: .index)
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
            case .deletePages, .movePages, .insertBlankPage, .insertPagesFrom, .deleteAnnotation, .moveAnnotation:
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
                 .deleteAnnotation, .setAnnotationContents, .setFieldValue:
                false
            case .addTextMarkup, .addNote, .addInk, .addSignature, .addTextBox, .addShape, .addLine, .moveAnnotation:
                true
            }
        }
    }

    /// Whether `edits`, worked out at revision `base`, still mean the same on the document as it is
    /// now: no change since `base` has shifted an index, and none has turned a page, or the edits
    /// have no point in view space for a turn to move.
    private static func canRebase(_ edits: [Edit], workedOutAt base: UInt64, indexShift: UInt64, geometryShift: UInt64) -> Bool {
        base >= indexShift && (base >= geometryShift || !hasViewSpaceGeometry(edits))
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
        formFields = state.formFields
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
    let formFields: [FormField]
    let capabilities: EditCapabilities

    static func read(_ document: PdfDocument) -> EngineState {
        EngineState(revision: document.revision(),
                    pages: (0..<document.pageCount()).compactMap { document.pageInfo(page: $0) },
                    annotations: document.annotations(),
                    formFields: document.formFields(),
                    capabilities: document.capabilities())
    }
}
