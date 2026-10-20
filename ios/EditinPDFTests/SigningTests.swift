import EditinPDFCore
import PDFKit
import PencilKit
import UIKit
import XCTest
@testable import EditinPDF

/// Sign: picking the tool, the pad a signature is drawn and saved in, and a tap that places the saved
/// signature on the page as ink. As in `ShapeDrawingTests`, the touches are for the simulator: here
/// the hooks are called the way the gestures call them.
@MainActor
final class SigningTests: XCTestCase {
    /// A made-up squiggle and a stroke under it, normalised.
    static func squiggle() throws -> SavedSignature {
        let wave = (0...120).map { CGPoint(x: Double($0) * 2, y: 40 + 25 * sin(Double($0) / 9)) }
        let underline = [CGPoint(x: 10, y: 90), CGPoint(x: 230, y: 84)]
        return try XCTUnwrap(SignatureStore.normalise([wave, underline]))
    }

    /// `pages` US Letter pages in a 400 x 800 view, Sign picked, with an undo manager; a squiggle saved
    /// in the model's (test's own) store when `signed`.
    func makeController(pages: Int = 3, data: Data? = nil, signed: Bool = true) async throws -> (PageScrollViewController, DocumentModel, UndoManager) {
        let model = isolatedModel(bytes: data ?? PageScrollViewControllerTests.letterPages(pages))
        let undoManager = UndoManager()
        model.undoManager = undoManager
        if signed { try model.signatures.save(try Self.squiggle()) }
        let controller = PageScrollViewController(model: model)
        controller.view.frame = CGRect(origin: .zero, size: CGSize(width: 400, height: 800))
        controller.view.layoutIfNeeded()
        await model.settle()
        pick(.signature, in: model, controller)
        return (controller, model, undoManager)
    }

    /// Picks `tool`, as the palette and SwiftUI's update of the scroll view do.
    func pick(_ tool: Tool?, in model: DocumentModel, _ controller: PageScrollViewController) {
        if let tool { model.pick(tool) } else { model.tool = nil }
        controller.markupTool = tool
    }

    /// `point` (PDF points on `page`) in the content view's coordinates.
    func contentPoint(_ point: CGPoint, page: Int = 0, in controller: PageScrollViewController) throws -> CGPoint {
        let frame = try XCTUnwrap(controller.pageView(for: page)).frame
        let scale = frame.width / CGFloat(controller.model.pages[page].widthPt)
        return CGPoint(x: frame.minX + point.x * scale, y: frame.minY + point.y * scale)
    }

    /// The box of all of `strokes`' points.
    func bounds(_ strokes: [[CGPoint]]) -> CGRect {
        let points = strokes.joined()
        guard let first = points.first else { return .null }
        return points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    // MARK: Picking Sign, the pad

    /// With no signature saved, picking Sign opens the pad; with one, it does not, and Sign is picked
    /// either way.
    func testPickingSignWithNoSignatureOpensThePad() async throws {
        let (m, _) = try makeModel()
        await m.settle()
        XCTAssertNil(m.signatures.saved)
        m.pick(.signature)
        XCTAssertEqual(m.tool, .signature)
        XCTAssertTrue(m.showsSignaturePad, "no signature yet: the pad opens")
        m.showsSignaturePad = false
        try m.signatures.save(try Self.squiggle())
        m.pick(.select)
        m.pick(.signature)
        XCTAssertEqual(m.tool, .signature)
        XCTAssertFalse(m.showsSignaturePad, "a signature is saved: the next tap places it")
        m.pick(.ink)
        XCTAssertFalse(m.showsSignaturePad)
    }

    /// Save keeps the signature and puts the pad away; a save that fails says why and leaves the pad
    /// up, with what was drawn in it.
    func testSavingFromThePadKeepsTheSignature() async throws {
        let (m, _) = try makeModel()
        m.showsSignaturePad = true
        let s = try Self.squiggle()
        XCTAssertTrue(m.saveSignature(s))
        XCTAssertEqual(m.signatures.saved, s)
        XCTAssertFalse(m.showsSignaturePad)
        XCTAssertNil(m.failure)

        // A store whose folder cannot be made (a file is in its place) cannot save.
        let blocked = FileManager.default.temporaryDirectory.appending(path: "SigningTests-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocked)
        addTeardownBlock { try? FileManager.default.removeItem(at: blocked) }
        let other = DocumentModel(outcome: OpenOutcome(bytes: try fixtureData("sample")), toolStyles: isolatedToolStyles(),
                                  signatures: SignatureStore(directory: blocked))
        other.showsSignaturePad = true
        XCTAssertFalse(other.saveSignature(s))
        XCTAssertEqual(other.failure?.message, Strings.signatureNotSaved)
        XCTAssertTrue(other.showsSignaturePad, "the pad stays, with the drawing")
        XCTAssertNil(other.signatures.saved)
    }

    /// Delete Signature forgets it; deleting with none saved is no failure.
    func testDeletingTheSignature() async throws {
        let (m, _) = try makeModel()
        try m.signatures.save(try Self.squiggle())
        m.deleteSignature()
        XCTAssertNil(m.signatures.saved)
        XCTAssertNil(SignatureStore(directory: m.signatures.directory).saved, "the file is gone")
        m.deleteSignature()
        XCTAssertNil(m.failure)
    }

    /// The pad's drawing becomes a signature from the points along each stroke's path (sampled, so
    /// curves survive), not only from the points PencilKit's spline is controlled by.
    func testThePadReadsThePointsAlongEachStroke() throws {
        let controlPoints = [CGPoint(x: 20, y: 100), CGPoint(x: 80, y: 20), CGPoint(x: 140, y: 180), CGPoint(x: 200, y: 20), CGPoint(x: 260, y: 100)]
        let drawing = PKDrawing(strokes: [InkGeometryTests.stroke(controlPoints)])
        let s = try XCTUnwrap(SignaturePadSheet.signature(of: drawing))
        let stroke = try XCTUnwrap(s.strokes.first)
        XCTAssertGreaterThan(stroke.count, 3 * controlPoints.count, "the path was sampled, not only its control points")
        XCTAssertTrue(s.isValid)
        XCTAssertNil(SignaturePadSheet.signature(of: PKDrawing()), "nothing drawn")
        XCTAssertNil(SignaturePadSheet.signature(of: PKDrawing(strokes: [InkGeometryTests.stroke([CGPoint(x: 50, y: 50)])])), "a dot")
    }

    /// Turned on its side, the pad is wider and lower: what was drawn keeps its place on the line to
    /// sign along, in the middle, and is shrunk about that point only as far as it must be to fit.
    func testWhatIsDrawnStaysInViewWhenThePadChangesSize() {
        let upright = CGSize(width: 360, height: 640), onItsSide = CGSize(width: 760, height: 230)
        // A signature 300 x 100 sitting on the line (at 0.65 of 640 = 416) of the upright pad.
        let drawn = CGRect(x: 30, y: 330, width: 300, height: 100)
        let turned = drawn.applying(SignatureCanvasView.keepingInView(drawn, from: upright, to: onItsSide))
        XCTAssertGreaterThanOrEqual(turned.minX, -1e-9); XCTAssertGreaterThanOrEqual(turned.minY, -1e-9)
        XCTAssertLessThanOrEqual(turned.maxX, onItsSide.width + 1e-9); XCTAssertLessThanOrEqual(turned.maxY, onItsSide.height + 1e-9)
        XCTAssertEqual(turned.width / turned.height, 3, accuracy: 1e-9, "its proportions are kept")
        // The point of the line it sat on is the same point of the new line.
        let anchor = CGPoint(x: 180, y: 416).applying(SignatureCanvasView.keepingInView(drawn, from: upright, to: onItsSide))
        XCTAssertEqual(anchor.x, 380, accuracy: 1e-9); XCTAssertEqual(anchor.y, 230 * 0.65, accuracy: 1e-9)
        // One too high for the pad on its side is shrunk, about that point, until it fits.
        let tall = CGRect(x: 30, y: 200, width: 300, height: 300)
        let shrunk = tall.applying(SignatureCanvasView.keepingInView(tall, from: upright, to: onItsSide))
        XCTAssertLessThan(shrunk.height, 300)
        XCTAssertEqual(shrunk.minY, 0, accuracy: 1e-9, "shrunk until its top is on the pad's edge")
        XCTAssertLessThanOrEqual(shrunk.maxY, onItsSide.height + 1e-9)
        XCTAssertEqual(shrunk.width, shrunk.height, accuracy: 1e-9)
        // Back upright, a drawing that fits is only moved, not grown.
        let small = CGRect(x: 300, y: 120, width: 160, height: 40)
        let back = small.applying(SignatureCanvasView.keepingInView(small, from: onItsSide, to: upright))
        XCTAssertEqual(back.width, 160, accuracy: 1e-9); XCTAssertEqual(back.height, 40, accuracy: 1e-9)
        XCTAssertEqual(back.midX - 180, small.midX - 380, accuracy: 1e-9)

        // The canvas does it as it is laid out at its new size.
        let canvas = SignatureCanvasView(frame: CGRect(origin: .zero, size: upright))
        canvas.layoutIfNeeded()
        canvas.drawing = PKDrawing(strokes: [InkGeometryTests.stroke([CGPoint(x: 40, y: 360), CGPoint(x: 180, y: 300), CGPoint(x: 320, y: 410)])])
        canvas.frame = CGRect(origin: .zero, size: onItsSide)
        canvas.layoutIfNeeded()
        let shown = canvas.drawing.bounds
        XCTAssertTrue(CGRect(origin: .zero, size: onItsSide).contains(shown), "\(shown) is out of the pad on its side")
    }

    // MARK: Placing

    /// A tap with Sign on a page puts the saved signature there, centred on the tap, at its default
    /// width: one change, named Add Signature, drawn over the page until the page shows it.
    func testATapPlacesTheSignatureCentredOnIt() async throws {
        let (controller, model, undoManager) = try await makeController()
        let markup = controller.markupInteraction
        let tap = CGPoint(x: 300, y: 400)
        let onPage = try contentPoint(tap, in: controller)
        XCTAssertTrue(markup.takesTap(atContentPoint: onPage))
        XCTAssertFalse(markup.takesTap(atContentPoint: try contentPoint(CGPoint(x: 300, y: 795), in: controller)), "the gap between pages")
        XCTAssertFalse(markup.takesTouch(atContentPoint: onPage), "a drag scrolls")
        let expected = try XCTUnwrap(model.signatureStrokes(onPage: 0, centeredAt: tap))
        XCTAssertEqual(bounds(expected).midX, tap.x, accuracy: 1e-6)
        XCTAssertEqual(bounds(expected).midY, tap.y, accuracy: 1e-6)
        XCTAssertEqual(bounds(expected).width, 150, accuracy: 1e-6)

        markup.place(atContentPoint: onPage)
        let overlay = try XCTUnwrap(controller.pageView(for: 0)).overlay
        XCTAssertEqual(overlay.signatures.count, 1, "drawn over the page at once")
        let drawn = bounds(try XCTUnwrap(overlay.signatures.first).strokes)
        for (got, want) in [(drawn.minX, bounds(expected).minX), (drawn.minY, bounds(expected).minY),
                            (drawn.width, bounds(expected).width), (drawn.height, bounds(expected).height)] {
            XCTAssertEqual(got, want, accuracy: 1e-3, "drawn where it is placed")
        }
        await model.settle()
        let ink = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first)
        XCTAssertEqual(ink.kind, .ink)
        InkGeometryTests.assertBox(ink.rect, isAround: bounds(expected), width: SignatureStore.lineWidth)
        XCTAssertEqual(undoManager.undoActionName, Strings.actionSign)
        XCTAssertFalse(model.showsSignaturePad)
        try await Task.sleep(for: MarkupInteraction.inkPreviewDuration + .milliseconds(300))
        XCTAssertTrue(try XCTUnwrap(controller.pageView(for: 0)).overlay.signatures.isEmpty, "the picture goes once the page shows it")
    }

    /// Each tap places one signature, one change each: two taps, two drawings; one undo takes back the
    /// second only.
    func testEachTapIsOneSignatureAndOneStep() async throws {
        let (controller, model, undoManager) = try await makeController()
        let markup = controller.markupInteraction
        // Two taps are two events, each its own undo group; made in one test event, they are grouped
        // as two.
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        let first = try XCTUnwrap(markup.placeSignature(onPage: 0, at: CGPoint(x: 200, y: 200)))
        undoManager.endUndoGrouping()
        undoManager.beginUndoGrouping()
        let second = try XCTUnwrap(markup.placeSignature(onPage: 0, at: CGPoint(x: 400, y: 600)))
        undoManager.endUndoGrouping()
        let firstMade = await first.value, secondMade = await second.value
        XCTAssertTrue(firstMade); XCTAssertTrue(secondMade)
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).count, 2)
        undoManager.undo(); await model.settle()
        let left = try XCTUnwrap(model.annotationIndex.annotations(onPage: 0).first)
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).count, 1)
        XCTAssertEqual(left.rect.x + left.rect.width / 2, 200, accuracy: 1, "the second one went")
        undoManager.undo(); await model.settle()
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
        XCTAssertFalse(undoManager.canUndo)
    }

    /// With no signature saved, a tap with Sign opens the pad and places nothing.
    func testATapWithNoSignatureOpensThePad() async throws {
        let (controller, model, undoManager) = try await makeController(signed: false)
        model.showsSignaturePad = false
        let markup = controller.markupInteraction
        let onPage = try contentPoint(CGPoint(x: 300, y: 400), in: controller)
        XCTAssertTrue(markup.takesTap(atContentPoint: onPage))
        markup.place(atContentPoint: onPage)
        XCTAssertTrue(model.showsSignaturePad)
        await model.settle()
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
        XCTAssertFalse(undoManager.canUndo)
        XCTAssertTrue(try XCTUnwrap(controller.pageView(for: 0)).overlay.signatures.isEmpty)
    }

    /// The signature is drawn black, 1.5 points wide, as ink in the file.
    func testThePlacedSignatureIsBlackAndOneAndAHalfPointsWide() async throws {
        let (m, _) = try makeModel()
        try m.signatures.save(try Self.squiggle())
        let made = await m.addSignature(page: 0, at: CGPoint(x: 300, y: 300))
        XCTAssertTrue(made)
        let saved = try XCTUnwrap(m.document()).save(mode: .incremental)
        let ink = try XCTUnwrap(PDFDocument(data: saved)?.page(at: 0)?.annotations.first { $0.type == "Ink" })
        XCTAssertEqual(try XCTUnwrap(ink.border).lineWidth, 1.5, accuracy: 0.001)
        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 0
        ink.color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        for component in [red, green, blue] { XCTAssertEqual(component, 0, accuracy: 0.01, "not black") }
    }

    /// The signature placed is ink like any drawing: Select picks it and moves it, and the eraser takes
    /// it off.
    func testThePlacedSignatureIsInkToSelectMoveAndErase() async throws {
        let (m, u) = try makeModel()
        try m.signatures.save(try Self.squiggle())
        let placed = await m.addSignature(page: 0, at: CGPoint(x: 300, y: 300))
        XCTAssertTrue(placed)
        let before = try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).first).rect
        m.selectAnnotation(page: 0, at: CGPoint(x: before.x + before.width / 2, y: before.y + before.height / 2))
        XCTAssertEqual(m.selectedAnnotationInfo?.kind, .ink)
        let moved = await m.moveSelectedAnnotation(by: CGSize(width: 40, height: 20))
        XCTAssertTrue(moved)
        let after = try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).first).rect
        XCTAssertEqual(after.x - before.x, 40, accuracy: 0.5)
        XCTAssertEqual(after.y - before.y, 20, accuracy: 0.5)
        let erased = await m.erase(page: 0, along: [CGPoint(x: after.x - 5, y: after.y + after.height / 2),
                                                     CGPoint(x: after.x + after.width + 5, y: after.y + after.height / 2)])
        XCTAssertTrue(erased)
        XCTAssertTrue(m.annotationIndex.annotations(onPage: 0).isEmpty)
        u.undo(); await m.settle()
        XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).count, 1, "the erase is undone")
    }

    /// A signature as big as the store keeps is one change the bridge takes.
    func testTheBiggestSignatureIsOneChangeTheBridgeTakes() async throws {
        var strokes: [[CGPoint]] = [(0..<30_000).map { CGPoint(x: Double($0) * 0.02, y: $0 % 2 == 0 ? 0 : 100) }]
        for i in 0..<1_199 {
            strokes.append((0..<200).map { CGPoint(x: Double(i % 40) * 15 + Double($0 % 2) * 10, y: Double(i / 40) * 3 + Double($0) * 0.5) })
        }
        let (m, u) = try makeModel()
        try m.signatures.save(try XCTUnwrap(SignatureStore.normalise(strokes)))
        let made = await m.addSignature(page: 0, at: CGPoint(x: 300, y: 300))
        XCTAssertTrue(made, String(describing: m.failure))
        XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).count, 1)
        u.undo(); await m.settle()
        XCTAssertTrue(m.annotationIndex.annotations(onPage: 0).isEmpty, "one change")
    }

    /// Where markup is refused, so is Sign: the tool cannot be picked, a tap takes nothing, the pad does
    /// not open, and the model refuses with the reason.
    func testSignIsRefusedWhereMarkupIs() async throws {
        let (controller, model, undoManager) = try await makeController(data: try fixtureData("restricted-form"))
        XCTAssertEqual(model.capabilities?.canAnnotate, false, "the fixture forbids markup")
        XCTAssertFalse(model.canUse(.signature))
        XCTAssertEqual(model.refusal(of: .signature), Strings.markupNotAllowed)
        model.showsSignaturePad = false
        try model.signatures.delete()
        model.pick(.signature)
        XCTAssertFalse(model.showsSignaturePad, "no pad for a tool that is refused")
        XCTAssertFalse(controller.markupInteraction.takesTap(atContentPoint: try contentPoint(CGPoint(x: 300, y: 400), in: controller)))
        try model.signatures.save(try Self.squiggle())
        let made = await model.addSignature(page: 0, at: CGPoint(x: 300, y: 400))
        XCTAssertFalse(made)
        XCTAssertEqual(model.failure?.message, Strings.markupNotAllowed)
        XCTAssertFalse(undoManager.canUndo)
    }

    /// A signature tapped while a turn of its page was on its way is refused as stale, and nothing that
    /// looks placed is left.
    func testASignaturePlacedWhileItsPageTurnedLeavesNoPicture() async throws {
        let (controller, model, _) = try await makeController()
        let rotate = model.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        let made = try XCTUnwrap(controller.markupInteraction.placeSignature(onPage: 0, at: CGPoint(x: 300, y: 300)))
        let rotated = await rotate.value
        let ok = await made.value
        XCTAssertTrue(rotated); XCTAssertFalse(ok)
        XCTAssertEqual(model.failure?.message, Strings.documentChangedTryAgain)
        for page in controller.loadedPages {
            XCTAssertEqual(controller.pageView(for: page)?.overlay.signatures.isEmpty, true, "no ghost on page \(page)")
        }
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
    }

    /// Nothing waits with Sign: a signature is in the document once tapped. Another tool, Markup off
    /// and Undo find it there.
    func testNothingWaitsWithSign() async throws {
        let (controller, model, undoManager) = try await makeController()
        let made = try XCTUnwrap(controller.markupInteraction.placeSignature(onPage: 0, at: CGPoint(x: 300, y: 300)))
        XCTAssertFalse(model.hasPendingEdit)
        pick(.ink, in: model, controller)
        pick(nil, in: model, controller)
        let ok = await made.value
        XCTAssertTrue(ok)
        XCTAssertEqual(model.annotationIndex.annotations(onPage: 0).count, 1)
        model.undo(); await model.settle()
        XCTAssertTrue(model.annotationIndex.annotations(onPage: 0).isEmpty)
        XCTAssertFalse(undoManager.canUndo)
    }
}
