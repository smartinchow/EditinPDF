//! `PdfDocument`: one open PDF, as the Swift side sees it.

use std::sync::{Arc, Mutex, MutexGuard};

use pdfcraft_engine::{DocId, Session};

use crate::render::{self, RendererPool};
use crate::{OpenError, PageInfo, RenderError, RenderedTile, TileRect};

/// An open PDF document. Safe to share between threads. Calls on one document run one at a time,
/// except drawing pages, which can run alongside each other and alongside the other calls.
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
    /// The renderers for the revision they were built for; replaced by the first render after the
    /// revision changes. Shared out as an `Arc`, so a render that is under way keeps its renderers
    /// even if a newer revision has replaced them here.
    renderers: Option<Arc<RendererPool>>,
}

impl Inner {
    /// The renderers that draw the current revision, once `page` (0-based) is known to exist.
    ///
    /// Cheap: a pool builds nothing until it is used, so this is fine to call under the state lock.
    fn render_pool(&mut self, page: u32) -> Result<Arc<RendererPool>, RenderError> {
        let doc = self
            .session
            .get(self.id)
            .ok_or_else(|| RenderError::Failed {
                message: "the document is no longer open".to_owned(),
            })?;
        let exists = usize::try_from(page).is_ok_and(|page| page < doc.info.pages.len());
        if !exists {
            return Err(RenderError::PageOutOfRange { page });
        }
        if let Some(pool) = &self.renderers
            && pool.revision() == self.revision
        {
            return Ok(pool.clone());
        }
        // What the pool opens is the page view (`display`), not the working file, and the password
        // is the one the engine opened the document with: for a file opened with its owner password
        // that can be the user password the engine recovered, which is what a renderer can use.
        let pool = Arc::new(RendererPool::new(
            self.revision,
            doc.display.clone(),
            doc.password.as_deref(),
        ));
        self.renderers = Some(pool.clone());
        Ok(pool)
    }
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
                renderers: None,
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

    /// Draws the 0-based page `page` as premultiplied RGBA pixels.
    ///
    /// `scale` is device pixels per point: 1.0 is 72 dpi, 2.0 suits a screen that doubles every
    /// pixel. `rect` picks the part of the page to draw, in device pixels at `scale` from the page's
    /// top-left corner as shown (after its rotation); without it the whole page is drawn. A tile is
    /// the same picture as that part of the whole-page drawing, and may reach past the page's edge,
    /// where it is white.
    ///
    /// Tiles are the way to zoom in: one never costs more than 4096 x 4096 pixels, whatever the page
    /// and the scale. A whole-page drawing is limited by the engine to 8192 pixels on a side and 64
    /// million pixels in all; beyond that it comes back reduced to fit (its width and height say by
    /// how much) instead of failing. For a tile, a scale outside 0.01 through 400 is clamped to it.
    ///
    /// Safe to call from several threads at once: up to two pages of one document are drawn at the
    /// same time, further calls wait their turn, and the document's other methods never wait for a
    /// drawing.
    ///
    /// Fails with `PageOutOfRange` for a page the document does not have, with `TileTooLarge` when
    /// `rect` is wider or taller than 4096 pixels or has no area (a zero width or height), and with
    /// `Failed` for a scale that is not a positive, finite number or a page the engine cannot draw.
    pub fn render_tile(
        &self,
        page: u32,
        scale: f64,
        rect: Option<TileRect>,
    ) -> Result<RenderedTile, RenderError> {
        let request = render::pixel_request(page, scale, rect)?;
        // The state lock is held only to check the page and fetch the renderers. Drawing can take a
        // long time, and must not hold up the document's other methods while it does.
        let pool = {
            let mut inner = self.lock();
            inner.render_pool(page)?
        };
        render::into_tile(pool.render(request))
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use std::sync::mpsc;
    use std::thread;
    use std::time::Duration;

    use super::*;

    fn open_one_page() -> Arc<PdfDocument> {
        let bytes = Session::new()
            .create_from_text("fixture", "hello")
            .expect("a text page creates")
            .to_vec();
        PdfDocument::open(bytes, None).expect("the page opens")
    }

    #[test]
    fn the_renderers_are_kept_until_the_revision_changes() {
        let doc = open_one_page();
        let mut inner = doc.lock();
        let first = inner.render_pool(0).unwrap();
        assert_eq!(first.revision(), 0);
        assert!(
            Arc::ptr_eq(&first, &inner.render_pool(0).unwrap()),
            "the same revision keeps its renderers"
        );

        inner.revision += 1;
        let second = inner.render_pool(0).unwrap();
        assert_eq!(second.revision(), 1);
        assert!(
            !Arc::ptr_eq(&first, &second),
            "a new revision gets renderers of its own"
        );
        assert!(
            Arc::ptr_eq(&second, &inner.render_pool(0).unwrap()),
            "and keeps them in turn"
        );
        // A render that began before the change still holds the old renderers and can finish.
        assert_eq!(first.revision(), 0);
    }

    #[test]
    fn a_page_that_does_not_exist_gets_no_renderers() {
        let doc = open_one_page();
        let mut inner = doc.lock();
        assert!(matches!(
            inner.render_pool(1),
            Err(RenderError::PageOutOfRange { page: 1 })
        ));
        assert!(inner.renderers.is_none(), "nothing was built for it");
    }

    #[test]
    fn a_draw_waiting_for_a_renderer_does_not_hold_up_the_document() {
        let doc = open_one_page();
        let pool = doc.lock().render_pool(0).unwrap();
        // Both renderers are busy, as two long drawings would leave them, so this draw has to wait.
        let busy = pool.hold_all();
        let (finished, result) = mpsc::channel();
        let drawing = {
            let doc = doc.clone();
            thread::spawn(move || {
                let _ = finished.send(doc.render_tile(0, 0.25, None).is_ok());
            })
        };
        assert!(
            result.recv_timeout(Duration::from_millis(200)).is_err(),
            "the draw should be waiting for a renderer"
        );
        // If that draw held the state lock while it waited, this would never be answered; the
        // timeout turns a hang into a failure.
        let (answered, answer) = mpsc::channel();
        {
            let doc = doc.clone();
            thread::spawn(move || {
                let _ = answered.send((doc.page_count(), doc.revision()));
            });
        }
        assert_eq!(
            answer
                .recv_timeout(Duration::from_secs(60))
                .expect("the document should answer while a draw waits"),
            (1, 0)
        );
        drop(busy);
        assert!(result.recv_timeout(Duration::from_secs(60)).unwrap());
        drawing.join().unwrap();
    }
}
