import CoreGraphics
import EditinPDFCore
import XCTest
@testable import EditinPDF

final class TileRendererTests: XCTestCase {
    func testMakesImageOfRequestedSize() throws {
        let t = RenderedTile(width: 2, height: 2, rgba: Data([255,0,0,255, 0,255,0,255, 0,0,255,255, 0,0,0,0]))
        let img = try XCTUnwrap(TileRenderer.image(for: t))
        XCTAssertEqual(img.width, 2); XCTAssertEqual(img.height, 2)
        XCTAssertEqual(img.alphaInfo, .premultipliedLast)
    }

    // MARK: Beyond the brief's test

    func testTheFirstRowIsTheTopAndTheBytesAreRGBA() throws {
        // Red, green / blue, clear: drawn upright, the image must read back in the same order, which
        // pins both the channel order and that the engine's first row is the top of the picture.
        let bytes: [UInt8] = [255,0,0,255, 0,255,0,255, 0,0,255,255, 0,0,0,0]
        let image = try XCTUnwrap(TileRenderer.image(for: RenderedTile(width: 2, height: 2, rgba: Data(bytes))))
        XCTAssertEqual(try Self.pixels(of: image), bytes)
    }

    func testRefusesPixelsThatDoNotMatchTheSize() {
        XCTAssertNil(TileRenderer.image(for: RenderedTile(width: 2, height: 2, rgba: Data(count: 15))))
        XCTAssertNil(TileRenderer.image(for: RenderedTile(width: 0, height: 0, rgba: Data())))
    }

    func testDrawsAnEngineTile() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "hello", withExtension: "pdf"))
        let document = try PdfDocument.open(bytes: Data(contentsOf: url), password: nil)
        let tile = try document.renderTile(page: 0, scale: 1, rect: TileRect(x: 0, y: 0, width: 256, height: 128))
        let image = try XCTUnwrap(TileRenderer.image(for: tile))
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(image.height, 128)
        // The page is opaque white paper: the corner pixel reads back as that.
        XCTAssertEqual(Array(try Self.pixels(of: image).prefix(4)), [255, 255, 255, 255])
    }

    /// `image` drawn upright into an sRGB RGBA bitmap, as bytes from the top-left pixel, row by row.
    static func pixels(of image: CGImage) throws -> [UInt8] {
        let (width, height) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                                  bytesPerRow: width * 4, space: space,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }
}
