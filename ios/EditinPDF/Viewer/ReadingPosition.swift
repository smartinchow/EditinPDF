import CoreGraphics

/// Where the reader is in the column of pages, in terms that outlast a new width: the page at the top
/// of the visible area, how far down it that top is, how far across the column the left edge of the
/// visible area is, and the zoom.
///
/// The viewer lays its pages out again whenever its width changes: the phone turning, an iPhone Duo
/// folding or unfolding (its two displays have the same shape, so the same page at the same zoom shows
/// the same part of it on either), Split View on a tablet or a Duo's inner display. Layout points do
/// not survive that, since every page is fitted to the width; fractions of a page and of the column do.
///
/// Pure geometry in layout points at zoom 1, like `PageLayout`.
struct ReadingPosition: Equatable {
    /// The page at the top of the visible area; a top in the gap between two pages counts as the top
    /// of the page below it.
    let page: Int
    /// How far down `page` the top of the visible area is, from 0 to 1.
    let fractionDown: CGFloat
    /// How far across the column the left edge of the visible area is, from 0 to 1: 0 unless zoomed in.
    let fractionAcross: CGFloat
    /// The scroll view's zoom scale.
    let zoom: CGFloat

    /// The position of `visibleArea` (layout points at zoom 1: the part of the content the bars leave)
    /// in `layout`, at `zoom`. Nil for a layout with no pages, or one with no width.
    init?(visibleArea: CGRect, zoom: CGFloat, in layout: PageLayout) {
        guard layout.pageCount > 0, layout.fitWidth > 0, !visibleArea.isNull, !visibleArea.isInfinite else { return nil }
        let top = visibleArea.minY
        let page = min(layout.visiblePages(in: CGRect(x: 0, y: top, width: layout.fitWidth, height: 0)).lowerBound,
                       layout.pageCount - 1)
        let frame = layout.frame(of: page)
        self.init(page: page,
                  fractionDown: frame.height > 0 ? Self.unit((top - frame.minY) / frame.height) : 0,
                  fractionAcross: Self.unit(visibleArea.minX / layout.fitWidth),
                  zoom: zoom.isFinite && zoom > 0 ? zoom : 1)
    }

    init(page: Int, fractionDown: CGFloat, fractionAcross: CGFloat, zoom: CGFloat) {
        self.page = page
        self.fractionDown = fractionDown
        self.fractionAcross = fractionAcross
        self.zoom = zoom
    }

    /// The point of `layout` (layout points at zoom 1) that goes at the top-left of the visible area to
    /// be at this position again; `.zero` for a page the layout does not have. The caller keeps the
    /// scroll offset within the ends of its range.
    func topLeft(in layout: PageLayout) -> CGPoint {
        guard (0..<layout.pageCount).contains(page) else { return .zero }
        let frame = layout.frame(of: page)
        return CGPoint(x: fractionAcross * layout.fitWidth, y: frame.minY + fractionDown * frame.height)
    }

    /// `value` kept within 0 to 1; 0 when it is not a number.
    private static func unit(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}
