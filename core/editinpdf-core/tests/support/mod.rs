//! Helpers shared by the editing tests: reading a page's text, reopening saved bytes, comparing
//! rectangles, and the colours the tests mark pages with.
//!
//! Each integration-test crate compiles this module on its own and uses only some helpers, hence
//! the `dead_code` allowance; the clippy allowances mirror the ones the test files carry.
#![allow(dead_code, clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::sync::Arc;

use editinpdf_core::{PdfDocument, Rect, RgbColor};

pub const YELLOW: RgbColor = RgbColor {
    red: 1.0,
    green: 1.0,
    blue: 0.0,
};
pub const RED: RgbColor = RgbColor {
    red: 1.0,
    green: 0.0,
    blue: 0.0,
};
pub const BLUE: RgbColor = RgbColor {
    red: 0.0,
    green: 0.0,
    blue: 1.0,
};

/// All of a page's glyph texts, one after another.
pub fn text_of(doc: &PdfDocument, page: u32) -> String {
    doc.page_text(page)
        .unwrap()
        .glyphs
        .iter()
        .map(|g| g.text.as_str())
        .collect()
}

/// Opens saved bytes again, as a new document.
pub fn reopen(bytes: Vec<u8>, password: Option<&str>) -> Arc<PdfDocument> {
    PdfDocument::open(bytes, password.map(str::to_owned)).expect("the saved bytes reopen")
}

/// Panics unless every side of `a` is within `tol` points of `b`'s.
pub fn assert_rect_close(a: &Rect, b: &Rect, tol: f64) {
    let close = (a.x - b.x).abs() <= tol
        && (a.y - b.y).abs() <= tol
        && (a.width - b.width).abs() <= tol
        && (a.height - b.height).abs() <= tol;
    assert!(close, "{a:?} is not within {tol} of {b:?}");
}
