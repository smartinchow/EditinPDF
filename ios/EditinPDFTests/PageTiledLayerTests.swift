import EditinPDFCore
import UIKit
import XCTest
@testable import EditinPDF

/// The page's layer drawing a tile while the page changes under it: the tile the engine was drawing
/// may show the page as it was, so it is not kept.
@MainActor
final class PageTiledLayerTests: XCTestCase {
    /// A 100 x 100 point page on a layer of the same size, whose tiles the engine draws black once
    /// `gate` lets it; `started` is signalled when a tile has been asked for.
    private func makeLayer(started: DispatchSemaphore, gate: DispatchSemaphore) -> PageTiledLayer {
        let layer = PageTiledLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        layer.attach(PageTiledLayer.Source(page: 0, pointSize: CGSize(width: 100, height: 100)) { _, _, rect in
            started.signal()
            gate.wait()
            // Opaque black, premultiplied RGBA.
            let count = Int(rect.width) * Int(rect.height)
            var pixels = Data(count: count * 4)
            for index in 0..<count { pixels[index * 4 + 3] = 255 }
            return RenderedTile(width: rect.width, height: rect.height, rgba: pixels)
        })
        return layer
    }

    /// A 100 x 100 bitmap filled with red, so paper (white) and the engine's tile (black) both show.
    private func makeContext() throws -> CGContext {
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                                              space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        // Core Animation hands a layer a y-down context.
        context.translateBy(x: 0, y: 100)
        context.scaleBy(x: 1, y: -1)
        return context
    }

    /// The red, green and blue of the bitmap's middle pixel.
    private func middle(of context: CGContext) throws -> [UInt8] {
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = 50 * context.bytesPerRow + 50 * 4
        return [data[offset], data[offset + 1], data[offset + 2]]
    }

    /// Draws a tile of `layer` into `context` off the main thread, running `meanwhile` once the engine
    /// has been asked and before it answers.
    private func drawTile(_ layer: PageTiledLayer, into context: CGContext, started: DispatchSemaphore,
                          gate: DispatchSemaphore, meanwhile: () -> Void) async {
        nonisolated(unsafe) let layer = layer
        nonisolated(unsafe) let context = context
        let drawing = Task.detached { layer.draw(in: context) }
        await Task.detached { Self.waitFor(started) }.value
        meanwhile()
        gate.signal()
        await drawing.value
    }

    /// Waits on `semaphore`, off the main thread (a semaphore cannot be waited on in async code).
    private nonisolated static func waitFor(_ semaphore: DispatchSemaphore) {
        semaphore.wait()
    }

    func testATileDrawnWhileThePageStaysTheSameIsKept() async throws {
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let layer = makeLayer(started: started, gate: gate)
        let context = try makeContext()
        await drawTile(layer, into: context, started: started, gate: gate) {}
        XCTAssertEqual(try middle(of: context), [0, 0, 0], "the engine's tile is drawn")
    }

    func testATileDrawnAcrossAChangeIsNotKept() async throws {
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let layer = makeLayer(started: started, gate: gate)
        let context = try makeContext()
        await drawTile(layer, into: context, started: started, gate: gate) {
            layer.invalidateContent()
        }
        XCTAssertEqual(try middle(of: context), [255, 255, 255], "paper, not the page as it was")
        XCTAssertEqual(layer.generation, 1)
    }

    /// The page view's redraw moves its layer's generation on.
    func testRedrawingAPageViewInvalidatesItsTiles() throws {
        let model = DocumentModel(bytes: PageScrollViewControllerTests.letterPages(1))
        let document = try XCTUnwrap(model.document())
        let view = PageView(page: 0, document: document, pointSize: CGSize(width: 612, height: 792))
        let layer = try XCTUnwrap(view.layer as? PageTiledLayer)
        XCTAssertEqual(layer.generation, 0)
        view.redraw()
        XCTAssertEqual(layer.generation, 1)
    }
}
