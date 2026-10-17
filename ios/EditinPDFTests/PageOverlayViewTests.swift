import UIKit
import XCTest
@testable import EditinPDF

// The overlay is a view, so these run on the main actor. It is never put in a window: layers keep
// their paths without being shown.
@MainActor
final class PageOverlayViewTests: XCTestCase {
    /// A US Letter page (612 x 792 points) shown 306 x 396 points: half a layout point to a PDF point.
    func makeOverlay(size: CGSize = CGSize(width: 306, height: 396)) -> PageOverlayView {
        let overlay = PageOverlayView(pointSize: CGSize(width: 612, height: 792))
        overlay.frame = CGRect(origin: .zero, size: size)
        overlay.layoutIfNeeded()
        return overlay
    }

    /// The rectangles a layer fills, one for each subpath `addRects` made.
    func rects(of layer: CAShapeLayer) -> [CGRect] {
        guard let path = layer.path else { return [] }
        var found: [CGRect] = []
        var corners: [CGPoint] = []
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                corners = [e.points[0]]
            case .addLineToPoint:
                corners.append(e.points[0])
            case .closeSubpath:
                if corners.count >= 4 {
                    let xs = corners.map(\.x), ys = corners.map(\.y)
                    found.append(CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                                        width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0)))
                }
                corners = []
            default:
                break
            }
        }
        return found
    }

    func testItDrawsNothingUntilItIsGivenBoxes() {
        let overlay = makeOverlay()
        XCTAssertNil(overlay.highlightLayer.path)
        XCTAssertNil(overlay.activeLayer.path)
        XCTAssertNil(overlay.selectionLayer.path)
        XCTAssertTrue(overlay.highlights.isEmpty)
        XCTAssertTrue(overlay.activeHighlights.isEmpty)
        XCTAssertTrue(overlay.selection.isEmpty)
    }

    /// Boxes are in PDF points; the overlay draws them `bounds.width / pointSize.width` times as big.
    func testBoxesAreScaledFromPDFPointsToTheBounds() {
        let overlay = makeOverlay()
        overlay.highlights = [CGRect(x: 72, y: 100, width: 100, height: 20), CGRect(x: 300, y: 500, width: 40, height: 10)]
        XCTAssertEqual(rects(of: overlay.highlightLayer), [CGRect(x: 36, y: 50, width: 50, height: 10),
                                                           CGRect(x: 150, y: 250, width: 20, height: 5)])
        overlay.activeHighlights = [CGRect(x: 72, y: 100, width: 100, height: 20)]
        XCTAssertEqual(rects(of: overlay.activeLayer), [CGRect(x: 36, y: 50, width: 50, height: 10)])
        overlay.selection = [CGRect(x: 0, y: 0, width: 612, height: 792)]
        XCTAssertEqual(rects(of: overlay.selectionLayer), [CGRect(x: 0, y: 0, width: 306, height: 396)])
    }

    /// The overlay is the page view's size and never changes it, but if it ever is resized the boxes
    /// follow: they are drawn at whatever scale the bounds give them.
    func testResizingRedrawsTheBoxesAtTheNewScale() {
        let overlay = makeOverlay()
        overlay.highlights = [CGRect(x: 72, y: 100, width: 100, height: 20)]
        overlay.frame = CGRect(x: 0, y: 0, width: 612, height: 792)
        overlay.layoutIfNeeded()
        XCTAssertEqual(rects(of: overlay.highlightLayer), [CGRect(x: 72, y: 100, width: 100, height: 20)])
        overlay.frame = CGRect(x: 0, y: 0, width: 153, height: 198)
        overlay.layoutIfNeeded()
        XCTAssertEqual(rects(of: overlay.highlightLayer), [CGRect(x: 18, y: 25, width: 25, height: 5)])
    }

    func testBoxesGivenBeforeTheOverlayHasASizeAreDrawnOnceItHasOne() {
        let overlay = PageOverlayView(pointSize: CGSize(width: 612, height: 792))
        overlay.highlights = [CGRect(x: 72, y: 100, width: 100, height: 20)]
        XCTAssertEqual(rects(of: overlay.highlightLayer), [], "no size yet, nothing to draw")
        overlay.frame = CGRect(x: 0, y: 0, width: 306, height: 396)
        overlay.layoutIfNeeded()
        XCTAssertEqual(rects(of: overlay.highlightLayer), [CGRect(x: 36, y: 50, width: 50, height: 10)])
    }

    func testClearingTheBoxesClearsTheDrawing() {
        let overlay = makeOverlay()
        overlay.highlights = [CGRect(x: 72, y: 100, width: 100, height: 20)]
        overlay.activeHighlights = [CGRect(x: 72, y: 100, width: 100, height: 20)]
        overlay.highlights = []
        overlay.activeHighlights = []
        XCTAssertNil(overlay.highlightLayer.path)
        XCTAssertNil(overlay.activeLayer.path)
    }

    func testAPageWithoutASizeDrawsNothingAndDoesNotTrap() {
        for size in [CGSize.zero, CGSize(width: 0, height: 792), CGSize(width: -612, height: 792), CGSize(width: CGFloat.nan, height: 792)] {
            let overlay = PageOverlayView(pointSize: size)
            overlay.frame = CGRect(x: 0, y: 0, width: 306, height: 396)
            overlay.highlights = [CGRect(x: 72, y: 100, width: 100, height: 20)]
            overlay.layoutIfNeeded()
            XCTAssertNil(overlay.highlightLayer.path, "\(size)")
        }
    }

    /// Yellow at 35 % for the hits, orange for the active one, light blue at 30 % for a selection.
    func testColours() throws {
        let overlay = makeOverlay()
        /// A layer's fill as red, green, blue and alpha.
        func fill(_ layer: CAShapeLayer) throws -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
            let color = UIColor(cgColor: try XCTUnwrap(layer.fillColor))
            var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
            return (r, g, b, a)
        }
        let yellow = try fill(overlay.highlightLayer)
        XCTAssertEqual(yellow.r, 1, accuracy: 0.01)
        XCTAssertEqual(yellow.g, 1, accuracy: 0.01)
        XCTAssertEqual(yellow.b, 0, accuracy: 0.01)
        XCTAssertEqual(yellow.a, 0.35, accuracy: 0.001)

        let orange = try fill(overlay.activeLayer)
        XCTAssertEqual(orange.r, 1, accuracy: 0.01)
        XCTAssertEqual(orange.g, 0.5, accuracy: 0.1, "orange: red full, green about half")
        XCTAssertEqual(orange.b, 0, accuracy: 0.01)
        XCTAssertGreaterThan(orange.a, yellow.a, "the active box stands out from the others")

        let blue = try fill(overlay.selectionLayer)
        XCTAssertGreaterThan(blue.b, blue.r, "blue")
        XCTAssertEqual(blue.a, 0.30, accuracy: 0.001)
    }

    /// The active hit's boxes are among the hits' boxes, and are drawn orange only: yellow under the
    /// orange would tint the text under it twice.
    func testTheActiveBoxesAreNotAlsoDrawnYellow() {
        let overlay = makeOverlay()
        let first = CGRect(x: 72, y: 100, width: 100, height: 20)
        let second = CGRect(x: 300, y: 500, width: 40, height: 10)
        let third = CGRect(x: 72, y: 120, width: 60, height: 20)
        overlay.highlights = [first, second, third]
        overlay.activeHighlights = [second, third]
        XCTAssertEqual(rects(of: overlay.highlightLayer), [CGRect(x: 36, y: 50, width: 50, height: 10)])
        XCTAssertEqual(rects(of: overlay.activeLayer), [CGRect(x: 150, y: 250, width: 20, height: 5),
                                                        CGRect(x: 36, y: 60, width: 30, height: 10)])
        // Taking the active hit away gives the yellow back.
        overlay.activeHighlights = []
        XCTAssertEqual(rects(of: overlay.highlightLayer).count, 3)
        XCTAssertNil(overlay.activeLayer.path)
        // The active boxes are drawn even if the page's list of hits does not have them.
        overlay.highlights = []
        overlay.activeHighlights = [second]
        XCTAssertNil(overlay.highlightLayer.path)
        XCTAssertEqual(rects(of: overlay.activeLayer), [CGRect(x: 150, y: 250, width: 20, height: 5)])
    }

    /// The active box is drawn over the others, and the selection under them.
    func testTheActiveBoxIsOnTop() throws {
        let overlay = makeOverlay()
        let layers = try XCTUnwrap(overlay.layer.sublayers)
        XCTAssertEqual(layers, [overlay.selectionLayer, overlay.highlightLayer, overlay.activeLayer])
    }

    /// Drawn over the page, but the page's gestures (Task 10's selection, the scroll view's own) are
    /// what the touches are for.
    func testItDoesNotTakeTouches() {
        let overlay = makeOverlay()
        XCTAssertFalse(overlay.isUserInteractionEnabled)
        XCTAssertFalse(overlay.isOpaque)
        XCTAssertNil(overlay.hitTest(CGPoint(x: 10, y: 10), with: nil))
    }

    /// Setting a layer's path animates it by default, which would blur a highlight into the next one.
    func testChangesAreNotAnimated() {
        let overlay = makeOverlay()
        for layer in [overlay.highlightLayer, overlay.activeLayer, overlay.selectionLayer] {
            XCTAssertTrue(layer.action(forKey: "path") is NSNull, "path")
            XCTAssertTrue(layer.action(forKey: "bounds") is NSNull, "bounds")
            XCTAssertTrue(layer.action(forKey: "fillColor") is NSNull, "fillColor")
        }
    }
}
