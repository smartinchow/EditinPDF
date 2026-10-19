import EditinPDFCore
import XCTest
@testable import EditinPDF

@MainActor
final class AnnotationIndexTests: XCTestCase {
    func testHitPicksTheTopmost() {
        let a = info(index: 0, rect: CGRect(x: 0, y: 0, width: 100, height: 100)), b = info(index: 3, rect: CGRect(x: 50, y: 50, width: 20, height: 20))
        let idx = AnnotationIndex([a, b])
        XCTAssertEqual(idx.hit(page: 0, at: CGPoint(x: 55, y: 55))?.index, 3)
        XCTAssertEqual(idx.hit(page: 0, at: CGPoint(x: 105, y: 50))?.index, 0)        // within slop
        XCTAssertNil(idx.hit(page: 1, at: CGPoint(x: 55, y: 55)))
    }

    func testAMissOutsideTheSlopFindsNothing() {
        let idx = AnnotationIndex([info(index: 0, y: 100)])
        XCTAssertNil(idx.hit(page: 0, at: CGPoint(x: 5, y: 80)))
        XCTAssertEqual(idx.hit(page: 0, at: CGPoint(x: 5, y: 93))?.index, 0)
        XCTAssertNil(idx.hit(page: 0, at: CGPoint(x: 5, y: 93), slop: 0))
    }

    func testAnnotationsAreKeptByPageInTheEnginesOrder() {
        let idx = AnnotationIndex([info(page: 1, index: 0, y: 0), info(page: 0, index: 0, y: 5), info(page: 1, index: 1, y: 9)])
        XCTAssertEqual(idx.annotations(onPage: 1).map(\.index), [0, 1])
        XCTAssertEqual(idx.annotations(onPage: 0).count, 1)
        XCTAssertTrue(idx.annotations(onPage: 7).isEmpty)
    }

    func testTheModelsIndexIsReadAgainAfterEachChange() async throws {
        let (m, _) = try makeModel(fixture: "annotated")
        await m.settle()
        let page = try XCTUnwrap(m.annotationsByPage.keys.min())
        let before = m.annotationIndex.annotations(onPage: page)
        let first = try XCTUnwrap(before.first)
        let r = first.rect
        XCTAssertEqual(m.annotationIndex.hit(page: page, at: CGPoint(x: r.x + r.width / 2, y: r.y + r.height / 2))?.page, first.page)
        await m.perform(.deleteAnnotation(page: UInt32(page), index: first.index), named: Strings.actionDeleteAnnotation, touching: [page])
        XCTAssertEqual(m.annotationIndex.annotations(onPage: page).count, before.count - 1)
    }
}
