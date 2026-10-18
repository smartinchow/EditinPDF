import EditinPDFCore
import Foundation
import Observation
import os
import UIKit

/// Small pictures of a document's pages, for the thumbnails sheet.
///
/// A picture is drawn by the engine once, the first time its page is asked for with `prefetch`, and
/// kept in a cache whose size is bounded. Pictures are drawn one at a time, off the main actor, at
/// low priority: the engine has two renderers per document, shared with the tiles of the pages being
/// read, and a thumbnail must not take both. Each picture is published on the main actor as it is
/// done, so a SwiftUI view that asked for it with `image(for:)` is redrawn with it.
///
/// The pictures are of one revision of the document (`revision`). When the document changes,
/// `reload(pages:revision:)` gives the store the new revision and its pages: every picture of an older
/// one is dropped, and so is one being drawn when it arrives, so a page never shows what it was.
///
/// Nothing the work in flight holds refers back to the store: it keeps the engine's document, and
/// finds the store again through a weak reference only to hand the picture over. Letting go of the
/// store therefore ends the work (the page being drawn finishes, and its picture is dropped).
@MainActor
@Observable
final class ThumbnailStore {
    /// Draws all of page `page` (counting from 0) at `scale` device pixels to the PDF point. The
    /// engine's `renderTile` with no rectangle does this; tests stand in for it.
    typealias Render = @Sendable (_ page: Int, _ scale: Double) throws -> RenderedTile

    /// At most this many pictures are kept, and ...
    static let cacheCountLimit = 200
    /// ... at most this many bytes of pixels: a 3x screen's thumbnail is about 0.7 MB. The cache
    /// also gives pictures up of its own accord when the system is short of memory.
    static let cacheByteLimit = 48 * 1024 * 1024

    /// The tallest a picture is drawn, in its own widths: a page more than 4 times as tall as it is
    /// wide is drawn narrower, so that it is 4 widths tall. The grid shows no page taller than that
    /// (its cell is as tall as 4 widths at most), and a 1:20 page drawn to the full width would take
    /// five times the memory for pixels nobody sees.
    nonisolated static let tallestInWidths = 4.0

    private nonisolated static let log = Logger(subsystem: Diagnostics.subsystem, category: "thumbnails")
    /// Marks each picture's drawing as an interval ("renderThumbnail") in Instruments' Points of
    /// Interest, beside the tiles' (`PageTiledLayer`): the two share the engine's renderers.
    private nonisolated static let signposter = OSSignposter(subsystem: Diagnostics.subsystem, category: .pointsOfInterest)

    /// How wide a picture is, in points: of every page but a very tall one (`tallestInWidths`).
    let targetWidth: CGFloat
    /// How many device pixels make a point on the screen the pictures are shown on.
    let displayScale: CGFloat

    /// The revision of the document the pictures are of.
    private(set) var revision: UInt64
    private var pageInfos: [PageInfo]
    private let render: Render
    @ObservationIgnored private let cache = NSCache<ThumbnailCacheKey, UIImage>()
    /// The pages waiting for their turn, in the order they were asked for.
    @ObservationIgnored private var pending: [Int] = []
    /// Every page in `pending`, and the one being drawn: a page in here is not asked for again.
    @ObservationIgnored private var queued: Set<Int> = []
    @ObservationIgnored private var isDrawing = false
    /// Counts the pictures published, and the reloads that took them away. A cache cannot be
    /// observed, so `image(for:)` reads this, which is what makes SwiftUI ask again when a picture
    /// arrives or goes.
    private var publishedCount = 0

    /// A store for `document`, whose pages are described by `pages` (page `n` is `pages[n]`). A
    /// picture is `targetWidth` points wide (narrower for a very tall page, see `tallestInWidths`)
    /// and drawn with `displayScale` pixels to the point; pass the screen's own (SwiftUI's
    /// `displayScale` environment value) so they are sharp.
    /// `revision` is the document's revision that `pages` were read at.
    convenience init(document: PdfDocument, pages: [PageInfo], revision: UInt64 = 0, targetWidth: CGFloat = 120,
                     displayScale: CGFloat = 2) {
        self.init(pages: pages, revision: revision, targetWidth: targetWidth, displayScale: displayScale) { page, scale in
            try document.renderTile(page: UInt32(clamping: page), scale: scale, rect: nil)
        }
    }

    /// A store whose pictures are drawn by `render`.
    init(pages: [PageInfo], revision: UInt64 = 0, targetWidth: CGFloat = 120, displayScale: CGFloat = 2,
         render: @escaping Render) {
        self.pageInfos = pages
        self.revision = revision
        self.targetWidth = targetWidth
        // A screen without a scale (0) would ask the engine for nothing.
        self.displayScale = displayScale > 0 ? displayScale : 1
        self.render = render
        cache.countLimit = Self.cacheCountLimit
        cache.totalCostLimit = Self.cacheByteLimit
    }

    /// The picture of `page` (counting from 0): `targetWidth` points wide (see `tallestInWidths`), or
    /// nil while it is not there: not asked for yet, waiting its turn, being drawn, one the engine
    /// could not draw, or one the cache gave up. A view that finds none is told when one is published.
    func image(for page: Int) -> UIImage? {
        _ = publishedCount
        return cache.object(forKey: key(page))
    }

    /// Moves the store on to `revision` of the document, whose pages are now `pages`: the pictures
    /// asked for and not started are dropped, and so is every picture there (all of an older
    /// revision); one being drawn is dropped when it arrives. Views that read a picture are told, and
    /// ask again. A revision no newer than the store's changes nothing.
    func reload(pages: [PageInfo], revision: UInt64) {
        guard revision > self.revision else { return }
        self.revision = revision
        pageInfos = pages
        pending.removeAll()
        queued.removeAll()
        cache.removeAllObjects()
        publishedCount += 1
    }

    private func key(_ page: Int) -> ThumbnailCacheKey {
        ThumbnailCacheKey(ThumbnailKey(page: page, revision: revision))
    }

    /// Asks for the pictures of `pages`, to be drawn in turn after those already asked for. Pages the
    /// document does not have are ignored, and so are pages whose picture is there, waiting or being
    /// drawn already.
    func prefetch(_ pages: Range<Int>) {
        for page in pages.clamped(to: 0..<pageInfos.count) where !queued.contains(page) && !hasImage(for: page) {
            queued.insert(page)
            pending.append(page)
        }
        drawNext()
    }

    /// Asks for the picture of `page` and then those of the pages around it, nearest first: the page,
    /// the one after it, the one before it, the second after, the second before, and so on up to
    /// `radius` pages either side. For a sheet that opens at `page`: its first rows are drawn before
    /// the cells further off, which the grid also asks for as it makes them. A `page` the document
    /// does not have asks for nothing.
    func prefetch(around page: Int, radius: Int) {
        guard pageInfos.indices.contains(page) else { return }
        prefetch(page..<page + 1)
        // Pages further off than the ends of the document are ignored, so no more than its length.
        for distance in stride(from: 1, through: min(radius, pageInfos.count), by: 1) {
            prefetch(page + distance..<page + distance + 1)
            prefetch(page - distance..<page - distance + 1)
        }
    }

    /// Takes back the request for the pictures of `pages` that have not been started: for pages that
    /// scrolled away before their turn. A page being drawn is finished and kept, and a picture that
    /// is there stays. Asking for a page again makes it wanted again.
    func cancelPrefetch(_ pages: Range<Int>) {
        let dropped = pending.filter { pages.contains($0) }
        guard !dropped.isEmpty else { return }
        pending.removeAll { pages.contains($0) }
        queued.subtract(dropped)
    }

    private func hasImage(for page: Int) -> Bool {
        cache.object(forKey: key(page)) != nil
    }

    /// Starts on the next page waiting, if nothing is being drawn. Pages whose width cannot be turned
    /// into a scale are skipped (and logged): they have no thumbnail.
    private func drawNext() {
        guard !isDrawing else { return }
        while !pending.isEmpty {
            let page = pending.removeFirst()
            guard let scale = pixelsPerPoint(forPage: page) else {
                queued.remove(page)
                Self.log.error("page \(page) has no width to scale a thumbnail by")
                continue
            }
            isDrawing = true
            let render = render
            let displayScale = displayScale
            let revision = revision
            // Low priority, and one at a time: the next page is only started once this one is done.
            Task.detached(priority: .utility) { [weak self] in
                let image = Self.thumbnail(page: page, scale: scale, displayScale: displayScale, render: render)
                await self?.finishDrawing(page, of: revision, image: image)
            }
            return
        }
    }

    /// Back on the main actor with the picture of `page` at `revision` (nil when it could not be
    /// drawn): keeps it and tells the views waiting for it, unless the document has changed since,
    /// and goes on to the next page.
    private func finishDrawing(_ page: Int, of revision: UInt64, image: UIImage?) {
        isDrawing = false
        // After a reload the page may have been asked for again, for the new revision: that request
        // stands.
        guard revision == self.revision else {
            drawNext()
            return
        }
        queued.remove(page)
        if let image {
            cache.setObject(image, forKey: key(page), cost: Self.byteCount(of: image))
            publishedCount += 1
        }
        drawNext()
    }

    /// Device pixels to the PDF point that make `page` `targetWidth` points wide on screen, or less
    /// where that would make it taller than `tallestInWidths` widths; nil for a page with no width
    /// the engine could scale. A page with no usable height is scaled by its width alone.
    private func pixelsPerPoint(forPage page: Int) -> Double? {
        let info = pageInfos[page]
        guard info.widthPt.isFinite, info.widthPt > 0 else { return nil }
        let pixelsWide = Double(targetWidth * displayScale)
        var scale = pixelsWide / info.widthPt
        if info.heightPt.isFinite, info.heightPt > 0 {
            scale = min(scale, pixelsWide * Self.tallestInWidths / info.heightPt)
        }
        return scale.isFinite && scale > 0 ? scale : nil
    }

    /// Draws one page and makes its picture. Runs off the main actor; a failure is logged and gives
    /// nil. The reason stays private in the log, since the engine's message can quote the document.
    private nonisolated static func thumbnail(page: Int, scale: Double, displayScale: CGFloat, render: Render) -> UIImage? {
        do {
            let tile = try signposter.withIntervalSignpost("renderThumbnail", id: signposter.makeSignpostID(),
                                                           "page \(page) scale \(scale)") {
                try render(page, scale)
            }
            guard let image = TileRenderer.image(for: tile) else {
                log.error("page \(page) thumbnail was left out: the pixels do not fill \(tile.width) x \(tile.height)")
                return nil
            }
            // `scale` makes the picture `targetWidth` points wide: its pixels over the screen's.
            return UIImage(cgImage: image, scale: displayScale, orientation: .up)
        } catch {
            log.error("page \(page) thumbnail was left out: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    private static func byteCount(of image: UIImage) -> Int {
        image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
    }
}

/// Which picture: a page (counting from 0) of a revision of the document.
struct ThumbnailKey: Hashable {
    let page: Int
    let revision: UInt64
}

/// `ThumbnailKey` as `NSCache` needs its keys: an object, equal and hashed by the key it holds.
final class ThumbnailCacheKey: NSObject {
    let key: ThumbnailKey

    init(_ key: ThumbnailKey) {
        self.key = key
    }

    override var hash: Int { key.hashValue }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? ThumbnailCacheKey)?.key == key
    }
}
