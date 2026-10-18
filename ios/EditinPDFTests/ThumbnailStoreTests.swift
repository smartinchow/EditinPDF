import EditinPDFCore
import UIKit
import XCTest
@testable import EditinPDF

// The store is main-actor isolated (SwiftUI reads it), so the tests are too. They wait by polling on
// the main actor: the store publishes each thumbnail there, so the waiting has to yield to let it.
@MainActor
final class ThumbnailStoreTests: XCTestCase {
    func openFixture() throws -> (PdfDocument, [PageInfo]) {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "hello", withExtension: "pdf"))
        let document = try PdfDocument.open(bytes: Data(contentsOf: url), password: nil)
        return (document, (0..<document.pageCount()).compactMap { document.pageInfo(page: $0) })
    }

    /// Polls until `condition` holds, for at most `timeout` seconds; false if it never did. (The
    /// condition is escaping because the compiler refuses a non-escaping one across the awaits.)
    func eventually(timeout: Double = 5, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    // MARK: On the real engine

    func testPrefetchRendersAThumbnailOfTheTargetWidth() async throws {
        let (document, pages) = try openFixture()
        let store = ThumbnailStore(document: document, pages: pages, targetWidth: 120, displayScale: 2)
        XCTAssertNil(store.image(for: 0), "nothing is drawn until it is asked for")

        store.prefetch(0..<1)
        let arrived = await eventually { store.image(for: 0) != nil }
        XCTAssertTrue(arrived, "no thumbnail within 5 seconds")
        let image = try XCTUnwrap(store.image(for: 0))

        // 120 points wide, drawn with 2 pixels to the point, in the page's own shape.
        XCTAssertEqual(image.size.width, 120, accuracy: 1)
        XCTAssertEqual(image.scale, 2)
        let page = try XCTUnwrap(pages.first)
        XCTAssertEqual(image.size.height / image.size.width, page.heightPt / page.widthPt, accuracy: 0.02)

        // It is the page: opaque paper at the corner and some ink on it.
        let pixels = try TileRendererTests.pixels(of: XCTUnwrap(image.cgImage))
        XCTAssertEqual(Array(pixels.prefix(4)), [255, 255, 255, 255])
        XCTAssertTrue(stride(from: 0, to: pixels.count, by: 4).contains { pixels[$0] < 128 }, "the page's text should show")
    }

    /// A page the document does not have does nothing, and never crashes.
    func testAPageTheDocumentDoesNotHaveIsIgnored() async throws {
        let (document, pages) = try openFixture()
        XCTAssertEqual(pages.count, 1)
        let store = ThumbnailStore(document: document, pages: pages, targetWidth: 120, displayScale: 2)

        store.prefetch(5..<6)
        store.prefetch(-3..<0)
        store.prefetch((Int.max - 1)..<Int.max)
        for page in [5, -1, 0] { XCTAssertNil(store.image(for: page)) }

        // The store is still in working order afterwards, and a range that only partly overlaps the
        // document draws the part that does.
        store.prefetch(-2..<10)
        let arrived = await eventually { store.image(for: 0) != nil }
        XCTAssertTrue(arrived)
        XCTAssertNil(store.image(for: 1))
    }

    // MARK: The worker, against a stand-in for the engine

    func testPagesNotInTheDocumentAreNeverAskedFor() async {
        let probe = RenderProbe()
        let store = makeStore(probe, pages: 2)
        store.prefetch(2..<4)
        store.prefetch(-5..<(-1))
        store.prefetch(-1..<1)       // only page 0 of this one is real
        store.prefetch(1..<Int.max)  // and page 1 of this one
        let arrived = await eventually { store.image(for: 0) != nil && store.image(for: 1) != nil }
        XCTAssertTrue(arrived)
        XCTAssertEqual(probe.requested, [0, 1])
    }

    func testPagesAreDrawnOneAtATimeInTheOrderAskedFor() async {
        let probe = RenderProbe(drawTime: 0.005)
        let store = makeStore(probe, pages: 8)
        store.prefetch(0..<4)
        store.prefetch(6..<8)
        store.prefetch(4..<6)
        let arrived = await eventually { (0..<8).allSatisfy { store.image(for: $0) != nil } }
        XCTAssertTrue(arrived)
        XCTAssertEqual(probe.requested, [0, 1, 2, 3, 6, 7, 4, 5])
        XCTAssertEqual(probe.mostDrawnAtOnce, 1, "thumbnails compete with the page tiles for the engine's two renderers: one at a time")
    }

    func testDrawingHappensOffTheMainThread() async {
        let probe = RenderProbe()
        let store = makeStore(probe, pages: 2)
        store.prefetch(0..<2)
        let arrived = await eventually { store.image(for: 1) != nil }
        XCTAssertTrue(arrived)
        XCTAssertEqual(probe.drawnOnMainThread, 0)
    }

    func testAPageAlreadyCachedOrQueuedIsNotAskedForAgain() async {
        let probe = RenderProbe()
        probe.holdFirstDraw()
        addTeardownBlock { probe.release() }
        let store = makeStore(probe, pages: 4)

        store.prefetch(0..<3)  // 0 is being drawn (held); 1 and 2 wait behind it
        let started = await eventually { probe.requested == [0] }
        XCTAssertTrue(started)
        store.prefetch(0..<3)  // being drawn or queued: nothing to do
        store.prefetch(1..<2)
        probe.release()
        let drawn = await eventually { (0..<3).allSatisfy { store.image(for: $0) != nil } }
        XCTAssertTrue(drawn)

        store.prefetch(0..<3)  // cached now: nothing to do
        store.prefetch(3..<4)  // a marker: anything wrongly queued above would be drawn before it
        let marker = await eventually { store.image(for: 3) != nil }
        XCTAssertTrue(marker)
        XCTAssertEqual(probe.requested, [0, 1, 2, 3])
    }

    func testAPageThatCouldNotBeDrawnStaysEmptyAndTheQueueGoesOn() async {
        let probe = RenderProbe()
        probe.failing = [1]    // the engine throws
        probe.garbled = [3]    // the engine answers with pixels that do not fill the size
        let store = makeStore(probe, pages: 5)
        store.prefetch(0..<5)
        let arrived = await eventually { [0, 2, 4].allSatisfy { store.image(for: $0) != nil } }
        XCTAssertTrue(arrived)
        XCTAssertNil(store.image(for: 1))
        XCTAssertNil(store.image(for: 3))
        XCTAssertEqual(probe.requested, [0, 1, 2, 3, 4])

        // A failure is not remembered: asking again tries again (the cell scrolled into view again).
        probe.failing = []
        store.prefetch(1..<2)
        let retried = await eventually { store.image(for: 1) != nil }
        XCTAssertTrue(retried)
    }

    func testCancelledPagesThatHaveNotStartedAreDropped() async {
        let probe = RenderProbe()
        probe.holdFirstDraw()
        addTeardownBlock { probe.release() }
        let store = makeStore(probe, pages: 6)

        store.prefetch(0..<5)
        let started = await eventually { probe.requested == [0] }
        XCTAssertTrue(started)
        // 1 to 3 scrolled away before their turn; 0 is already being drawn and is finished.
        store.cancelPrefetch(1..<4)
        store.cancelPrefetch(0..<1)
        probe.release()
        let arrived = await eventually { store.image(for: 4) != nil }
        XCTAssertTrue(arrived)
        XCTAssertNotNil(store.image(for: 0))
        XCTAssertEqual(probe.requested, [0, 4])
        for page in 1...3 { XCTAssertNil(store.image(for: page)) }

        // Cancelling is not forgetting that a page is wanted for good: asking again draws it.
        store.prefetch(2..<3)
        let again = await eventually { store.image(for: 2) != nil }
        XCTAssertTrue(again)
        // Cancelling pages that are not queued, or not there, does nothing.
        store.cancelPrefetch(2..<3)
        store.cancelPrefetch(-4..<100)
        XCTAssertNotNil(store.image(for: 2), "a drawn thumbnail stays")
    }

    func testPrefetchAroundAPageDrawsThatPageFirstThenTheNearest() async {
        let probe = RenderProbe()
        let store = makeStore(probe, pages: 12)
        store.prefetch(around: 5, radius: 3)
        let arrived = await eventually { (2...8).allSatisfy { store.image(for: $0) != nil } }
        XCTAssertTrue(arrived)
        // The page, the one after it, the one before it, two after, two before, ...
        XCTAssertEqual(probe.requested, [5, 6, 4, 7, 3, 8, 2])
    }

    func testPrefetchAroundStopsAtTheEndsOfTheDocument() async {
        let probe = RenderProbe()
        let store = makeStore(probe, pages: 4)
        store.prefetch(around: 0, radius: 2)
        let first = await eventually { (0...2).allSatisfy { store.image(for: $0) != nil } }
        XCTAssertTrue(first)
        XCTAssertEqual(probe.requested, [0, 1, 2])

        store.prefetch(around: 3, radius: 100)  // more than the document has: no more than its pages
        let last = await eventually { store.image(for: 3) != nil }
        XCTAssertTrue(last)
        XCTAssertEqual(probe.requested, [0, 1, 2, 3])
    }

    func testPrefetchAroundJustThePageWhenTheRadiusIsNone() async {
        let probe = RenderProbe()
        let store = makeStore(probe, pages: 4)
        store.prefetch(around: 2, radius: 0)
        store.prefetch(around: 2, radius: -3)
        let arrived = await eventually { store.image(for: 2) != nil }
        XCTAssertTrue(arrived)
        XCTAssertEqual(probe.requested, [2])
    }

    func testPrefetchAroundAPageThatIsNotThereDoesNothing() async {
        let probe = RenderProbe()
        let store = makeStore(probe, pages: 4)
        store.prefetch(around: 9, radius: 3)
        store.prefetch(around: -1, radius: 3)
        store.prefetch(around: Int.max, radius: Int.max)
        store.prefetch(around: 0, radius: 0)  // a marker: nothing was queued before it
        let arrived = await eventually { store.image(for: 0) != nil }
        XCTAssertTrue(arrived)
        XCTAssertEqual(probe.requested, [0])
    }

    func testTheImageIsTargetWidthPointsWideAtAnyDisplayScale() async throws {
        for displayScale: CGFloat in [1, 2, 3] {
            let probe = RenderProbe(pageSize: CGSize(width: 200, height: 300))
            let store = ThumbnailStore(pages: [Self.page(0, width: 200, height: 300)], targetWidth: 100,
                                       displayScale: displayScale, render: probe.render)
            store.prefetch(0..<1)
            let arrived = await eventually { store.image(for: 0) != nil }
            XCTAssertTrue(arrived)
            // Device pixels per PDF point: the width wanted in pixels over the page's width.
            XCTAssertEqual(probe.scales, [100 * Double(displayScale) / 200])
            let image = try XCTUnwrap(store.image(for: 0))
            XCTAssertEqual(image.scale, displayScale)
            XCTAssertEqual(image.size.width, 100, accuracy: 0.01)
            XCTAssertEqual(image.size.height, 150, accuracy: 0.01)
        }
    }

    func testEachPageIsDrawnToItsOwnWidth() async {
        let probe = RenderProbe()
        let pages = [Self.page(0, width: 612, height: 792), Self.page(1, width: 792, height: 612), Self.page(2, width: 300, height: 400)]
        let store = ThumbnailStore(pages: pages, targetWidth: 120, displayScale: 2, render: probe.render)
        store.prefetch(0..<3)
        let arrived = await eventually { store.image(for: 2) != nil }
        XCTAssertTrue(arrived)
        XCTAssertEqual(probe.scales, [240.0 / 612, 240.0 / 792, 240.0 / 300])
    }

    func testAVeryTallPageIsDrawnNoTallerThanFourTimesTheTargetWidth() async throws {
        // By its width alone a 30 x 600 point page (1:20) would be drawn at 12 pixels to the point:
        // 360 x 7,200 pixels, about 10 MB, for a cell that shows it no taller than 1:4.
        let probe = RenderProbe(pageSize: CGSize(width: 30, height: 600))
        let pages = [
            Self.page(0, width: 30, height: 600),   // 1:20
            Self.page(1, width: 100, height: 400),  // 1:4 exactly: the width and the height agree
            Self.page(2, width: 612, height: 792),  // an ordinary page: by its width, as before
            Self.page(3, width: 600, height: 0),    // no height to go by: by its width
            Self.page(4, width: 600, height: .nan),
        ]
        let store = ThumbnailStore(pages: pages, targetWidth: 120, displayScale: 3, render: probe.render)
        store.prefetch(0..<5)
        let arrived = await eventually { (0..<5).allSatisfy { store.image(for: $0) != nil } }
        XCTAssertTrue(arrived)
        // 4 x 120 points tall at 3 pixels to the point is 1,440 pixels: 2.4 to the PDF point.
        let tallPageScale: Double = 1440.0 / 600
        let expected: [Double] = [tallPageScale, 360.0 / 100, 360.0 / 612, 360.0 / 600, 360.0 / 600]
        XCTAssertEqual(probe.scales, expected)
        // The tall page's picture is 24 x 480 points: no taller than four target widths.
        let tall = try XCTUnwrap(store.image(for: 0))
        XCTAssertEqual(tall.size.height, 480, accuracy: 0.01)
        XCTAssertEqual(tall.size.width, 24, accuracy: 0.01)
    }

    func testAPageWithNoUsableWidthIsLeftEmptyWithoutAskingTheEngine() async {
        let probe = RenderProbe()
        let pages = [Self.page(0, width: 0, height: 792), Self.page(1, width: .nan, height: 792), Self.page(2, width: 612, height: 792)]
        let store = ThumbnailStore(pages: pages, targetWidth: 120, displayScale: 2, render: probe.render)
        store.prefetch(0..<3)
        let arrived = await eventually { store.image(for: 2) != nil }
        XCTAssertTrue(arrived)
        XCTAssertNil(store.image(for: 0))
        XCTAssertNil(store.image(for: 1))
        XCTAssertEqual(probe.requested, [2])
    }

    // MARK: SwiftUI

    func testPublishingAThumbnailTellsWhatReadAnEmptySlot() async {
        let probe = RenderProbe()
        let store = makeStore(probe, pages: 1)
        let told = expectation(description: "the reader of the empty slot is told")
        // What a SwiftUI body does: ask for the thumbnail, find none, and be told when one arrives.
        withObservationTracking {
            XCTAssertNil(store.image(for: 0))
        } onChange: {
            told.fulfill()
        }
        store.prefetch(0..<1)
        await fulfillment(of: [told], timeout: 5)
        XCTAssertNotNil(store.image(for: 0))
    }

    // MARK: Lifetime

    func testTheStoreIsFreedWhileWorkIsStillQueued() async {
        let probe = RenderProbe()
        probe.holdFirstDraw()
        addTeardownBlock { probe.release() }
        weak var weakStore: ThumbnailStore?
        do {
            let store = makeStore(probe, pages: 4)
            weakStore = store
            store.prefetch(0..<4)
            let started = await eventually { probe.requested == [0] }
            XCTAssertTrue(started)
        }
        // The draw in flight holds the engine's document and nothing of the store, and the queue
        // is the store's own: letting go of the store ends the work.
        XCTAssertNil(weakStore)
        probe.release()
        let finished = await eventually { probe.finishedDraws == 1 }
        XCTAssertTrue(finished)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(probe.requested, [0], "pages queued behind the one in flight are not drawn for nobody")
    }

    // MARK: Following the document's changes

    func testReloadForANewRevisionDropsOldPictures() async throws {
        let probe = RenderProbe()
        let store = ThumbnailStore(pages: [Self.page(0, width: 612, height: 792)], render: probe.render)
        XCTAssertEqual(store.revision, 0)
        store.prefetch(0..<1)
        let arrived = await eventually { store.image(for: 0) != nil }
        XCTAssertTrue(arrived)

        store.reload(pages: [Self.page(0, width: 792, height: 612)], revision: 1)
        XCTAssertNil(store.image(for: 0))
        XCTAssertEqual(store.revision, 1)

        // Asked for again, the page is drawn afresh, to its new width.
        store.prefetch(0..<1)
        let redrawn = await eventually { store.image(for: 0) != nil }
        XCTAssertTrue(redrawn)
        XCTAssertEqual(probe.requested, [0, 0])
        XCTAssertEqual(probe.scales.last ?? 0, 240.0 / 792.0, accuracy: 0.0001)
    }

    /// A picture that was being drawn when the document changed shows the page as it was: it is
    /// thrown away, and the next page waiting is the new revision's.
    func testAPictureDrawnForAnOlderRevisionIsThrownAway() async {
        let probe = RenderProbe()
        probe.holdFirstDraw()
        let store = makeStore(probe, pages: 3)
        store.prefetch(0..<3)
        let started = await eventually { probe.requested == [0] }
        XCTAssertTrue(started)

        store.reload(pages: (0..<2).map { Self.page($0, width: 612, height: 792) }, revision: 4)
        probe.release()
        let finished = await eventually { probe.finishedDraws == 1 }
        XCTAssertTrue(finished)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(store.image(for: 0), "the old revision's picture is not kept")
        XCTAssertEqual(probe.requested, [0], "the pages waiting were the old revision's, and were dropped")

        // The page being drawn is not counted as queued any more: it can be asked for again at once.
        store.prefetch(0..<2)
        let both = await eventually { store.image(for: 0) != nil && store.image(for: 1) != nil }
        XCTAssertTrue(both)
        store.prefetch(2..<3)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(store.image(for: 2), "the document has two pages now")
    }

    /// A reload for the revision the store already has (or an older one) changes nothing.
    func testReloadForTheSameRevisionKeepsThePictures() async {
        let probe = RenderProbe()
        let store = makeStore(probe, pages: 1)
        store.reload(pages: [Self.page(0, width: 612, height: 792)], revision: 2)
        store.prefetch(0..<1)
        let arrived = await eventually { store.image(for: 0) != nil }
        XCTAssertTrue(arrived)
        store.reload(pages: [Self.page(0, width: 612, height: 792)], revision: 2)
        store.reload(pages: [Self.page(0, width: 612, height: 792)], revision: 1)
        XCTAssertNotNil(store.image(for: 0))
        XCTAssertEqual(store.revision, 2)
    }

    /// A view that read a picture is told when a reload takes it away.
    func testReloadTellsWhatReadAPicture() async {
        let probe = RenderProbe()
        let store = makeStore(probe, pages: 1)
        store.prefetch(0..<1)
        let arrived = await eventually { store.image(for: 0) != nil }
        XCTAssertTrue(arrived)
        let told = expectation(description: "the reader of the picture is told")
        withObservationTracking {
            XCTAssertNotNil(store.image(for: 0))
        } onChange: {
            told.fulfill()
        }
        store.reload(pages: [Self.page(0, width: 612, height: 792)], revision: 1)
        await fulfillment(of: [told], timeout: 1)
    }

    // MARK: Helpers

    static func page(_ index: Int, width: Double, height: Double) -> PageInfo {
        PageInfo(index: UInt32(index), widthPt: width, heightPt: height, rotationDegrees: 0, label: nil)
    }

    /// A store over `pages` Letter-sized pages, drawn by `probe` at 120 points wide, 2 pixels to the point.
    func makeStore(_ probe: RenderProbe, pages count: Int) -> ThumbnailStore {
        ThumbnailStore(pages: (0..<count).map { Self.page($0, width: 612, height: 792) },
                       targetWidth: 120, displayScale: 2, render: probe.render)
    }
}

/// Stands in for the engine. It records which pages were asked for (and at what scale), how many
/// were being drawn at the same moment and on which thread, and it can fail a page, garble one, or
/// hold the first draw until `release()`. Its lock is why it can be `@unchecked Sendable`.
final class RenderProbe: @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let drawTime: Double
    private let pageSize: CGSize
    private var held = false
    private var _requested: [Int] = []
    private var _scales: [Double] = []
    private var _failing: Set<Int> = []
    private var _garbled: Set<Int> = []
    private var running = 0
    private var _mostDrawnAtOnce = 0
    private var _drawnOnMainThread = 0
    private var _finishedDraws = 0

    /// `pageSize` is the size in points of every page it draws; `drawTime` how long a draw takes, in seconds.
    init(drawTime: Double = 0, pageSize: CGSize = CGSize(width: 612, height: 792)) {
        self.drawTime = drawTime
        self.pageSize = pageSize
    }

    var requested: [Int] { lock.withLock { _requested } }
    var scales: [Double] { lock.withLock { _scales } }
    var mostDrawnAtOnce: Int { lock.withLock { _mostDrawnAtOnce } }
    var drawnOnMainThread: Int { lock.withLock { _drawnOnMainThread } }
    var finishedDraws: Int { lock.withLock { _finishedDraws } }
    var failing: Set<Int> {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }
    var garbled: Set<Int> {
        get { lock.withLock { _garbled } }
        set { lock.withLock { _garbled = newValue } }
    }

    /// Makes the next draw wait inside the engine until `release()`.
    func holdFirstDraw() { lock.withLock { held = true } }
    func release() { gate.signal() }

    var render: ThumbnailStore.Render {
        { [self] page, scale in try draw(page: page, scale: scale) }
    }

    private func draw(page: Int, scale: Double) throws -> RenderedTile {
        let (shouldHold, fails, garbles) = lock.withLock { () -> (Bool, Bool, Bool) in
            _requested.append(page)
            _scales.append(scale)
            running += 1
            _mostDrawnAtOnce = max(_mostDrawnAtOnce, running)
            if Thread.isMainThread { _drawnOnMainThread += 1 }
            defer { held = false }
            return (held, _failing.contains(page), _garbled.contains(page))
        }
        if shouldHold { gate.wait() }
        if drawTime > 0 { Thread.sleep(forTimeInterval: drawTime) }
        lock.withLock {
            running -= 1
            _finishedDraws += 1
        }
        if fails { throw Failure() }
        // The whole page at `scale` pixels to the point.
        let width = max(1, Int((pageSize.width * scale).rounded()))
        let height = max(1, Int((pageSize.height * scale).rounded()))
        return RenderedTile(width: UInt32(width), height: UInt32(height),
                            rgba: Data(repeating: 255, count: garbles ? 7 : width * height * 4))
    }
}

