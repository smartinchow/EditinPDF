import EditinPDFCore
import XCTest
@testable import EditinPDF

// The controller is main-actor isolated (SwiftUI reads it), so the tests are too. They wait by
// polling on the main actor: the controller publishes each result there, so the waiting has to
// yield to let it. The engine's search is stood in for by `SearchProbe` wherever a test needs to
// know what it was asked, when, and on which thread, or to make it slow.
@MainActor
final class SearchControllerTests: XCTestCase {
    func openFixture() throws -> PdfDocument {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "hello", withExtension: "pdf"))
        return try PdfDocument.open(bytes: Data(contentsOf: url), password: nil)
    }

    /// Polls until `condition` holds, for at most `timeout` seconds; false if it never did. (The
    /// condition is escaping because the compiler refuses a non-escaping one across the awaits.)
    func eventually(timeout: Double = 3, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// Keeps the main thread busy for `seconds` without yielding the main actor, as a slow moment
    /// would. (A function of its own: the compiler refuses `Thread.sleep` straight in an async test.)
    static func blockTheMainThread(for seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Gives the main actor time to handle whatever is already waiting for it: a result that has
    /// been handed back from a task is applied (or dropped) before this returns.
    func letTheMainActorCatchUp() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    /// A controller whose searches are answered by `probe`, with a debounce short enough to wait for.
    func makeController(_ probe: SearchProbe) -> SearchController {
        SearchController(debounce: .milliseconds(5), search: probe.search)
    }

    // MARK: On the real engine

    /// The brief's test: the fixture says "Hello world", so "hello" finds one hit, and an empty
    /// query takes it away again.
    func testFindsTheWordAndAnEmptyQueryClearsTheHits() async throws {
        let controller = SearchController(document: try openFixture())
        XCTAssertTrue(controller.hits.isEmpty)
        XCTAssertNil(controller.activeIndex)

        controller.query = "hello"
        let found = await eventually { controller.hits.count == 1 }
        XCTAssertTrue(found, "no hit within 3 seconds")
        let hit = try XCTUnwrap(controller.hits.first)
        XCTAssertEqual(hit.page, 0)
        XCTAssertTrue(hit.snippet.contains("Hello"), hit.snippet)
        XCTAssertFalse(hit.rects.isEmpty, "a hit comes with the boxes to highlight")
        XCTAssertEqual(controller.activeIndex, 0, "the first hit is the active one when a search returns hits")
        XCTAssertFalse(controller.isSearching)

        controller.query = ""
        XCTAssertTrue(controller.hits.isEmpty, "an empty query clears the hits at once")
        XCTAssertNil(controller.activeIndex)
        XCTAssertFalse(controller.isSearching)
    }

    func testCapitalAndSmallLettersMatchEachOther() async throws {
        let controller = SearchController(document: try openFixture())
        controller.query = "WORLD"
        let found = await eventually { controller.hits.count == 1 }
        XCTAssertTrue(found, "a search ignores case")
    }

    func testAWordThatIsNotThereFindsNothing() async throws {
        let controller = SearchController(document: try openFixture())
        XCTAssertFalse(controller.foundNothing, "nothing has been looked for")
        controller.query = "zzz"
        XCTAssertFalse(controller.foundNothing, "not before the search is done")
        let done = await eventually { !controller.isSearching }
        XCTAssertTrue(done)
        XCTAssertTrue(controller.hits.isEmpty)
        XCTAssertNil(controller.activeIndex)
        XCTAssertTrue(controller.foundNothing)

        controller.query = ""
        XCTAssertFalse(controller.foundNothing, "an empty query has found nothing because it looked for nothing")
    }

    /// The real engine, typed over at once: the first query's result never shows.
    func testTheEarlierQueryOfTwoTypedAtOnceNeverShows() async throws {
        let controller = SearchController(document: try openFixture())
        controller.query = "hello"
        controller.query = "zzz"
        let done = await eventually { !controller.isSearching }
        XCTAssertTrue(done)
        await letTheMainActorCatchUp()
        XCTAssertTrue(controller.hits.isEmpty)
    }

    func testOneHitIsNotTruncated() async throws {
        let controller = SearchController(document: try openFixture())
        XCTAssertFalse(controller.isTruncated)
        controller.query = "hello"
        let found = await eventually { controller.hits.count == 1 }
        XCTAssertTrue(found)
        XCTAssertFalse(controller.isTruncated)
    }

    // MARK: The queries, against a stand-in for the engine

    func testTheDebounceIs250Milliseconds() {
        XCTAssertEqual(SearchController.defaultDebounce, .milliseconds(250))
    }

    func testTheEngineIsNeverAskedOnTheMainThread() async {
        let probe = SearchProbe(counts: ["a": 1])
        let controller = makeController(probe)
        controller.query = "a"
        let found = await eventually { controller.hits.count == 1 }
        XCTAssertTrue(found)
        XCTAssertEqual(probe.queries, ["a"])
        XCTAssertEqual(probe.askedOnTheMainThread, 0, "a search takes long enough to freeze the screen")
    }

    func testABlankQueryClearsAtOnceAndNeverAsksTheEngine() async {
        let probe = SearchProbe(counts: ["a": 2])
        let controller = makeController(probe)

        controller.query = "   "
        XCTAssertFalse(controller.isSearching, "nothing to look for")
        await letTheMainActorCatchUp()
        XCTAssertEqual(probe.queries, [], "blanks are not looked for")

        controller.query = "a"
        let found = await eventually { controller.hits.count == 2 }
        XCTAssertTrue(found)
        controller.query = " \n\t "
        XCTAssertTrue(controller.hits.isEmpty, "blanks clear the hits at once, without waiting for the debounce")
        XCTAssertNil(controller.activeIndex)
        XCTAssertFalse(controller.isSearching)
        await letTheMainActorCatchUp()
        XCTAssertEqual(probe.queries, ["a"])
    }

    /// Each key press starts the wait again, so keys closer together than the debounce are one search,
    /// for what was typed last. (The pauses between the keys let the main actor run, as typing does.)
    func testQueriesTypedInQuickSuccessionAreOneSearchForTheLast() async {
        let probe = SearchProbe(counts: ["hel": 1])
        // The wait is long beside the pauses between keys, so a slow moment does not make it end between two.
        let controller = SearchController(debounce: .milliseconds(500), search: probe.search)
        for typed in ["h", "he", "hel"] {
            controller.query = typed
            try? await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertEqual(probe.queries, [], "still waiting for the reader to stop")
        XCTAssertTrue(controller.isSearching)
        let found = await eventually { controller.hits.count == 1 }
        XCTAssertTrue(found)
        XCTAssertEqual(probe.queries, ["hel"])
    }

    /// A pause as long as the debounce is the reader stopping: what is typed before it is searched for.
    func testAPauseAsLongAsTheDebounceStartsASearch() async {
        let probe = SearchProbe(counts: ["he": 1, "hel": 2])
        let controller = SearchController(debounce: .milliseconds(30), search: probe.search)
        controller.query = "he"
        let first = await eventually { controller.hits.count == 1 }
        XCTAssertTrue(first)
        controller.query = "hel"
        let second = await eventually { controller.hits.count == 2 }
        XCTAssertTrue(second)
        XCTAssertEqual(probe.queries, ["he", "hel"])
    }

    func testTheEngineSeesTheQueryWithoutTheBlanksAtItsEnds() async {
        let probe = SearchProbe(counts: ["hel lo": 1])
        let controller = makeController(probe)
        controller.query = "  hel lo \n"
        let found = await eventually { controller.hits.count == 1 }
        XCTAssertTrue(found)
        XCTAssertEqual(probe.queries, ["hel lo"], "blanks inside the query count, those around it do not")
        // The reader's own text is left as typed.
        XCTAssertEqual(controller.query, "  hel lo \n")
    }

    func testSearchingLastsFromTheQueryToTheResult() async {
        let probe = SearchProbe(counts: ["a": 2])
        probe.hold("a")
        let controller = makeController(probe)
        XCTAssertFalse(controller.isSearching)

        controller.query = "a"
        XCTAssertTrue(controller.isSearching, "from the moment there is something to look for, so no 'no matches' flashes up")
        let started = await eventually { probe.queries == ["a"] }
        XCTAssertTrue(started)
        XCTAssertTrue(controller.isSearching, "still, while the engine is at it")
        XCTAssertTrue(controller.hits.isEmpty)

        probe.release("a")
        let done = await eventually { !controller.isSearching }
        XCTAssertTrue(done)
        XCTAssertEqual(controller.hits.count, 2)
    }

    /// The engine's search cannot be called off, so a slow one for a query that has been typed over
    /// finishes anyway, and its result must not replace the newer one's.
    func testAResultThatArrivesAfterANewerQueryWasTypedIsIgnored() async {
        let probe = SearchProbe(counts: ["hello": 1, "zzz": 0])
        probe.hold("hello")
        let controller = makeController(probe)

        controller.query = "hello"
        let started = await eventually { probe.queries == ["hello"] }
        XCTAssertTrue(started, "the first search is inside the engine")
        controller.query = "zzz"
        let newer = await eventually { probe.finished == ["zzz"] && !controller.isSearching }
        XCTAssertTrue(newer, "the second search answered while the first was still going")
        XCTAssertTrue(controller.hits.isEmpty)

        probe.release("hello")
        let late = await eventually { probe.finished == ["zzz", "hello"] }
        XCTAssertTrue(late)
        await letTheMainActorCatchUp()
        XCTAssertTrue(controller.hits.isEmpty, "the late result is for a query that is gone")
        XCTAssertNil(controller.activeIndex)
        XCTAssertFalse(controller.isSearching)
    }

    func testAResultThatArrivesAfterTheQueryWasEmptiedIsIgnored() async {
        let probe = SearchProbe(counts: ["hello": 1])
        probe.hold("hello")
        let controller = makeController(probe)

        controller.query = "hello"
        let started = await eventually { probe.queries == ["hello"] }
        XCTAssertTrue(started)
        controller.query = ""
        XCTAssertFalse(controller.isSearching)

        probe.release("hello")
        let late = await eventually { probe.finished == ["hello"] }
        XCTAssertTrue(late)
        await letTheMainActorCatchUp()
        XCTAssertTrue(controller.hits.isEmpty)
        XCTAssertFalse(controller.isSearching)
    }

    func testEditingOnlyTheBlanksAroundTheQueryDoesNotSearchAgain() async {
        let probe = SearchProbe(counts: ["a": 3])
        let controller = makeController(probe)
        controller.query = "a"
        let found = await eventually { controller.hits.count == 3 }
        XCTAssertTrue(found)
        controller.next()
        XCTAssertEqual(controller.activeIndex, 1)

        controller.query = "a "
        controller.query = " a "
        XCTAssertFalse(controller.isSearching)
        await letTheMainActorCatchUp()
        XCTAssertEqual(probe.queries, ["a"], "the same words are not looked for twice")
        XCTAssertEqual(controller.activeIndex, 1, "and the reader keeps their place among the hits")
    }

    /// A search whose wait has ended is on its way to the engine, and typing again cannot call it back:
    /// cancelling a task whose sleep has already finished does nothing. So the search looks once more
    /// before it asks the engine. The wait is let begin, and then the main thread is held past its end:
    /// the timer fires and the search is lined up behind this test when the next key is typed.
    func testAQueryTypedOverAfterItsWaitEndedNeverReachesTheEngine() async {
        let probe = SearchProbe(counts: ["a": 1, "b": 1])
        let controller = SearchController(debounce: .milliseconds(300), search: probe.search)
        controller.query = "a"
        try? await Task.sleep(for: .milliseconds(20))
        Self.blockTheMainThread(for: 0.4)
        controller.query = "b"
        let found = await eventually { controller.hits.count == 1 }
        XCTAssertTrue(found)
        await letTheMainActorCatchUp()
        XCTAssertEqual(probe.queries, ["b"], "the engine is never asked for words that were typed over")
        XCTAssertFalse(controller.isSearching)
    }

    // MARK: Moving between the hits

    func testNextAndPreviousWrapAround() async {
        let probe = SearchProbe(counts: ["a": 3])
        let controller = makeController(probe)
        controller.query = "a"
        let found = await eventually { controller.hits.count == 3 }
        XCTAssertTrue(found)
        XCTAssertEqual(controller.activeIndex, 0)

        var seen: [Int?] = []
        for _ in 0..<4 {
            controller.next()
            seen.append(controller.activeIndex)
        }
        XCTAssertEqual(seen, [1, 2, 0, 1])

        seen = []
        for _ in 0..<4 {
            controller.previous()
            seen.append(controller.activeIndex)
        }
        XCTAssertEqual(seen, [0, 2, 1, 0])
        controller.previous()
        XCTAssertEqual(controller.activeIndex, 2, "before the first comes the last")
    }

    func testNextAndPreviousStartFromTheEndsWhenNoHitIsActive() async {
        let probe = SearchProbe(counts: ["a": 4])
        let controller = makeController(probe)
        controller.query = "a"
        let found = await eventually { controller.hits.count == 4 }
        XCTAssertTrue(found)

        controller.activeIndex = nil
        controller.next()
        XCTAssertEqual(controller.activeIndex, 0)
        controller.activeIndex = nil
        controller.previous()
        XCTAssertEqual(controller.activeIndex, 3)
        // An index that is not a hit is no place to start from either.
        controller.activeIndex = 40
        controller.next()
        XCTAssertEqual(controller.activeIndex, 0)
    }

    func testNextAndPreviousDoNothingWithoutHits() {
        let controller = makeController(SearchProbe())
        controller.next()
        XCTAssertNil(controller.activeIndex)
        controller.previous()
        XCTAssertNil(controller.activeIndex)
    }

    func testAFreshResultStartsAtTheFirstHit() async {
        let probe = SearchProbe(counts: ["a": 3, "ab": 2])
        let controller = makeController(probe)
        controller.query = "a"
        let first = await eventually { controller.hits.count == 3 }
        XCTAssertTrue(first)
        controller.next()
        controller.next()
        XCTAssertEqual(controller.activeIndex, 2)

        controller.query = "ab"
        let second = await eventually { controller.hits.count == 2 }
        XCTAssertTrue(second)
        XCTAssertEqual(controller.activeIndex, 0)
    }

    // MARK: Picking a hit

    /// A controller whose search finds `hits` for any query, and has found them.
    func makeController(finding hits: [SearchHit]) async -> SearchController {
        let controller = SearchController(debounce: .milliseconds(5)) { _ in hits }
        controller.query = "x"
        let found = await eventually { controller.hits.count == hits.count }
        XCTAssertTrue(found)
        return controller
    }

    func testSelectMakesAHitActiveAndNamesItsPageAndBox() async {
        let controller = await makeController(finding: [
            SearchProbe.hit(page: 0, index: 0),
            SearchProbe.hit(page: 4, index: 1, rects: [Rect(x: 72, y: 100, width: 30, height: 12)]),
            SearchProbe.hit(page: 7, index: 2),
        ])
        XCTAssertEqual(controller.activeIndex, 0)
        let target = controller.select(1)
        XCTAssertEqual(controller.activeIndex, 1)
        // The box with a few points round it, so the hit is not flush with the edge of the view.
        XCTAssertEqual(target, PageRect(page: 4, rect: CGRect(x: 66, y: 94, width: 42, height: 24)))
        XCTAssertEqual(controller.activeHit, controller.hits[1])
        XCTAssertEqual(controller.activeHighlight?.page, 4)
    }

    /// A match over a line break has a box on each line: the box to bring into view holds them all.
    func testSelectNamesTheUnionOfAHitsBoxes() async {
        let controller = await makeController(finding: [
            SearchProbe.hit(page: 2, index: 0, rects: [Rect(x: 400, y: 100, width: 40, height: 12),
                                                       Rect(x: 72, y: 114, width: 20, height: 12)]),
        ])
        // (72, 100) to (440, 126), and six points more all round.
        XCTAssertEqual(controller.select(0), PageRect(page: 2, rect: CGRect(x: 66, y: 94, width: 380, height: 38)))
    }

    func testSelectOfAnIndexThatIsNotAHitChangesNothing() async {
        let controller = await makeController(finding: [SearchProbe.hit(page: 0, index: 0), SearchProbe.hit(page: 1, index: 1)])
        controller.select(1)
        XCTAssertEqual(controller.activeIndex, 1)
        XCTAssertNil(controller.select(2))
        XCTAssertNil(controller.select(-1))
        XCTAssertNil(controller.select(Int.max))
        XCTAssertEqual(controller.activeIndex, 1, "the active hit stays the active hit")
    }

    func testSelectWithoutAnyHitDoesNothing() {
        let controller = makeController(SearchProbe())
        XCTAssertNil(controller.select(0))
        XCTAssertNil(controller.activeIndex)
    }

    /// A hit with no box that can be drawn still has a page to go to.
    func testSelectOfAHitWithNoBoxStillNamesItsPage() async {
        let controller = await makeController(finding: [
            SearchProbe.hit(page: 3, index: 0, rects: [Rect(x: 10, y: 10, width: 0, height: 5)]),
            SearchProbe.hit(page: 5, index: 1, rects: []),
        ])
        XCTAssertEqual(controller.select(0), PageRect(page: 3, rect: .null))
        XCTAssertEqual(controller.select(1), PageRect(page: 5, rect: .null))
        XCTAssertEqual(controller.activeIndex, 1)
    }

    /// Next and previous pick a hit like a tap does, and say where to take the viewer.
    func testNextAndPreviousNameWhereToTakeTheViewer() async {
        let controller = await makeController(finding: [
            SearchProbe.hit(page: 0, index: 0, rects: [Rect(x: 10, y: 20, width: 30, height: 10)]),
            SearchProbe.hit(page: 2, index: 1, rects: [Rect(x: 50, y: 60, width: 30, height: 10)]),
        ])
        XCTAssertEqual(controller.next(), PageRect(page: 2, rect: CGRect(x: 44, y: 54, width: 42, height: 22)))
        XCTAssertEqual(controller.activeIndex, 1)
        XCTAssertEqual(controller.next(), PageRect(page: 0, rect: CGRect(x: 4, y: 14, width: 42, height: 22)), "round to the first")
        XCTAssertEqual(controller.previous(), PageRect(page: 2, rect: CGRect(x: 44, y: 54, width: 42, height: 22)), "back round to the last")
        XCTAssertEqual(controller.activeIndex, 1)

        let none = makeController(SearchProbe())
        XCTAssertNil(none.next())
        XCTAssertNil(none.previous())
    }

    // MARK: Truncation

    func testTruncatedExactlyWhenTheHitsFillTheLimit() async {
        let limit = Int(searchHitLimit())
        XCTAssertEqual(limit, 1_000, "the note says 1,000, and so does the engine")
        let probe = SearchProbe(counts: ["full": limit, "almost": limit - 1])
        let controller = makeController(probe)

        controller.query = "almost"
        let almost = await eventually { controller.hits.count == limit - 1 }
        XCTAssertTrue(almost)
        XCTAssertFalse(controller.isTruncated)

        controller.query = "full"
        let full = await eventually { controller.hits.count == limit }
        XCTAssertTrue(full)
        XCTAssertTrue(controller.isTruncated, "a result of exactly the limit means there may be more")
    }

    // MARK: What the viewer draws

    func testTheActiveHitAndItsBoxesFollowTheActiveIndex() async {
        let probe = SearchProbe(counts: ["a": 3])
        let controller = makeController(probe)
        XCTAssertNil(controller.activeHit)
        XCTAssertNil(controller.activeHighlight)
        XCTAssertTrue(controller.highlightsByPage.isEmpty)

        controller.query = "a"
        let found = await eventually { controller.hits.count == 3 }
        XCTAssertTrue(found)
        XCTAssertEqual(controller.activeHit, controller.hits[0])
        XCTAssertEqual(controller.activeHighlight, ActiveHighlight(page: 0, rects: SearchController.rects(of: controller.hits[0])))
        controller.next()
        controller.next()
        XCTAssertEqual(controller.activeHit, controller.hits[2])
        XCTAssertEqual(controller.activeHighlight, ActiveHighlight(page: 1, rects: SearchController.rects(of: controller.hits[2])))
        XCTAssertEqual(controller.highlightsByPage, SearchController.highlights(of: controller.hits))
        XCTAssertEqual(Set(controller.highlightsByPage.keys), [0, 1])

        controller.activeIndex = 7
        XCTAssertNil(controller.activeHit, "an index that is not a hit is no active hit")
        XCTAssertNil(controller.activeHighlight)

        controller.query = ""
        XCTAssertTrue(controller.highlightsByPage.isEmpty, "no hits, nothing to highlight")
        XCTAssertNil(controller.activeHighlight)
    }

    /// A hit's boxes in PDF points, as the viewer is given them: the bridge's `Rect`s as `CGRect`s.
    func testAHitsBoxesAreCGRectsInTheSameUnits() {
        let hit = SearchProbe.hit(page: 4, index: 0, rects: [Rect(x: 72, y: 100.5, width: 30, height: 12),
                                                            Rect(x: 72, y: 114.5, width: 18, height: 12)])
        XCTAssertEqual(SearchController.rects(of: hit), [CGRect(x: 72, y: 100.5, width: 30, height: 12),
                                                         CGRect(x: 72, y: 114.5, width: 18, height: 12)])
    }

    func testHighlightsAreGroupedByPageInReadingOrder() {
        let first = SearchProbe.hit(page: 0, index: 0, rects: [Rect(x: 72, y: 100, width: 30, height: 12)])
        // A match that runs over a line break has a box on each line.
        let broken = SearchProbe.hit(page: 0, index: 1, rects: [Rect(x: 400, y: 100, width: 40, height: 12),
                                                                Rect(x: 72, y: 114, width: 20, height: 12)])
        let later = SearchProbe.hit(page: 3, index: 2, rects: [Rect(x: 1, y: 2, width: 3, height: 4)])
        XCTAssertEqual(SearchController.highlights(of: [first, broken, later]), [
            0: [CGRect(x: 72, y: 100, width: 30, height: 12), CGRect(x: 400, y: 100, width: 40, height: 12),
                CGRect(x: 72, y: 114, width: 20, height: 12)],
            3: [CGRect(x: 1, y: 2, width: 3, height: 4)],
        ])
        XCTAssertEqual(SearchController.highlights(of: []), [:])
    }

    func testBoxesThatCannotBeDrawnAreLeftOut() {
        let good = Rect(x: 10, y: 10, width: 5, height: 5)
        let hit = SearchProbe.hit(page: 2, index: 0, rects: [
            good,
            Rect(x: 10, y: 10, width: 0, height: 5),         // no width
            Rect(x: 10, y: 10, width: 5, height: -1),        // upside down
            Rect(x: .nan, y: 10, width: 5, height: 5),
            Rect(x: 10, y: 10, width: .infinity, height: 5),
        ])
        XCTAssertEqual(SearchController.rects(of: hit), [CGRect(x: 10, y: 10, width: 5, height: 5)])
        XCTAssertEqual(SearchController.highlights(of: [hit]), [2: [CGRect(x: 10, y: 10, width: 5, height: 5)]])

        // A hit with nothing to draw does not put its page in the result.
        let empty = SearchProbe.hit(page: 5, index: 1, rects: [])
        XCTAssertEqual(SearchController.highlights(of: [empty]), [:])
    }
}

/// A stand-in for the engine's search: answers each query with as many hits as it was told to,
/// remembers what it was asked and on which thread, and can keep a query inside the call until it
/// is released, as a slow search would. Hit `n` is on page `n / 2`, with a box of its own.
final class SearchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let counts: [String: Int]
    private var holds: [String: DispatchSemaphore] = [:]
    private var _queries: [String] = []
    private var _finished: [String] = []
    private var _onMainThread = 0

    /// `counts` is how many hits each query finds; a query that is not in it finds none.
    init(counts: [String: Int] = [:]) {
        self.counts = counts
    }

    /// Every query the engine was asked, in order, from the moment it was asked.
    var queries: [String] { lock.withLock { _queries } }
    /// Every query the engine has answered, in order.
    var finished: [String] { lock.withLock { _finished } }
    var askedOnTheMainThread: Int { lock.withLock { _onMainThread } }

    /// Makes the engine keep `query` inside its call until `release(_:)`.
    func hold(_ query: String) {
        lock.withLock { holds[query] = DispatchSemaphore(value: 0) }
    }

    func release(_ query: String) {
        lock.withLock { holds[query] }?.signal()
    }

    var search: SearchController.Search {
        { [self] query in answer(query) }
    }

    private func answer(_ query: String) -> [SearchHit] {
        let (count, gate) = lock.withLock { () -> (Int, DispatchSemaphore?) in
            _queries.append(query)
            if Thread.isMainThread { _onMainThread += 1 }
            return (counts[query] ?? 0, holds[query])
        }
        gate?.wait()
        lock.withLock { _finished.append(query) }
        return (0..<count).map { Self.hit(page: $0 / 2, index: $0) }
    }

    /// A hit on `page`, number `index` of its search, whose box is at `y == 10 * index` by default.
    static func hit(page: Int, index: Int, rects: [Rect]? = nil) -> SearchHit {
        SearchHit(page: UInt32(page), start: UInt32(index * 10), end: UInt32(index * 10 + 5),
                  rects: rects ?? [Rect(x: 72, y: Double(index) * 10, width: 30, height: 8)],
                  snippet: "hit \(index)")
    }
}
