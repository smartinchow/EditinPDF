//! `PdfDocument`: one open PDF, as the Swift side sees it.

use std::collections::{HashMap, HashSet};
use std::panic::{self, AssertUnwindSafe};
use std::sync::{Arc, Mutex, MutexGuard};

use pdfcraft_engine::{DocId, Session};

use crate::annotations::{self, AnnotationInfo};
use crate::edit::{Edit, EditCapabilities, EditOutcome, MAX_STEP_EDITS, SaveMode};
use crate::forms::{self, FormField};
use crate::render::{self, RendererPool};
use crate::text::{self, EnginePageText, MAX_SEARCH_HITS};
use crate::text_cache::TextCache;
use crate::{
    EditError, OpenError, PageInfo, PageText, RenderError, RenderedTile, SaveError, SearchHit,
    TextSelection, TileRect,
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

    /// Runs `f` on the session under the lock, catching a panic as `EditError::Failed` so the lock
    /// is never poisoned; on success bumps the revision and retires the renderer pool and text
    /// layers of the old revision, which are dropped after the lock is released.
    ///
    /// `f` is given the session and the document's id, and returns the change's label. With
    /// `base_revision`, the change is refused as `Stale` unless the document is still at that
    /// revision.
    ///
    /// A failure can come after the engine has already changed the document: undo and redo swap the
    /// state in before they refresh the view data, and do not swap it back when that fails, and a
    /// panic can strike anywhere. So the revision is bumped and the caches retired after a panic,
    /// and after an error that `may_have_changed` says can follow a change, just as after a success.
    /// The caller still gets the error; a bump the document did not need only makes the apps read it
    /// again.
    fn mutate(
        &self,
        f: impl FnOnce(&mut Session, DocId) -> Result<String, EditError>,
        base_revision: Option<u64>,
        may_have_changed: fn(&EditError) -> bool,
    ) -> Result<EditOutcome, EditError> {
        let (result, old_pool, retired) = {
            let mut inner = self.lock();
            if let Some(base) = base_revision
                && base != inner.revision
            {
                return Err(EditError::Stale {
                    current: inner.revision,
                });
            }
            let id = inner.id;
            open_doc(&inner.session, id)?;
            let (result, changed) =
                match panic::catch_unwind(AssertUnwindSafe(|| f(&mut inner.session, id))) {
                    Ok(Ok(label)) => (Ok(label), true),
                    Ok(Err(err)) => {
                        let changed = may_have_changed(&err);
                        (Err(err), changed)
                    }
                    Err(_) => (
                        Err(EditError::Failed {
                            message: "the engine failed while changing the document".to_owned(),
                        }),
                        true,
                    ),
                };
            if !changed {
                return result.map(|label| EditOutcome {
                    revision: inner.revision,
                    label,
                });
            }
            inner.revision += 1;
            let revision = inner.revision;
            let old_pool = inner.renderers.take();
            inner.text_cache.advance(revision);
            let retired = inner.text_cache.take_retired();
            (
                result.map(|label| EditOutcome { revision, label }),
                old_pool,
                retired,
            )
        };
        // Freeing the old revision's renderers and text is slow enough to keep out of the lock. A
        // render still under way holds its own reference to the pool, and frees it when it ends.
        drop(old_pool);
        drop(retired);
        result
    }

    /// Reads the document under the lock; `default` when it is no longer open.
    fn read<T>(&self, default: T, f: impl FnOnce(&pdfcraft_engine::Document) -> T) -> T {
        let inner = self.lock();
        inner.session.get(inner.id).map_or(default, f)
    }
}

/// The document `id` names in `session`; `Failed` when it is no longer open.
fn open_doc(session: &Session, id: DocId) -> Result<&pdfcraft_engine::Document, EditError> {
    session.get(id).ok_or_else(|| EditError::Failed {
        message: "the document is no longer open".to_owned(),
    })
}

/// Whether the edits of one step read the places of a page's comments consistently, refused as
/// `Invalid` when they do not: `DeleteAnnotations` reads them as the page's list is before the step,
/// so no other edit of the step may address a comment of its page by its place, which the deletes
/// would move (or the other edit's change, the deletes'). Adding a comment puts it at the end of the
/// list, which moves no place, so that goes with it.
fn annotation_places_check(edits: &[Edit]) -> Result<(), EditError> {
    let mut addressing: HashMap<u32, usize> = HashMap::new();
    for page in edits.iter().filter_map(Edit::annotation_page) {
        *addressing.entry(page).or_default() += 1;
    }
    let clash = edits.iter().find_map(|edit| {
        let Edit::DeleteAnnotations { page, .. } = edit else {
            return None;
        };
        addressing
            .get(page)
            .is_some_and(|&count| count > 1)
            .then_some(*page)
    });
    match clash {
        Some(page) => Err(EditError::Invalid {
            message: format!(
                "deleting several comments of page {page} can't be combined with other changes to \
                 its comments in one step"
            ),
        }),
        None => Ok(()),
    }
}

/// Whether the document accepts pages taken from another PDF, as the engine would refuse them:
/// `ReadOnly` when it cannot be edited, `NotPermitted` when its security settings forbid page
/// changes. Checked before the source is read, so a document that would refuse the pages anyway
/// never parses the source, and the reason given is the document's own.
fn destination_check(session: &Session, id: DocId) -> Result<(), EditError> {
    let doc = session.get(id).ok_or_else(|| EditError::Failed {
        message: "the document is no longer open".to_owned(),
    })?;
    if !doc.editable() {
        return Err(pdfcraft_engine::EditError::ReadOnly(
            doc.read_only_reason.clone().unwrap_or_default(),
        )
        .into());
    }
    if !doc.allows_assembly() {
        return Err(pdfcraft_engine::EditError::NotPermitted("page changes").into());
    }
    Ok(())
}

/// Whether every form field `edits` fill in is one the document has, refused as `Invalid` when one
/// is not: the bridge does not rely on the engine to turn an unknown name away. Names are read
/// against the fields as they are before the step, so a field that pages taken from another PDF
/// bring in can be filled in from the next step on, not in the step that inserts them.
///
/// A document that does not let its fields be filled in at all (one that cannot be edited, or
/// whose security settings forbid it) is left to the engine, so the reason given is the
/// document's own, as for pages taken from another PDF.
fn field_check(session: &Session, id: DocId, edits: &[Edit]) -> Result<(), EditError> {
    let doc = session.get(id).ok_or_else(|| EditError::Failed {
        message: "the document is no longer open".to_owned(),
    })?;
    if !doc.allows_form_filling() || edits.iter().all(|edit| edit.field_name().is_none()) {
        return Ok(());
    }
    // Built once, so a step of many fills over a form of many fields stays linear.
    let names: HashSet<&str> = doc.form.iter().map(|field| field.name.as_str()).collect();
    match edits
        .iter()
        .filter_map(Edit::field_name)
        .find(|name| !names.contains(name))
    {
        Some(name) => Err(EditError::Invalid {
            message: format!("there is no form field named {name:?}"),
        }),
        None => Ok(()),
    }
}

/// For `apply`: the engine makes an edit on a copy and puts the old state back when it cannot
/// show the result, so only an error the bridge reports as `Failed` (writing, reopening, a panic
/// the engine caught) may leave something changed. A refused or invalid edit changes nothing.
fn apply_may_have_changed(err: &EditError) -> bool {
    matches!(err, EditError::Failed { .. })
}

/// For `undo` and `redo`: the engine swaps the state in before it refreshes the view data, and
/// does not swap it back when that fails. Only finding nothing to undo or redo changes nothing.
fn step_may_have_changed(err: &EditError) -> bool {
    !matches!(err, EditError::NothingToUndo | EditError::NothingToRedo)
}

/// The label of the change on top of the undo stack: the one just made or redone.
fn undo_label(session: &Session, id: DocId) -> String {
    session
        .get(id)
        .and_then(|doc| doc.can_undo())
        .unwrap_or_default()
        .to_owned()
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
    /// older state: 0 when opened, and one more after every edit, undo and redo that succeeds.
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
        self.search_pages(&query, |page, layer, query, room| {
            text::search_page(page, layer, query, case_sensitive, room)
        })
    }

    /// Makes one change to the document, as one step that `undo` takes back.
    ///
    /// `base_revision` is the `revision` the change was made for: when the document has changed
    /// since, nothing is done and the error is `Stale`, with the current revision. On success the
    /// revision goes up by one, and what was drawn or read for the old one is out of date.
    ///
    /// Fails with `ReadOnly` for a document that cannot be edited, `NotPermitted` when its security
    /// settings forbid the change, `WouldRemoveAllPages` for a change that leaves no page, `Invalid`
    /// for a change that does not fit the document (a page, comment or form field it does not have,
    /// a turn that is not a multiple of 90 degrees, a size that is not a positive, finite number of
    /// at most 14,400 points, text markup without a box, a position or colour that is not a number,
    /// a value its field does not take or a field that is read-only), `SourceNeedsPassword`, `SourceNotPermitted` or `SourceUnreadable` for pages taken
    /// from a PDF that needs a password, does not allow its pages to be copied, or cannot be read
    /// (the document's own refusal comes first: the source is not read then), and `Failed` when the engine cannot make it. After any error but `Failed` the document is as it
    /// was; after `Failed` it may not be, and the revision has gone up by one all the same, so the
    /// apps should read the document again.
    pub fn apply(&self, edit: Edit, base_revision: u64) -> Result<EditOutcome, EditError> {
        self.mutate(
            |session, id| {
                if edit.takes_source() {
                    destination_check(session, id)?;
                }
                field_check(session, id, std::slice::from_ref(&edit))?;
                let edit = edit.to_engine(open_doc(session, id)?)?;
                session.apply(id, edit)?;
                Ok(undo_label(session, id))
            },
            Some(base_revision),
            apply_may_have_changed,
        )
    }

    /// Makes several changes, in order, as one step called `label` that `undo` takes back whole.
    /// Either all of them are made or none is.
    ///
    /// Positions on a page are read against the pages as they are before the step, so a step that
    /// changes the pages (turns, deletes, moves or inserts) cannot also carry a change with a
    /// position: that is refused as `Invalid`. Likewise a step that deletes, moves or inserts pages
    /// cannot also delete a comment or change its text, which address the comment by its page as it
    /// is before the step (turning pages keeps their numbers, so that mix is allowed). A step that
    /// deletes several comments of a page (`DeleteAnnotations`) cannot also address another comment
    /// of that page by its place. Filling in a form field addresses it by its name, so it goes with
    /// any page change. Otherwise the errors are those of `apply`, and a step of more than 10,000
    /// changes is refused as `Invalid`.
    pub fn apply_all(
        &self,
        label: String,
        edits: Vec<Edit>,
        base_revision: u64,
    ) -> Result<EditOutcome, EditError> {
        if edits.len() > MAX_STEP_EDITS {
            return Err(EditError::Invalid {
                message: format!(
                    "one step makes at most {MAX_STEP_EDITS} changes, not {}",
                    edits.len()
                ),
            });
        }
        if edits.iter().any(Edit::is_page_structure) && edits.iter().any(Edit::has_geometry) {
            return Err(EditError::Invalid {
                message: "page changes and annotation changes can't be combined in one step"
                    .to_owned(),
            });
        }
        if edits.iter().any(Edit::renumbers_pages) && edits.iter().any(Edit::addresses_annotation) {
            return Err(EditError::Invalid {
                message: "deleting, moving or inserting pages and changing comments can't be \
                          combined in one step"
                    .to_owned(),
            });
        }
        annotation_places_check(&edits)?;
        self.mutate(
            |session, id| {
                if edits.iter().any(Edit::takes_source) {
                    destination_check(session, id)?;
                }
                field_check(session, id, &edits)?;
                let doc = open_doc(session, id)?;
                let edits = edits
                    .iter()
                    .map(|edit| edit.to_engine(doc))
                    .collect::<Result<Vec<_>, _>>()?;
                session.apply(id, pdfcraft_engine::Edit::Batch { label, edits })?;
                Ok(undo_label(session, id))
            },
            Some(base_revision),
            apply_may_have_changed,
        )
    }

    /// Takes back the last change made or redone. The revision goes up by one, as for an edit.
    ///
    /// Fails with `NothingToUndo` when there is none, and `Failed` when the engine cannot undo it.
    /// The engine can fail after it has already taken the change back, so after `Failed` the
    /// revision has gone up by one all the same, and the apps should read the document again.
    pub fn undo(&self) -> Result<EditOutcome, EditError> {
        self.mutate(
            |session, id| Ok(session.undo(id)?.as_str().to_owned()),
            None,
            step_may_have_changed,
        )
    }

    /// Makes again the last change undone. The revision goes up by one, as for an edit.
    ///
    /// Fails with `NothingToRedo` when there is none, and `Failed` when the engine cannot redo it.
    /// The engine can fail after it has already made the change again, so after `Failed` the
    /// revision has gone up by one all the same, and the apps should read the document again.
    pub fn redo(&self) -> Result<EditOutcome, EditError> {
        self.mutate(
            |session, id| Ok(session.redo(id)?.as_str().to_owned()),
            None,
            step_may_have_changed,
        )
    }

    /// Whether there is a change to undo.
    pub fn can_undo(&self) -> bool {
        self.read(false, |doc| doc.can_undo().is_some())
    }

    /// Whether there is an undone change to redo.
    pub fn can_redo(&self) -> bool {
        self.read(false, |doc| doc.can_redo().is_some())
    }

    /// Whether the document has changed since it was opened. Saving does not clear it.
    pub fn is_dirty(&self) -> bool {
        self.read(false, |doc| doc.dirty)
    }

    /// The document's bytes as they are now, for the app to write.
    ///
    /// `Incremental` appends the changes to the file as it was opened (an unchanged document comes
    /// back exactly as it was opened); `Full` writes a complete, compact file. An encrypted
    /// document stays encrypted with the same password either way. Saving waits for an edit under
    /// way to finish, so it never sees half of one, and does not mark the document as saved.
    ///
    /// Fails with `Signed` for a `Full` save of a signed document (it would invalidate the
    /// signatures), `ReadOnly` for a `Full` save of a document that cannot be edited, and `Failed`
    /// when the engine cannot write the document.
    pub fn save(&self, mode: SaveMode) -> Result<Vec<u8>, SaveError> {
        let inner = self.lock();
        let id = inner.id;
        let session = &inner.session;
        let saved = panic::catch_unwind(AssertUnwindSafe(|| match mode {
            SaveMode::Incremental => session.save_bytes(id),
            SaveMode::Full => session.save_full_bytes(id),
        }))
        .unwrap_or_else(|_| {
            Err(pdfcraft_engine::EditError::Write(
                "the engine failed while writing the document".to_owned(),
            ))
        })?;
        drop(inner);
        Ok(Arc::unwrap_or_clone(saved))
    }

    /// A new PDF holding copies of `pages` (0-based), in the order given, for the app to write.
    /// The new document is not encrypted, whether or not this one is. The document itself does not
    /// change: extracting is not an edit, and the revision stays as it is.
    ///
    /// Fails with `Invalid` when `pages` is empty or names a page the document does not have,
    /// `NotPermitted` when the document's security settings do not allow taking its pages, and
    /// `Failed` when the engine cannot write the new document.
    pub fn extract_pages(&self, pages: Vec<u32>) -> Result<Vec<u8>, EditError> {
        let inner = self.lock();
        let id = inner.id;
        let count = inner
            .session
            .get(id)
            .map(|doc| doc.info.pages.len())
            .ok_or_else(|| EditError::Failed {
                message: "the document is no longer open".to_owned(),
            })?;
        if pages.is_empty() {
            return Err(EditError::Invalid {
                message: "choose at least one page to extract".to_owned(),
            });
        }
        let pages = pages
            .into_iter()
            .map(|page| {
                usize::try_from(page)
                    .ok()
                    .filter(|&index| index < count)
                    .ok_or_else(|| EditError::Invalid {
                        message: format!("page {page} does not exist"),
                    })
            })
            .collect::<Result<Vec<_>, _>>()?;
        let session = &inner.session;
        let extracted = panic::catch_unwind(AssertUnwindSafe(|| session.extract(id, &pages)))
            .unwrap_or_else(|_| {
                Err(pdfcraft_engine::EditError::Write(
                    "the engine failed while extracting the pages".to_owned(),
                ))
            })?;
        drop(inner);
        Ok(Arc::unwrap_or_clone(extracted))
    }

    /// What can be done to the document, given whether the engine can edit it and what its
    /// security settings allow.
    pub fn capabilities(&self) -> EditCapabilities {
        let closed = EditCapabilities {
            can_edit: false,
            read_only_reason: Some("the document is no longer open".to_owned()),
            can_organize: false,
            can_annotate: false,
            can_fill_forms: false,
            is_signed: false,
            is_encrypted: false,
        };
        self.read(closed, |doc| {
            let editable = doc.editable();
            EditCapabilities {
                can_edit: editable && doc.allows_modification(),
                read_only_reason: doc.read_only_reason.clone(),
                can_organize: editable && doc.allows_assembly(),
                can_annotate: editable && doc.allows_annotation(),
                can_fill_forms: editable && doc.allows_form_filling(),
                is_signed: doc.is_signed(),
                is_encrypted: doc.info.encrypted || doc.permissions().is_some(),
            }
        })
    }

    /// The document's comments: page by page, and top to bottom within a page, in view space.
    /// Replies to other comments are left out. Read the list again after every change, undo and
    /// redo: a comment's `index` is its position on its page, which those can move.
    pub fn annotations(&self) -> Vec<AnnotationInfo> {
        // Only reads what the engine read when it opened or last changed the document, and turns
        // the boxes with the page's plain arithmetic: nothing here can panic.
        self.read(Vec::new(), |doc| annotations::list(&doc.info))
    }

    /// The document's form fields, in the document's order, with their widgets in view space.
    /// A hidden widget, or one on no page, is left out, and so is a field with no other widget.
    /// Read the list again after every change, undo and redo.
    ///
    /// The list is capped: at most 5,000 fields (the first ones), and for each at most 1,000
    /// options, 1,000 chosen values and 100 widgets (the first ones). `form_fields_truncated` says
    /// whether the caps left anything out, for the apps to say the form is too large to show
    /// completely.
    pub fn form_fields(&self) -> Vec<FormField> {
        // Only reads what the engine read when it opened or last changed the document, and turns
        // the boxes with the page's plain arithmetic: nothing here can panic.
        self.read(Vec::new(), |doc| {
            forms::list(&doc.info.pages, &doc.form).fields
        })
    }

    /// Whether `form_fields`, at the same `revision`, leaves out fields, options, chosen values or
    /// widgets for its caps.
    pub fn form_fields_truncated(&self) -> bool {
        // As `form_fields`: a plain read that cannot panic.
        self.read(false, |doc| {
            forms::list(&doc.info.pages, &doc.form).truncated
        })
    }
}

impl PdfDocument {
    /// What `search` does, with `search_page` finding the hits of one page: given the page, its
    /// text, what to look for and the most hits it may give.
    ///
    /// A page whose reading or searching panics is skipped, like a page whose text cannot be read,
    /// and the search goes on with the next. `search` has no error to report the panic with: the
    /// Swift side calls it without `try`, so a panic that reached the FFI boundary would end the app
    /// (see the crate's documentation). The panic itself has been reported by the panic hook, and the
    /// page is logged as skipped, by its number only (its text is the user's business). The state
    /// lock recovers from the poisoning such a panic can leave behind (`lock`).
    fn search_pages(
        &self,
        query: &str,
        mut search_page: impl FnMut(u32, &EnginePageText, &str, usize) -> Vec<SearchHit>,
    ) -> Vec<SearchHit> {
        // Nothing to look for, or too much to look for: no reason to read any page.
        let Some(query) = text::search_text(query) else {
            return Vec::new();
        };
        let mut hits = Vec::new();
        for page in 0..self.page_count() {
            // Each page may give what is left of the budget, and when none is left no page is read.
            let room = MAX_SEARCH_HITS.saturating_sub(hits.len());
            if room == 0 {
                break;
            }
            let found = panic::catch_unwind(AssertUnwindSafe(|| {
                self.text_layer(page)
                    .map(|layer| search_page(page, &layer, query, room))
            }));
            match found {
                Ok(Ok(found)) => hits.extend(found),
                // A page whose text cannot be read has nothing to find.
                Ok(Err(_)) => {}
                // Reading or searching the page panicked. The panic hook has already reported it,
                // so the page is skipped.
                Err(_) => {}
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
    fn a_change_that_panics_is_a_failure_and_leaves_the_document_usable() {
        let doc = open_pages(&["one", "two"]);
        let err = doc
            .mutate(|_, _| panic!("an engine bug"), Some(0), |_| false)
            .unwrap_err();
        assert!(matches!(err, EditError::Failed { .. }));
        assert!(!doc.inner.is_poisoned(), "the lock is not poisoned");
        // The panic may have left the engine half changed, so the revision moves on all the same.
        assert_eq!(doc.revision(), 1);
        let out = doc
            .apply(
                Edit::RotatePages {
                    pages: vec![0],
                    degrees: 90,
                },
                1,
            )
            .unwrap();
        assert_eq!((out.revision, out.label.as_str()), (2, "Rotate page"));
    }

    /// The renderers built for the current revision, as a draw would get them.
    fn current_pool(doc: &PdfDocument) -> Arc<RendererPool> {
        doc.lock().render_pool(0).unwrap()
    }

    #[test]
    fn a_failure_after_the_engine_changed_the_document_moves_the_revision_on() {
        let rotate = || pdfcraft_engine::Edit::RotatePages {
            pages: vec![0],
            degrees: 90,
        };
        // An error after the change, as undo or redo can give when refreshing fails.
        let doc = open_one_page();
        let pool = current_pool(&doc);
        let err = doc
            .mutate(
                |session, id| {
                    session.apply(id, rotate())?;
                    Err(EditError::Failed {
                        message: "refresh failed".to_owned(),
                    })
                },
                Some(0),
                step_may_have_changed,
            )
            .unwrap_err();
        assert!(matches!(err, EditError::Failed { .. }));
        assert_eq!(doc.revision(), 1);
        assert!(doc.lock().renderers.is_none(), "the old pool is retired");
        assert!(!Arc::ptr_eq(&pool, &current_pool(&doc)));
        assert_eq!(doc.page_info(0).unwrap().rotation_degrees, 90);

        // A panic after the change, whatever the call.
        let doc = open_one_page();
        let pool = current_pool(&doc);
        let err = doc
            .mutate(
                |session, id| {
                    session.apply(id, rotate())?;
                    panic!("an engine bug after the change");
                },
                Some(0),
                |_| false,
            )
            .unwrap_err();
        assert!(matches!(err, EditError::Failed { .. }));
        assert_eq!(doc.revision(), 1);
        assert!(!Arc::ptr_eq(&pool, &current_pool(&doc)));

        // Nothing to undo changes nothing, and keeps the revision and the pool.
        let doc = open_one_page();
        let pool = current_pool(&doc);
        assert!(matches!(doc.undo(), Err(EditError::NothingToUndo)));
        assert!(matches!(doc.redo(), Err(EditError::NothingToRedo)));
        assert_eq!(doc.revision(), 0);
        assert!(Arc::ptr_eq(&pool, &current_pool(&doc)));
    }

    #[test]
    fn a_change_retires_the_old_revisions_renderers_and_text_at_once() {
        let doc = open_one_page();
        let pool = doc.lock().render_pool(0).unwrap();
        doc.text_layer(0).unwrap();
        doc.apply(
            Edit::RotatePages {
                pages: vec![0],
                degrees: 90,
            },
            0,
        )
        .unwrap();
        let mut inner = doc.lock();
        assert!(inner.renderers.is_none(), "the old pool is let go of");
        assert!(inner.text_cache.get(1, 0).is_none(), "and the old text");
        assert!(inner.text_cache.take_retired().is_empty(), "and freed");
        drop(inner);
        assert_eq!(Arc::strong_count(&pool), 1, "only this test holds it now");
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
    fn a_page_whose_search_panics_is_skipped_and_the_others_are_searched() {
        let doc = open_pages(&["needle one", "needle two", "needle three"]);
        let hits = doc.search_pages("needle", |page, layer, query, room| {
            if page == 1 {
                panic!("a page the search cannot cope with");
            }
            text::search_page(page, layer, query, false, room)
        });
        assert_eq!(hits.iter().map(|hit| hit.page).collect::<Vec<_>>(), [0, 2]);
        // The panic left nothing behind: the document is searched in full again.
        assert_eq!(doc.search("needle".into(), false).len(), 3);
        assert_eq!(doc.page_text(1).unwrap().glyphs.len(), 10);
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
