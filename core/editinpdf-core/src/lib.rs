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
//!   memory of one call bounded whatever the document.

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
