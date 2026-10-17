import CoreGraphics
import EditinPDFCore
import Foundation
import Observation

/// Searching the open document for the words the reader types, and which of the hits they are
/// looking at.
///
/// The engine's search reads the text of every page, which takes a while for a long document (about
/// 600 ms for 200 pages the first time), and a call cannot be cancelled once it has started. So
/// nothing here calls it on the main actor: a search starts a moment after the reader stops typing
/// (`debounce`), in a task off the main actor, and what it finds is only kept if its words are still
/// the latest. Every change of the words counts a new generation, and a result tagged with an older
/// one is dropped: a slow search for words that have been typed over finishes anyway, and must not
/// replace what the newer one found.
///
/// The controller belongs to one document and holds only the engine's document, never the model
/// that holds the controller.
@MainActor
@Observable
final class SearchController {
    /// Looks for `query` in the whole document: the hits in reading order, at most `searchHitLimit()`
    /// of them. The engine's search, or a stand-in for it in tests. It is called off the main actor.
    typealias Search = @Sendable (_ query: String) -> [SearchHit]

    /// How long the reader has to stop typing before a search starts.
    static let defaultDebounce: Duration = .milliseconds(250)

    /// The most hits a search gives: the engine's own number, so the note about a cut-short list
    /// and the engine never disagree.
    static let hitLimit = Int(searchHitLimit())

    /// How many PDF points of the page are brought into view round a hit's boxes, so it is not flush
    /// with the edge of the view.
    nonisolated static let revealPadding: CGFloat = 6

    /// What the reader has typed. Changing it starts a search for it, a moment later; blanks around
    /// the words are not looked for, and a query that is only blanks clears the hits at once, with no
    /// call to the engine.
    var query = "" {
        didSet { queryDidChange() }
    }

    /// What the latest search found, in reading order: at most `searchHitLimit()` hits. They stay
    /// until the search for newer words has an answer, or the query is emptied.
    private(set) var hits: [SearchHit] = []

    /// Which hit is the one being looked at: the first when a search returns hits, nil when there are
    /// none. The sheet sets it to the hit the reader picked; `next()` and `previous()` move it.
    var activeIndex: Int?

    /// Whether the words typed have no answer yet: from the moment there is something to look for
    /// until its hits arrive, the debounce included.
    private(set) var isSearching = false

    /// The hits' boxes by page, in PDF points, for the viewer to draw: the boxes of `hits`, kept in
    /// step with them.
    private(set) var highlightsByPage: [Int: [CGRect]] = [:]

    /// Whether the list is as long as a search is allowed to be, so there may be more hits than it
    /// has.
    var isTruncated: Bool { hits.count == Self.hitLimit }

    /// Whether the words typed have been looked for, and are not in the document.
    var foundNothing: Bool { !requested.isEmpty && !isSearching && hits.isEmpty }

    /// The hit being looked at, if `activeIndex` is one.
    var activeHit: SearchHit? {
        guard let index = activeIndex, hits.indices.contains(index) else { return nil }
        return hits[index]
    }

    /// The boxes of the hit being looked at, for the viewer to draw in the active colour.
    var activeHighlight: ActiveHighlight? {
        activeHit.map { ActiveHighlight(page: Int($0.page), rects: Self.rects(of: $0)) }
    }

    @ObservationIgnored private let search: Search
    @ObservationIgnored private let debounce: Duration
    /// Counts the changes of the words to look for. A search remembers the count it was started at.
    @ObservationIgnored private var generation = 0
    /// `query` without the blanks at its ends, as last acted on: what `hits` is, or the search under
    /// way will be, the answer to.
    private var requested = ""
    /// The wait before a search, and the search; replaced when newer words are typed.
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// A search of `document`, ignoring case.
    convenience init(document: PdfDocument) {
        self.init { query in document.search(query: query, caseSensitive: false) }
    }

    /// A search that asks `search` for each query once the reader has stopped typing for `debounce`.
    /// For tests, which stand in for the engine.
    init(debounce: Duration = SearchController.defaultDebounce, search: @escaping Search) {
        self.debounce = debounce
        self.search = search
    }

    /// Makes the next hit the active one, going round to the first after the last. With no hit active
    /// it is the first. Nothing happens when there are no hits. Says where to take the viewer, as
    /// `select(_:)` does.
    @discardableResult
    func next() -> PageRect? {
        step(by: 1)
    }

    /// Makes the previous hit the active one, going round to the last before the first. With no hit
    /// active it is the last. Nothing happens when there are no hits. Says where to take the viewer,
    /// as `select(_:)` does.
    @discardableResult
    func previous() -> PageRect? {
        step(by: -1)
    }

    /// Makes hit `index` the active one, for a reader who picked it or stepped to it, and says where to
    /// take the viewer: its page, and the box to bring into view there, the union of the boxes of the
    /// hit (a match over a line break has one on each line) with `revealPadding` points round it.
    /// The box is `.null` for a hit with none that can be drawn, which still has its page. Nil, and
    /// nothing changed, when `index` is not a hit.
    @discardableResult
    func select(_ index: Int) -> PageRect? {
        guard hits.indices.contains(index) else { return nil }
        activeIndex = index
        return Self.revealTarget(of: hits[index])
    }

    private func step(by delta: Int) -> PageRect? {
        guard !hits.isEmpty else { return nil }
        let current = activeIndex.flatMap { hits.indices.contains($0) ? $0 : nil }
        // From no hit, going forward arrives at the first and going back at the last.
        let from = current ?? (delta > 0 ? -1 : 0)
        return select(((from + delta) % hits.count + hits.count) % hits.count)
    }

    // MARK: Searching

    private func queryDidChange() {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the blanks at the ends changed: the same words, so the same hits, and the reader keeps
        // their place among them.
        guard words != requested else { return }
        requested = words
        generation += 1
        pending?.cancel()
        pending = nil
        guard !words.isEmpty else {
            apply([])
            return
        }
        isSearching = true
        let generation = generation
        let debounce = debounce
        pending = Task { [weak self] in
            // Typing again cancels this wait, and then nothing more is done for these words.
            do { try await Task.sleep(for: debounce) } catch { return }
            await self?.find(words, generation: generation)
        }
    }

    /// Asks the engine for `words` off the main actor and keeps the answer if no newer words have
    /// been typed since.
    private func find(_ words: String, generation: Int) async {
        // Typing again cancels the wait before this, but cannot call back a wait that has just ended
        // and is on its way here: this is the last chance to keep the engine from looking for words
        // that have been typed over.
        guard generation == self.generation else { return }
        let search = search
        let found = await Task.detached(priority: .userInitiated) { search(words) }.value
        guard generation == self.generation else { return }
        apply(found)
    }

    /// Makes `found` the hits, with the first the active one, and the search over.
    private func apply(_ found: [SearchHit]) {
        hits = found
        highlightsByPage = Self.highlights(of: found)
        activeIndex = found.isEmpty ? nil : 0
        isSearching = false
    }

    // MARK: Boxes

    /// The boxes of `hit` as `CGRect`s, in PDF points of its page (view space: origin at the
    /// top-left, y down), as the engine gives them. A box that cannot be drawn, with no area or a
    /// number that is not finite, is left out.
    nonisolated static func rects(of hit: SearchHit) -> [CGRect] {
        hit.rects.compactMap { box in
            guard box.x.isFinite, box.y.isFinite, box.width.isFinite, box.height.isFinite,
                  box.width > 0, box.height > 0 else { return nil }
            return CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
        }
    }

    /// Where to take the viewer for `hit`: its page, and the union of its boxes (see `rects(of:)`) with
    /// `revealPadding` points round it; `.null` when it has no box.
    nonisolated static func revealTarget(of hit: SearchHit) -> PageRect {
        let union = rects(of: hit).reduce(CGRect.null) { $0.union($1) }
        let box = union.isNull ? union : union.insetBy(dx: -revealPadding, dy: -revealPadding)
        return PageRect(page: Int(hit.page), rect: box)
    }

    /// The boxes of `hits` by the page (counting from 0) they are on, each page's in the order of the
    /// hits. A page with no box to draw is not in the result.
    nonisolated static func highlights(of hits: [SearchHit]) -> [Int: [CGRect]] {
        var byPage: [Int: [CGRect]] = [:]
        for hit in hits {
            let boxes = rects(of: hit)
            if !boxes.isEmpty { byPage[Int(hit.page), default: []].append(contentsOf: boxes) }
        }
        return byPage
    }
}
