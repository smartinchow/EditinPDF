import EditinPDFCore
import os
import UIKit

/// One page, drawn by the engine one tile at a time, sharp at every zoom.
///
/// A thin view: its layer, a `PageTiledLayer`, does the drawing. The view hands the layer what to
/// draw and sets it up: 1024-pixel tiles, and levels of detail from the screen's own resolution
/// up to 16 times it, so tiles are drawn again, sharper, as the page is zoomed in. Above the tiles
/// sits an overlay, with the search hits and the selected text.
final class PageView: UIView {
    override class var layerClass: AnyClass { PageTiledLayer.self }

    /// The page, counting from 0.
    let page: Int
    /// The page's size in PDF points, as shown (its rotation applied).
    let pointSize: CGSize
    /// What is drawn over the tiles: the boxes of search hits and of selected text. It always has
    /// the view's bounds, so the scroll view's zoom scales it with the page.
    let overlay: PageOverlayView

    /// A view for page `page` of `document`, whose size is `pointSize` PDF points. The page is
    /// drawn to fill the view's bounds, which the scroll view sets to the page's place in the
    /// layout and never changes afterwards (it makes new views when the layout changes).
    init(page: Int, document: PdfDocument, pointSize: CGSize) {
        self.page = page
        self.pointSize = pointSize
        overlay = PageOverlayView(pointSize: pointSize)
        super.init(frame: .zero)
        // Paper: what shows until a tile has been drawn, and where one could not be.
        backgroundColor = .white
        isOpaque = true
        addSubview(overlay)
        // For UI tests, which find where a page is on screen by it; not shown or spoken.
        accessibilityIdentifier = "page-\(page)"
        guard let tiledLayer = layer as? PageTiledLayer else { return }
        tiledLayer.attach(PageTiledLayer.Source(document: document, page: UInt32(clamping: page), pointSize: pointSize))
        tiledLayer.tileSize = CGSize(width: TileMath.maxTileSide, height: TileMath.maxTileSide)
        // Five levels: 1x (the screen's resolution, for zoom 1) and four magnified ones, 2x to 16x,
        // each drawn when the zoom passes the one below.
        tiledLayer.levelsOfDetail = 5
        tiledLayer.levelsOfDetailBias = 4
        // The window can move to a screen of another resolution while the page is up (an external
        // display; a device whose displays differ): the tiles are drawn again at the new one.
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: PageView, _: UITraitCollection) in
            view.matchDisplayScale()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        overlay.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        matchDisplayScale()
    }

    /// Tiles are drawn at the resolution of the screen the page is shown on, read from the view's
    /// traits (the screen it is on), never `UIScreen.main`.
    private func matchDisplayScale() {
        let scale = traitCollection.displayScale
        guard window != nil, scale > 0, layer.contentsScale != scale else { return }
        layer.contentsScale = scale
        layer.setNeedsDisplay()
    }
}

/// The page view's layer, which draws the page's tiles with the engine.
///
/// Core Animation calls `draw(in:)` for each tile on background threads, several at a time. Under
/// Swift 6 that is why the drawing is here and not in the view: `UIView` is main-actor isolated,
/// `CALayer` is not. The drawing reads nothing of the view: only its context, the layer's own
/// bounds (Core Animation allows any thread to read a layer's properties), and `Source`, immutable
/// values that are `Sendable`.
///
/// UIKit makes a view's layer itself, with `init()`, so the source cannot be an initializer
/// argument: the view attaches it straight after, before the layer is ever shown, and it never
/// changes. It is kept behind a lock so the tile threads read it safely; every stored property is
/// a `let`.
final class PageTiledLayer: CATiledLayer {
    /// What to draw: page `page` of `document`, whose size is `pointSize` PDF points.
    struct Source: Sendable {
        let document: PdfDocument
        let page: UInt32
        let pointSize: CGSize
    }

    private static let log = Logger(subsystem: Diagnostics.subsystem, category: "tiles")
    /// Marks each tile's call to the engine as an interval ("renderTile", with its page, scale and
    /// pixels), and each tile left blank as an event ("tileLeftBlank"), in Instruments' Points of
    /// Interest: that tells a tile that waited for a renderer, or one that failed, from one never
    /// asked for.
    private static let signposter = OSSignposter(subsystem: Diagnostics.subsystem, category: .pointsOfInterest)

    private let sourceLock = OSAllocatedUnfairLock<Source?>(initialState: nil)

    override init() {
        super.init()
    }

    /// Core Animation's copy of a layer (for its presentation layer) draws the same page.
    override init(layer: Any) {
        super.init(layer: layer)
        if let source = (layer as? PageTiledLayer)?.source { attach(source) }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// What the layer draws; nothing until `attach(_:)`.
    var source: Source? { sourceLock.withLock { $0 } }

    /// Gives the layer what to draw. Only the first call counts: a layer draws one page.
    func attach(_ source: Source) {
        sourceLock.withLock { current in
            if current == nil { current = source }
        }
    }

    override func draw(in ctx: CGContext) {
        #if DEBUG
        if Thread.isMainThread { Self.log.fault("a page tile was drawn on the main thread") }
        #endif
        guard let source else { return }
        let clip = ctx.boundingBoxOfClipPath
        // `ctm.a` is device pixels per layer point at the level of detail being drawn.
        guard let request = TileMath.request(clip: clip, contextScale: ctx.ctm.a, layerSize: bounds.size,
                                             pointSize: source.pointSize) else {
            // Core Animation only asks for tiles on the layer, so this is a page without a usable
            // size (the engine reported an empty page box).
            return fail(ctx, clip, page: source.page, reason: "no pixels to ask for: page \(source.pointSize), layer \(bounds.size)")
        }
        let image: CGImage
        do {
            let rect = request.rect
            let tile = try Self.signposter.withIntervalSignpost(
                "renderTile", id: Self.signposter.makeSignpostID(),
                "page \(source.page) scale \(request.scale) x \(rect.x) y \(rect.y) w \(rect.width) h \(rect.height)"
            ) {
                try source.document.renderTile(page: source.page, scale: request.scale, rect: rect)
            }
            guard let made = TileRenderer.image(for: tile) else {
                return fail(ctx, clip, page: source.page, reason: "the pixels do not fill \(tile.width) x \(tile.height)")
            }
            image = made
        } catch {
            return fail(ctx, clip, page: source.page, reason: String(describing: error))
        }
        ctx.saveGState()
        // Core Animation gives a layer a y-down context, and an image is drawn with its first row at
        // the destination's maxY: flipping within the destination puts the first row at the top.
        ctx.translateBy(x: 0, y: request.destination.minY + request.destination.maxY)
        ctx.scaleBy(x: 1, y: -1)
        // One image pixel to one device pixel: nothing to smooth. Unless the page wanted more pixels
        // than the engine draws a tile with, and the image is enlarged: then smoothed, not blocky.
        ctx.interpolationQuality = request.isEnlarged ? .high : .none
        ctx.draw(image, in: request.destination)
        ctx.restoreGState()
    }

    /// A tile that could not be drawn is left blank, like paper, and logged: the rest of the page
    /// still shows, and nothing is thrown out of Core Animation's drawing. The reason stays private
    /// in the log, since the engine's message can quote the document.
    private func fail(_ ctx: CGContext, _ clip: CGRect, page: UInt32, reason: String) {
        Self.log.error("page \(page) tile \(clip.debugDescription, privacy: .public) was left blank: \(reason, privacy: .private)")
        Self.signposter.emitEvent("tileLeftBlank", "page \(page) tile \(clip.debugDescription, privacy: .public)")
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(clip)
    }
}
