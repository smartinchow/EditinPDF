//! Turning view-space positions (points from the page's top-left corner as shown, after its
//! rotation, `y` growing down) into PDF user space and back.
//!
//! The engine's own conversions (`PageInfo::view_to_user`, `user_to_view`) do the work, so the
//! bridge and the engine agree on every page, whatever its `/Rotate` and crop box. They work in
//! single precision; these widen the result back to the double precision the records carry.

use pdfcraft_render::PageInfo;

use crate::{Point, Rect};

/// Narrowed to the engine's precision. Page-sized values lose nothing that matters (a single
/// precision value is exact to about a thousandth of a point on a page).
#[allow(clippy::cast_possible_truncation)]
fn narrow(value: f64) -> f32 {
    value as f32
}

/// The user-space point under the view-space point `p`.
pub(crate) fn to_user(page: &PageInfo, p: Point) -> [f64; 2] {
    page.view_to_user(narrow(p.x), narrow(p.y)).map(f64::from)
}

/// The view-space point over the user-space point `user`.
pub(crate) fn to_view(page: &PageInfo, user: [f64; 2]) -> Point {
    let [x, y] = page
        .user_to_view(narrow(user[0]), narrow(user[1]))
        .map(f64::from);
    Point { x, y }
}

/// The user-space rectangle `[x0, y0, x1, y1]` (x0 < x1, y0 < y1) a view-space one covers.
pub(crate) fn rect_to_user(page: &PageInfo, r: &Rect) -> [f64; 4] {
    let [ax, ay] = to_user(page, Point { x: r.x, y: r.y });
    let [bx, by] = to_user(
        page,
        Point {
            x: r.x + r.width,
            y: r.y + r.height,
        },
    );
    [ax.min(bx), ay.min(by), ax.max(bx), ay.max(by)]
}

/// The view-space rectangle a user-space one `[x0, y0, x1, y1]` covers.
pub(crate) fn rect_to_view(page: &PageInfo, r: [f32; 4]) -> Rect {
    let [x0, y0, x1, y1] = r.map(f64::from);
    let a = to_view(page, [x0, y0]);
    let b = to_view(page, [x1, y1]);
    let (left, top) = (a.x.min(b.x), a.y.min(b.y));
    Rect {
        x: left,
        y: top,
        width: a.x.max(b.x) - left,
        height: a.y.max(b.y) - top,
    }
}

/// The text-markup quadrilateral for a view-space rectangle: its corners top-left, top-right,
/// bottom-left, bottom-right as shown, each in user space. Mapping each corner, rather than the
/// user-space box, keeps the reading direction on a turned page, so an underline lies under the
/// text and not beside it.
pub(crate) fn rect_to_quad(page: &PageInfo, r: &Rect) -> [f64; 8] {
    let (left, top) = (r.x, r.y);
    let (right, bottom) = (r.x + r.width, r.y + r.height);
    let [x1, y1] = to_user(page, Point { x: left, y: top });
    let [x2, y2] = to_user(page, Point { x: right, y: top });
    let [x3, y3] = to_user(page, Point { x: left, y: bottom });
    let [x4, y4] = to_user(
        page,
        Point {
            x: right,
            y: bottom,
        },
    );
    [x1, y1, x2, y2, x3, y3, x4, y4]
}

/// A view-space displacement as a user-space one: how far a move by `(dx, dy)` as shown goes in
/// the file. For moving annotations, which the next editing step adds.
#[allow(dead_code)]
pub(crate) fn delta_to_user(page: &PageInfo, dx: f64, dy: f64) -> [f64; 2] {
    let [ox, oy] = to_user(page, Point { x: 0.0, y: 0.0 });
    let [x, y] = to_user(page, Point { x: dx, y: dy });
    [x - ox, y - oy]
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    fn page(rotation: u16) -> PageInfo {
        let (width, height) = if rotation.is_multiple_of(180) {
            (612.0, 792.0)
        } else {
            (792.0, 612.0)
        };
        PageInfo {
            width,
            height,
            label: String::new(),
            crop: [10.0, 20.0, 622.0, 812.0],
            rotation,
        }
    }

    #[test]
    fn view_user_round_trip_every_rotation() {
        for rotation in [0u16, 90, 180, 270] {
            let page = page(rotation);
            let r = Rect {
                x: 100.0,
                y: 50.0,
                width: 80.0,
                height: 20.0,
            };
            let back = rect_to_view(&page, rect_to_user(&page, &r).map(narrow));
            assert!(
                (back.x - r.x).abs() < 0.01
                    && (back.y - r.y).abs() < 0.01
                    && (back.width - r.width).abs() < 0.01
                    && (back.height - r.height).abs() < 0.01,
                "{rotation}: {back:?}"
            );
            let q = rect_to_quad(&page, &r);
            let corners = [(100.0, 50.0), (180.0, 50.0), (100.0, 70.0), (180.0, 70.0)];
            for (i, (x, y)) in corners.into_iter().enumerate() {
                let p = to_view(&page, [q[2 * i], q[2 * i + 1]]);
                assert!(
                    (p.x - x).abs() < 0.01 && (p.y - y).abs() < 0.01,
                    "{rotation}: quad corner {i} is {p:?}, not ({x}, {y})"
                );
            }
        }
    }

    #[test]
    fn the_view_origin_is_the_crop_corner_shown_top_left() {
        // Unturned: the top-left of the crop box. Turned a quarter clockwise: its bottom-left.
        assert_eq!(to_user(&page(0), Point { x: 0.0, y: 0.0 }), [10.0, 812.0]);
        assert_eq!(to_user(&page(90), Point { x: 0.0, y: 0.0 }), [10.0, 20.0]);
    }

    #[test]
    fn a_move_as_shown_is_turned_with_the_page() {
        let [dx, dy] = delta_to_user(&page(0), 5.0, 10.0);
        assert!((dx - 5.0).abs() < 0.01 && (dy + 10.0).abs() < 0.01);
        // On a page turned a quarter clockwise, right as shown is up in the file.
        let [dx, dy] = delta_to_user(&page(90), 5.0, 0.0);
        assert!(dx.abs() < 0.01 && (dy - 5.0).abs() < 0.01, "{dx}, {dy}");
    }
}
