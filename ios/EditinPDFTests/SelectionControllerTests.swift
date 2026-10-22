import EditinPDFCore
import UIKit
import XCTest
@testable import EditinPDF

// The controller is main-actor isolated (SwiftUI reads it), so the tests are too. Its answers come
// from a worker off the main actor, so a test either waits for what it expects to show up
// (`eventually`, for at most 3 seconds) or, to know that nothing more is coming, waits for the
// controller to be done with everything it was asked (`waitUntilSettled`). Where a test needs to
// know what the engine was asked, and on which thread, or to make it slow, `SelectionProbe` stands
// between the controller and the real document.
@MainActor
final class SelectionControllerTests: XCTestCase {
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

    /// The centre of glyph `index` of `page`, in PDF points: the point a finger would be on.
    func centre(of index: Int, on page: Int = 0, in document: PdfDocument) throws -> CGPoint {
        let glyphs = try document.pageText(page: UInt32(page)).glyphs
        let glyph = try XCTUnwrap(glyphs.indices.contains(index) ? glyphs[index] : nil, "glyph \(index) of page \(page)")
        return CGPoint(x: glyph.rect.x + glyph.rect.width / 2, y: glyph.rect.y + glyph.rect.height / 2)
    }

    func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: On the real engine: "Hello world" is 11 glyphs, the space among them

    /// The brief's test, part one: the word under the finger is selected.
    func testALongPressOnAWordSelectsIt() async throws {
        let document = try openFixture()
        let controller = SelectionController(document: document)
        XCTAssertNil(controller.selection)
        XCTAssertEqual(controller.text, "")

        controller.beginWord(page: 0, at: try centre(of: 0, in: document))
        let found = await eventually { controller.text == "Hello" }
        XCTAssertTrue(found, "no word within 3 seconds: \(controller.text)")
        let selection = try XCTUnwrap(controller.selection)
        XCTAssertEqual(selection.page, 0)
        XCTAssertEqual(selection.start, 0)
        XCTAssertEqual(selection.end, 5)
        XCTAssertFalse(selection.rects.isEmpty, "the boxes to highlight come with it")
    }

    /// Part two: dragging the end onto the last glyph takes in the whole line.
    func testExtendingToTheLastGlyphSelectsTheWholeLine() async throws {
        let document = try openFixture()
        let controller = SelectionController(document: document)
        controller.beginWord(page: 0, at: try centre(of: 0, in: document))
        let began = await eventually { controller.text == "Hello" }
        XCTAssertTrue(began)

        controller.extend(to: try centre(of: 10, in: document))
        let extended = await eventually { self.trimmed(controller.text) == "Hello world" }
        XCTAssertTrue(extended, "the text is \(controller.text)")
        let selection = try XCTUnwrap(controller.selection)
        XCTAssertEqual(selection.start, 0, "the end moved, the start did not")
        XCTAssertEqual(selection.end, 11)
    }

    /// Part three: nothing is selected after `clear()`, and at once.
    func testClearEmptiesTheSelection() async throws {
        let document = try openFixture()
        let controller = SelectionController(document: document)
        controller.beginWord(page: 0, at: try centre(of: 0, in: document))
        let began = await eventually { controller.selection != nil }
        XCTAssertTrue(began)

        controller.clear()
        XCTAssertNil(controller.selection, "cleared at once, not when the engine has been asked")
        XCTAssertEqual(controller.text, "")
        await controller.waitUntilSettled()
        XCTAssertNil(controller.selection)
    }

    func testBeginningOnEmptyPaperSelectsNothing() async throws {
        let document = try openFixture()
        let info = try XCTUnwrap(document.pageInfo(page: 0))
        let controller = SelectionController(document: document)
        controller.beginWord(page: 0, at: CGPoint(x: info.widthPt - 10, y: info.heightPt - 10))
        await controller.waitUntilSettled()
        XCTAssertNil(controller.selection, "no text there")
    }

    /// Nothing under the finger is nothing to select, not a reason to lose what is selected.
    func testBeginningOnEmptyPaperKeepsWhatWasSelected() async throws {
        let document = try openFixture()
        let info = try XCTUnwrap(document.pageInfo(page: 0))
        let controller = SelectionController(document: document)
        controller.beginWord(page: 0, at: try centre(of: 0, in: document))
        let began = await eventually { controller.text == "Hello" }
        XCTAssertTrue(began)

        controller.beginWord(page: 0, at: CGPoint(x: info.widthPt - 10, y: info.heightPt - 10))
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.text, "Hello")
    }

    func testBeginningOnAPageTheDocumentLacksSelectsNothing() async throws {
        let controller = SelectionController(document: try openFixture())
        controller.beginWord(page: 7, at: CGPoint(x: 80, y: 80))
        controller.beginWord(page: -1, at: CGPoint(x: 80, y: 80))
        await controller.waitUntilSettled()
        XCTAssertNil(controller.selection)
    }

    func testExtendingBeforeBeginningIsANoOp() async throws {
        let document = try openFixture()
        let controller = SelectionController(document: document)
        controller.extend(to: try centre(of: 10, in: document))
        await controller.waitUntilSettled()
        XCTAssertNil(controller.selection, "there is nothing to extend")

        controller.beginExtending(.start)
        controller.extend(to: try centre(of: 0, in: document))
        await controller.waitUntilSettled()
        XCTAssertNil(controller.selection, "nor to drag a handle of")
    }

    func testExtendingAfterClearingIsANoOp() async throws {
        let document = try openFixture()
        let controller = SelectionController(document: document)
        controller.beginWord(page: 0, at: try centre(of: 0, in: document))
        let began = await eventually { controller.selection != nil }
        XCTAssertTrue(began)
        controller.clear()
        controller.extend(to: try centre(of: 10, in: document))
        await controller.waitUntilSettled()
        XCTAssertNil(controller.selection)
    }

    // MARK: Which answer counts

    /// The brief's stale result: a word asked for at one place and then at another leaves the second.
    func testTheLaterOfTwoBeginsWins() async throws {
        let document = try openFixture()
        let first = try centre(of: 1, in: document)
        let second = try centre(of: 8, in: document)
        let controller = SelectionController(document: document)
        // Many times over, so a lucky ordering of the worker's threads cannot make it pass.
        for round in 0..<25 {
            controller.clear()
            controller.beginWord(page: 0, at: first)
            controller.beginWord(page: 0, at: second)
            await controller.waitUntilSettled()
            XCTAssertEqual(controller.text, "world", "round \(round)")
        }
    }

    /// A word that is slow to find, and that has been asked over before it is found, does not show
    /// when it is: the engine answers the first and the second in turn, and only the second is kept.
    func testAnAnswerThatArrivesAfterANewerRequestIsDropped() async throws {
        let document = try openFixture()
        let probe = SelectionProbe(document)
        let controller = SelectionController(document: probe)
        probe.holdTheNext(.word)
        controller.beginWord(page: 0, at: try centre(of: 1, in: document))
        let asked = await eventually { probe.calls.count(of: .word) == 1 }
        XCTAssertTrue(asked, "the engine is looking for the first word")

        controller.beginWord(page: 0, at: try centre(of: 8, in: document))
        probe.release(.word)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.text, "world", "the first word's answer came first, and was old by then")
        XCTAssertEqual(probe.calls.count(of: .word), 2, "both were asked: the second had not been superseded")
    }

    /// A request that is superseded while it waits for the worker is never made to the engine: with a
    /// handle dragged across a page many points are sent, and only the latest matters.
    func testAnExtendSupersededWhileItWaitsNeverReachesTheEngine() async throws {
        let document = try openFixture()
        let probe = SelectionProbe(document)
        let controller = SelectionController(document: probe)
        controller.beginWord(page: 0, at: try centre(of: 0, in: document))
        let began = await eventually { controller.text == "Hello" }
        XCTAssertTrue(began)

        probe.holdTheNext(.range)
        controller.extend(to: try centre(of: 6, in: document))
        let inEngine = await eventually { probe.calls.count(of: .range) == 1 }
        XCTAssertTrue(inEngine, "the first extend is in the engine, held there")
        controller.extend(to: try centre(of: 7, in: document))
        controller.extend(to: try centre(of: 8, in: document))
        controller.extend(to: try centre(of: 10, in: document))
        probe.release(.range)
        await controller.waitUntilSettled()

        XCTAssertEqual(probe.calls.count(of: .range), 2, "the one already in the engine, and the last: \(probe.calls)")
        XCTAssertEqual(trimmed(controller.text), "Hello world")
        XCTAssertEqual(controller.selection?.end, 11)
    }

    func testAClearedRequestNeverShows() async throws {
        let document = try openFixture()
        let probe = SelectionProbe(document)
        let controller = SelectionController(document: probe)
        probe.holdTheNext(.word)
        controller.beginWord(page: 0, at: try centre(of: 0, in: document))
        let asked = await eventually { probe.calls.count(of: .word) == 1 }
        XCTAssertTrue(asked)
        controller.clear()
        probe.release(.word)
        await controller.waitUntilSettled()
        XCTAssertNil(controller.selection, "the word was found after it was no longer wanted")
    }

    func testNoCallToTheEngineIsMadeOnTheMainThread() async throws {
        let document = try openFixture()
        let probe = SelectionProbe(document)
        let controller = SelectionController(document: probe)
        controller.beginWord(page: 0, at: try centre(of: 0, in: document))
        await controller.waitUntilSettled()
        controller.beginExtending(.end)
        controller.extend(to: try centre(of: 10, in: document))
        await controller.waitUntilSettled()
        controller.beginExtending(.start)
        controller.extend(to: try centre(of: 6, in: document))
        await controller.waitUntilSettled()
        XCTAssertFalse(probe.calls.isEmpty)
        XCTAssertEqual(probe.askedOnTheMainThread, 0, "a call into the engine can take long enough to freeze the screen")
    }

    /// A page's glyphs are read once, however many times the handle moves.
    func testAPagesTextIsReadOnce() async throws {
        let document = try openFixture()
        let probe = SelectionProbe(document)
        let controller = SelectionController(document: probe)
        controller.beginWord(page: 0, at: try centre(of: 0, in: document))
        await controller.waitUntilSettled()
        for glyph in [4, 6, 8, 10, 3] {
            controller.extend(to: try centre(of: glyph, in: document))
            await controller.waitUntilSettled()
        }
        XCTAssertEqual(probe.calls.count(of: .text), 1, "\(probe.calls)")
    }

    /// Glyph indices only mean something for the revision of the document they were read at: when it
    /// changes, what was read is read again.
    func testAPagesTextIsReadAgainWhenTheDocumentChanges() async throws {
        let document = try openFixture()
        let probe = SelectionProbe(document)
        let controller = SelectionController(document: probe)
        controller.beginWord(page: 0, at: try centre(of: 0, in: document))
        await controller.waitUntilSettled()
        controller.extend(to: try centre(of: 8, in: document))
        await controller.waitUntilSettled()
        XCTAssertEqual(probe.calls.count(of: .text), 1)

        probe.changeTheDocument()
        controller.extend(to: try centre(of: 10, in: document))
        await controller.waitUntilSettled()
        XCTAssertEqual(probe.calls.count(of: .text), 2, "the glyphs of the old revision are not to be used")
        XCTAssertEqual(trimmed(controller.text), "Hello world")
    }

    // MARK: The handles

    func testDraggingTheEndHandleMovesTheEnd() async throws {
        let document = try openFixture()
        let controller = SelectionController(document: document)
        controller.beginWord(page: 0, at: try centre(of: 0, in: document))
        let began = await eventually { controller.text == "Hello" }
        XCTAssertTrue(began)

        controller.beginExtending(.end)
        controller.extend(to: try centre(of: 8, in: document))
        let moved = await eventually { controller.selection?.end == 9 }
        XCTAssertTrue(moved, "\(String(describing: controller.selection))")
        XCTAssertEqual(controller.selection?.start, 0, "the start stays")
        XCTAssertEqual(controller.text, "Hello wor")
    }

    func testDraggingTheStartHandleMovesTheStart() async throws {
        let document = try openFixture()
        let controller = SelectionController(document: document)
        controller.beginWord(page: 0, at: try centre(of: 8, in: document))
        let began = await eventually { controller.text == "world" }
        XCTAssertTrue(began)

        controller.beginExtending(.start)
        controller.extend(to: try centre(of: 1, in: document))
        // The centre of glyph 1 is the gap after it: the selection starts at glyph 2.
        let moved = await eventually { controller.selection?.start == 2 }
        XCTAssertTrue(moved, "\(String(describing: controller.selection))")
        XCTAssertEqual(controller.selection?.end, 11, "the end stays")
        XCTAssertEqual(trimmed(controller.text), "llo world")
    }

    /// Both ends are dragged in turn, and each drag keeps the other end where the last one left it.
    func testTheHandlesCanBeDraggedOneAfterTheOther() async throws {
        let document = try openFixture()
        let controller = SelectionController(document: document)
        controller.beginWord(page: 0, at: try centre(of: 0, in: document))
        let began = await eventually { controller.text == "Hello" }
        XCTAssertTrue(began)

        controller.beginExtending(.end)
        controller.extend(to: try centre(of: 7, in: document))
        let first = await eventually { controller.selection?.end == 8 }
        XCTAssertTrue(first)

        controller.beginExtending(.start)
        controller.extend(to: try centre(of: 5, in: document))
        let second = await eventually { controller.selection?.start == 6 }
        XCTAssertTrue(second, "\(String(describing: controller.selection))")
        XCTAssertEqual(controller.selection?.end, 8, "the end stays where the first drag left it")
        XCTAssertEqual(controller.text, "wo")
    }

    /// The glyph a drag began on stays selected, even when the other end is taken across it.
    func testDraggingAHandlePastTheOtherKeepsTheGlyphItBeganOn() async throws {
        let document = try openFixture()
        let controller = SelectionController(document: document)
        controller.beginWord(page: 0, at: try centre(of: 8, in: document))
        let began = await eventually { controller.text == "world" }
        XCTAssertTrue(began)

        // The end handle, which holds on to the start (glyph 6, "w"), is taken back over it to
        // glyph 3: the gap after it is 4, and the selection runs from there to the held glyph.
        controller.beginExtending(.end)
        controller.extend(to: try centre(of: 3, in: document))
        let crossed = await eventually { controller.selection?.start == 4 }
        XCTAssertTrue(crossed, "\(String(describing: controller.selection))")
        XCTAssertEqual(controller.selection?.end, 7)
        XCTAssertEqual(controller.text, "o w")

        // And back past the other way again, still held to glyph 6.
        controller.extend(to: try centre(of: 9, in: document))
        let back = await eventually { controller.selection?.start == 6 }
        XCTAssertTrue(back, "\(String(describing: controller.selection))")
        XCTAssertEqual(controller.selection?.end, 10)
        XCTAssertEqual(controller.text, "worl")
    }

    /// With no handle named, a drag moves the end, as the brief's own test has it.
    func testWithoutAHandleNamedADragMovesTheEndOfTheWordThatWasSelected() async throws {
        let document = try openFixture()
        let controller = SelectionController(document: document)
        controller.beginWord(page: 0, at: try centre(of: 8, in: document))
        let began = await eventually { controller.text == "world" }
        XCTAssertTrue(began)
        controller.extend(to: try centre(of: 9, in: document))
        let moved = await eventually { controller.selection?.end == 10 }
        XCTAssertTrue(moved)
        XCTAssertEqual(controller.selection?.start, 6)
        // The same drag goes on: the word's start is still what it moves from.
        controller.extend(to: try centre(of: 3, in: document))
        let crossed = await eventually { controller.selection?.start == 4 }
        XCTAssertTrue(crossed, "\(String(describing: controller.selection))")
    }

    /// A drag past the page is a drag to the nearest text on it: M1 selects within one page.
    func testPointsOutsideThePageStayOnThePage() async throws {
        let document = try openFixture()
        let controller = SelectionController(document: document)
        controller.beginWord(page: 0, at: try centre(of: 0, in: document))
        let began = await eventually { controller.text == "Hello" }
        XCTAssertTrue(began)

        controller.extend(to: CGPoint(x: 100_000, y: 100_000))
        let toTheEnd = await eventually { controller.selection?.end == 11 }
        XCTAssertTrue(toTheEnd, "\(String(describing: controller.selection))")
        XCTAssertEqual(controller.selection?.page, 0)

        controller.extend(to: CGPoint(x: -100_000, y: -100_000))
        let toTheStart = await eventually { controller.selection?.end == 1 }
        XCTAssertTrue(toTheStart, "\(String(describing: controller.selection))")
        XCTAssertEqual(controller.text, "H", "from the glyph the drag began on, to the start of the page")
    }

    func testAPointThatIsNotANumberMovesNothing() async throws {
        let document = try openFixture()
        let controller = SelectionController(document: document)
        controller.beginWord(page: 0, at: try centre(of: 0, in: document))
        let began = await eventually { controller.text == "Hello" }
        XCTAssertTrue(began)
        controller.extend(to: CGPoint(x: Double.nan, y: 100))
        controller.extend(to: CGPoint(x: 100, y: Double.infinity))
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.text, "Hello")
    }

    // MARK: Pages other than the first

    func testAWordOnALaterPageIsSelectedOnThatPage() async throws {
        let data = PageScrollViewControllerTests.letterPages(3)
        let document = try PdfDocument.open(bytes: data, password: nil)
        let controller = SelectionController(document: document)
        controller.beginWord(page: 2, at: try centre(of: 1, on: 2, in: document))
        let found = await eventually { controller.text == "Page" }
        XCTAssertTrue(found, "\(controller.text)")
        XCTAssertEqual(controller.selection?.page, 2)

        controller.extend(to: try centre(of: 5, on: 2, in: document))
        let extended = await eventually { controller.text == "Page 3" }
        XCTAssertTrue(extended, "\(controller.text)")
        XCTAssertEqual(controller.selection?.page, 2, "an extension stays on the page it began on")
    }

    func testABeginOnAnotherPageReplacesTheSelection() async throws {
        let data = PageScrollViewControllerTests.letterPages(3)
        let document = try PdfDocument.open(bytes: data, password: nil)
        let controller = SelectionController(document: document)
        controller.beginWord(page: 0, at: try centre(of: 1, on: 0, in: document))
        let first = await eventually { controller.selection?.page == 0 }
        XCTAssertTrue(first)
        controller.beginWord(page: 1, at: try centre(of: 1, on: 1, in: document))
        let second = await eventually { controller.selection?.page == 1 }
        XCTAssertTrue(second)
        XCTAssertEqual(controller.text, "Page")
    }

    // MARK: What the viewer draws

    func testTheViewerIsGivenTheBoxesOfTheSelectionOnItsPage() async throws {
        let document = try openFixture()
        let controller = SelectionController(document: document)
        XCTAssertNil(controller.pageRects, "nothing selected, nothing to draw")
        controller.beginWord(page: 0, at: try centre(of: 0, in: document))
        let found = await eventually { controller.selection != nil }
        XCTAssertTrue(found)
        let drawn = try XCTUnwrap(controller.pageRects)
        XCTAssertEqual(drawn.page, 0)
        let selection = try XCTUnwrap(controller.selection)
        XCTAssertEqual(drawn.rects, selection.rects.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) })
        XCTAssertFalse(drawn.rects.isEmpty)
        controller.clear()
        XCTAssertNil(controller.pageRects)
    }

    func testABoxThatCannotBeDrawnIsLeftOut() {
        let selection = EditinPDFCore.TextSelection(
            page: 3, start: 0, end: 4,
            rects: [Rect(x: 72, y: 100, width: 30, height: 12),
                    Rect(x: .nan, y: 100, width: 30, height: 12),
                    Rect(x: 72, y: 100, width: 0, height: 12),
                    Rect(x: 72, y: 100, width: 30, height: -1),
                    Rect(x: 72, y: .infinity, width: 30, height: 12),
                    Rect(x: 10, y: 120, width: 20, height: 12)],
            text: "abcd")
        XCTAssertEqual(SelectionController.rects(of: selection), [CGRect(x: 72, y: 100, width: 30, height: 12),
                                                                   CGRect(x: 10, y: 120, width: 20, height: 12)])
    }

    // MARK: Copying

    func testCopyingPutsTheSelectedTextOnThePasteboard() async throws {
        let document = try openFixture()
        let controller = SelectionController(document: document)
        UIPasteboard.general.string = "something else"
        controller.beginWord(page: 0, at: try centre(of: 0, in: document))
        let found = await eventually { controller.text == "Hello" }
        XCTAssertTrue(found)

        XCTAssertTrue(controller.copySelection())
        XCTAssertEqual(UIPasteboard.general.string, "Hello")
        XCTAssertEqual(controller.text, "Hello", "copying leaves the selection as it was")
    }

    func testCopyingWithNothingSelectedLeavesThePasteboardAlone() throws {
        let controller = SelectionController(document: try openFixture())
        UIPasteboard.general.string = "something else"
        XCTAssertFalse(controller.copySelection())
        XCTAssertEqual(UIPasteboard.general.string, "something else")
    }
}

/// A document that answers as the real one does and notes how it was asked about text: which calls,
/// in which order, and on which thread. It can hold a call inside it until it is released, as a slow
/// engine would, so a test can have a request on its way while others are made.
final class SelectionProbe: PdfDocumentProtocol, @unchecked Sendable {
    /// What the controller can ask for.
    enum Kind: Hashable { case text, word, range }

    /// One call, as it was made.
    enum Call: Equatable {
        case text(page: UInt32)
        case word(page: UInt32)
        case range(page: UInt32, start: UInt32, end: UInt32)

        var kind: Kind {
            switch self {
            case .text: .text
            case .word: .word
            case .range: .range
            }
        }
    }

    private let document: PdfDocument
    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _onMainThread = 0
    private var toHold: [Kind: DispatchSemaphore] = [:]
    private var holding: [Kind: DispatchSemaphore] = [:]
    private var revisionsPast: UInt64 = 0

    init(_ document: PdfDocument) {
        self.document = document
    }

    /// Every call made so far, in order, from the moment it was made (a held call is in).
    var calls: [Call] { lock.withLock { _calls } }
    var askedOnTheMainThread: Int { lock.withLock { _onMainThread } }

    /// Makes the document report a new revision, as an edit would.
    func changeTheDocument() {
        lock.withLock { revisionsPast += 1 }
    }

    /// Makes the next call of `kind` stay inside the engine until `release(_:)`.
    func holdTheNext(_ kind: Kind) {
        lock.withLock { toHold[kind] = DispatchSemaphore(value: 0) }
    }

    func release(_ kind: Kind) {
        lock.withLock { holding.removeValue(forKey: kind) }?.signal()
    }

    private func note(_ call: Call) {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            _calls.append(call)
            if Thread.isMainThread { _onMainThread += 1 }
            guard let gate = toHold.removeValue(forKey: call.kind) else { return nil }
            holding[call.kind] = gate
            return gate
        }
        gate?.wait()
    }

    // MARK: PdfDocumentProtocol

    func pageCount() -> UInt32 { document.pageCount() }
    func pageInfo(page: UInt32) -> PageInfo? { document.pageInfo(page: page) }
    func revision() -> UInt64 { document.revision() + lock.withLock { revisionsPast } }
    func search(query: String, caseSensitive: Bool) -> [SearchHit] { document.search(query: query, caseSensitive: caseSensitive) }

    func renderTile(page: UInt32, scale: Double, rect: TileRect?) throws -> RenderedTile {
        try document.renderTile(page: page, scale: scale, rect: rect)
    }

    func pageText(page: UInt32) throws -> PageText {
        note(.text(page: page))
        return try document.pageText(page: page)
    }

    func selectWord(page: UInt32, x: Double, y: Double) throws -> EditinPDFCore.TextSelection? {
        note(.word(page: page))
        return try document.selectWord(page: page, x: x, y: y)
    }

    func selectRange(page: UInt32, start: UInt32, end: UInt32) throws -> EditinPDFCore.TextSelection {
        note(.range(page: page, start: start, end: end))
        return try document.selectRange(page: page, start: start, end: end)
    }

    // Editing API: plain forwards, the selection tests never edit.
    func apply(edit: Edit, baseRevision: UInt64) throws -> EditOutcome { try document.apply(edit: edit, baseRevision: baseRevision) }
    func applyAll(label: String, edits: [Edit], baseRevision: UInt64) throws -> EditOutcome {
        try document.applyAll(label: label, edits: edits, baseRevision: baseRevision)
    }
    func undo() throws -> EditOutcome { try document.undo() }
    func redo() throws -> EditOutcome { try document.redo() }
    func canUndo() -> Bool { document.canUndo() }
    func canRedo() -> Bool { document.canRedo() }
    func isDirty() -> Bool { document.isDirty() }
    func save(mode: SaveMode) throws -> Data { try document.save(mode: mode) }
    func extractPages(pages: [UInt32]) throws -> Data { try document.extractPages(pages: pages) }
    func annotations() -> [AnnotationInfo] { document.annotations() }
    func annotationDates() -> [AnnotationDate] { document.annotationDates() }
    func formFields() -> [FormField] { document.formFields() }
    func formFieldsTruncated() -> Bool { document.formFieldsTruncated() }
    func capabilities() -> EditCapabilities { document.capabilities() }
}

extension Array where Element == SelectionProbe.Call {
    /// How many of the calls are of `kind`.
    func count(of kind: SelectionProbe.Kind) -> Int {
        filter { $0.kind == kind }.count
    }
}
