#if DEBUG
import XCTest
@testable import EditinPDF

/// The Debug build's test support: the documents the UI tests open travel inside the app, and a
/// launch argument puts one of them in the app's Documents folder, where the document browser lists
/// it. (`FixtureStaging` does not exist in Release, and neither do the documents.)
@MainActor
final class FixtureStagingTests: XCTestCase {
    /// A new, empty folder that is removed when the test ends.
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FixtureStagingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// What the app bundle carries under `name`.
    private func bundled(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: name, withExtension: nil), "\(name) is not in the app bundle"))
    }

    // MARK: The launch argument

    func testTheLaunchArgumentNamesTheFixture() {
        XCTAssertEqual(FixtureStaging.requestedFixture(in: ["EditinPDF", "-openFixture", "sample.pdf"]), "sample.pdf")
        XCTAssertEqual(FixtureStaging.requestedFixture(in: ["-other", "x", "-openFixture", "locked.pdf", "-more"]), "locked.pdf")
    }

    func testWithoutTheArgumentOrItsValueNothingIsRequested() {
        XCTAssertNil(FixtureStaging.requestedFixture(in: []))
        XCTAssertNil(FixtureStaging.requestedFixture(in: ["EditinPDF"]))
        XCTAssertNil(FixtureStaging.requestedFixture(in: ["EditinPDF", "-openFixture"]))
    }

    // MARK: Staging

    func testStagingCopiesTheBundledFixtureIntoTheFolder() throws {
        let folder = try makeFolder()
        let staged = try FixtureStaging.stage("sample.pdf", into: folder)
        XCTAssertEqual(staged.lastPathComponent, "sample.pdf")
        XCTAssertEqual(staged.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: staged), try bundled("sample.pdf"))
    }

    func testStagingReplacesAFileAlreadyThere() throws {
        let folder = try makeFolder()
        try Data("an older sample".utf8).write(to: folder.appendingPathComponent("sample.pdf"))
        let staged = try FixtureStaging.stage("sample.pdf", into: folder)
        XCTAssertEqual(try Data(contentsOf: staged), try bundled("sample.pdf"))
    }

    func testStagingLeavesOtherFilesAlone() throws {
        let folder = try makeFolder()
        let other = folder.appendingPathComponent("mine.pdf")
        try Data("not a fixture".utf8).write(to: other)
        try FixtureStaging.stage("locked.pdf", into: folder)
        XCTAssertEqual(try Data(contentsOf: other), Data("not a fixture".utf8))
    }

    func testOnlyAFileNameIsAccepted() throws {
        let folder = try makeFolder()
        for name in ["", ".", "..", "../sample.pdf", "sub/sample.pdf", "/etc/hosts"] {
            XCTAssertThrowsError(try FixtureStaging.stage(name, into: folder), "\"\(name)\" is not a file name") { error in
                // Refused for what it is, not merely because no such file is bundled.
                guard case FixtureStaging.StagingError.notAFileName = error else { return XCTFail("\"\(name)\": expected notAFileName, got \(error)") }
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testAFixtureThatIsNotBundledIsRefused() throws {
        let folder = try makeFolder()
        XCTAssertThrowsError(try FixtureStaging.stage("missing.pdf", into: folder))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testTheAppStagesWhatItsLaunchArgumentsAskFor() throws {
        let folder = try makeFolder()
        FixtureStaging.stageRequestedFixture(arguments: ["EditinPDF", "-openFixture", "garbage.pdf"], into: folder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["garbage.pdf"])
    }

    func testTheAppStagesUnderTheNameItIsGiven() throws {
        let folder = try makeFolder()
        let name = "A rather long report name for the title bar.pdf"
        FixtureStaging.stageRequestedFixture(arguments: ["EditinPDF", "-openFixture", "sample.pdf", "-fixtureName", name], into: folder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [name])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), try bundled("sample.pdf"))
    }

    func testAStagedNameWithAPathIsRefused() throws {
        let folder = try makeFolder()
        XCTAssertThrowsError(try FixtureStaging.stage("sample.pdf", as: "../outside.pdf", into: folder))
        XCTAssertThrowsError(try FixtureStaging.stage("sample.pdf", as: "", into: folder))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testTheAppStagesNothingWithoutTheArgument() throws {
        let folder = try makeFolder()
        FixtureStaging.stageRequestedFixture(arguments: ["EditinPDF"], into: folder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testAnUnusableRequestIsLoggedAndTheAppCarriesOn() throws {
        let folder = try makeFolder()
        FixtureStaging.stageRequestedFixture(arguments: ["EditinPDF", "-openFixture", "../missing.pdf"], into: folder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    // MARK: The documents the UI tests rely on

    func testTheSampleHasTheThreePagesTheUITestsScrollThrough() throws {
        let model = DocumentModel(bytes: try bundled("sample.pdf"))
        guard case .open = model.state else { return XCTFail("expected open, got \(model.state)") }
        XCTAssertEqual(model.pageCount, 3)
    }

    func testTheLockedDocumentOpensWithItsPasswordAndNoOtherOne() async throws {
        let model = DocumentModel(bytes: try bundled("locked.pdf"))
        guard case .locked(_, let refused) = model.state else { return XCTFail("expected locked, got \(model.state)") }
        XCTAssertFalse(refused)
        let withTheWrongOne = await model.unlock(password: "nope")
        XCTAssertFalse(withTheWrongOne)
        let withTheRightOne = await model.unlock(password: "hunter2")
        XCTAssertTrue(withTheRightOne)
        XCTAssertEqual(model.pageCount, 1)
    }

    func testTheGarbageIsNotADocumentTheEngineCanOpen() throws {
        let bytes = try bundled("garbage.pdf")
        XCTAssertEqual(bytes.count, 2048)
        guard case .failed = DocumentModel(bytes: bytes).state else { return XCTFail("expected failed") }
    }
}
#endif
