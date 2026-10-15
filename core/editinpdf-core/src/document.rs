//! `PdfDocument`: one open PDF, as the Swift side sees it.

use std::sync::{Arc, Mutex, MutexGuard};

use pdfcraft_engine::{DocId, Session};

use crate::{OpenError, PageInfo};

/// An open PDF document. Safe to share between threads; calls on one document run one at a time.
#[derive(uniffi::Object)]
pub struct PdfDocument {
    // The engine session is not `Sync`, so it lives behind a single mutex. Every method locks once
    // and returns, never holding the lock while it waits on anything else.
    inner: Mutex<Inner>,
}

struct Inner {
    session: Session,
    id: DocId,
    /// Bumped by every edit, so caches (rendered pages, text) can tell when they are stale.
    revision: u64,
}

impl std::fmt::Debug for PdfDocument {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The document's contents are the user's business; leave them out of logs and panics.
        f.debug_struct("PdfDocument").finish_non_exhaustive()
    }
}

impl PdfDocument {
    /// The state lock. It is only poisoned if an earlier call panicked while holding it, and UniFFI
    /// has already reported that panic; recover the guard rather than fail every later call.
    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

#[uniffi::export]
impl PdfDocument {
    /// Opens a PDF from its bytes. `password` is the user or owner password, for an encrypted file.
    ///
    /// Fails with `NeedsPassword` when the file is encrypted and no password was given,
    /// `WrongPassword` when the given one does not open it, and `Corrupt` for anything that is
    /// not a readable PDF. Bad input is an error, not a crash.
    #[uniffi::constructor]
    pub fn open(bytes: Vec<u8>, password: Option<String>) -> Result<Arc<Self>, OpenError> {
        let mut session = Session::new();
        let id = session.open("document.pdf", None, Arc::new(bytes), password.as_deref())?;
        Ok(Arc::new(Self {
            inner: Mutex::new(Inner {
                session,
                id,
                revision: 0,
            }),
        }))
    }

    /// The number of pages.
    pub fn page_count(&self) -> u32 {
        let inner = self.lock();
        let pages = inner
            .session
            .get(inner.id)
            .map_or(0, |doc| doc.info.pages.len());
        u32::try_from(pages).unwrap_or(u32::MAX)
    }

    /// The geometry and label of the 0-based page `page`; nothing when there is no such page.
    pub fn page_info(&self, page: u32) -> Option<PageInfo> {
        let inner = self.lock();
        let doc = inner.session.get(inner.id)?;
        let info = doc.info.pages.get(usize::try_from(page).ok()?)?;
        Some(PageInfo::from_engine(page, info))
    }

    /// Changes whenever the document's content does, so callers can drop what they cached for an
    /// older state. Always 0 until editing exists.
    pub fn revision(&self) -> u64 {
        self.lock().revision
    }
}
