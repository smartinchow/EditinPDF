import EditinPDFCore
import XCTest
@testable import EditinPDF

final class OrganizeMathTests: XCTestCase {
    /// A Letter page turned a quarter: 792 wide and 612 tall as shown.
    private let rotatedLetter = PageInfo(index: 0, widthPt: 792, heightPt: 612, rotationDegrees: 90, label: nil)
    private let letter = PageInfo(index: 0, widthPt: 612, heightPt: 792, rotationDegrees: 0, label: nil)
    private let a5 = PageInfo(index: 1, widthPt: 420, heightPt: 595, rotationDegrees: 0, label: nil)

    func testMoveTarget() {
        XCTAssertEqual(OrganizeMath.moveTarget(moving: [4], dropIndex: 0), 0)
        XCTAssertEqual(OrganizeMath.moveTarget(moving: [0], dropIndex: 3), 2)     // drop before old item 3 → index 2 in the result
        XCTAssertEqual(OrganizeMath.moveTarget(moving: [1, 3], dropIndex: 5), 3)
        XCTAssertEqual(OrganizeMath.selectionAfterMove(moving: [3, 1], to: 3), [3, 4])
    }

    func testInsertionAndBlankSize() {
        XCTAssertEqual(OrganizeMath.insertionIndex(selection: [], pageCount: 3), 3)
        XCTAssertEqual(OrganizeMath.insertionIndex(selection: [0, 1], pageCount: 3), 2)
        XCTAssertEqual(OrganizeMath.blankSize(near: 0, pages: [rotatedLetter]), CGSize(width: 792, height: 612))
    }

    func testBlankSizePrefersThePageBeforeAndFallsBackToLetter() {
        XCTAssertEqual(OrganizeMath.blankSize(near: 1, pages: [letter, a5]), CGSize(width: 612, height: 792))
        XCTAssertEqual(OrganizeMath.blankSize(near: 2, pages: [letter, a5]), CGSize(width: 420, height: 595))
        XCTAssertEqual(OrganizeMath.blankSize(near: 0, pages: []), CGSize(width: 612, height: 792))
        let broken = PageInfo(index: 0, widthPt: .nan, heightPt: 0, rotationDegrees: 0, label: nil)
        XCTAssertEqual(OrganizeMath.blankSize(near: 1, pages: [broken]), CGSize(width: 612, height: 792))
    }

    func testInsertionIndexIgnoresPagesTheDocumentDoesNotHave() {
        XCTAssertEqual(OrganizeMath.insertionIndex(selection: [7], pageCount: 3), 3)
    }

    /// The reader stays on the same page's content when pages before it go, move or arrive.
    func testTheReadersPageFollowsItsContent() {
        // Deleting pages before it moves it up; deleting it lands on the page that followed.
        XCTAssertEqual(OrganizeMath.readerPage(3, after: [.deletePages(pages: [0, 1])], pagesAdded: -2), 1)
        XCTAssertEqual(OrganizeMath.readerPage(1, after: [.deletePages(pages: [1])], pagesAdded: -1), 1)
        XCTAssertEqual(OrganizeMath.readerPage(1, after: [.deletePages(pages: [3])], pagesAdded: -1), 1)
        // Moving: [0 1 2 3 4], 0 and 1 before old 4 → [2 3 0 1 4].
        XCTAssertEqual(OrganizeMath.readerPage(0, after: [.movePages(pages: [0, 1], to: 2)], pagesAdded: 0), 2)
        XCTAssertEqual(OrganizeMath.readerPage(2, after: [.movePages(pages: [0, 1], to: 2)], pagesAdded: 0), 0)
        XCTAssertEqual(OrganizeMath.readerPage(4, after: [.movePages(pages: [0, 1], to: 2)], pagesAdded: 0), 4)
        XCTAssertEqual(OrganizeMath.readerPage(3, after: [.movePages(pages: [3], to: 0)], pagesAdded: 0), 0)
        // Inserting at or before it pushes it down.
        XCTAssertEqual(OrganizeMath.readerPage(1, after: [.insertBlankPage(at: 1, widthPt: 612, heightPt: 792)], pagesAdded: 1), 2)
        XCTAssertEqual(OrganizeMath.readerPage(1, after: [.insertBlankPage(at: 2, widthPt: 612, heightPt: 792)], pagesAdded: 1), 1)
        XCTAssertEqual(OrganizeMath.readerPage(0, after: [.insertPagesFrom(name: "a.pdf", bytes: Data(), pages: nil, at: 0)], pagesAdded: 4), 4)
        // Turning pages changes nothing.
        XCTAssertEqual(OrganizeMath.readerPage(2, after: [.rotatePages(pages: [0, 2], degrees: 90)], pagesAdded: 0), 2)
    }

    /// The collection view counts a drop's destination without the item lifted out of the grid
    /// (checked on the iOS 26.5 simulator: page 0 dropped on the last of 3 gives 2, page 2 on the first gives 0).
    func testDropIndexFromTheCollectionViewsDestination() {
        XCTAssertEqual(PageGridViewController.dropIndex(destination: 2, origin: 0, pageCount: 3), 3)
        XCTAssertEqual(PageGridViewController.dropIndex(destination: 0, origin: 2, pageCount: 3), 0)
        XCTAssertEqual(PageGridViewController.dropIndex(destination: 1, origin: 1, pageCount: 3), 2)
        XCTAssertEqual(PageGridViewController.dropIndex(destination: nil, origin: 1, pageCount: 3), 3)
    }
}
