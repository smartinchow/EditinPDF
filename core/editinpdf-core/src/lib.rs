//! editinpdf-core: the bridge between the PdfCraft engine and the EditinPDF apps.
//!
//! Everything the Swift side sees is declared here through UniFFI proc-macros. The engine's
//! types never cross the FFI boundary; each call maps a small, stable API onto `pdfcraft_engine`.
//!
//! - [`PdfDocument`]: one open document (open, page count, page geometry, page pixels, page text,
//!   selecting text and searching, editing, listing comments and form fields, undo and redo,
//!   saving, extracting pages). No script a document carries is ever run: the engine's
//!   JavaScript is off in every session the bridge makes.
//! - [`Edit`], [`EditOutcome`], [`EditCapabilities`], [`SaveMode`], [`Point`], [`RgbColor`],
//!   [`MarkupKind`], [`ShapeKind`], [`FieldValue`], [`EditError`], [`SaveError`]: what editing takes
//!   and gives.
//! - [`AnnotationInfo`], [`AnnotationKind`]: the document's comments, as `annotations` lists them.
//! - [`FormField`], [`FormFieldKind`], [`FormWidget`], [`ChoiceOption`]: the document's form
//!   fields, as `form_fields` lists them.
//! - [`OpenError`], [`RenderError`], [`PageInfo`], [`TileRect`], [`RenderedTile`], [`Rect`],
//!   [`PageText`], [`TextGlyph`], [`TextSelection`], [`SearchHit`]: its error and record types.
//! - [`MAX_SEARCH_HITS`], [`MAX_QUERY_CHARS`]: the limits of a search. They bound what one search
//!   hands back (its hits, and so the memory they take) and the work of matching the query against
//!   a page's text. They do not bound the time a search takes: reading each page's text is the
//!   engine's work, which grows with the page and the document. [`search_hit_limit`] hands the first
//!   to the apps, which cannot read a Rust constant.
//! - [`blank_document`]: a new one-page PDF, for starting a document from nothing.
//! - [`max_text_chars`]: the most characters the text of a comment, a text box or a document
//!   information entry may have, for the apps to hold their editors to.
//! - [`min_tile_scale`], [`max_tile_scale`]: the scales a tile is drawn at, for the apps to keep
//!   their requests within.
//!
//! # Panics
//!
//! A method that returns a `Result` reports a panic as an error: UniFFI catches it at the FFI
//! boundary, and Swift sees an error thrown. A method that returns no `Result` has no way to report
//! one: the Swift bindings call it with `try!`, and a panic there ends the app. So the methods and
//! functions without a `Result` (`page_count`, `page_info`, `revision`, `can_undo`, `can_redo`,
//! `is_dirty`, `capabilities`, `annotations`, `form_fields`, `form_fields_truncated`, `search`, and the free functions here other than
//! `blank_document`) must never panic. They only read the document's state, under a lock that recovers from
//! poisoning, except `search`, which runs the engine's text code and therefore catches a panic
//! itself, page by page. Keep it that way when adding one.
//!
//! The calls that run engine code under the lock (`apply`, `apply_all`, `undo`, `redo`, `save`,
//! `extract_pages`) catch a panic themselves and report it as an error, so the lock is never left
//! poisoned.

uniffi::setup_scaffolding!();

mod annotations;
mod document;
mod edit;
mod error;
mod forms;
mod geometry;
mod render;
mod text;
mod text_cache;
mod types;

pub use annotations::{AnnotationInfo, AnnotationKind};
pub use document::PdfDocument;
pub use edit::*;
pub use error::*;
pub use forms::{ChoiceOption, FormField, FormFieldKind, FormWidget};
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

/// A new PDF of one blank page, `width_pt` by `height_pt` points, for the app to write.
///
/// Fails with `Invalid` when a side is not a positive, finite number of at most 14,400 points, and
/// `Failed` when the engine cannot write the document.
#[uniffi::export]
pub fn blank_document(width_pt: f64, height_pt: f64) -> Result<Vec<u8>, EditError> {
    let width = edit::page_side(width_pt)?;
    let height = edit::page_side(height_pt)?;
    let bytes = document::session().create_blank(width, height, 1)?;
    Ok(std::sync::Arc::unwrap_or_clone(bytes))
}

/// The most hits `search` returns: the first ones, in page order. A search that returns this many
/// has stopped looking, so the document may have more matches than it shows.
#[uniffi::export]
pub fn search_hit_limit() -> u32 {
    u32::try_from(MAX_SEARCH_HITS).unwrap_or(u32::MAX)
}

/// The most characters (Unicode scalar values) the text of a comment, of a text box or of a
/// document information entry may have: 100,000. An edit that carries more is refused as
/// `Invalid`, so the apps hold their editors to it. (A form field's text has a cap of its own,
/// 10,000.)
#[uniffi::export]
pub fn max_text_chars() -> u32 {
    u32::try_from(edit::MAX_TEXT_CHARS).unwrap_or(u32::MAX)
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
    fn the_exported_text_cap_is_the_one_edits_are_held_to() {
        assert_eq!(
            usize::try_from(max_text_chars()).unwrap(),
            edit::MAX_TEXT_CHARS
        );
    }

    #[test]
    fn the_exported_hit_limit_is_the_one_a_search_stops_at() {
        assert_eq!(
            usize::try_from(search_hit_limit()).unwrap(),
            MAX_SEARCH_HITS
        );
    }
}
