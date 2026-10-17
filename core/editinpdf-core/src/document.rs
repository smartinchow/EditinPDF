//! `PdfDocument`: one open PDF, as the Swift side sees it.

use std::sync::{Arc, Mutex, MutexGuard};

use pdfcraft_engine::{DocId, Session};

use crate::render::{self, RendererPool};
use crate::text::{self, EnginePageText, MAX_SEARCH_HITS};
use crate::text_cache::TextCache;
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
    /// The text of the pages read most recently, for the revision it was read from, within a budget
    /// of glyphs. Like `renderers`, it is replaced by the first use after the revision changes, so a
    /// page's text is read from the engine once per revision rather than once per call, unless the
    /// budget made room for other pages in between.
    ///
    /// It lets go of layers as it is used, and does not free them: the calls that use it do that
    /// once they have released the lock (see `PdfDocument::with_state`).
    text_cache: TextCache,
}

/// What a call that wants a page's text finds when it looks for it.
enum Reading {
    /// The text, read before and kept.
    Cached(Arc<EnginePageText>),
    /// Not kept: the renderers to read it with.
    ToRead(Arc<RendererPool>),
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

    /// Looks for the text of the 0-based `page` at the current revision in the cache, and when it is
    /// not there fetches the renderers to read it with, once `page` is known to exist.
    ///
    /// Cheap, like `render_pool`, so fine to call under the state lock.
    fn reading(&mut self, page: u32) -> Result<Reading, RenderError> {
        let revision = self.revision;
        if let Some(layer) = self.text_cache.get(revision, page) {
            return Ok(Reading::Cached(layer));
        }
        self.render_pool(page).map(Reading::ToRead)
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

    /// Runs `f` on the state with the state lock held, and returns what it returns.
    ///
    /// This is how the text cache is used. The cache lets go of layers as it works (those of an
    /// older revision, those that do not fit), and freeing the text of a page is thousands of small
    /// deallocations. They are done here, once the lock is released, so no other call waits for them.
    fn with_state<T>(&self, f: impl FnOnce(&mut Inner) -> T) -> T {
        let (result, retired) = {
            let mut inner = self.lock();
            let result = f(&mut inner);
            (result, inner.text_cache.take_retired())
        };
        drop(retired);
        result
    }

    /// The engine's text layer for the 0-based `page` at the current revision: the one read before
    /// when the cache has it, otherwise read now and given to the cache.
    ///
    /// Reading is the engine's work, done on one of the pool's renderers. The state lock is held to
    /// look in the cache and fetch the renderers, and again to store the result, never while the
    /// engine reads. Two calls that both miss for the same page both read it, which costs time and
    /// nothing else. The result is the same whichever renderer reads: a page's glyphs come in the
    /// same order every time, so the indices a caller was given stay right when the cache has let go
    /// of the page and it is read again.
    fn text_layer(&self, page: u32) -> Result<Arc<EnginePageText>, RenderError> {
        let request = render::text_request(page)?;
        // This is also where a page the document does not have is turned away.
        let pool = match self.with_state(|inner| inner.reading(page))? {
            Reading::Cached(layer) => return Ok(layer),
            Reading::ToRead(pool) => pool,
        };
        let layer = render::into_text(pool.render(request))?;
        // Filed under the revision the renderers were made for, not the current one: the revision
        // can have changed while the engine read, and this is then the text of a document that is
        // gone. The cache drops such a layer. A layer too big for the cache is not kept; it is still
        // returned.
        self.with_state(|inner| {
            inner
                .text_cache
                .insert(pool.revision(), page, layer.clone());
        });
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
    /// and the scale. A tile is drawn at a scale from 0.01 through 400 (`min_tile_scale` and
    /// `max_tile_scale`). A whole-page drawing has no such range, but is limited by the engine to 8192
    /// pixels on a side and 64 million pixels in all; beyond that it comes back reduced to fit (its
    /// width and height say by how much) instead of failing.
    ///
    /// Safe to call from several threads at once: up to two pages of one document are drawn at the
    /// same time (reading a page's text takes one of the two places while it lasts), further calls
    /// wait their turn, in the order they came, for whichever place is free first, and the
    /// document's other methods, such as `page_count` and `page_info`, never wait for a drawing.
    ///
    /// Fails with `PageOutOfRange` for a page the document does not have, with `TileTooLarge` when
    /// `rect` is wider or taller than 4096 pixels or has no area (a zero width or height), and with
    /// `Failed` for a scale that is not a positive, finite number, a tile's scale outside 0.01
    /// through 400, or a page the engine cannot draw.
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
    /// The first call for a page reads its text, which can take a moment. The text of the pages used
    /// most recently is kept, up to 500,000 glyphs in all, so later calls for such a page, and
    /// selecting and searching in it, are quick until the document changes.
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
    /// one whose text cannot be read; the other pages are still searched. A `query` of more than 256
    /// characters, not counting the white space at its ends, finds nothing either.
    ///
    /// The result has at most 1,000 hits, the first ones. The search stops there and reads no further
    /// page, so a result of exactly 1,000 hits means that there may be more.
    ///
    /// A search reads the text of the pages it goes through, which takes a while for a long document,
    /// so call it away from the main thread. Text that has been read is kept for the next search, up
    /// to 500,000 glyphs in all; beyond that the pages used longest ago are read again when they are
    /// needed. A search reads one page at a time and holds nothing else of the document, so drawing
    /// and the other calls carry on alongside it.
    pub fn search(&self, query: String, case_sensitive: bool) -> Vec<SearchHit> {
        // Nothing to look for, or too much to look for: no reason to read any page.
        let Some(query) = text::search_text(&query) else {
            return Vec::new();
        };
        let mut hits = Vec::new();
        for page in 0..self.page_count() {
            // Each page may give what is left of the budget, and when none is left no page is read.
            let room = MAX_SEARCH_HITS.saturating_sub(hits.len());
            if room == 0 {
                break;
            }
            if let Ok(layer) = self.text_layer(page) {
                hits.extend(text::search_page(page, &layer, query, case_sensitive, room));
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
    use crate::text::MAX_QUERY_CHARS;

    fn open_one_page() -> Arc<PdfDocument> {
        open_pages(&["hello"])
    }

    /// A document with one page for each entry of `pages`, each showing that text.
    fn open_pages(pages: &[&str]) -> Arc<PdfDocument> {
        let bytes = Session::new()
            .create_from_text("fixture", &pages.join("\u{c}"))
            .expect("text pages create")
            .to_vec();
        PdfDocument::open(bytes, None).expect("the pages open")
    }

    /// Gives `doc` a text cache that holds `budget` glyphs.
    fn limit_the_text_cache(doc: &PdfDocument, budget: usize) {
        doc.lock().text_cache = TextCache::with_budget(budget);
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
    fn a_document_keeps_the_text_of_the_pages_used_most_recently_within_its_budget() {
        let doc = open_pages(&["aaaa", "bbbb", "cccc"]);
        limit_the_text_cache(&doc, 8); // room for two of the three pages
        let a = doc.text_layer(0).unwrap();
        let b = doc.text_layer(1).unwrap();
        assert!(Arc::ptr_eq(&a, &doc.text_layer(0).unwrap()), "kept");
        // Page 0 was used last, so reading page 2 makes room by letting go of page 1.
        let c = doc.text_layer(2).unwrap();
        assert!(Arc::ptr_eq(&a, &doc.text_layer(0).unwrap()), "page 0 stays");
        assert!(
            Arc::ptr_eq(&c, &doc.text_layer(2).unwrap()),
            "page 2 is kept"
        );
        let again = doc.text_layer(1).unwrap();
        assert!(
            !Arc::ptr_eq(&b, &again),
            "page 1 was let go and is read again"
        );
        // Read again, it is the same text with the same glyphs in the same order, so the indices
        // handed out for it before still point at the same glyphs.
        assert_eq!(*b, *again);
        assert_eq!(b.plain_text(), "bbbb");
    }

    #[test]
    fn what_the_cache_lets_go_of_is_collected_by_the_call_that_made_it_let_go() {
        // Letting go of a layer is the cache's doing, freeing it is the caller's, once the lock is
        // released: nothing may be left waiting in the cache after a call.
        let doc = open_pages(&["aaaa", "bbbb", "cccc"]);
        limit_the_text_cache(&doc, 8);
        for page in [0, 1, 2, 0, 1, 2] {
            doc.text_layer(page).unwrap(); // every one but the first two lets another go
            assert!(
                doc.lock().text_cache.take_retired().is_empty(),
                "page {page}"
            );
        }
        doc.lock().revision += 1;
        doc.text_layer(0).unwrap(); // the old revision's layers all go
        assert!(doc.lock().text_cache.take_retired().is_empty());
    }

    #[test]
    fn a_layer_too_big_for_the_cache_is_given_to_the_caller_and_not_kept() {
        let doc = open_pages(&["hello", "world"]);
        limit_the_text_cache(&doc, 4); // "hello" is 5 glyphs
        let first = doc.text_layer(0).unwrap();
        assert_eq!(first.plain_text(), "hello");
        assert!(doc.lock().text_cache.get(0, 0).is_none(), "not kept");
        let second = doc.text_layer(0).unwrap();
        assert!(!Arc::ptr_eq(&first, &second), "so it is read again");
        // Everything still works, a read at a time.
        assert_eq!(doc.page_text(1).unwrap().glyphs.len(), 5);
        assert_eq!(doc.search("o".into(), false).len(), 2);
        assert!(doc.select_word(0, 1.0, 1.0).unwrap().is_none());
    }

    #[test]
    fn a_search_gives_the_same_hits_whether_or_not_the_cache_can_hold_the_text() {
        let pages = [
            "needle one",
            "no luck",
            "a needle here",
            "needle needle",
            "end",
        ];
        let places = |doc: &PdfDocument| {
            doc.search("needle".into(), false)
                .iter()
                .map(|h| (h.page, h.start, h.end, h.snippet.clone(), h.rects.clone()))
                .collect::<Vec<_>>()
        };
        let roomy = open_pages(&pages);
        let tight = open_pages(&pages);
        limit_the_text_cache(&tight, 12); // about one page at a time
        let expected = places(&roomy);
        assert_eq!(expected.len(), 4);
        for round in 0..3 {
            assert_eq!(places(&tight), expected, "round {round}");
        }
    }

    #[test]
    fn a_search_that_fills_its_budget_reads_no_further_pages() {
        // Page 0 alone has more matches than a search returns.
        let page = vec!["l".repeat(90); 14].join("\n"); // 1,260 glyphs
        let doc = open_pages(&[page.as_str(), "ll", "ll"]);
        assert_eq!(doc.search("l".into(), false).len(), MAX_SEARCH_HITS);
        let mut inner = doc.lock();
        assert!(inner.text_cache.get(0, 0).is_some(), "page 0 was read");
        assert!(inner.text_cache.get(0, 1).is_none(), "page 1 was not");
        assert!(inner.text_cache.get(0, 2).is_none(), "nor page 2");
    }

    #[test]
    fn a_query_that_cannot_be_looked_for_reads_no_page() {
        let doc = open_pages(&["aaa", "bbb"]);
        for query in ["", "  ", &"a".repeat(MAX_QUERY_CHARS + 1)] {
            assert!(doc.search(query.to_owned(), false).is_empty());
        }
        let mut inner = doc.lock();
        assert!(inner.text_cache.get(0, 0).is_none() && inner.text_cache.get(0, 1).is_none());
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
