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
    /// Its comment: the annotation's text, none when it has none.
    let detail: String?
    let author: String?
    /// When the file says it was last changed (`CommentDate.parse`); nil when it does not say.
    let modified: Date?
    /// Where it is on its page (view space): what the list brings into view.
    let rect: CGRect
    /// Whether the file locks it: the list does not delete it.
    let isLocked: Bool

    /// Whether it has a comment.
    var hasComment: Bool { detail != nil }
    /// What the row leads with: the comment, or, with none, `Strings.addACommentPlaceholder`.
    var headline: String { detail ?? Strings.addACommentPlaceholder }
    /// What is under the comment: the kind of mark and its page ("Highlight on page 3").
    var subtitle: String { Strings.markOnPage(title, page: page + 1) }
}

/// Which marks the list of comments shows.
enum CommentFilter: String, CaseIterable, Identifiable, Sendable {
    /// Every mark, with a comment or not.
    case all
    /// Only the marks with a comment.
    case withComments

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: Strings.allMarks
        case .withComments: Strings.withComments
        }
    }

    /// What the list starts on: the marks with a comment when any has one, otherwise all of them.
    static func initial(for rows: [CommentRow]) -> CommentFilter {
        rows.contains(where: \.hasComment) ? .withComments : .all
    }

    /// The rows of `rows` this shows, in their order.
    func rows(_ rows: [CommentRow]) -> [CommentRow] {
        switch self {
        case .all: rows
        case .withComments: rows.filter(\.hasComment)
        }
    }
}

/// When a mark was last changed, as the file says (`AnnotationInfo.modified`), and how the list of
/// comments shows it.
enum CommentDate {
    /// The date `text` gives: as the engine gives one, `YYYY-MM-DD HH:MM` with the time zone left out
    /// (the engine writes its own dates in UTC, so it is read as UTC), or a PDF date as a file has it,
    /// `D:YYYYMMDDHHmmSS` with as much of it as is there after the year, and its offset from UTC
    /// (`Z`, `+HH'mm'`, `-HH'mm'`) when it has one. Nil for anything else.
    static func parse(_ text: String) -> Date? {
        var fields: [Int] = []
        var offset = 0
        if text.hasPrefix("D:") {
            let body = Array(text.dropFirst(2))
            let digits = body.prefix { $0.isASCII && $0.isNumber }
            guard digits.count >= 4, digits.count % 2 == 0, digits.count <= 14 else { return nil }
            let numbers = String(digits)
            fields.append(Int(numbers.prefix(4)) ?? -1)
            var rest = numbers.dropFirst(4)
            while !rest.isEmpty {
                fields.append(Int(rest.prefix(2)) ?? -1)
                rest = rest.dropFirst(2)
            }
            let zone = body.dropFirst(digits.count)
            if let sign = zone.first, sign == "+" || sign == "-" {
                let parts = String(zone.dropFirst()).split(separator: "'").compactMap { Int($0) }
                let minutes = (parts.first ?? 0) * 60 + (parts.dropFirst().first ?? 0)
                offset = (sign == "+" ? 1 : -1) * minutes * 60
            }
        } else {
            let parts = text.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" })
            guard parts.count == 5, parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
            fields = parts.compactMap { Int($0) }
        }
        guard fields.count >= 1, fields.allSatisfy({ $0 >= 0 }) else { return nil }
        func field(_ i: Int, default value: Int) -> Int { fields.count > i ? fields[i] : value }
        let (month, day, hour, minute, second) = (field(1, default: 1), field(2, default: 1), field(3, default: 0), field(4, default: 0),
                                                  field(5, default: 0))
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { return nil }
        var utc = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(identifier: "UTC") else { return nil }
        utc.timeZone = zone
        let components = DateComponents(year: fields[0], month: month, day: day, hour: hour, minute: minute, second: second)
        guard components.isValidDate(in: utc), let date = utc.date(from: components) else { return nil }
        return date.addingTimeInterval(TimeInterval(-offset))
    }

    /// How the list shows `date`: how long before `now` within the last week ("2 hours ago"), otherwise
    /// the date, short.
    static func text(for date: Date, now: Date = Date()) -> String {
        let age = now.timeIntervalSince(date)
        if age >= 0, age < 7 * 86_400 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return formatter.localizedString(for: date, relativeTo: now)
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
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

    // MARK: Comments

    /// Whether Select's Comment is offered for `info`: a mark the file does not lock, in a document that
    /// allows markup. Not a note nor a text box: their text is their comment, which Edit changes.
    func canComment(on info: AnnotationInfo) -> Bool {
        info.kind != .note && info.kind != .textBox && canChange(info)
    }

    /// Opens the comment sheet (`noteDraft`, a comment) for `mark`, with its text: Save changes that
    /// text, one change named `Strings.actionEditComment`, worked out against `revision`, the one `mark`
    /// was read at (the model's now when nil).
    func comment(on mark: AnnotationInfo, workedOutAt revision: UInt64? = nil) {
        noteDraft = NoteDraft(page: Int(mark.page), point: CGPoint(x: mark.rect.x, y: mark.rect.y),
                              existing: AnnotationRef(page: Int(mark.page), index: mark.index), text: mark.contents ?? "",
                              revision: revision ?? self.revision, isComment: true)
    }

    /// A row of the list of comments, tapped: its sheet opens, a note's as a note (`editNote`), any
    /// other mark's as its comment (`comment(on:)`). Nothing for a row whose mark the document no
    /// longer has.
    func editComment(of row: CommentRow) {
        guard let info = annotationIndex.annotation(row.id) else { return }
        if info.kind == .note { editNote(info) } else { comment(on: info) }
    }

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
                         keepingText: Bool = false, named actionName: String = Strings.actionEditAnnotation) -> Task<Bool, Never> {
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
        return enqueue([edit], named: actionName, touching: [ref.page], workedOutAt: revision,
                       whenStale: whenStale)
    }

    // MARK: Formatting a text box

    /// Whether `info` is a text box whose look Select's Format may change: the document allows markup,
    /// the file does not lock it, and its page is shown upright (a new size or background adds it again,
    /// which the bridge does only there).
    func canFormat(_ info: AnnotationInfo) -> Bool {
        info.kind == .textBox && canChange(info) && canAddTextBox(onPage: Int(info.page))
    }

    /// Opens the format sheet (`formatDraft`) for `box`, a text box on its page, with the look it has:
    /// Apply gives it the look picked, worked out against `revision`, the one `box` was read at (the
    /// model's now when nil).
    func formatTextBox(_ box: AnnotationInfo, workedOutAt revision: UInt64? = nil) {
        formatDraft = TextBoxFormatDraft(ref: AnnotationRef(page: Int(box.page), index: box.index),
                                         format: TextBoxFormat(box, otherwise: toolStyles[.textBox]),
                                         revision: revision ?? self.revision)
    }

    /// The format sheet's Apply: the text box it is open for gets `format` (`enqueueRestyle`), unless it
    /// is the look it had, and the sheet goes. Says whether a change was made.
    @discardableResult
    func applyFormatDraft(_ format: TextBoxFormat) async -> Bool {
        guard let draft = formatDraft else { return false }
        formatDraft = nil
        guard format != draft.format else { return false }
        return await enqueueRestyle(draft.ref, to: format, workedOutAt: draft.revision).value
    }

    /// Gives the text box `ref` names the look `format`, handed over at once: one change named
    /// `Strings.formatTextBox`, addressed as at `revision` (the model's now when nil, and then only a
    /// text box the document has now). The bridge changes the colour and the border in place, and adds
    /// the box again for a new size or background (`Edit.restyleTextBox`). One the file locks is
    /// refused, saying the document does not allow it.
    @discardableResult
    func enqueueRestyle(_ ref: AnnotationRef, to format: TextBoxFormat, workedOutAt revision: UInt64? = nil) -> Task<Bool, Never> {
        let info = annotationIndex.annotation(ref)
        guard revision != nil || info?.kind == .textBox, let edit = format.restyle(ref) else { return Task { false } }
        if let refusal = changeRefusal(onPage: ref.page) { return refuse(refusal) }
        let namesInfo = revision.map(stillNamesTheSame(workedOutAt:)) ?? true
        if namesInfo, info?.locked == true { return refuse(Strings.editNotAllowed) }
        return enqueue([edit], named: Strings.formatTextBox, touching: [ref.page], workedOutAt: revision)
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
                           modified: info.modified.flatMap(CommentDate.parse), rect: info.box, isLocked: info.locked)
            }
    }
}
