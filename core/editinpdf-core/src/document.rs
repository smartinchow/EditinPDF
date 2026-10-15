//! `PdfDocument`: one open PDF, as the Swift side sees it.

use std::sync::{Arc, Mutex, MutexGuard};

use pdfcraft_engine::{DocId, Session};

use crate::render::{self, RendererPool};
use crate::text::{self, EnginePageText, TextCache};
use crate::{
    OpenError, PageInfo, PageText, RenderError, RenderedTile, SearchHit, TextSelection, TileRect,
};

/// An open PDF document. Safe to share between threads. Calls on one document run one at a time,
/// except those that draw a page or read its text, which can run alongside each other and alongside
/// the other calls.
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
    /// The text of the pages read so far, for the revision it was read from. Like `renderers`, it
    /// is replaced by the first use after the revision changes, so each page's text is read from the
    /// engine once per revision rather than once per call.
    text_cache: TextCache,
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

    /// The engine's text layer for the 0-based `page` at the current revision: the one read before
    /// when the cache has it, otherwise read now and cached.
    ///
    /// Reading is the engine's work, done on one of the pool's renderers. The state lock is held to
    /// look in the cache and fetch the renderers, and again to store the result, never while the
    /// engine reads. Two calls that both miss for the same page both read it, which costs time and
    /// nothing else.
    fn text_layer(&self, page: u32) -> Result<Arc<EnginePageText>, RenderError> {
        let request = render::text_request(page)?;
        let pool = {
            let mut inner = self.lock();
            let revision = inner.revision;
            if let Some(layer) = inner.text_cache.get(revision, page) {
                return Ok(layer);
            }
            // This is also where a page the document does not have is turned away.
            inner.render_pool(page)?
        };
        let layer = render::into_text(pool.render(request))?;
        // Filed under the revision the renderers were made for, not the current one: the revision
        // can have changed while the engine read, and this is then the text of a document that is
        // gone. The cache drops such a layer.
        self.lock()
            .text_cache
            .insert(pool.revision(), page, layer.clone());
        Ok(layer)
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
                text_cache: TextCache::default(),
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
    /// same time (reading a page's text takes one of the two places while it lasts), further calls
    /// wait their turn, and the document's other methods, such as `page_count` and `page_info`,
    /// never wait for a drawing.
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

    /// The text of the 0-based page `page`: its glyphs in reading order, each with the characters it
    /// stands for and its box in view space (points from the page's top-left corner as shown, after
    /// its rotation).
    ///
    /// A page without text, such as a scan, has no glyphs. A glyph is known by its index in the
    /// result: selections and search hits name theirs that way, and the indices stay the same for as
    /// long as the document's `revision` does.
    ///
    /// The first call for a page reads its text, which can take a moment. The text is kept, so later
    /// calls for the page, and selecting and searching in it, are quick until the document changes.
    ///
    /// Fails with `PageOutOfRange` for a page the document does not have, and with `Failed` for a
    /// page whose text the engine cannot read.
    pub fn page_text(&self, page: u32) -> Result<PageText, RenderError> {
        let layer = self.text_layer(page)?;
        Ok(PageText::from_engine(&layer))
    }

    /// The word at the point (`x`, `y`) of the 0-based page `page`, as a double tap selects it. The
    /// point is in view space: points from the page's top-left corner as shown, after its rotation.
    ///
    /// Nothing when there is no word there: the page has no text, the point is not on a word or
    /// within half a glyph's size of one, or it is on the blank between two words.
    ///
    /// Fails with `PageOutOfRange` for a page the document does not have, and with `Failed` for a
    /// page whose text the engine cannot read.
    pub fn select_word(
        &self,
        page: u32,
        x: f64,
        y: f64,
    ) -> Result<Option<TextSelection>, RenderError> {
        let layer = self.text_layer(page)?;
        Ok(text::select_word(page, &layer, x, y))
    }

    /// The text of the 0-based page `page` from glyph `start` up to, but not including, glyph `end`,
    /// the indices being those of the glyphs `page_text` gives: what dragging from one glyph to
    /// another selects.
    ///
    /// An `end` past the last glyph is taken as the last, and a `start` past the `end` as the `end`,
    /// so the selection comes back shorter or empty; the indices are never an error.
    ///
    /// Fails with `PageOutOfRange` for a page the document does not have, and with `Failed` for a
    /// page whose text the engine cannot read.
    pub fn select_range(
        &self,
        page: u32,
        start: u32,
        end: u32,
    ) -> Result<TextSelection, RenderError> {
        let layer = self.text_layer(page)?;
        Ok(text::select_range(page, &layer, start, end))
    }

    /// Finds `query` in the text of every page. The hits come in page order, and in reading order
    /// within a page.
    ///
    /// Capital and small letters match each other unless `case_sensitive` is set. The words of
    /// `query` may be separated by any amount of white space, and a match may run over a line break.
    /// A `query` that is empty or only white space finds nothing, and so does a page without text or
    /// one whose text cannot be read; the other pages are still searched.
    ///
    /// The first search reads the text of every page, which takes a while for a long document, so
    /// call it away from the main thread. The text is kept, so later searches are quick. A search
    /// reads one page at a time and holds nothing else of the document, so drawing and the other
    /// calls carry on alongside it.
    pub fn search(&self, query: String, case_sensitive: bool) -> Vec<SearchHit> {
        // Nothing to look for, so there is no reason to read any page.
        if query.trim().is_empty() {
            return Vec::new();
        }
        let mut hits = Vec::new();
        for page in 0..self.page_count() {
            if let Ok(layer) = self.text_layer(page) {
                hits.extend(text::search_page(page, &layer, &query, case_sensitive));
            }
        }
        hits
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
    fn a_pages_text_is_read_once_per_revision() {
        let doc = open_one_page();
        let first = doc.text_layer(0).unwrap();
        assert_eq!(first.plain_text(), "hello");
        assert!(
            Arc::ptr_eq(&first, &doc.text_layer(0).unwrap()),
            "the same revision keeps the text it read"
        );

        doc.lock().revision += 1;
        let second = doc.text_layer(0).unwrap();
        assert!(
            !Arc::ptr_eq(&first, &second),
            "a new revision reads the page again"
        );
        assert_eq!(second.plain_text(), "hello");
        assert!(
            Arc::ptr_eq(&second, &doc.text_layer(0).unwrap()),
            "and keeps that in turn"
        );
        // A read that began before the change still holds the old text and can finish.
        assert_eq!(first.plain_text(), "hello");
    }

    #[test]
    fn a_page_that_does_not_exist_has_no_text_and_nothing_is_kept_for_it() {
        let doc = open_one_page();
        assert!(matches!(
            doc.text_layer(1),
            Err(RenderError::PageOutOfRange { page: 1 })
        ));
        let mut inner = doc.lock();
        assert!(inner.text_cache.get(0, 1).is_none());
        assert!(inner.renderers.is_none(), "no renderers were built for it");
    }

    #[test]
    fn text_is_read_by_the_renderers_the_drawing_uses() {
        let doc = open_one_page();
        doc.render_tile(0, 0.25, None).unwrap();
        let pool = doc.lock().render_pool(0).unwrap();
        doc.page_text(0).unwrap();
        assert!(
            Arc::ptr_eq(&pool, &doc.lock().render_pool(0).unwrap()),
            "reading the text did not replace the pool"
        );
    }

    #[test]
    fn reading_text_while_both_renderers_are_busy_does_not_hold_up_the_document() {
        let doc = open_one_page();
        let pool = doc.lock().render_pool(0).unwrap();
        // Both renderers are busy, as two long drawings would leave them, so the read has to wait.
        let busy = pool.hold_all();
        let (finished, result) = mpsc::channel();
        let reading = {
            let doc = doc.clone();
            thread::spawn(move || {
                let _ = finished.send(doc.page_text(0).is_ok());
            })
        };
        assert!(
            result.recv_timeout(Duration::from_millis(200)).is_err(),
            "the read should be waiting for a renderer"
        );
        // If the read held the state lock while it waited, this would never be answered; the
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
                .expect("the document should answer while a read waits"),
            (1, 0)
        );
        drop(busy);
        assert!(result.recv_timeout(Duration::from_secs(60)).unwrap());
        reading.join().unwrap();
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
