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

/// Why a page could not be drawn, or its text could not be read.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RenderError {
    /// The document has no page with this index (pages count from 0).
    #[error("page {page} is out of range")]
    PageOutOfRange { page: u32 },
    /// The requested tile is wider or taller than 4096 pixels, or has no area (a width or a height
    /// of zero): both are reported the same way, since either way the size is outside 1 to 4096.
    #[error("tile too large (max 4096 px per side)")]
    TileTooLarge,
    /// The page could not be drawn or its text could not be read: the scale is not a positive,
    /// finite number, or the engine could not draw the page or read its text. `message` says what
    /// was wrong.
    #[error("{message}")]
    Failed { message: String },
}

/// Why an edit, an undo or a redo did not happen.
///
/// The document is as it was, except possibly after `Failed`: undo and redo can fail after the
/// engine has already changed the document, and so can a change that panics. Then the revision has
/// moved on all the same, and the apps should read the document again.
#[derive(Clone, Debug, PartialEq, thiserror::Error, uniffi::Error)]
pub enum EditError {
    /// The document cannot be edited at all (for example, it is encrypted in a way the engine can
    /// read but not write). `message` says why, and may be empty when the engine gave no reason.
    #[error("{}", read_only(.message))]
    ReadOnly { message: String },
    /// The document's security settings do not allow this change. `message` says which.
    #[error("{message}")]
    NotPermitted { message: String },
    /// The change would leave the document without a page.
    #[error("a document must keep at least one page")]
    WouldRemoveAllPages,
    /// The change does not fit the document: a page it does not have, a rotation that is not a
    /// multiple of 90 degrees, a size or a position that is not a finite number, and the like.
    #[error("{message}")]
    Invalid { message: String },
    /// The change was made for an older revision of the document than the current one, `current`.
    #[error("the document has changed since this edit was made (now at revision {current})")]
    Stale { current: u64 },
    /// The document to take pages from is encrypted and no password was given for it.
    #[error("the other document needs a password")]
    SourceNeedsPassword,
    /// The document to take pages from could not be read as a PDF: damaged, not a PDF at all, or
    /// using something the engine does not support. `message` says why.
    #[error("{message}")]
    SourceUnreadable { message: String },
    /// The document to take pages from is readable, but its security settings do not allow its
    /// pages to be copied.
    #[error("the other PDF doesn't allow its pages to be copied")]
    SourceNotPermitted,
    /// There is no change to undo.
    #[error("nothing to undo")]
    NothingToUndo,
    /// There is no undone change to redo.
    #[error("nothing to redo")]
    NothingToRedo,
    /// The engine could not make the change, or failed while making it. `message` says what was
    /// wrong.
    #[error("{message}")]
    Failed { message: String },
}

impl From<pdfcraft_engine::EditError> for EditError {
    fn from(err: pdfcraft_engine::EditError) -> Self {
        use pdfcraft_engine::EditError as Engine;
        use pdfcraft_organize::OrganizeError;
        // Every engine variant is named so that one added upstream stops the build here and gets
        // classified, instead of silently being reported as a failure.
        match err {
            Engine::Organize(OrganizeError::WouldRemoveAllPages) => Self::WouldRemoveAllPages,
            Engine::Organize(_)
            | Engine::Bookmark(_)
            | Engine::Comment(_)
            | Engine::Form(_)
            | Engine::Invalid(_)
            | Engine::Measure(_) => Self::Invalid {
                message: err.to_string(),
            },
            Engine::ReadOnly(message) => Self::ReadOnly { message },
            Engine::NotPermitted(_) => Self::NotPermitted {
                message: err.to_string(),
            },
            Engine::Source(message) => Self::SourceUnreadable { message },
            Engine::NothingToUndo => Self::NothingToUndo,
            Engine::NothingToRedo => Self::NothingToRedo,
            Engine::NoDocument
            | Engine::Protection(_)
            | Engine::WrongPassword
            | Engine::Redact(_)
            | Engine::Print(_)
            | Engine::Accessibility(_)
            | Engine::Data(_)
            | Engine::Edit(_)
            | Engine::Create(_)
            | Engine::Write(_)
            | Engine::Reopen(_)
            | Engine::Sign(_)
            | Engine::Optimize(_)
            | Engine::Cancelled
            | Engine::SignedRewrite(_)
            | Engine::Signed => Self::Failed {
                message: err.to_string(),
            },
        }
    }
}

/// Why a document could not be saved. Nothing about the document changes.
#[derive(Clone, Debug, PartialEq, thiserror::Error, uniffi::Error)]
pub enum SaveError {
    /// The document is signed, and this save would rewrite it and so invalidate the signatures. An
    /// incremental save keeps them, except for a document saving writes out in full
    /// (`EditCapabilities::rewrites_on_save`), which no save of is made.
    #[error("this document is signed: rewriting it would invalidate its signatures")]
    Signed,
    /// The document cannot be edited, so it cannot be rewritten. `message` says why, and may be
    /// empty when the engine gave no reason.
    #[error("{}", read_only(.message))]
    ReadOnly { message: String },
    /// The engine could not write the document, or failed while writing it. `message` says what
    /// was wrong.
    #[error("{message}")]
    Failed { message: String },
}

impl From<pdfcraft_engine::EditError> for SaveError {
    fn from(err: pdfcraft_engine::EditError) -> Self {
        use pdfcraft_engine::EditError as Engine;
        match err {
            Engine::Signed | Engine::SignedRewrite(_) => Self::Signed,
            Engine::ReadOnly(message) => Self::ReadOnly { message },
            _ => Self::Failed {
                message: err.to_string(),
            },
        }
    }
}

/// The sentence for a document that cannot be edited, with the engine's reason when it gave one.
fn read_only(reason: &str) -> String {
    let reason = reason.trim();
    if reason.is_empty() {
        "this document can't be edited".to_owned()
    } else {
        format!("this document can't be edited: {reason}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_read_only_document_without_a_reason_reads_as_a_plain_sentence() {
        let none = String::new();
        assert_eq!(
            EditError::ReadOnly {
                message: none.clone()
            }
            .to_string(),
            "this document can't be edited"
        );
        assert_eq!(
            SaveError::ReadOnly { message: none }.to_string(),
            "this document can't be edited"
        );
        assert_eq!(
            EditError::ReadOnly {
                message: "it is encrypted".to_owned()
            }
            .to_string(),
            "this document can't be edited: it is encrypted"
        );
    }
}
