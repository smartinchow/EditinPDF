import CoreGraphics
import EditinPDFCore
import XCTest
@testable import EditinPDF

/// A page turned by `/Rotate`, end to end, as the viewer handles it: its size, a search hit's box,
/// and the pixels drawn under that box. `rotated.pdf` is one US Letter page with `/Rotate 90` that
/// reads "Rotated page", so it is shown landscape, with its line of text running down the page.
///
/// The viewer works in view space throughout (the page as shown: its rotation applied, origin at the
/// top-left, y down): the page's size from `pageInfo`, a hit's boxes from `search` and a tile's pixels
/// from `renderTile`. Were one of them in the page's own, unturned space, a highlight would sit on
/// blank paper. This checks that they agree, through the code the viewer draws with: the layout's
/// scale (which is the overlay's), `TileMath` and `TileRenderer`.
final class RotatedPageTests: XCTestCase {
    func openFixture() throws -> PdfDocument {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "rotated", withExtension: "pdf"))
        return try PdfDocument.open(bytes: Data(contentsOf: url), password: nil)
    }

    func testATurnedPageIsLandscape() throws {
        let info = try XCTUnwrap(try openFixture().pageInfo(page: 0))
        XCTAssertEqual(info.rotationDegrees, 90)
        XCTAssertGreaterThan(info.widthPt, info.heightPt, "a Letter page turned a quarter is landscape")
        XCTAssertEqual(info.widthPt, 792)
        XCTAssertEqual(info.heightPt, 612)
        let frame = PageLayout(pages: [info], fitWidth: 390).frame(of: 0)
        XCTAssertGreaterThan(frame.width, frame.height, "and laid out landscape")
    }

    func testASearchHitsBoxIsDrawnOverItsText() throws {
        let document = try openFixture()
        let info = try XCTUnwrap(document.pageInfo(page: 0))
        let pointSize = CGSize(width: info.widthPt, height: info.heightPt)
        let hit = try XCTUnwrap(document.search(query: "Rotated", caseSensitive: false).first, "no hit for the word on the page")
        XCTAssertEqual(hit.page, 0)
        let box = try XCTUnwrap(SearchController.rects(of: hit).first)
        // The line runs down the turned page: the box of a word is taller than it is wide, and is near
        // the right edge, where the top of the unturned page went.
        XCTAssertGreaterThan(box.height, box.width, "\(box)")
        XCTAssertGreaterThan(box.minX, pointSize.width / 2, "\(box)")

        // Under the box, the word's dark pixels (about 400 of them).
        XCTAssertGreaterThan(try Self.darkPixels(under: box, of: document, pointSize: pointSize), 50,
                             "the box \(box) is on blank paper")
        // Where the word is on the unturned page, the turned page shows blank paper. That is where the
        // box would be if the search gave its boxes in unturned space, and where the word would be drawn
        // if the tiles were, so the count above tells the two conventions apart.
        let unturned = CGRect(x: box.minY, y: pointSize.width - box.maxX, width: box.height, height: box.width)
        XCTAssertEqual(try Self.darkPixels(under: unturned, of: document, pointSize: pointSize), 0, "\(unturned)")
    }

    /// How many dark pixels the viewer draws under `box` (PDF points, view space) of page 0. The page is
    /// laid out one layout point to the PDF point, as on a screen as wide as the page, and drawn at 2
    /// device pixels to the layout point: the overlay puts the box at `box` times the layout's scale,
    /// and that area is the clip whose tile the page's layer asks the engine for.
    static func darkPixels(under box: CGRect, of document: PdfDocument, pointSize: CGSize) throws -> Int {
        let info = PageInfo(index: 0, widthPt: pointSize.width, heightPt: pointSize.height, rotationDegrees: 0, label: nil)
        let layout = PageLayout(pages: [info], fitWidth: pointSize.width)
        let scale = layout.scale(of: 0)
        let clip = box.applying(CGAffineTransform(scaleX: scale, y: scale))
        let request = try XCTUnwrap(TileMath.request(clip: clip, contextScale: 2, layerSize: layout.frame(of: 0).size,
                                                     pointSize: pointSize))
        XCTAssertEqual(request.scale, 2, "two device pixels to the PDF point")
        let tile = try document.renderTile(page: 0, scale: request.scale, rect: request.rect)
        let pixels = try TileRendererTests.pixels(of: try XCTUnwrap(TileRenderer.image(for: tile)))
        return stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 128 && pixels[$0 + 1] < 128 && pixels[$0 + 2] < 128 }.count
    }
}
