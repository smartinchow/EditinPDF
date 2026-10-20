import EditinPDFCore
import PencilKit
import UIKit
import XCTest
@testable import EditinPDF

/// Strokes drawn with Draw reach the file: a document closed with strokes waiting keeps them.
///
/// The document scene closes the file when its back button is tapped, before the screen hears it is
/// going, and saves it only if a change has been registered by then: a touch outside the pages (the
/// back button is one) adds the strokes as it goes down. A save then waits for the changes handed
/// over to reach the engine, so it writes them. (The whole path, drawing then going back without
/// Done, is `EditorSmokeTests.testStrokesLeftWaitingAreKeptWhenTheDocumentIsClosed`.)
@MainActor
final class InkSavingTests: XCTestCase {
    // MARK: Saving waits for the changes handed over

    func testWaitingForEditsReturnsOnceNoneIsOnItsWay() {
        let handle = EngineHandle()
        XCTAssertTrue(handle.waitForEdits(timeout: 0.1), "none: at once")
        handle.editWillStart()
        XCTAssertFalse(handle.waitForEdits(timeout: 0.1), "one on its way: the wait runs out")
        handle.editDidFinish()
        XCTAssertTrue(handle.waitForEdits(timeout: 0.1))
    }

    func testAWaitEndsWhenTheEditArrives() async {
        let handle = EngineHandle()
        handle.editWillStart()
        let waited = Task.detached { handle.waitForEdits(timeout: 5) }
        try? await Task.sleep(for: .milliseconds(100))
        handle.editDidFinish()
        let arrived = await waited.value
        XCTAssertTrue(arrived)
    }

    /// A change handed over just before a save (the strokes added as the back button goes down) is in
    /// what the save writes, though it reached the engine after the save began.
    func testASaveWritesAChangeHandedOverBeforeIt() async throws {
        let file = PDFFileDocument(bytes: try fixtureData("sample"))
        let model = file.model
        await model.settle()
        let snapshot = try file.snapshot(contentType: .pdf)
        model.enqueueInk(page: 0, strokes: [[CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 150)]])
        let bytes = try await Task.detached { try file.savedBytes(of: snapshot) }.value
        let saved = try PdfDocument.open(bytes: bytes, password: nil)
        XCTAssertEqual(saved.annotations().map(\.kind), [.ink])
    }

    /// Every change, undo and redo counts as on its way from when it is handed over until it has run.
    func testChangesUndoAndRedoAreOnTheirWayUntilTheyRun() async throws {
        let (model, undoManager) = try makeModel()
        await model.settle()
        model.enqueueInk(page: 0, strokes: [[CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40)]])
        XCTAssertFalse(model.engine.waitForEdits(timeout: 0), "handed over, not run")
        await model.settle()
        XCTAssertTrue(model.engine.waitForEdits(timeout: 0))
        undoManager.undo()
        XCTAssertFalse(model.engine.waitForEdits(timeout: 0), "the undo is on its way")
        await model.settle()
        XCTAssertTrue(model.engine.waitForEdits(timeout: 0))
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
    }

    // MARK: A touch outside the pages adds the strokes

    func makeController() async -> (PageScrollViewController, DocumentModel) {
        let model = DocumentModel(bytes: PageScrollViewControllerTests.letterPages(2))
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(origin: .zero, size: CGSize(width: 400, height: 800))
        controller.view.layoutIfNeeded()
        await model.settle()
        model.tool = .ink
        controller.markupTool = .ink
        return (controller, model)
    }

    func draw(on controller: PageScrollViewController) throws {
        let ink = try XCTUnwrap(controller.markupInteraction.ink)
        ink.drawing = PKDrawing(strokes: [InkGeometryTests.stroke((0...20).map { CGPoint(x: 50 + Double($0) * 5, y: 100) })])
    }

    /// A finger going down anywhere but the pages (the back button, the toolbar, the palette) adds the
    /// strokes waiting; one on the pages does not.
    func testAFingerOutsideThePagesAddsTheStrokes() async throws {
        let (controller, model) = await makeController()
        try draw(on: controller)
        controller.markupInteraction.fingerWentDown(on: controller.contentView)
        XCTAssertTrue(model.hasPendingInk, "on the pages: still drawing")
        controller.markupInteraction.fingerWentDown(on: try XCTUnwrap(controller.markupInteraction.ink))
        XCTAssertTrue(model.hasPendingInk, "on the canvas: still drawing")
        controller.markupInteraction.fingerWentDown(on: UIView())
        XCTAssertFalse(model.hasPendingInk, "outside the pages: added")
        await model.settle()
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).map(\.kind), [.ink])
    }

    /// The screen's window tells the markup of every finger going down, without taking it.
    func testTheWindowReportsFingersWithoutTakingThem() async throws {
        let (controller, _) = await makeController()
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 400, height: 800)))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let observer = controller.markupInteraction.fingersDown
        // The controller's view appears on the run loop's next turns.
        for _ in 0..<50 where observer.view !== window { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(observer.view === window, "the observer is on the window")
        XCTAssertFalse(observer.cancelsTouchesInView)
        XCTAssertFalse(observer.delaysTouchesBegan)
        XCTAssertFalse(observer.delaysTouchesEnded)
        XCTAssertFalse(observer.canPrevent(controller.scrollView.panGestureRecognizer))
    }

    /// A finger going down while another is already held (a palm on the page, the Pencil drawing) is
    /// still reported: the observer stays listening until every finger it heard of has lifted, and only
    /// then fails, ready for the next touches.
    func testAFingerDownWhileAnotherIsHeldIsStillReported() {
        let observer = FingerDownObserver()
        var reported: [UIView?] = []
        observer.fingerWentDown = { reported.append($0) }
        let page = UIView(), back = UIView()
        let palm = UITouch(), tap = UITouch()
        observer.touchWentDown(palm, on: page)
        XCTAssertEqual(observer.state, .possible, "still listening")
        observer.touchWentDown(tap, on: back)
        XCTAssertEqual(reported.count, 2, "the second finger is heard though the first is down")
        XCTAssertTrue(reported.last ?? nil === back)
        observer.touchLifted(tap)
        XCTAssertEqual(observer.state, .possible, "a finger is still held")
        XCTAssertEqual(observer.heldCount, 1)
        // Every finger lifted: it fails, done with these touches. (Outside a real touch sequence UIKit
        // puts a failed recognizer straight back to possible, so its state cannot be read here.)
        observer.touchLifted(palm)
        XCTAssertEqual(observer.heldCount, 0)
        XCTAssertFalse(observer.canBePrevented(by: UIPanGestureRecognizer()), "another gesture recognizing does not stop it listening")
    }

    /// A save whose wait for a change runs out still writes (what the engine has), and says so in the
    /// log, not to the reader.
    func testASaveWhoseWaitRunsOutStillWrites() async throws {
        let file = PDFFileDocument(bytes: try fixtureData("hello"))
        let snapshot = try file.snapshot(contentType: .pdf)
        file.engine.editWillStart()          // one that never arrives
        defer { file.engine.editDidFinish() }
        let started = Date()
        let bytes = try await Task.detached { try file.savedBytes(of: snapshot) }.value
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), PDFFileDocument.editWait - 0.1, "it waited")
        XCTAssertEqual(bytes, try fixtureData("hello"), "and wrote the document as the engine had it")
    }

    /// The strokes are also added when the screen goes, whatever took it away.
    func testTheStrokesAreAddedWhenTheScreenGoes() async throws {
        let (controller, model) = await makeController()
        try draw(on: controller)
        PageScrollView.dismantleUIViewController(controller, coordinator: ())
        XCTAssertFalse(model.hasPendingInk)
        await model.settle()
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).map(\.kind), [.ink])
    }

    // MARK: The canvas

    /// The canvas does not take the tap on the status bar that scrolls the pages to the top, and its own
    /// undo history goes with the strokes it held.
    func testTheCanvasKeepsNoHistoryOfStrokesAdded() async throws {
        let (controller, model) = await makeController()
        let markup = controller.markupInteraction
        let ink = try XCTUnwrap(markup.ink)
        XCTAssertFalse(ink.scrollsToTop)
        ink.undoManager?.registerUndo(withTarget: ink) { _ in }
        XCTAssertEqual(ink.undoManager?.canUndo, true)
        try draw(on: controller)
        model.commitPendingInk()
        XCTAssertEqual(ink.undoManager?.canUndo, false, "added: the canvas's history goes")
        ink.undoManager?.registerUndo(withTarget: ink) { _ in }
        XCTAssertTrue(markup.prepareToDraw(atContentPoint: CGPoint(x: 200, y: 530 + 200)))
        XCTAssertEqual(ink.page, 1)
        XCTAssertEqual(ink.undoManager?.canUndo, false, "moved to another page: the history goes")
    }
}
