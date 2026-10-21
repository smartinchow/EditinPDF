import CoreGraphics
import EditinPDFCore
import Foundation

/// One row of the Comments list (`CommentsSheet`): an annotation of the document, named for its kind
/// (`title`), with its text (`detail`, none when it has none) and who the file says wrote it
/// (`author`). Both are the file's, shown as they are, and never logged.
struct CommentRow: Identifiable, Equatable {
    let id: AnnotationRef
    /// Its page, counting from 0.
    let page: Int
    let kind: AnnotationKind
    let title: String
    let detail: String?
    let author: String?
    /// Where it is on its page (view space): what the list brings into view.
    let rect: CGRect
    /// Whether the file locks it: the list does not delete it.
    let isLocked: Bool
}

/// The annotations already on the pages: picking one (`selectedAnnotation`), moving it, deleting it,
/// changing its text, and the eraser, which deletes those it touches. Every change here addresses an
/// annotation by its page and its index on that page at the revision it was worked out at (the
/// model's now, unless said otherwise): one handed over behind a change that numbers the page's
/// annotations again, or turns the page under a move, is refused as stale (`enqueue`) rather than
/// changing another annotation, or moving it the wrong way.
extension DocumentModel {
    /// The most changes the bridge makes in one step, and the most annotations one
    /// `deleteAnnotations` deletes.
    static let maxEditsPerStep = 10_000
    /// The most characters of an annotation's text, and of its author's name, a row of the Comments
    /// list carries: a row shows three lines of it, and a file can hold megabytes of text.
    static let maxRowText = 500

    // MARK: Selecting

    /// Selects the annotation on top under `point` (view space) on `page`, within `slop` points of its
    /// box (`AnnotationIndex.hit`), or nothing when there is none.
    func selectAnnotation(page: Int, at point: CGPoint, slop: CGFloat = 8) {
        selectedAnnotation = annotationIndex.hit(page: page, at: point, slop: slop).map { AnnotationRef(page: page, index: $0.index) }
    }

    /// The selected annotation, as the document has it now; nil when none is selected.
    var selectedAnnotationInfo: AnnotationInfo? {
        selectedAnnotation.flatMap(annotationIndex.annotation)
    }

    /// Where the selected annotation is: its page and its box there (view space), for the page to
    /// outline it; nil when none is selected.
    var selectedAnnotationPlace: PageRect? {
        selectedAnnotationInfo.map { PageRect(page: Int($0.page), rect: $0.box) }
    }

    /// Whether `info` may be moved and deleted: the document allows markup (once its permissions are
    /// read) and the file does not lock it.
    func canChange(_ info: AnnotationInfo) -> Bool {
        capabilities?.canAnnotate == true && !info.locked
    }

    /// Whether the text of `info` may be changed: the document allows markup. A lock keeps an
    /// annotation where it is and on the page, not its text (PDF 32000-1, 12.5.3), and the engine
    /// changes a locked one's text.
    func canChangeText(of info: AnnotationInfo) -> Bool {
        capabilities?.canAnnotate == true
    }

    /// Why annotations on `page` cannot be changed (the document forbids markup); nil when they can
    /// be, and while the permissions are not read yet.
    private func changeRefusal(onPage page: Int) -> String? {
        refusal(of: .eraser, onPage: page)
    }

    // MARK: Moving

    /// Moves the selected annotation `offset` points (view space: across and down the page as shown)
    /// and says whether it moved. See `enqueueMoveSelectedAnnotation`.
    @discardableResult
    func moveSelectedAnnotation(by offset: CGSize, workedOutAt revision: UInt64? = nil) async -> Bool {
        await enqueueMoveSelectedAnnotation(by: offset, workedOutAt: revision).value
    }

    /// `moveSelectedAnnotation`, handed over at once: one change named `Strings.actionMoveAnnotation`.
    /// A move of less than a point, of none selected, or of one the file locks, is no change. The
    /// distance is in view space, worked out against `revision` (the model's now when nil): one
    /// handed over behind a turn of its page is refused as stale, as is one behind a change that
    /// numbers the page's annotations again. Once made, the selection goes, as with every change.
    @discardableResult
    func enqueueMoveSelectedAnnotation(by offset: CGSize, workedOutAt revision: UInt64? = nil) -> Task<Bool, Never> {
        guard let ref = selectedAnnotation, let info = annotationIndex.annotation(ref), !info.locked,
              let pageNumber = UInt32(exactly: ref.page),
              ShapeGeometry.isInReach(offset.width), ShapeGeometry.isInReach(offset.height),
              hypot(offset.width, offset.height) >= 1 else { return Task { false } }
        if let refusal = changeRefusal(onPage: ref.page) { return refuse(refusal) }
        let edit = Edit.moveAnnotation(page: pageNumber, index: ref.index, dx: Double(offset.width), dy: Double(offset.height))
        return enqueue([edit], named: Strings.actionMoveAnnotation, touching: [ref.page], workedOutAt: revision)
    }

    // MARK: Deleting

    /// Deletes the selected annotation and says whether it was deleted; nothing happens with none.
    @discardableResult
    func deleteSelectedAnnotation() async -> Bool {
        guard let ref = selectedAnnotation else { return false }
        return await deleteAnnotation(ref)
    }

    /// Deletes the annotation `ref` names (with its pop-up and its replies, as the engine does) and
    /// says whether it was deleted.
    @discardableResult
    func deleteAnnotation(_ ref: AnnotationRef) async -> Bool {
        await enqueueDelete(ref).value
    }

    /// `deleteAnnotation`, handed over at once: one change named `Strings.actionDeleteAnnotation`,
    /// addressed as at `revision` (the model's now when nil, and then only an annotation the document
    /// has now). One the file locks is refused, saying the document does not allow it: also one worked
    /// out earlier (a text box emptied in place), while `ref` still names it (`stillNamesTheSame`).
    @discardableResult
    func enqueueDelete(_ ref: AnnotationRef, workedOutAt revision: UInt64? = nil) -> Task<Bool, Never> {
        guard let pageNumber = UInt32(exactly: ref.page) else { return Task { false } }
        let info = annotationIndex.annotation(ref)
        guard revision != nil || info != nil else { return Task { false } }
        if let refusal = changeRefusal(onPage: ref.page) { return refuse(refusal) }
        // Otherwise the delete is refused as stale on its way (`enqueue`), whatever `ref` names now.
        let namesInfo = revision.map(stillNamesTheSame(workedOutAt:)) ?? true
        if namesInfo, info?.locked == true { return refuse(Strings.editNotAllowed) }
        let edit = Edit.deleteAnnotation(page: pageNumber, index: ref.index)
        return enqueue([edit], named: Strings.actionDeleteAnnotation, touching: [ref.page], workedOutAt: revision)
    }

    // MARK: Changing the text

    /// Gives the annotation `ref` names the text `text` (a note's, a text box's, which the engine
    /// draws again and fits to it) and says whether it changed.
    @discardableResult
    func setContents(of ref: AnnotationRef, to text: String) async -> Bool {
        await enqueueContents(of: ref, to: text).value
    }

    /// `setContents`, handed over at once: one change named `Strings.actionEditAnnotation`, addressed
    /// as at `revision` (the model's now when nil, and then only an annotation the document has now,
    /// whose text is not `text` already). The text is the reader's, and never logged. Refused as stale
    /// with `keepingText`, the text is kept on the pasteboard and the reader told so
    /// (`keepTypedText`): the box it was typed in is gone (the text box being typed in, changed in
    /// place). Without, the reader is told the document changed (the note sheet, which stays up with
    /// the text).
    @discardableResult
    func enqueueContents(of ref: AnnotationRef, to text: String, workedOutAt revision: UInt64? = nil,
                         keepingText: Bool = false) -> Task<Bool, Never> {
        guard let pageNumber = UInt32(exactly: ref.page) else { return Task { false } }
        if revision == nil {
            guard let info = annotationIndex.annotation(ref), (info.contents ?? "") != text else { return Task { false } }
        }
        if let refusal = changeRefusal(onPage: ref.page) { return refuse(refusal) }
        let edit = Edit.setAnnotationContents(page: pageNumber, index: ref.index, contents: text)
        var whenStale: (@MainActor () -> EditFailure?)?
        if keepingText {
            whenStale = { [weak self] in self?.keepTypedText(text) }
        }
        return enqueue([edit], named: Strings.actionEditAnnotation, touching: [ref.page], workedOutAt: revision,
                       whenStale: whenStale)
    }

    /// Opens the note sheet (`noteDraft`) for `note`, a note on its page, with its text: Save changes
    /// that text, worked out against `revision`, the one `note` was read at (the model's now when nil).
    func editNote(_ note: AnnotationInfo, workedOutAt revision: UInt64? = nil) {
        noteDraft = NoteDraft(page: Int(note.page), point: CGPoint(x: note.rect.x, y: note.rect.y),
                              existing: AnnotationRef(page: Int(note.page), index: note.index), text: note.contents ?? "",
                              revision: revision ?? self.revision)
    }

    // MARK: The eraser

    /// Deletes what an eraser dragged along `points` (view space, on `page`) touches, and says whether
    /// anything was deleted. See `enqueueErase`.
    @discardableResult
    func erase(page: Int, along points: [CGPoint], slop: CGFloat = 8) async -> Bool {
        await enqueueErase(page: page, along: points, slop: slop).value
    }

    /// `erase`, handed over at once: everything the path touches is deleted (`eraseEdit`), with its
    /// pop-up and its replies, in one change that one undo takes back, named
    /// `Strings.actionDeleteAnnotation`. A path that touches none is no change.
    @discardableResult
    func enqueueErase(page: Int, along points: [CGPoint], slop: CGFloat = 8) -> Task<Bool, Never> {
        guard let edit = eraseEdit(page: page, along: points, slop: slop) else { return Task { false } }
        if let refusal = changeRefusal(onPage: page) { return refuse(refusal) }
        return enqueue([edit], named: Strings.actionDeleteAnnotation, touching: [page])
    }

    /// What an eraser dragged along `points` (view space, on `page`) changes: one `deleteAnnotations`
    /// of every annotation the path touches, within `slop` points (`AnnotationIndex.erased`: the one
    /// on top at each point, each once, none the file locks); nil when it touches none. The bridge
    /// follows each index to the annotation it is, so they go in one edit, in any order, however
    /// deleting one moves the others. Past the bridge's limit for one change, the highest are left.
    func eraseEdit(page: Int, along points: [CGPoint], slop: CGFloat = 8) -> Edit? {
        guard let pageNumber = UInt32(exactly: page) else { return nil }
        let doomed = annotationIndex.erased(page: page, along: points, slop: slop)
        guard !doomed.isEmpty else { return nil }
        return .deleteAnnotations(page: pageNumber, indices: doomed.prefix(Self.maxEditsPerStep).map(\.index))
    }

    // MARK: The Comments list

    /// The rows of the Comments list for the annotations of `index`: page by page, and top to bottom
    /// (then left to right) on a page. Each is named for its kind (`Strings.annotationKindName`, looked
    /// up once for each kind), with its text, and its author's name, when it has them: without the
    /// blank around them, and at most `maxRowText` characters of each.
    static func commentRows(_ index: AnnotationIndex) -> [CommentRow] {
        func key(_ info: AnnotationInfo) -> (UInt32, Double, Double, UInt32) {
            (info.page, info.rect.y.isFinite ? info.rect.y : 0, info.rect.x.isFinite ? info.rect.x : 0, info.index)
        }
        // Only the start of a long text is looked at: leading blanks skipped, then `maxRowText`
        // characters at most, then the blanks at their end.
        func shown(_ text: String?) -> String? {
            guard let text else { return nil }
            let head = text.drop { $0.isWhitespace }.prefix(maxRowText)
            let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var names: [AnnotationKind: String] = [:]
        func name(of kind: AnnotationKind) -> String {
            if let known = names[kind] { return known }
            let looked = Strings.annotationKindName(kind)
            names[kind] = looked
            return looked
        }
        return index.byPage.values.joined()
            .sorted { key($0) < key($1) }
            .map { info in
                CommentRow(id: AnnotationRef(page: Int(info.page), index: info.index), page: Int(info.page), kind: info.kind,
                           title: name(of: info.kind), detail: shown(info.contents), author: shown(info.author),
                           rect: info.box, isLocked: info.locked)
            }
    }
}
