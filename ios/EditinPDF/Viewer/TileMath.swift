import CoreGraphics
import EditinPDFCore

/// The arithmetic between a tile Core Animation asks a page view to draw and the request that
/// draws it: the engine's scale, the pixels to ask for and where they go. Kept pure, and in one
/// place, so it is tested without a screen.
///
/// Three units are involved:
/// - Layer points: the page view's own coordinates, the page as laid out at zoom 1 (origin
///   top-left, y down). Core Animation names the area to draw in these.
/// - Device pixels: what a tile's context draws into. The context's x scale (`ctm.a`) is device
///   pixels per layer point at the current level of detail, the screen scale times the zoom
///   rounded up to a power of two.
/// - PDF points: the page's own size (view space: rotation applied, y down). The engine's `scale`
///   is device pixels per PDF point, and its tile rect is in device pixels at that scale from the
///   page's top-left corner.
///
/// One PDF point is `layerSize.width / pointSize.width` layer points, so the engine's scale is
/// `ctm.a * layerSize.width / pointSize.width`, and at that scale the engine's pixels are exactly
/// the context's. A tile's pixel rect is therefore its clip times `ctm.a`, rounded to whole pixels
/// the same way on every side, so that neighbouring tiles share their edges: no seam, and no line
/// drawn twice.
///
/// The engine draws a tile at 0.01 to 400 pixels to the PDF point (`minTileScale()`,
/// `maxTileScale()`) and refuses another scale. A page narrower than about 24 points zoomed in all
/// the way wants more than 400: it is asked for 400, and its pixels are enlarged to cover the clip
/// (`Request.isEnlarged`), fewer pixels than the screen has but still the page. A page that wants
/// less than 0.01 even at zoom 1 is wider than 75,000 points, which only a hostile file makes: it
/// gets no request, and stays blank.
enum TileMath {
    /// The largest tile side the page view asks the engine for, in pixels. The engine allows 4096;
    /// the page view's tiles are this size, so a request is never cut down in practice.
    static let maxTileSide = 1024

    /// What to ask the engine for, and where its pixels go.
    struct Request: Equatable {
        /// Device pixels per PDF point: the engine's `scale`.
        let scale: Double
        /// The pixels to draw, at `scale`, from the page's top-left corner: the clip rounded out to
        /// whole pixels, cut at the page's edges, and at most `maxTileSide` on a side.
        let rect: TileRect
        /// Where those pixels go, in layer points: `rect` divided by the context's scale, so the
        /// image lands on whole device pixels, one image pixel to one device pixel; or, when the
        /// page wants more pixels than the engine draws (`isEnlarged`), divided by the engine's
        /// pixels per layer point, so the image covers the clip.
        let destination: CGRect
        /// Whether the image has fewer pixels than its destination has device pixels: the scale was
        /// cut to the engine's largest. It is then to be drawn smoothed, not pixel for pixel.
        let isEnlarged: Bool
    }

    /// The request for the area `clip` (layer points) of a page laid out `layerSize` (layer points)
    /// whose own size is `pointSize` (PDF points), drawn into a context with `contextScale` device
    /// pixels per layer point. Nil when there is nothing to draw: the clip is off the page, a size or
    /// the scale is not a positive, finite number, or the page wants fewer pixels than the engine's
    /// smallest scale draws.
    static func request(clip: CGRect, contextScale: CGFloat, layerSize: CGSize, pointSize: CGSize) -> Request? {
        guard contextScale.isFinite, contextScale > 0,
              isUsable(layerSize), isUsable(pointSize),
              !clip.isNull, !clip.isInfinite else { return nil }
        // Device pixels to the PDF point that the context wants, and what the engine is asked for:
        // the same, but no more than the engine's largest scale for a tile.
        let wantedScale = Double(contextScale * layerSize.width / pointSize.width)
        guard wantedScale.isFinite, wantedScale >= engineScales.lowerBound else { return nil }
        let isEnlarged = wantedScale > engineScales.upperBound
        let scale = isEnlarged ? engineScales.upperBound : wantedScale
        // The engine's pixels to the layer point: the context's own, unless the scale was cut.
        let pixelsPerPoint = isEnlarged ? CGFloat(scale) * pointSize.width / layerSize.width : contextScale
        // The bound keeps every conversion to an integer below in range whatever the input.
        guard layerSize.width * pixelsPerPoint < pixelLimit, layerSize.height * pixelsPerPoint < pixelLimit else { return nil }
        let wanted = clip.intersection(CGRect(origin: .zero, size: layerSize))
        guard !wanted.isNull else { return nil }

        // Rounded outward, so a pixel the clip only partly covers is drawn too; cut at the page's
        // last pixel (rounded up the same way) and at the largest tile.
        let x0 = max(0, pixels(wanted.minX * pixelsPerPoint, .down))
        let y0 = max(0, pixels(wanted.minY * pixelsPerPoint, .down))
        let x1 = min(pixels(layerSize.width * pixelsPerPoint, .up), pixels(wanted.maxX * pixelsPerPoint, .up), x0 + maxTileSide)
        let y1 = min(pixels(layerSize.height * pixelsPerPoint, .up), pixels(wanted.maxY * pixelsPerPoint, .up), y0 + maxTileSide)
        guard x1 > x0, y1 > y0 else { return nil }

        return Request(
            scale: scale,
            rect: TileRect(x: UInt32(x0), y: UInt32(y0), width: UInt32(x1 - x0), height: UInt32(y1 - y0)),
            destination: CGRect(x: CGFloat(x0) / pixelsPerPoint, y: CGFloat(y0) / pixelsPerPoint,
                                width: CGFloat(x1 - x0) / pixelsPerPoint, height: CGFloat(y1 - y0) / pixelsPerPoint),
            isEnlarged: isEnlarged)
    }

    /// The scales the engine draws a tile at, in device pixels to the PDF point: the bridge's own
    /// numbers, so the two cannot disagree.
    static let engineScales = minTileScale()...maxTileScale()

    /// Larger than any page at any zoom (a 16,000-point page at 48 pixels per point is under a
    /// million pixels), and small enough to convert to `Int` and `UInt32` safely.
    private static let pixelLimit = CGFloat(1 << 30)

    private static func isUsable(_ size: CGSize) -> Bool {
        size.width > 0 && size.height > 0 && size.width.isFinite && size.height.isFinite
    }

    /// `value` (device pixels, below `pixelLimit` in size) as whole pixels, rounded the given way,
    /// except that a value within a thousandth of a pixel of a whole number is that number: tile
    /// edges are whole pixels up to floating-point noise, and the noise must not move an edge by a
    /// pixel.
    private static func pixels(_ value: CGFloat, _ rule: FloatingPointRoundingRule) -> Int {
        let nearest = value.rounded()
        return Int(abs(value - nearest) < 0.001 ? nearest : value.rounded(rule))
    }
}
