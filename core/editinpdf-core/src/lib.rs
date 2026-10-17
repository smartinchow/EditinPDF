//! editinpdf-core: the bridge between the PdfCraft engine and the EditinPDF apps.
//!
//! Everything the Swift side sees is declared here through UniFFI proc-macros. The engine's
//! types never cross the FFI boundary; each call maps a small, stable API onto `pdfcraft_engine`.
//!
//! - [`PdfDocument`]: one open document (open, page count, page geometry, page pixels, page text,
//!   selecting text and searching).
//! - [`OpenError`], [`RenderError`], [`PageInfo`], [`TileRect`], [`RenderedTile`], [`Rect`],
//!   [`PageText`], [`TextGlyph`], [`TextSelection`], [`SearchHit`]: its error and record types.
//! - [`MAX_SEARCH_HITS`], [`MAX_QUERY_CHARS`]: the limits of a search, which keep the work and the
//!   memory of one call bounded whatever the document. [`search_hit_limit`] hands the first to the
//!   apps, which cannot read a Rust constant.
//! - [`min_tile_scale`], [`max_tile_scale`]: the scales a tile is drawn at, for the apps to keep
//!   their requests within.

uniffi::setup_scaffolding!();

mod document;
mod error;
mod render;
mod text;
mod text_cache;
mod types;

pub use document::PdfDocument;
pub use error::*;
pub use text::{MAX_QUERY_CHARS, MAX_SEARCH_HITS};
pub use types::*;

/// The bridge version and the PdfCraft release it was built against.
#[uniffi::export]
pub fn engine_version() -> String {
    format!(
        "editinpdf-core {} / pdfcraft v{}",
        env!("CARGO_PKG_VERSION"),
        env!("PDFCRAFT_VERSION")
    )
}

/// The most hits `search` returns: the first ones, in page order. A search that returns this many
/// has stopped looking, so the document may have more matches than it shows.
#[uniffi::export]
pub fn search_hit_limit() -> u32 {
    u32::try_from(MAX_SEARCH_HITS).unwrap_or(u32::MAX)
}

/// The smallest scale, in device pixels per point, that `PdfDocument::render_tile` draws a tile at.
#[uniffi::export]
pub fn min_tile_scale() -> f64 {
    f64::from(render::MIN_TILE_SCALE)
}

/// The largest scale, in device pixels per point, that `PdfDocument::render_tile` draws a tile at.
#[uniffi::export]
pub fn max_tile_scale() -> f64 {
    f64::from(render::MAX_TILE_SCALE)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn the_exported_hit_limit_is_the_one_a_search_stops_at() {
        assert_eq!(
            usize::try_from(search_hit_limit()).unwrap(),
            MAX_SEARCH_HITS
        );
    }
}
