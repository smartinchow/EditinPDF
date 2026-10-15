//! Errors the bridge reports to Swift.

/// Why a document could not be opened.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum OpenError {
    /// The document is encrypted and no password was given.
    #[error("this document needs a password")]
    NeedsPassword,
    /// A password was given and it does not open the document.
    #[error("wrong password")]
    WrongPassword,
    /// The bytes are not a PDF the engine can read: damaged, truncated, not a PDF at all, or
    /// using something the engine does not support. `message` says what was wrong.
    #[error("{message}")]
    Corrupt { message: String },
}

impl From<pdfcraft_render::OpenError> for OpenError {
    fn from(err: pdfcraft_render::OpenError) -> Self {
        use pdfcraft_render::OpenError as Engine;
        // Every engine variant is named so that one added upstream stops the build here and gets
        // classified, instead of silently being reported as corruption.
        match err {
            Engine::NeedsPassword => Self::NeedsPassword,
            Engine::WrongPassword => Self::WrongPassword,
            Engine::Invalid(_) | Engine::Unsupported(_) => Self::Corrupt {
                message: err.to_string(),
            },
        }
    }
}

/// Why a page could not be rendered.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RenderError {
    /// The document has no page with this index (pages count from 0).
    #[error("page {page} is out of range")]
    PageOutOfRange { page: u32 },
    /// The requested tile is wider or taller than 4096 pixels, or has no area (a width or a height
    /// of zero): both are reported the same way, since either way the size is outside 1 to 4096.
    #[error("tile too large (max 4096 px per side)")]
    TileTooLarge,
    /// The page could not be drawn: the scale is not a positive, finite number, or the engine could
    /// not draw the page. `message` says what was wrong.
    #[error("{message}")]
    Failed { message: String },
}
