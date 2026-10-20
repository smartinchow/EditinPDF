import CoreGraphics
import Foundation
import Observation

/// A signature as it is kept: its strokes, each the points it passes through, from 0 to 1 across and
/// down a box `aspect` times as wide as it is high. Placed on a page (`SignatureStore.place`), the box
/// is given a width and a place, and the strokes become ink.
struct SavedSignature: Codable, Equatable, Sendable {
    var strokes: [[CGPoint]]
    var aspect: Double

    /// Whether it is a signature the store makes (`SignatureStore.normalise`) and the bridge takes once
    /// placed: at least one stroke, each with at least one point, no more strokes and points than the
    /// store keeps, every point within its box, and proportions that are a number the store allows.
    /// A file that holds anything else (damaged, or written by hand) is not read as a signature.
    var isValid: Bool {
        guard aspect.isFinite, aspect >= 1 / SignatureStore.maxAspect - 1e-9, aspect <= SignatureStore.maxAspect + 1e-9,
              !strokes.isEmpty, strokes.count <= SignatureStore.maxStrokes else { return false }
        var points = 0
        for stroke in strokes {
            guard !stroke.isEmpty, stroke.count <= SignatureStore.maxStrokePoints else { return false }
            points += stroke.count
            let inBox = stroke.allSatisfy { $0.x.isFinite && $0.y.isFinite && (-1e-6...1 + 1e-6).contains($0.x) && (-1e-6...1 + 1e-6).contains($0.y) }
            guard inBox else { return false }
        }
        return points <= SignatureStore.maxPoints
    }
}

/// The reader's signature, drawn once in the pad (`SignaturePadSheet`) and placed by Sign with a tap.
///
/// It is kept on the device only, in a file of the app's own (`signature.json` in `directory`, by
/// default Application Support/Signature): written whole or not at all, readable only while the device
/// is unlocked (complete file protection), and in a folder left out of backups. It is never logged and
/// never sent anywhere. A file that cannot be read as a signature reads as none.
///
/// Observable, so the palette sees at once whether one is saved.
@MainActor
@Observable
final class SignatureStore {
    /// The most strokes a signature keeps: the bridge's most for one drawing.
    nonisolated static let maxStrokes = InkGeometry.maxStrokes
    /// The most points one stroke keeps: a fifth of the bridge's most.
    nonisolated static let maxStrokePoints = InkGeometry.maxStrokePoints / 5
    /// The most points a signature keeps in all: a fifth of the bridge's most for one drawing.
    nonisolated static let maxPoints = InkGeometry.maxDrawingPoints / 5
    /// How much wider than high, or higher than wide, a signature's box may be: a line straight across
    /// is given this much height (and one straight down this much width), so its proportions stay a
    /// number.
    nonisolated static let maxAspect: Double = 20
    /// The least a drawing must measure across or down, in its own points (the pad's), to be a
    /// signature: less is a dot.
    nonisolated static let minimumExtent: CGFloat = 2
    /// How far apart, as a part of the drawing's longer side, two points of a stroke must be for both to
    /// be kept: closer ones are not told apart at the size a signature is placed (0.3 points at 150).
    nonisolated static let resolution: CGFloat = 0.002
    /// The width a signature is placed at on a page wide enough: `defaultWidth`.
    nonisolated static let placedWidth: CGFloat = 150
    /// The colour and width, in points, a signature is drawn in on the page.
    nonisolated static let color = RGBA(r: 0, g: 0, b: 0)
    nonisolated static let lineWidth: Double = 1.5
    /// The name of the file in the store's folder.
    nonisolated static let fileName = "signature.json"

    /// Where the app keeps its signature: Application Support/Signature.
    nonisolated static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Signature", directoryHint: .isDirectory)
    }

    /// The app's store, which every document's model shares: a signature saved in one window is the one
    /// the next tap places in any.
    static let shared = SignatureStore(directory: defaultDirectory)

    /// The folder the file is in.
    @ObservationIgnored let directory: URL
    /// The signature saved; nil when there is none, or its file cannot be read as one.
    private(set) var saved: SavedSignature?

    enum StoreError: Error {
        /// The signature is not one the store makes (`SavedSignature.isValid`): it is not saved.
        case invalid
    }

    /// The store of the file in `directory`, read now.
    init(directory: URL) {
        self.directory = directory
        saved = Self.read(directory.appending(path: Self.fileName))
    }

    private var fileURL: URL { directory.appending(path: Self.fileName) }

    /// Reads the file again: it may not have been readable before (the device locked, with the file's
    /// protection) or have changed since.
    func reload() {
        let read = Self.read(fileURL)
        if read != saved { saved = read }
    }

    /// Keeps `signature` in place of any saved, in its folder (made if need be, and left out of
    /// backups), written whole or not at all, with complete file protection. Throws when it cannot be
    /// written, or is not one the store makes; the one saved before stays then.
    func save(_ signature: SavedSignature) throws {
        guard signature.isValid else { throw StoreError.invalid }
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let data = try JSONEncoder().encode(signature)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        saved = signature
    }

    /// Forgets the saved signature: its file goes. Nothing saved, nothing happens. Signatures already
    /// placed on pages are ink in their documents, and stay.
    func delete() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Nothing was saved.
        }
        saved = nil
    }

    /// The signature in `file`; nil when there is none, or it cannot be read as one.
    private nonisolated static func read(_ file: URL) -> SavedSignature? {
        guard let data = try? Data(contentsOf: file),
              let signature = try? JSONDecoder().decode(SavedSignature.self, from: data), signature.isValid else { return nil }
        return signature
    }

    // MARK: Normalising and placing

    /// `strokes` (each the points it passed through, in the pad's points or any others the same way
    /// across and down) as a signature: from 0 to 1 across and down the box of all their points, with
    /// the box's proportions. Nil when nothing is drawn, or what is drawn has no extent (a dot: less
    /// than `minimumExtent` across and down).
    ///
    /// - Points that are not numbers are left out, and strokes left with none; so are strokes after the
    ///   `maxStrokes`th (the bridge's most: no signature has so many).
    /// - A line straight across or down is given a depth (`maxAspect`), about its middle.
    /// - A point closer than `resolution` (of the box's longer side) to the last one kept is dropped;
    ///   each stroke keeps its first and last points.
    /// - Then it is kept well inside what the bridge takes for one drawing: a stroke of more than
    ///   `maxStrokePoints`, or a drawing of more than `maxPoints`, is thinned evenly, ends kept.
    nonisolated static func normalise(_ strokes: [[CGPoint]]) -> SavedSignature? {
        let drawn = strokes.map { $0.filter { $0.x.isFinite && $0.y.isFinite } }.filter { !$0.isEmpty }.prefix(maxStrokes)
        let points = drawn.joined()
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        var width = maxX - minX, height = maxY - minY
        let longer = max(width, height)
        guard longer.isFinite, longer >= minimumExtent else { return nil }
        let least = longer / CGFloat(maxAspect)
        if height < least {
            minY -= (least - height) / 2
            height = least
        }
        if width < least {
            minX -= (least - width) / 2
            width = least
        }
        let closest = longer * resolution
        var kept = drawn.map { stroke in
            decimated(stroke, closest: closest).map { point in
                CGPoint(x: rounded(min(max((point.x - minX) / width, 0), 1)), y: rounded(min(max((point.y - minY) / height, 0), 1)))
            }
        }
        kept = kept.map { thinned($0, to: maxStrokePoints) }
        let total = kept.reduce(0) { $0 + $1.count }
        if total > maxPoints {
            // Each stroke keeps its share of what may be kept, and at least its ends.
            let room = Double(maxPoints - 2 * kept.count)
            kept = kept.map { thinned($0, to: max(2, Int(Double($0.count) * room / Double(total)))) }
        }
        return SavedSignature(strokes: kept, aspect: Double(width / height))
    }

    /// `stroke` without the points closer than `closest` to the last one kept; its first and last points
    /// stay (a stroke that never goes that far is its first point: a dot).
    private nonisolated static func decimated(_ stroke: [CGPoint], closest: CGFloat) -> [CGPoint] {
        guard let first = stroke.first, let last = stroke.last else { return [] }
        var kept = [first]
        for point in stroke.dropFirst() {
            guard let previous = kept.last else { continue }
            if hypot(point.x - previous.x, point.y - previous.y) >= closest { kept.append(point) }
        }
        if kept.count > 1, kept.last != last { kept[kept.count - 1] = last }
        return kept
    }

    /// `points` thinned evenly to at most `limit` (at least 2), its first and last kept.
    private nonisolated static func thinned(_ points: [CGPoint], to limit: Int) -> [CGPoint] {
        let limit = max(limit, 2)
        guard points.count > limit else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { points[min(Int((Double($0) * step).rounded()), points.count - 1)] }
    }

    /// `value` to 1/10,000 of the box: finer than any page shows it, and a smaller file.
    private nonisolated static func rounded(_ value: CGFloat) -> CGFloat {
        (value * 10_000).rounded() / 10_000
    }

    /// The width a signature is placed at on a page `pageSize` in size (as shown): `placedWidth`, or two
    /// fifths of a page too narrow for it.
    nonisolated static func defaultWidth(pageSize: CGSize) -> CGFloat {
        min(placedWidth, pageSize.width * 0.4)
    }

    /// `signature`'s strokes on a page `pageSize` in size (view space: PDF points, origin top-left, y
    /// down, the page's rotation applied), in a box `width` wide and as high as its proportions make
    /// it, centred on `point` (the page's middle when that is not a number), moved in as far as it
    /// takes to lie wholly on the page. On a page narrower or lower than the box it is shrunk to fit,
    /// keeping its proportions. None for a page, a width or a signature with no size.
    nonisolated static func place(_ signature: SavedSignature, centeredAt point: CGPoint, width: CGFloat, pageSize: CGSize) -> [[CGPoint]] {
        let aspect = CGFloat(signature.aspect)
        guard aspect.isFinite, aspect > 0, width.isFinite, width > 0, pageSize.width.isFinite, pageSize.height.isFinite,
              pageSize.width > 0, pageSize.height > 0 else { return [] }
        var boxWidth = min(width, pageSize.width)
        var boxHeight = boxWidth / aspect
        if boxHeight > pageSize.height {
            boxHeight = pageSize.height
            boxWidth = boxHeight * aspect
        }
        let centreX = point.x.isFinite ? point.x : pageSize.width / 2
        let centreY = point.y.isFinite ? point.y : pageSize.height / 2
        let left = min(max(centreX - boxWidth / 2, 0), pageSize.width - boxWidth)
        let top = min(max(centreY - boxHeight / 2, 0), pageSize.height - boxHeight)
        return signature.strokes.map { stroke in
            stroke.map { CGPoint(x: left + $0.x * boxWidth, y: top + $0.y * boxHeight) }
        }
    }
}
