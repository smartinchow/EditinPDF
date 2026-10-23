import CoreGraphics
import EditinPDFCore

/// What Highlight, Underline or Strikethrough does to selected text, as in a word processor: it takes
/// that mark off text that has it, and puts it on text that does not.
///
/// - **Every selected glyph already has the mark** (a mark of that kind covers it): the mark comes off
///   the selected glyphs, and only those. Each mark that covers one of them is deleted, and what it
///   covers outside the selection is added back as new marks of the same kind, colour, opacity
///   (`Edit.addTextMarkup`'s `opacityOf`): one for the part before the selection and one for the part
///   after it, each with the boxes of its lines as a selection of those glyphs gives them. The mark's
///   comment goes with the first of them (the part before the selection, when there is one).
/// - **Otherwise** the mark goes on the selected glyphs it is not on yet, so a mark is never laid over
///   one of the same kind: over the whole selection when none of it has the mark, as one mark over the
///   stretches without it when some of it has.
///
/// A glyph is covered by a mark when the middle of its box is in one of the mark's quads
/// (`AnnotationInfo.quads`). The spaces between words, and glyphs with no box, do not count: a
/// selection of two words marked one at a time is all marked. A mark the file locks is never deleted
/// or cut short: when such marks are all that cover the selection, the change is refused (`locked`);
/// when unlocked ones cover it too, those come off, and the locked ones stay. A mark another comment
/// replies to (`AnnotationInfo.hasReplies`) is never cut short, since adding back what stays of it would
/// leave the replies deleted with it: when the selection would cut one, the change is refused
/// (`replies`). One wholly inside the selection comes off, replies and all, as Delete takes it off.
///
/// A drag with the tool, and the menu's Highlight, Underline and Strikethrough, only ever add; the menu's
/// Remove items only ever take off (`DocumentModel.MarkIntent`).
///
/// Everything is in view space (PDF points from the page's top-left, y down), and glyphs are known by
/// their index on the page, as the engine gives them at one revision.
///
/// The work is bounded, whatever the file: at most `maxLooks` looks of a glyph against a mark's box or
/// quad (`tooMuch` past it) and `maxRuns` stretches of glyphs to mark or add back.
enum MarkupToggle {
    /// What a mark cut short leaves: the mark it is cut from, the stretches of glyphs of it that stay
    /// on one side of the selection, and whether it takes the mark's comment.
    struct Piece: Equatable, Sendable {
        let source: AnnotationInfo
        let runs: [Range<Int>]
        let keepsContents: Bool
    }

    /// What picking a text tool does to the selection.
    enum Plan: Equatable, Sendable {
        /// None of it has the mark: the selection is marked as it is.
        case markSelection
        /// Some of it has the mark: these stretches of glyphs, the selected ones without it, are marked.
        case mark(runs: [Range<Int>])
        /// All of it has the mark: the marks at these places of the page's list are deleted, and these
        /// pieces of them added back.
        case remove(deleting: [UInt32], pieces: [Piece])
        /// All of it has the mark, and only marks the file locks give it.
        case locked
        /// All of it has the mark, and taking it off would cut short a mark that has replies.
        case replies
        /// The page has more glyphs, marks or quads than the work allows.
        case tooMuch
    }

    /// A `Plan` with the boxes of its stretches of glyphs worked out by the engine: what the model makes
    /// the change from.
    enum Step: Sendable {
        case markSelection
        case mark([Rect])
        case remove(deleting: [UInt32], pieces: [(source: AnnotationInfo, boxes: [Rect], keepsContents: Bool)])
        case locked
        case replies
        case tooMuch

        /// `plan`, for `page` of `document`. Calls into the engine: not on the main actor.
        init(_ plan: Plan, page: UInt32, document: any PdfDocumentProtocol) throws {
            switch plan {
            case .markSelection:
                self = .markSelection
            case .mark(let runs):
                self = .mark(try MarkupToggle.boxes(of: runs, page: page, in: document))
            case .remove(let deleting, let pieces):
                self = .remove(deleting: deleting, pieces: try pieces.map { piece in
                    (piece.source, try MarkupToggle.boxes(of: piece.runs, page: page, in: document), piece.keepsContents)
                })
            case .locked:
                self = .locked
            case .replies:
                self = .replies
            case .tooMuch:
                self = .tooMuch
            }
        }
    }

    /// The most looks of a glyph against a mark's box or one of its quads that one plan makes: a page of
    /// some thousands of glyphs under some hundreds of marks takes far fewer.
    static let maxLooks = 4_000_000

    /// The most stretches of glyphs a plan marks or adds back: each is a selection the engine works out
    /// boxes for.
    static let maxRuns = 1_000

    /// The plan for `kind` over the glyphs `selection` of a page whose glyphs are `glyphs` and whose
    /// annotations are `annotations` (as the engine listed them at the same revision).
    static func plan(_ kind: MarkupKind, selection: Range<Int>, glyphs: [TextGlyph], annotations: [AnnotationInfo]) -> Plan {
        let page = PageGlyphs(glyphs)
        let selection = selection.clamped(to: 0..<glyphs.count)
        let marks = marks(of: kind, in: annotations)
        let selected = selection.filter(page.isText)
        guard !marks.isEmpty, !selected.isEmpty else { return .markSelection }
        var budget = Budget()
        // The marks that cover each selected glyph.
        var covering: [Int: [Int]] = [:]
        for glyph in selected {
            guard let found = page.marks(covering: glyph, of: marks, budget: &budget) else { return .tooMuch }
            if !found.isEmpty { covering[glyph] = found }
        }
        if covering.isEmpty { return .markSelection }
        if covering.count < selected.count {
            let runs = uncoveredRuns(of: selection, page: page, covered: Set(covering.keys))
            return runs.count > maxRuns ? .tooMuch : .mark(runs: runs)
        }
        let unlocked = Set(covering.values.joined()).filter { !marks[$0].info.locked }.sorted { marks[$0].info.index < marks[$1].info.index }
        guard !unlocked.isEmpty else { return .locked }
        var pieces: [Piece] = []
        var runCount = 0
        for position in unlocked {
            guard let left = page.leftOver(of: marks[position], outside: selection, budget: &budget) else { return .tooMuch }
            let before = left.filter { $0.upperBound <= selection.lowerBound }
            let after = left.filter { $0.lowerBound >= selection.upperBound }
            runCount += left.count
            if runCount > maxRuns { return .tooMuch }
            if marks[position].info.hasReplies, !left.isEmpty { return .replies }
            for (side, runs) in [before, after].enumerated() where !runs.isEmpty {
                let first = side == 0 || before.isEmpty
                pieces.append(Piece(source: marks[position].info, runs: runs, keepsContents: first))
            }
        }
        return .remove(deleting: unlocked.map { marks[$0].info.index }, pieces: pieces)
    }

    /// Whether every glyph of `selection` that counts (see the type) has a mark of `kind`, and a mark the
    /// file does not lock is among those that give it: what the selection's menu offers to take off. False
    /// when none counts; nil when the work is too much to tell.
    static func covers(_ kind: MarkupKind, selection: Range<Int>, glyphs: [TextGlyph], annotations: [AnnotationInfo]) -> Bool? {
        let page = PageGlyphs(glyphs)
        let marks = marks(of: kind, in: annotations)
        let selected = selection.clamped(to: 0..<glyphs.count).filter(page.isText)
        guard !marks.isEmpty, !selected.isEmpty else { return false }
        var budget = Budget()
        var unlocked = false
        for glyph in selected {
            guard let found = page.marks(covering: glyph, of: marks, budget: &budget) else { return nil }
            if found.isEmpty { return false }
            if !unlocked { unlocked = found.contains { !marks[$0].info.locked } }
        }
        return unlocked
    }

    /// Whether `annotations` has any mark of `kind` that tells which text it covers: with none, there is
    /// nothing to take off, and the page's text need not be read.
    static func hasMarks(of kind: MarkupKind, in annotations: [AnnotationInfo]) -> Bool {
        annotations.contains { $0.kind == annotationKind(of: kind) && !$0.quads.isEmpty }
    }

    /// The boxes of the glyphs of `runs` of `page`, as selections of them give them (one for each line
    /// a run is on), in order: what a mark over those glyphs covers, as one made from a selection does.
    /// A box that cannot be drawn is left out. Calls into the engine: not on the main actor.
    static func boxes(of runs: [Range<Int>], page: UInt32, in document: any PdfDocumentProtocol) throws -> [Rect] {
        var boxes: [Rect] = []
        for run in runs {
            let selection = try document.selectRange(page: page, start: UInt32(clamping: run.lowerBound), end: UInt32(clamping: run.upperBound))
            boxes += SelectionController.rects(of: selection).map { Rect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }
        }
        return boxes
    }

    /// The kind of annotation a mark of `kind` is.
    static func annotationKind(of kind: MarkupKind) -> AnnotationKind {
        switch kind {
        case .highlight: .highlight
        case .underline: .underline
        case .strikeOut: .strikeOut
        }
    }

    // MARK: Working it out

    /// A mark, with its quads as boxes and the box that holds them all (looked at first).
    struct Mark {
        let info: AnnotationInfo
        let quads: [CGRect]
        let bounds: CGRect
    }

    private static func marks(of kind: MarkupKind, in annotations: [AnnotationInfo]) -> [Mark] {
        let kind = annotationKind(of: kind)
        return annotations.compactMap { info in
            guard info.kind == kind else { return nil }
            let quads = info.quads.compactMap { quad -> CGRect? in
                guard quad.x.isFinite, quad.y.isFinite, quad.width.isFinite, quad.height.isFinite,
                      quad.width > 0, quad.height > 0 else { return nil }
                return CGRect(x: quad.x, y: quad.y, width: quad.width, height: quad.height)
            }
            guard let first = quads.first else { return nil }
            return Mark(info: info, quads: quads, bounds: quads.dropFirst().reduce(first) { $0.union($1) })
        }
    }

    /// The stretches of `selection` to mark when some of it is marked: from each glyph that counts and is
    /// not `covered` to the last such glyph before the next covered one. Spaces and glyphs with no box
    /// between them are taken in; those at the ends are left out.
    private static func uncoveredRuns(of selection: Range<Int>, page: PageGlyphs, covered: Set<Int>) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        var last: Int?
        func close() {
            if let start, let last { runs.append(start..<(last + 1)) }
            start = nil
            last = nil
        }
        for glyph in selection where page.isText(glyph) {
            if covered.contains(glyph) {
                close()
            } else {
                if start == nil { start = glyph }
                last = glyph
            }
        }
        close()
        return runs
    }

    /// Counts the looks a plan makes.
    struct Budget {
        private(set) var left = MarkupToggle.maxLooks

        /// Takes `looks` from what is left; false, taking nothing, when that is not enough.
        mutating func spend(_ looks: Int) -> Bool {
            guard looks <= left else { return false }
            left -= looks
            return true
        }
    }

    /// The glyphs of a page: the middle of each one's box, and which are text that counts.
    struct PageGlyphs {
        /// The middle of each glyph's box; nil for one with no box (not finite, no height, or a width
        /// below nothing).
        let middles: [CGPoint?]
        /// Whether each glyph is more than spaces.
        private let words: [Bool]
        /// How many glyphs with a box come before each index (and, last, in all).
        private let boxedBefore: [Int]

        init(_ glyphs: [TextGlyph]) {
            middles = glyphs.map { glyph in
                let r = glyph.rect
                guard r.x.isFinite, r.y.isFinite, r.width.isFinite, r.height.isFinite, r.width >= 0, r.height > 0 else { return nil }
                return CGPoint(x: r.x + r.width / 2, y: r.y + r.height / 2)
            }
            words = glyphs.map { !$0.text.isEmpty && !$0.text.allSatisfy(\.isWhitespace) }
            var counts = [0]
            counts.reserveCapacity(glyphs.count + 1)
            for middle in middles { counts.append((counts.last ?? 0) + (middle == nil ? 0 : 1)) }
            boxedBefore = counts
        }

        /// Whether the glyph counts: it has a box and is more than spaces.
        func isText(_ glyph: Int) -> Bool {
            middles.indices.contains(glyph) && middles[glyph] != nil && words[glyph]
        }

        /// The positions in `marks` of those that cover `glyph`; nil when the budget runs out.
        func marks(covering glyph: Int, of marks: [Mark], budget: inout Budget) -> [Int]? {
            guard middles.indices.contains(glyph), let middle = middles[glyph] else { return [] }
            var found: [Int] = []
            for (position, mark) in marks.enumerated() {
                guard budget.spend(1) else { return nil }
                guard mark.bounds.contains(middle) else { continue }
                guard budget.spend(mark.quads.count) else { return nil }
                if mark.quads.contains(where: { $0.contains(middle) }) { found.append(position) }
            }
            return found
        }

        /// What `mark` covers outside `selection`, as stretches of glyphs: glyphs whose middles are in its
        /// quads, those next to one another (or with only glyphs with no box between them) together,
        /// never across the selection, each from its first glyph that counts to its last (one with none
        /// left out). Nil when the budget runs out.
        func leftOver(of mark: Mark, outside selection: Range<Int>, budget: inout Budget) -> [Range<Int>]? {
            var runs: [Range<Int>] = []
            var first: Int?
            var last: Int?
            var previous: Int?
            func close() {
                if let first, let last { runs.append(first..<(last + 1)) }
                first = nil
                last = nil
            }
            for (glyph, middle) in middles.enumerated() {
                guard let middle else { continue }
                guard budget.spend(1) else { return nil }
                guard mark.bounds.contains(middle) else { continue }
                guard budget.spend(mark.quads.count) else { return nil }
                guard !selection.contains(glyph), mark.quads.contains(where: { $0.contains(middle) }) else { continue }
                if let previous, !joins(previous, glyph, across: selection) { close() }
                previous = glyph
                if words[glyph] {
                    if first == nil { first = glyph }
                    last = glyph
                }
            }
            close()
            return runs
        }

        /// Whether glyphs `a` and `b` (a before b) of a mark are in one stretch: only glyphs with no box
        /// are between them, and the selection is not.
        private func joins(_ a: Int, _ b: Int, across selection: Range<Int>) -> Bool {
            let between = boxedBefore[b] - boxedBefore[a + 1]
            let straddles = a < selection.lowerBound && b >= selection.upperBound
            return between == 0 && !straddles
        }
    }
}
