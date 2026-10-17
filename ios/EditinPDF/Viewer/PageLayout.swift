import CoreGraphics
import EditinPDFCore

/// Where each page sits in the single column the viewer scrolls through, at zoom 1.
///
/// Every page is fitted to the same width, `fitWidth`, whatever its own size, so a landscape page
/// is as wide as a portrait one and less tall. Pages are stacked from the top with `gap` points
/// between them and none above the first or below the last. Heights are rounded to whole points,
/// so every page starts on a whole point and its edges fall on device pixels at zoom 1 (an edge
/// between pixels would make Core Animation blur the whole page).
///
/// A page is laid out at most `maxAspect` (1,000) times as tall as it is wide, and at least a
/// 1,000th as tall. A hostile file can give a page a box one point wide and 10^38 points tall, which
/// fitted to the width would be taller than Core Animation, which works in single precision, can
/// place. Real pages stay far within the bound: even a long receipt, or a web page saved whole, is
/// rarely a hundred times as tall as it is wide. A page beyond it keeps its width's scale
/// (`scale(of:)`), so it is drawn as any page is, and only the part of it within the bound is shown.
///
/// Pure geometry in layout points: the scroll view's content coordinates at zoom 1, origin
/// top-left, y down. The scroll view multiplies everything by its zoom scale.
struct PageLayout {
    /// The width every page is fitted to.
    let fitWidth: CGFloat
    /// The space between two pages.
    let gap: CGFloat
    /// The size of the whole column at zoom 1.
    let contentSize: CGSize
    /// Layout points per PDF point at zoom 1 for the first page, and so for every page as wide
    /// as the first, which is normally all of them. A page of another width has its own,
    /// `scale(of:)`, since every page is fitted to the width.
    var scalePerPoint: CGFloat { scale(of: 0) }

    /// The most a page is laid out tall, in its own widths, and the inverse of the least.
    static let maxAspect: CGFloat = 1_000

    private let frames: [CGRect]
    private let scales: [CGFloat]

    init(pages: [PageInfo], fitWidth: CGFloat, gap: CGFloat = 12) {
        let width = max(0, fitWidth)
        var frames: [CGRect] = []
        var scales: [CGFloat] = []
        frames.reserveCapacity(pages.count)
        scales.reserveCapacity(pages.count)
        var y: CGFloat = 0
        for page in pages {
            if !frames.isEmpty { y += gap }
            let size = Self.usableSize(of: page)
            let aspect = min(max(size.height / size.width, 1 / Self.maxAspect), Self.maxAspect)
            let height = max(1, (width * aspect).rounded())
            frames.append(CGRect(x: 0, y: y, width: width, height: height))
            scales.append(width / size.width)
            y += height
        }
        self.fitWidth = width
        self.gap = gap
        self.frames = frames
        self.scales = scales
        self.contentSize = CGSize(width: width, height: y)
    }

    /// How many pages the layout has.
    var pageCount: Int { frames.count }

    /// The page's place in the column at zoom 1; `.zero` for a page the layout does not have.
    func frame(of page: Int) -> CGRect {
        frames.indices.contains(page) ? frames[page] : .zero
    }

    /// Layout points per PDF point for `page` at zoom 1 (its width is fitted to `fitWidth`); 0 for
    /// a page the layout does not have.
    func scale(of page: Int) -> CGFloat {
        scales.indices.contains(page) ? scales[page] : 0
    }

    /// The pages that `rect` (layout points at zoom 1) overlaps vertically, in order; empty when it
    /// overlaps none, such as a rect inside a gap or outside the column.
    func visiblePages(in rect: CGRect) -> Range<Int> {
        guard !rect.isNull, !rect.isInfinite else { return 0..<0 }
        let first = firstPage { $0.maxY > rect.minY }
        let end = firstPage { $0.minY >= rect.maxY }
        return first..<max(first, end)
    }

    /// The page under `point` (layout points at zoom 1); nil in a gap or outside the column.
    func page(at point: CGPoint) -> Int? {
        let index = firstPage { $0.maxY > point.y }
        guard frames.indices.contains(index), frames[index].contains(point) else { return nil }
        return index
    }

    /// The first page whose frame satisfies `isAtOrPast`, or `pageCount` if none does. The frames
    /// go down the column, so a predicate about how far down a frame is holds for a suffix of
    /// them, which a binary search finds in O(log n) for a long document.
    private func firstPage(where isAtOrPast: (CGRect) -> Bool) -> Int {
        var low = 0
        var high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if isAtOrPast(frames[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// The page's size in points, or the shape of a US Letter page when the engine reports a size
    /// that cannot be laid out (zero, negative or not finite), so that one odd page cannot give the
    /// column an infinite or empty height.
    private static func usableSize(of page: PageInfo) -> CGSize {
        let size = CGSize(width: page.widthPt, height: page.heightPt)
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
            return CGSize(width: 612, height: 792)
        }
        return size
    }
}
