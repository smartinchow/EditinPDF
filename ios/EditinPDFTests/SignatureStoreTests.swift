import CoreGraphics
import Foundation
import XCTest
@testable import EditinPDF

/// The saved signature: drawn strokes normalised into a box of their own proportions, kept in a file
/// of the app's own, and placed on a page at a size that fits it.
@MainActor
final class SignatureStoreTests: XCTestCase {
    /// A folder of the test's own, under the temporary folder, removed once the test is over.
    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SignatureStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// The box of all of `strokes`' points.
    private func bounds(_ strokes: [[CGPoint]]) -> CGRect {
        let points = strokes.joined()
        guard let first = points.first else { return .null }
        return points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    private func assertRect(_ rect: CGRect, equals expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        for (got, want) in [(rect.minX, expected.minX), (rect.minY, expected.minY), (rect.width, expected.width), (rect.height, expected.height)] {
            XCTAssertEqual(got, want, accuracy: 1e-6, "\(rect) is not \(expected)", file: file, line: line)
        }
    }

    /// A signature twice as wide as it is high: a stroke from one corner of its box to the other.
    private func twoToOne() throws -> SavedSignature {
        try XCTUnwrap(SignatureStore.normalise([[CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 50)]]))
    }

    // MARK: The brief's

    func testNormaliseAndPlaceRoundTrip() throws {
        let s = try XCTUnwrap(SignatureStore.normalise([[CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 60)]]))
        XCTAssertEqual(s.aspect, 2, accuracy: 0.001)
        let placed = SignatureStore.place(s, centeredAt: CGPoint(x: 300, y: 400), width: 150, pageSize: CGSize(width: 612, height: 792))
        XCTAssertEqual(placed[0].first?.x ?? 0, 225, accuracy: 0.01); XCTAssertEqual(placed[0].last?.y ?? 0, 437.5, accuracy: 0.01)
    }

    func testStorePersistsAndDeletes() throws {
        let dir = temporaryDirectory()
        let store = SignatureStore(directory: dir); try store.save(SavedSignature(strokes: [[.zero, CGPoint(x: 1, y: 1)]], aspect: 2))
        XCTAssertNotNil(SignatureStore(directory: dir).saved); try store.delete(); XCTAssertNil(SignatureStore(directory: dir).saved)
    }

    // MARK: Normalising

    /// Nothing drawn, or a dot (a drawing with no extent), is no signature; nor is a drawing none of
    /// whose points is a number.
    func testNothingDrawnOrADotIsNoSignature() {
        XCTAssertNil(SignatureStore.normalise([]))
        XCTAssertNil(SignatureStore.normalise([[], []]))
        XCTAssertNil(SignatureStore.normalise([[CGPoint(x: 40, y: 40)]]), "a dot")
        XCTAssertNil(SignatureStore.normalise([[CGPoint(x: 40, y: 40), CGPoint(x: 40.5, y: 40.5)], [CGPoint(x: 41, y: 40)]]),
                     "a dot of a few points")
        XCTAssertNil(SignatureStore.normalise([[CGPoint(x: CGFloat.nan, y: 3), CGPoint(x: CGFloat.infinity, y: 9)]]), "no point is a number")
    }

    /// Points that are not numbers are left out, and a stroke left with none goes.
    func testPointsThatAreNotNumbersAreLeftOut() throws {
        let s = try XCTUnwrap(SignatureStore.normalise([
            [CGPoint(x: 0, y: 0), CGPoint(x: CGFloat.nan, y: 5), CGPoint(x: 100, y: 50)],
            [CGPoint(x: CGFloat.infinity, y: 0), CGPoint(x: 3, y: -CGFloat.infinity)],
        ]))
        XCTAssertEqual(s.strokes, [[CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]])
        XCTAssertEqual(s.aspect, 2, accuracy: 1e-9)
    }

    /// A line straight across (no height) or down (no width) is given the least depth, about its
    /// middle, so the box's proportions stay a number, and the line can be placed.
    func testAStraightLineIsGivenADepth() throws {
        let across = try XCTUnwrap(SignatureStore.normalise([[CGPoint(x: 10, y: 50), CGPoint(x: 210, y: 50)]]))
        XCTAssertEqual(across.aspect, SignatureStore.maxAspect, accuracy: 1e-9)
        XCTAssertEqual(across.strokes, [[CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)]], "about the middle of its box")
        let down = try XCTUnwrap(SignatureStore.normalise([[CGPoint(x: 5, y: 0), CGPoint(x: 5, y: 80)]]))
        XCTAssertEqual(down.aspect, 1 / SignatureStore.maxAspect, accuracy: 1e-9)
        XCTAssertEqual(down.strokes, [[CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)]])
        let page = CGSize(width: 612, height: 792)
        for s in [across, down] {
            let placed = SignatureStore.place(s, centeredAt: CGPoint(x: 300, y: 400), width: 150, pageSize: page)
            XCTAssertFalse(placed.isEmpty)
            XCTAssertTrue(placed.joined().allSatisfy { $0.x.isFinite && $0.y.isFinite && (0...page.width).contains($0.x) && (0...page.height).contains($0.y) },
                          "\(placed)")
        }
    }

    /// Points closer to the last one kept than the resolution (a small part of the drawing's longer
    /// side) are dropped; each stroke keeps its ends.
    func testPointsCloserThanTheResolutionAreDropped() throws {
        // 1,001 points about 0.11 apart along a line 100 across and 50 down: the resolution is 0.2.
        let line = (0...1_000).map { CGPoint(x: Double($0) / 10, y: Double($0) / 20) }
        let s = try XCTUnwrap(SignatureStore.normalise([line]))
        let kept = try XCTUnwrap(s.strokes.first)
        XCTAssertLessThan(kept.count, 520, "close points were kept")
        XCTAssertGreaterThan(kept.count, 400, "points further apart than the resolution were dropped")
        XCTAssertEqual(kept.first, CGPoint(x: 0, y: 0))
        XCTAssertEqual(kept.last, CGPoint(x: 1, y: 1), "the stroke's end is kept")
        // In the drawing's own points (100 across, 50 down), no two kept points but the last pair are
        // closer than the resolution.
        for (a, b) in zip(kept.dropLast(2), kept.dropFirst().dropLast()) {
            XCTAssertGreaterThanOrEqual(hypot((b.x - a.x) * 100, (b.y - a.y) * 50), SignatureStore.resolution * 100 - 1e-6)
        }
    }

    /// However much is drawn, the signature stays well inside what the bridge takes for one drawing
    /// (500 strokes, 10,000 points a stroke, 100,000 in all): a long stroke and too many points are
    /// thinned (its ends kept), and strokes after the 500th are left out.
    func testABigDrawingStaysWellInsideTheBridgesCaps() throws {
        // A zigzag of 30,000 points, each 100 from the last, then 1,199 scribbles of 200 points.
        var strokes: [[CGPoint]] = [(0..<30_000).map { CGPoint(x: Double($0) * 0.02, y: $0 % 2 == 0 ? 0 : 100) }]
        for i in 0..<1_199 {
            strokes.append((0..<200).map { CGPoint(x: Double(i % 40) * 15 + Double($0 % 2) * 10, y: Double(i / 40) * 3 + Double($0) * 0.5) })
        }
        let s = try XCTUnwrap(SignatureStore.normalise(strokes))
        XCTAssertLessThan(SignatureStore.maxStrokePoints, InkGeometry.maxStrokePoints)
        XCTAssertLessThan(SignatureStore.maxPoints, InkGeometry.maxDrawingPoints)
        XCTAssertLessThanOrEqual(SignatureStore.maxStrokes, InkGeometry.maxStrokes)
        XCTAssertEqual(s.strokes.count, SignatureStore.maxStrokes, "the strokes after the 500th are left out")
        XCTAssertTrue(s.strokes.allSatisfy { !$0.isEmpty && $0.count <= SignatureStore.maxStrokePoints })
        XCTAssertLessThanOrEqual(s.strokes.map(\.count).reduce(0, +), SignatureStore.maxPoints)
        // The box is the kept strokes': 599.98 across (the zigzag) and 135.5 down (the 499th scribble).
        XCTAssertEqual(s.aspect, 599.98 / 135.5, accuracy: 1e-9)
        let zigzag = try XCTUnwrap(s.strokes.first)
        XCTAssertEqual(zigzag.first, CGPoint(x: 0, y: 0))
        XCTAssertEqual(zigzag.last?.x, 1, "the zigzag's end is kept")
        XCTAssertEqual(zigzag.last?.y ?? 0, 100 / 135.5, accuracy: 1e-4)
        XCTAssertTrue(s.isValid)
    }

    // MARK: Placing

    /// Placed at its default width: 150 points, or two fifths of a page narrower than 375 points.
    func testTheDefaultWidthIsAtMost150PointsAndTwoFifthsOfThePage() {
        XCTAssertEqual(SignatureStore.defaultWidth(pageSize: CGSize(width: 612, height: 792)), 150)
        XCTAssertEqual(SignatureStore.defaultWidth(pageSize: CGSize(width: 300, height: 400)), 120, accuracy: 1e-9)
        XCTAssertEqual(SignatureStore.defaultWidth(pageSize: CGSize(width: 792, height: 612)), 150)
    }

    /// A signature placed near an edge, or with its centre off the page, is moved in until it is wholly
    /// on the page.
    func testAPlacementNearAnEdgeIsKeptOnThePage() throws {
        let s = try twoToOne()
        let page = CGSize(width: 612, height: 792)
        assertRect(bounds(SignatureStore.place(s, centeredAt: CGPoint(x: 600, y: 5), width: 150, pageSize: page)),
                   equals: CGRect(x: 462, y: 0, width: 150, height: 75))
        assertRect(bounds(SignatureStore.place(s, centeredAt: CGPoint(x: -50, y: 900), width: 150, pageSize: page)),
                   equals: CGRect(x: 0, y: 717, width: 150, height: 75))
        assertRect(bounds(SignatureStore.place(s, centeredAt: CGPoint(x: CGFloat.nan, y: 400), width: 150, pageSize: page)),
                   equals: CGRect(x: 231, y: 362.5, width: 150, height: 75))
    }

    /// On a page narrower or lower than the signature at the width asked for, it is shrunk to fit,
    /// keeping its proportions.
    func testASignatureLargerThanThePageIsShrunkToIt() throws {
        assertRect(bounds(SignatureStore.place(try twoToOne(), centeredAt: CGPoint(x: 50, y: 50), width: 150, pageSize: CGSize(width: 100, height: 300))),
                   equals: CGRect(x: 0, y: 25, width: 100, height: 50))
        let tall = try XCTUnwrap(SignatureStore.normalise([[CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 100)]]))
        XCTAssertEqual(tall.aspect, 0.5, accuracy: 1e-9)
        assertRect(bounds(SignatureStore.place(tall, centeredAt: CGPoint(x: 100, y: 40), width: 150, pageSize: CGSize(width: 300, height: 80))),
                   equals: CGRect(x: 80, y: 0, width: 40, height: 80))
        XCTAssertTrue(SignatureStore.place(tall, centeredAt: .zero, width: 150, pageSize: .zero).isEmpty, "no page, no place")
        XCTAssertTrue(SignatureStore.place(tall, centeredAt: .zero, width: .nan, pageSize: CGSize(width: 300, height: 80)).isEmpty)
    }

    /// Sizes are the page's as shown (view space, its rotation applied): on a page turned a quarter
    /// the signature fits the page on its side, and lands where the tap was.
    func testOnATurnedPageTheSignatureFitsThePageAsShown() async throws {
        let (m, _) = try makeModel(fixture: "rotated")
        await m.settle()
        XCTAssertEqual(m.pages[0].rotationDegrees, 90)
        let shown = CGSize(width: m.pages[0].widthPt, height: m.pages[0].heightPt)
        // A signature as high as it is wide: its height follows the width, which follows the page's
        // width as shown, not as the file has it.
        let square = try XCTUnwrap(SignatureStore.normalise([[CGPoint(x: 0, y: 0), CGPoint(x: 80, y: 80)]]))
        let width = SignatureStore.defaultWidth(pageSize: shown)
        XCTAssertEqual(width, min(150, shown.width * 0.4), accuracy: 1e-9)
        let middle = CGPoint(x: shown.width / 2, y: shown.height / 2)
        let placed = SignatureStore.place(square, centeredAt: middle, width: width, pageSize: shown)
        let side = min(width, shown.height)
        assertRect(bounds(placed), equals: CGRect(x: middle.x - side / 2, y: middle.y - side / 2, width: side, height: side))
        // Near the shown page's bottom-right corner it is kept on the page as shown.
        let corner = bounds(SignatureStore.place(square, centeredAt: CGPoint(x: shown.width, y: shown.height), width: width, pageSize: shown))
        XCTAssertEqual(corner.maxX, shown.width, accuracy: 1e-6)
        XCTAssertEqual(corner.maxY, shown.height, accuracy: 1e-6)
        // Placed through the model, it comes back from the file where it was put.
        try m.signatures.save(square)
        let tap = CGPoint(x: 200, y: 150)
        let expected = bounds(try XCTUnwrap(m.signatureStrokes(onPage: 0, centeredAt: tap)))
        let made = await m.addSignature(page: 0, at: tap)
        XCTAssertTrue(made)
        let ink = try XCTUnwrap(m.annotationIndex.annotations(onPage: 0).first)
        XCTAssertEqual(ink.kind, .ink)
        InkGeometryTests.assertBox(ink.rect, isAround: expected, width: SignatureStore.lineWidth)
    }

    // MARK: The file

    /// A file that is not a signature (damaged, another version's, or a signature out of shape) reads
    /// as none; it never stops the store.
    func testADamagedFileReadsAsNoSignature() throws {
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: SignatureStore.fileName)
        for contents in ["not json", "{}", #"{"strokes":[],"aspect":2}"#, #"{"strokes":[[[0,0],[1,1]]],"aspect":0}"#,
                         #"{"strokes":[[[0,0],[7,1]]],"aspect":2}"#, #"{"strokes":[[[0,0],[1,1]]],"aspect":1e300}"#] {
            try Data(contents.utf8).write(to: file)
            XCTAssertNil(SignatureStore(directory: dir).saved, contents)
        }
        try Data([0xFF, 0x00, 0x13]).write(to: file)
        XCTAssertNil(SignatureStore(directory: dir).saved)
        // A store whose file is unreadable still saves over it.
        let store = SignatureStore(directory: dir)
        try store.save(try twoToOne())
        XCTAssertEqual(SignatureStore(directory: dir).saved, try twoToOne())
    }

    /// Deleting when nothing is saved does nothing, and is no error.
    func testDeletingNothingIsNoError() throws {
        let dir = temporaryDirectory()
        let store = SignatureStore(directory: dir)
        XCTAssertNil(store.saved)
        XCTAssertNoThrow(try store.delete())
        XCTAssertNoThrow(try store.delete())
        XCTAssertNil(store.saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: SignatureStore.fileName).path))
    }

    /// The store says at once what it has saved, and a signature out of shape is not saved.
    func testTheStoreSaysWhatItHas() throws {
        let store = SignatureStore(directory: temporaryDirectory())
        let s = try twoToOne()
        try store.save(s)
        XCTAssertEqual(store.saved, s)
        XCTAssertThrowsError(try store.save(SavedSignature(strokes: [], aspect: 2)))
        XCTAssertThrowsError(try store.save(SavedSignature(strokes: [[CGPoint(x: 0, y: 3)]], aspect: 2)))
        XCTAssertEqual(store.saved, s, "a refused save leaves the one saved")
        try store.delete()
        XCTAssertNil(store.saved)
    }

    /// The file is in the store's folder, as `signature.json`; the folder is left out of backups, and
    /// the file is protected completely: unreadable while the device is locked.
    func testTheFileIsProtectedAndLeftOutOfBackups() throws {
        let dir = temporaryDirectory()
        try SignatureStore(directory: dir).save(try twoToOne())
        let file = dir.appending(path: SignatureStore.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        // The simulator may not report a protection class; where it does, it is complete.
        let protection = try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey] as? FileProtectionType
        if let protection { XCTAssertEqual(protection, .complete) }
    }

    /// The app's store is in Application Support, in a folder of its own.
    func testTheDefaultFolderIsInApplicationSupport() {
        XCTAssertEqual(SignatureStore.defaultDirectory.lastPathComponent, "Signature")
        XCTAssertEqual(SignatureStore.defaultDirectory.deletingLastPathComponent().standardizedFileURL,
                       URL.applicationSupportDirectory.standardizedFileURL)
        XCTAssertEqual(SignatureStore.fileName, "signature.json")
    }
}
