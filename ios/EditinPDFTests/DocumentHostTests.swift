import UIKit
import XCTest
@testable import EditinPDF

/// The document's view controller as the scene hands it to each screen (`DocumentHost`): the scene shows
/// every document it opens in the same controller, so a second screen finds the navigation item as the
/// first one left it, and must take the back button over all the same.
@MainActor
final class DocumentHostTests: XCTestCase {
    /// Counts the runs of the system's back action.
    @MainActor
    private final class Runs {
        var count = 0
    }

    /// The scene's document view controller, with a back action of the system's that counts its runs.
    private func makeController(runs: Runs) -> UIDocumentViewController {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("host-\(UUID().uuidString).pdf")
        let controller = UIDocumentViewController(document: UIDocument(fileURL: url))
        controller.navigationItem.backAction = UIAction(title: "Documents", identifier: UIAction.Identifier("test.system.back")) { _ in
            runs.count += 1
        }
        return controller
    }

    /// Taps the back button: runs the navigation item's back action.
    private func tapBack(_ controller: UIDocumentViewController) throws {
        UIButton(type: .system).sendAction(try XCTUnwrap(controller.navigationItem.backAction))
    }

    /// A second document shown in the same controller, the first screen's back action still on its
    /// navigation item: the second screen takes Back over too, is saved by Save, and closes with the
    /// system's own action.
    func testASecondScreenInTheSameControllerTakesBackOver() throws {
        let runs = Runs()
        let controller = makeController(runs: runs)
        let first = DocumentHost()
        first.attach(from: controller)
        first.decide()
        XCTAssertEqual(first.decided, .explicit)
        XCTAssertTrue(first.interceptsBack)

        // As the scene leaves it for the next document: the first screen's back action still on the item.
        // (Setting `document` here would have UIKit set a back action of its own, which the app does not see.)
        let second = DocumentHost()
        var asked = 0
        second.goBack = { asked += 1 }
        second.attach(from: controller)
        second.decide()
        XCTAssertEqual(second.decided, .explicit, "the second document is saved the system's way")
        XCTAssertTrue(second.interceptsBack, "the second screen's Back is not its own")
        try tapBack(controller)
        XCTAssertEqual(asked, 1, "Back did not ask the second screen")
        XCTAssertEqual(runs.count, 0)
        XCTAssertTrue(second.close())
        XCTAssertEqual(runs.count, 1, "closing did not run the system's back action")
    }

    /// The second screen writes Save through the document the controller shows now.
    func testSaveWritesThroughTheDocumentShownNow() {
        let controller = makeController(runs: Runs())
        let first = DocumentHost()
        first.attach(from: controller)
        controller.document = UIDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("host-now.pdf"))
        first.attach(from: controller)
        XCTAssertTrue(first.writer?.document === controller.document)
        let second = DocumentHost()
        second.attach(from: controller)
        XCTAssertTrue(second.writer?.document === controller.document)
    }

    /// As its screen goes, a host gives the navigation item back as it found it: the system's back action,
    /// no "Edited"; nor does it watch the item or answer Back any more.
    func testDetachGivesTheNavigationItemBack() throws {
        let runs = Runs()
        let controller = makeController(runs: runs)
        // The item keeps copies of the actions it is given: the system's is known by its identifier.
        let system = controller.navigationItem.backAction?.identifier
        let host = DocumentHost()
        var asked = 0
        host.goBack = { asked += 1 }
        host.attach(from: controller)
        host.decide()
        host.showEdited(true)
        XCTAssertTrue(host.interceptsBack)
        host.detach()
        XCTAssertEqual(controller.navigationItem.backAction?.identifier, system, "the system's back action was not given back")
        if #available(iOS 26, *) {
            XCTAssertNil(controller.navigationItem.subtitle, "\"Edited\" stayed under the name")
        }
        XCTAssertFalse(host.interceptsBack)
        host.showEdited(true)
        host.reapply()
        XCTAssertEqual(controller.navigationItem.backAction?.identifier, system, "a host that has gone took Back over again")
        try tapBack(controller)
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(runs.count, 1)
    }

    /// A first screen whose going comes after the second screen took Back over leaves the second's alone.
    func testALateDetachLeavesTheNextScreensBackAlone() throws {
        let controller = makeController(runs: Runs())
        let first = DocumentHost()
        first.attach(from: controller)
        first.decide()
        let second = DocumentHost()
        var asked = 0
        second.goBack = { asked += 1 }
        second.attach(from: controller)
        second.decide()
        second.showEdited(true)
        first.detach()
        XCTAssertTrue(second.interceptsBack, "the first screen's going took the second's Back away")
        if #available(iOS 26, *) {
            XCTAssertEqual(controller.navigationItem.subtitle, Strings.edited)
        }
        try tapBack(controller)
        XCTAssertEqual(asked, 1)
    }

    /// The back action found only after the screen appeared: the document is still saved by Save, decided
    /// as soon as it is found, not the system's way.
    func testABackActionFoundLateStillMeansSave() async throws {
        let controller = makeController(runs: Runs())
        let system = controller.navigationItem.backAction
        controller.navigationItem.backAction = nil
        let host = DocumentHost()
        host.attach(from: controller)
        host.decide()
        XCTAssertNil(host.decided, "decided before the back action was there")
        controller.navigationItem.backAction = system
        host.reapply()
        XCTAssertEqual(host.decided, .explicit)
        XCTAssertTrue(host.interceptsBack)
    }

    /// Nothing found a moment after the screen appeared (no document view controller): saved the system's way.
    func testNothingFoundFallsBackToTheSystemsWay() async throws {
        let host = DocumentHost()
        host.attach(from: UIViewController())
        host.decide()
        XCTAssertNil(host.decided, "fell back at once, before anything had a chance to be found")
        var waited = Duration.zero
        while host.decided == nil, waited < DocumentHost.fallbackDelay + .seconds(3) {
            try await Task.sleep(for: .milliseconds(100))
            waited += .milliseconds(100)
        }
        XCTAssertEqual(host.decided, .automatic)
    }

    /// A screen that goes undecided does not fall back afterwards.
    func testAHostThatWentDoesNotFallBack() async throws {
        let host = DocumentHost()
        host.attach(from: UIViewController())
        host.decide()
        host.detach()
        try await Task.sleep(for: DocumentHost.fallbackDelay + .milliseconds(500))
        XCTAssertNil(host.decided)
    }

    // MARK: Two screens alive at once

    /// The second screen attaches while the first is still attached (their lives overlap, or the first's
    /// going comes late): once the item's watchers have run, the second's Back is in place and stays, the
    /// first has been taken over and no longer sets the item, and the first's going leaves it alone.
    func testTwoHostsAliveAtOnceDoNotFightOverBack() async throws {
        let runs = Runs()
        let controller = makeController(runs: runs)
        let kept = DocumentHost.keptSystemBacks
        let first = DocumentHost()
        var firstAsked = 0
        first.goBack = { firstAsked += 1 }
        first.attach(from: controller)
        first.decide()
        first.showEdited(true)
        let second = DocumentHost()
        var secondAsked = 0
        second.goBack = { secondAsked += 1 }
        second.attach(from: controller)
        second.decide()
        second.showEdited(false)
        // The watchers run on later turns of the main actor.
        let sets = Runs()
        let counting = controller.navigationItem.observe(\.backAction) { _, _ in
            MainActor.assumeIsolated { sets.count += 1 }
        }
        defer { counting.invalidate() }
        let installed = controller.navigationItem.backAction?.identifier
        for _ in 0..<10 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(sets.count, 0, "the hosts set Back again and again")
        XCTAssertEqual(controller.navigationItem.backAction?.identifier, installed)
        XCTAssertTrue(second.interceptsBack, "the second screen's Back was taken away")
        XCTAssertFalse(first.interceptsBack)
        XCTAssertEqual(second.decided, .explicit)
        if #available(iOS 26, *) {
            XCTAssertNil(controller.navigationItem.subtitle, "the first screen put its \"Edited\" back")
        }
        first.detach()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(second.interceptsBack, "the first screen's going took the second's Back away")
        try tapBack(controller)
        XCTAssertEqual(secondAsked, 1)
        XCTAssertEqual(firstAsked, 0)
        XCTAssertTrue(second.close())
        XCTAssertEqual(runs.count, 1, "the second screen did not close with the system's action")
        second.detach()
        XCTAssertEqual(DocumentHost.keptSystemBacks, kept, "a system's back action is kept after its screens went")
    }

    /// A host taken over closes nothing (the controller shows the other screen's document).
    func testAHostTakenOverClosesNothing() async throws {
        let runs = Runs()
        let controller = makeController(runs: runs)
        let first = DocumentHost()
        first.attach(from: controller)
        let second = DocumentHost()
        second.attach(from: controller)
        first.reapply()
        XCTAssertTrue(first.superseded)
        XCTAssertFalse(first.close())
        XCTAssertEqual(runs.count, 0)
        first.detach()
        second.detach()
    }

    /// Each screen's system action is kept only while its action is on an item: many documents opened and
    /// closed in turn keep none.
    func testSystemActionsAreNotKeptAfterTheScreensGo() {
        let controller = makeController(runs: Runs())
        let kept = DocumentHost.keptSystemBacks
        for _ in 0..<20 {
            let host = DocumentHost()
            host.attach(from: controller)
            XCTAssertEqual(DocumentHost.keptSystemBacks, kept + 1)
            host.detach()
        }
        // Each taking the last one's over, the last one never gone.
        for _ in 0..<20 {
            DocumentHost().attach(from: controller)
        }
        XCTAssertEqual(DocumentHost.keptSystemBacks, kept + 1)
    }

    /// Gone undecided and come back, the screen waits its full moment again before falling back: the first
    /// wait was cancelled as it went.
    func testFallingBackWaitsAgainAfterTheScreenCameBack() async throws {
        let host = DocumentHost()
        host.attach(from: UIViewController())
        host.decide()
        try await Task.sleep(for: .milliseconds(1500))
        host.detach()
        host.resume()
        host.attach(from: UIViewController())
        host.decide()
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertNil(host.decided, "fell back on the first appearance's wait")
        var waited = Duration.zero
        while host.decided == nil, waited < DocumentHost.fallbackDelay + .seconds(2) {
            try await Task.sleep(for: .milliseconds(100))
            waited += .milliseconds(100)
        }
        XCTAssertEqual(host.decided, .automatic)
    }
}
