import CoreGraphics
import EditinPDFCore
import XCTest
@testable import EditinPDF

final class TileMathTests: XCTestCase {
    // A US Letter page (612 x 792 pt) laid out 402 points wide and 520 tall, as on an iPhone 17 Pro
    // in portrait; its context is 3 device pixels per layer point at zoom 1.
    let pointSize = CGSize(width: 612, height: 792)
    let layerSize = CGSize(width: 402, height: 520)

    func request(_ clip: CGRect, _ contextScale: CGFloat) -> TileMath.Request? {
        TileMath.request(clip: clip, contextScale: contextScale, layerSize: layerSize, pointSize: pointSize)
    }

    /// The tiles Core Animation asks for at `contextScale`: 1024 device pixels square from the
    /// top-left corner, cut off at the layer's edges, with the floating-point noise it comes with.
    func grid(_ contextScale: CGFloat) -> [CGRect] {
        let side = 1024 / contextScale
        let bounds = CGRect(origin: .zero, size: layerSize)
        var tiles: [CGRect] = []
        var y: CGFloat = 0
        while y < layerSize.height {
            var x: CGFloat = 0
            while x < layerSize.width {
                tiles.append(CGRect(x: x, y: y, width: side, height: side).intersection(bounds))
                x += side
            }
            y += side
        }
        return tiles
    }

    func testTheScaleIsDevicePixelsPerPDFPoint() throws {
        let r = try XCTUnwrap(request(CGRect(x: 0, y: 0, width: 1024.0 / 3, height: 1024.0 / 3), 3))
        // 3 pixels per layer point, 402 / 612 layer points per PDF point.
        XCTAssertEqual(r.scale, 3 * 402 / 612, accuracy: 1e-12)
        XCTAssertEqual(r.rect, TileRect(x: 0, y: 0, width: 1024, height: 1024))
        XCTAssertEqual(r.destination.minX, 0)
        XCTAssertEqual(r.destination.width, 1024.0 / 3, accuracy: 1e-9)
    }

    func testTilesCoverThePageOnceWithSharedEdgesAtEveryLevelOfDetail() throws {
        // 2 and 3 are the screen scales; the rest are the magnified levels up to 16x a 3x screen.
        for contextScale: CGFloat in [2, 3, 6, 12, 24, 48] {
            let pageWidth = Int((layerSize.width * contextScale).rounded(.up))
            let pageHeight = Int((layerSize.height * contextScale).rounded(.up))
            var covered = 0
            for clip in grid(contextScale) {
                let r = try XCTUnwrap(request(clip, contextScale), "\(clip) at \(contextScale)")
                // Every tile starts on Core Animation's 1024-pixel grid, so it ends where the next starts...
                XCTAssertEqual(r.rect.x % 1024, 0, "\(clip) at \(contextScale)")
                XCTAssertEqual(r.rect.y % 1024, 0, "\(clip) at \(contextScale)")
                XCTAssertLessThanOrEqual(r.rect.width, 1024)
                XCTAssertLessThanOrEqual(r.rect.height, 1024)
                // ...or at the page's edge, and is drawn exactly over its own pixels.
                XCTAssertTrue(Int(r.rect.width) == 1024 || Int(r.rect.x + r.rect.width) == pageWidth)
                XCTAssertTrue(Int(r.rect.height) == 1024 || Int(r.rect.y + r.rect.height) == pageHeight)
                XCTAssertEqual(r.destination.minX * contextScale, CGFloat(r.rect.x), accuracy: 1e-6)
                XCTAssertEqual(r.destination.maxY * contextScale, CGFloat(r.rect.y + r.rect.height), accuracy: 1e-6)
                covered += Int(r.rect.width) * Int(r.rect.height)
            }
            // No pixel left out and none drawn twice.
            XCTAssertEqual(covered, pageWidth * pageHeight, "at \(contextScale)")
        }
    }

    func testATileAtThePageEdgeStopsThere() throws {
        // The page is 402 x 3 = 1206 pixels wide, so the second column is 182 pixels.
        let r = try XCTUnwrap(request(CGRect(x: 1024.0 / 3, y: 0, width: 1024.0 / 3, height: 1024.0 / 3), 3))
        XCTAssertEqual(r.rect, TileRect(x: 1024, y: 0, width: 182, height: 1024))
        XCTAssertEqual(r.destination.maxX, 402, accuracy: 1e-9)
    }

    func testZoomingInRaisesTheScaleNotTheTileSize() throws {
        // Zoom 8 on a 3x screen: 24 pixels per layer point, a page 9648 x 12480 pixels.
        let side = 1024.0 / 24
        let r = try XCTUnwrap(request(CGRect(x: 5 * side, y: 3 * side, width: side, height: side), 24))
        XCTAssertEqual(r.scale, 24 * 402 / 612, accuracy: 1e-12)
        XCTAssertEqual(r.rect, TileRect(x: 5_120, y: 3_072, width: 1024, height: 1024))
    }

    func testNoTileIsLargerThan1024Pixels() throws {
        // Core Animation never asks for more than its tile size, but if it did, the engine would
        // still be asked for 1024 pixels at most, drawn where they belong.
        let r = try XCTUnwrap(request(CGRect(x: 0, y: 0, width: 402, height: 520), 3))
        XCTAssertEqual(r.rect, TileRect(x: 0, y: 0, width: 1024, height: 1024))
        XCTAssertEqual(r.destination.width, 1024.0 / 3, accuracy: 1e-9)
    }

    func testAClipBetweenPixelsIsCoveredOutward() throws {
        let r = try XCTUnwrap(request(CGRect(x: 0.1, y: 0.1, width: 10, height: 10), 3))
        // 0.3 ... 30.3 pixels: every pixel the clip touches is drawn.
        XCTAssertEqual(r.rect, TileRect(x: 0, y: 0, width: 31, height: 31))
    }

    // MARK: The engine's range of scales

    /// A page narrower than about 24 points, zoomed in all the way, would want more pixels to the PDF
    /// point than the engine draws a tile at (400): it is asked for its largest, and the tile is
    /// enlarged to cover the clip, instead of the engine refusing it.
    func testANarrowPageZoomedAllTheWayInIsDrawnAtTheEnginesLargestScale() throws {
        let narrow = CGSize(width: 20, height: 26)            // laid out 402 x 523 at zoom 1
        let layer = CGSize(width: 402, height: 523)
        // The 16x level of a 3x screen: 48 pixels per layer point, 964.8 to the PDF point.
        let contextScale: CGFloat = 48
        let side = 1024 / contextScale
        for clip in [CGRect(x: 0, y: 0, width: side, height: side), CGRect(x: 3 * side, y: 7 * side, width: side, height: side)] {
            let r = try XCTUnwrap(TileMath.request(clip: clip, contextScale: contextScale, layerSize: layer, pointSize: narrow))
            XCTAssertEqual(r.scale, maxTileScale(), "the engine's largest, not 964.8")
            XCTAssertTrue(r.isEnlarged)
            XCTAssertLessThanOrEqual(r.rect.width, 1024)
            // The engine's pixels cover the whole clip, so the tile has no gap at its edges.
            XCTAssertTrue(r.destination.insetBy(dx: -1e-9, dy: -1e-9).contains(clip), "\(r.destination) does not cover \(clip)")
            // And they are its own: 400 to the PDF point is 400 * 20 / 402 to the layer point.
            XCTAssertEqual(r.destination.width * 400 * 20 / 402, CGFloat(r.rect.width), accuracy: 1e-6)
        }
        // Below the largest scale nothing changes.
        let r = try XCTUnwrap(request(CGRect(x: 0, y: 0, width: 1024.0 / 48, height: 1024.0 / 48), 48))
        XCTAssertEqual(r.scale, 48 * 402 / 612, accuracy: 1e-12)
        XCTAssertFalse(r.isEnlarged)
    }

    /// What the page view asks for at the deepest zoom of a narrow page is what the engine draws.
    func testTheEngineDrawsACappedRequest() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "hello", withExtension: "pdf"))
        let document = try PdfDocument.open(bytes: Data(contentsOf: url), password: nil)
        // The 612-point page laid out as if it were 25 times narrower than it is: 1,224 pixels to its point.
        let layer = CGSize(width: 612 * 25, height: 792 * 25)
        let r = try XCTUnwrap(TileMath.request(clip: CGRect(x: 2_000, y: 2_000, width: 1024.0 / 48, height: 1024.0 / 48),
                                               contextScale: 48, layerSize: layer, pointSize: pointSize))
        XCTAssertEqual(r.scale, maxTileScale())
        let tile = try document.renderTile(page: 0, scale: r.scale, rect: r.rect)
        XCTAssertEqual(tile.width, r.rect.width)
        XCTAssertEqual(tile.height, r.rect.height)
    }

    /// A page so wide that even the screen's own resolution is below the smallest scale the engine
    /// draws a tile at (0.01 pixels to the point, a page over 75,000 points wide: only a hostile file
    /// has one) asks for nothing; the page view leaves it blank.
    func testAPageTooWideForTheEnginesSmallestScaleAsksForNothing() {
        let wide = CGSize(width: 1e6, height: 1e6)
        XCTAssertNil(TileMath.request(clip: CGRect(x: 0, y: 0, width: 100, height: 100), contextScale: 2,
                                      layerSize: CGSize(width: 402, height: 402), pointSize: wide))
        // At the smallest scale exactly, it is drawn.
        let atTheSmallest = CGSize(width: 402 * 2 / minTileScale(), height: 100)
        XCTAssertNotNil(TileMath.request(clip: CGRect(x: 0, y: 0, width: 100, height: 100), contextScale: 2,
                                         layerSize: CGSize(width: 402, height: 402), pointSize: atTheSmallest))
    }

    func testNothingToDrawAsksForNothing() {
        XCTAssertNil(request(CGRect(x: 500, y: 0, width: 10, height: 10), 3))       // right of the page
        XCTAssertNil(request(CGRect(x: -20, y: -20, width: 10, height: 10), 3))     // above and left of it
        XCTAssertNil(request(.null, 3))
        XCTAssertNil(request(.infinite, 3))
        XCTAssertNil(request(CGRect(x: 0, y: 0, width: 10, height: 10), 0))
        XCTAssertNil(request(CGRect(x: 0, y: 0, width: 10, height: 10), .nan))
        XCTAssertNil(TileMath.request(clip: CGRect(x: 0, y: 0, width: 10, height: 10), contextScale: 3,
                                      layerSize: .zero, pointSize: pointSize))
        XCTAssertNil(TileMath.request(clip: CGRect(x: 0, y: 0, width: 10, height: 10), contextScale: 3,
                                      layerSize: layerSize, pointSize: .zero))
    }
}
