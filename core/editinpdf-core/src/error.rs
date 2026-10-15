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
