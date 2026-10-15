//! editinpdf-core: the bridge between the PdfCraft engine and the EditinPDF apps.
//!
//! Everything the Swift side sees is declared here through UniFFI proc-macros. The engine's
//! types never cross the FFI boundary; each call maps a small, stable API onto `pdfcraft_engine`.
//!
//! M0 spike: this file only proves the engine compiles and links for iOS.

uniffi::setup_scaffolding!();

/// The bridge version and the PdfCraft release it was built against.
#[uniffi::export]
pub fn engine_version() -> String {
    format!("editinpdf-core {} / pdfcraft v{}", env!("CARGO_PKG_VERSION"), env!("PDFCRAFT_VERSION"))
}

/// M0 probe: opens a PDF from bytes and reports its page count, or 0 if it does not open.
/// Replaced by `PdfDocument` in M1.
#[uniffi::export]
pub fn probe_page_count(bytes: Vec<u8>) -> u32 {
    let mut session = pdfcraft_engine::Session::new();
    match session.open("probe", None, std::sync::Arc::new(bytes), None) {
        Ok(id) => session.get(id).map(|doc| doc.info.pages.len() as u32).unwrap_or(0),
        Err(_) => 0,
    }
}
