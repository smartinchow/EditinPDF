import EditinPDFCore
import XCTest
@testable import EditinPDF

/// The Organize screen's actions, on `sample.pdf` (three pages: "Page one", "Page two", "Page three").
@MainActor
final class OrganizeControllerTests: XCTestCase {
    /// A controller of a freshly opened document, once its state (what may be changed) has been read.
    private func makeController(fixture: String = "sample") async throws -> (OrganizeController, DocumentModel, UndoManager) {
        let (m, u) = try makeModel(fixture: fixture)
        await m.settle()
        return (OrganizeController(model: m), m, u)
    }

    /// The first word on each page, to tell the pages apart after they move.
    private func firstWords(_ m: DocumentModel) throws -> [String] {
        let document = try XCTUnwrap(m.document())
        return try (0..<m.pageCount).map { page in
            let text = try document.pageText(page: UInt32(page)).glyphs.map(\.text).joined()
            return String(text.dropFirst("Page".count).drop(while: { $0 == " " }).prefix(while: \.isLetter))
        }
    }

    func testInsertBlankTappedTwiceQuicklyAddsOnePageAndShowsNoFailure() async throws {
        let (c, m, _) = try await makeController()
        XCTAssertTrue(c.canInsertBlank)
        c.insertBlank()
        XCTAssertTrue(m.isApplying)
        XCTAssertFalse(c.canInsertBlank, "Insert is off while the first one is being made")
        XCTAssertFalse(c.canDelete); XCTAssertFalse(c.canMove)
        c.insertBlank()
        await m.settle()
        XCTAssertNil(m.failure, "the second tap must not end in \"The document changed\"")
        XCTAssertEqual(m.pageCount, 4)
        XCTAssertEqual(c.selection, [3], "the inserted page is selected")
        XCTAssertTrue(c.canInsertBlank)
    }

    func testDeleteAndMoveAreIgnoredWhileAChangeIsBeingMade() async throws {
        let (c, m, _) = try await makeController()
        c.selection = [0]
        c.insertBlank()
        c.selection = [0]
        c.deleteSelection()
        c.move([0], dropIndex: 3)
        await m.settle()
        XCTAssertNil(m.failure)
        XCTAssertEqual(m.pageCount, 4)
        XCTAssertEqual(m.revision, 1, "only the insert was made")
    }

    func testDeletingSeveralPagesIsOneUndoStep() async throws {
        let (c, m, u) = try await makeController()
        c.selection = [2, 0]
        XCTAssertTrue(c.canDelete)
        await c.deleteSelection()?.value
        XCTAssertEqual(m.pageCount, 1)
        XCTAssertEqual(m.revision, 1)
        XCTAssertEqual(c.selection, [])
        XCTAssertEqual(u.undoActionName, Strings.actionDelete)
        u.undo(); await m.settle()
        XCTAssertEqual(m.pageCount, 3)
        XCTAssertFalse(u.canUndo, "one step took it all back")
    }

    func testDeleteIsOffWithNothingOrEverythingSelected() async throws {
        let (c, _, _) = try await makeController()
        XCTAssertFalse(c.canDelete)
        c.selectAll()
        XCTAssertEqual(c.selection, [0, 1, 2]); XCTAssertTrue(c.allSelected)
        XCTAssertFalse(c.canDelete, "a document keeps a page")
        c.selectAll()
        XCTAssertEqual(c.selection, [], "Select All again deselects")
    }

    func testRotateKeepsTheSelectionAndTwoQuickRotationsBothHappen() async throws {
        let (c, m, _) = try await makeController()
        c.selection = [1]
        c.rotate(by: 90)
        c.rotate(by: 90)
        await m.settle()
        XCTAssertNil(m.failure)
        XCTAssertEqual(m.pages[1].rotationDegrees, 180)
        XCTAssertEqual(c.selection, [1])
        await c.rotate(by: -90)?.value
        XCTAssertEqual(m.pages[1].rotationDegrees, 90)
    }

    func testMoveSelectsTheMovedPagesWhereTheyLand() async throws {
        let (c, m, _) = try await makeController()
        await c.move([2], dropIndex: 0)?.value
        XCTAssertEqual(try firstWords(m), ["three", "one", "two"])
        XCTAssertEqual(c.selection, [0])
        await c.move([0, 1], dropIndex: 3)?.value
        XCTAssertEqual(try firstWords(m), ["two", "three", "one"])
        XCTAssertEqual(c.selection, [1, 2])
    }

    func testADropThatMovesNothingChangesNothing() async throws {
        let (c, m, _) = try await makeController()
        XCTAssertNil(c.move([1], dropIndex: 1))
        XCTAssertNil(c.move([1], dropIndex: 2))
        await m.settle()
        XCTAssertEqual(m.revision, 0)
    }

    func testAnUndoClearsTheSelectionAndOwnChangesDoNot() async throws {
        let (c, m, u) = try await makeController()
        c.selection = [0]
        await c.rotate(by: 90)?.value
        c.modelDidChange(m.lastChange)
        XCTAssertEqual(c.selection, [0], "the screen's own change keeps its selection")
        u.undo(); await m.settle()
        c.modelDidChange(m.lastChange)
        XCTAssertEqual(c.selection, [], "an undo may have moved the pages")
    }

    func testNothingCanBeChangedWhenTheDocumentDoesNotAllowIt() async throws {
        let (m, _) = try makeModel()
        // Before its state is read, what may be changed is not known.
        let c = OrganizeController(model: m)
        XCTAssertFalse(c.canInsertBlank)
        c.insertBlank()
        await m.settle()
        XCTAssertEqual(m.pageCount, 3)
    }
}
