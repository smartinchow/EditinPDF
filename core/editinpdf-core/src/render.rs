//! Page rendering: the pool of renderers behind `PdfDocument::render_tile` and the page text calls,
//! and the translation between the bridge's records and the engine's render requests and results.

use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};

use pdfcraft_render::{PageRenderer, RenderConfig, RenderRequest, RenderedPage, RequestKind, Tile};

use crate::{RenderError, RenderedTile, TileRect};

/// The most renderers one pool builds. Each is a separate parse of the document, so the number is
/// small; two let the viewer's concurrent tile draws run on two cores instead of queueing on one.
const MAX_RENDERERS: usize = 2;

/// The longest side of a tile, in pixels. The engine clamps a larger tile, which would hand back
/// a picture of another size than was asked for, so a larger one is refused instead.
const MAX_TILE_SIDE: u32 = 4096;

/// The smallest and the largest scale, in device pixels per point, that the engine draws a tile at.
/// It clamps another scale into this range, which would draw another part of the page than was
/// asked for, so another scale is refused instead. (A whole-page drawing has no such range: the
/// engine fits it within its size limits.)
pub(crate) const MIN_TILE_SCALE: f32 = 0.01;
pub(crate) const MAX_TILE_SCALE: f32 = 400.0;

/// The request to draw pixels of the 0-based `page` at `scale` device pixels per point, or of the
/// part of it in `rect`.
///
/// Refuses what the engine would quietly change instead of doing: a scale it cannot use, a tile
/// scale it would clamp, and a tile side it would clamp. (Whether `page` exists is for the document
/// to say; this does not know.)
pub(crate) fn pixel_request(
    page: u32,
    scale: f64,
    rect: Option<TileRect>,
) -> Result<RenderRequest, RenderError> {
    // The engine's scale is single precision. A value that does not fit becomes infinite or zero
    // there, and zero would draw the whole page at the largest size the engine allows, so it is the
    // narrowed value that has to be a positive, finite number, and for a tile one within the range
    // the engine draws tiles at.
    let scale = scale as f32;
    let usable = if rect.is_some() {
        (MIN_TILE_SCALE..=MAX_TILE_SCALE).contains(&scale)
    } else {
        scale.is_finite() && scale > 0.0
    };
    if !usable {
        return Err(RenderError::Failed {
            message: "invalid scale".to_owned(),
        });
    }
    let tile = rect.map(tile_for).transpose()?;
    Ok(RenderRequest {
        page: usize::try_from(page).map_err(|_| RenderError::PageOutOfRange { page })?,
        kind: RequestKind::Pixels,
        tile,
        scale,
        tag: 0,
        preview: false,
    })
}

fn tile_for(rect: TileRect) -> Result<Tile, RenderError> {
    let sides = 1..=MAX_TILE_SIDE;
    if !sides.contains(&rect.width) || !sides.contains(&rect.height) {
        return Err(RenderError::TileTooLarge);
    }
    Ok(Tile {
        x: rect.x,
        y: rect.y,
        w: rect.width,
        h: rect.height,
    })
}

/// The request for the text layer of the 0-based `page`: its glyphs, with their Unicode text and
/// their boxes in view space.
///
/// The engine takes it as one more kind of request, so it goes to the same renderers as a drawing.
/// (Whether `page` exists is for the document to say; this does not know.)
pub(crate) fn text_request(page: u32) -> Result<RenderRequest, RenderError> {
    Ok(RenderRequest {
        page: usize::try_from(page).map_err(|_| RenderError::PageOutOfRange { page })?,
        kind: RequestKind::Text,
        tile: None,
        // The engine reads no scale for text; this is the value of a plain 72 dpi drawing.
        scale: 1.0,
        tag: 0,
        preview: false,
    })
}

/// The tile the engine drew, or why it drew none.
pub(crate) fn into_tile(drawn: RenderedPage) -> Result<RenderedTile, RenderError> {
    let RenderedPage {
        width,
        height,
        rgba,
        error,
        ..
    } = drawn;
    if rgba.is_empty() {
        let message = error.unwrap_or_else(|| "the page produced no pixels".to_owned());
        return Err(RenderError::Failed { message });
    }
    // An error that comes with pixels would be a page drawn in part (the engine reports no such
    // case today). A partial picture is more use than a blank one, so the pixels are returned.
    //
    // What Swift gets promises `rgba.len() == width * height * 4`; make sure it is true.
    let expected = usize::try_from(width)
        .ok()
        .zip(usize::try_from(height).ok())
        .and_then(|(w, h)| w.checked_mul(h)?.checked_mul(4));
    if expected != Some(rgba.len()) {
        return Err(RenderError::Failed {
            message: format!(
                "the renderer returned {} bytes for a {width} x {height} picture",
                rgba.len()
            ),
        });
    }
    Ok(RenderedTile {
        width,
        height,
        rgba: rgba.to_vec(),
    })
}

/// The text layer the engine extracted, or why it extracted none.
///
/// A page without any text (a scan) is not a failure: the engine answers with a layer that has no
/// glyphs. A failure is a page it could not read at all, and carries the engine's reason.
pub(crate) fn into_text(
    extracted: RenderedPage,
) -> Result<Arc<pdfcraft_render::PageText>, RenderError> {
    let RenderedPage { text, error, .. } = extracted;
    text.ok_or_else(|| RenderError::Failed {
        message: error.unwrap_or_else(|| "the page's text could not be read".to_owned()),
    })
}

/// The renderers for one revision of one document, shared by every thread that draws it.
///
/// A renderer draws one page at a time (drawing needs exclusive access), so a single one would make
/// concurrent tile requests queue up. The pool keeps up to [`MAX_RENDERERS`] and hands a caller
/// whichever is idle. When none is, the caller waits for whichever is let go of first, and callers
/// that wait are served in the order they came, so none waits for ever.
pub(crate) struct RendererPool {
    revision: u64,
    /// The document as displayed at `revision`: what every renderer here parses.
    bytes: Arc<Vec<u8>>,
    config: RenderConfig,
    /// Which slots are taken, and whose turn it is to take the next one. Its lock is held to look and
    /// to mark, never while a renderer draws.
    turns: Mutex<Turns>,
    /// Woken when a slot is let go of, and when one is taken while others wait, so that the caller
    /// whose turn it is looks again.
    changed: Condvar,
    /// A slot starts empty, and the caller that takes an empty one builds its renderer in it. The
    /// lowest free slot is the one taken, so the pool grows only when every renderer it has is busy,
    /// one renderer at a time, and never beyond its slots. Only the caller that has taken a slot
    /// (see `turns`) locks it, so that lock is never waited for.
    slots: [Mutex<Option<PageRenderer>>; MAX_RENDERERS],
}

/// Who has which slot, and the line for them.
struct Turns {
    /// Whether each slot is taken.
    busy: [bool; MAX_RENDERERS],
    /// The number the next caller to come is given.
    next: u64,
    /// The number of the caller that takes the next free slot. Callers take slots in the order of
    /// their numbers, so one that arrives later cannot take a slot from under one that waits.
    serving: u64,
}

impl Turns {
    /// Whether a caller is waiting for a slot.
    fn has_waiters(&self) -> bool {
        self.serving != self.next
    }
}

/// A slot taken from a pool: its renderer is the holder's until this is dropped, which gives the
/// slot back and wakes the caller whose turn is next.
pub(crate) struct Claim<'pool> {
    pool: &'pool RendererPool,
    index: usize,
}

impl Drop for Claim<'_> {
    fn drop(&mut self) {
        let mut turns = self.pool.turns();
        turns.busy[self.index] = false;
        let wake = turns.has_waiters();
        drop(turns);
        if wake {
            self.pool.changed.notify_all();
        }
    }
}

impl RendererPool {
    /// A pool for `bytes`, the document as displayed at `revision`, opened with `password` when it
    /// is protected.
    ///
    /// Builds nothing yet: a renderer parses the document the first time it is needed, so making the
    /// pool is cheap enough to do while the document's state lock is held.
    pub(crate) fn new(revision: u64, bytes: Arc<Vec<u8>>, password: Option<&str>) -> Self {
        Self {
            revision,
            bytes,
            config: RenderConfig {
                password: password.map(Arc::from),
                ..RenderConfig::default()
            },
            turns: Mutex::new(Turns {
                busy: [false; MAX_RENDERERS],
                next: 0,
                serving: 0,
            }),
            changed: Condvar::new(),
            slots: std::array::from_fn(|_| Mutex::new(None)),
        }
    }

    /// The revision of the document that this pool draws.
    pub(crate) fn revision(&self) -> u64 {
        self.revision
    }

    /// Draws `request` with an idle renderer, building one first when every renderer is busy and
    /// the pool has room; otherwise waits for whichever renderer is free first.
    pub(crate) fn render(&self, request: RenderRequest) -> RenderedPage {
        let claim = self.claim();
        // A caller panicked while drawing and the panic was already reported. The renderer itself
        // never panics on a bad page, so what it holds is still sound.
        let mut slot = self.slots[claim.index]
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let drawn = slot
            .get_or_insert_with(|| PageRenderer::new(self.bytes.clone(), self.config.clone()))
            .render(request);
        // The renderer before the slot, so the next caller never finds the renderer still locked.
        drop(slot);
        drop(claim);
        drawn
    }

    /// Takes the lowest free slot. When every slot is taken, or callers that came earlier are still
    /// waiting, waits in line: for whichever slot is let go of first, once the callers ahead have
    /// been served.
    fn claim(&self) -> Claim<'_> {
        let mut turns = self.turns();
        let ticket = turns.next;
        turns.next = turns.next.wrapping_add(1);
        loop {
            if turns.serving == ticket
                && let Some(index) = turns.busy.iter().position(|busy| !busy)
            {
                turns.busy[index] = true;
                turns.serving = turns.serving.wrapping_add(1);
                // The caller next in line may find another slot free.
                let wake = turns.has_waiters();
                drop(turns);
                if wake {
                    self.changed.notify_all();
                }
                return Claim { pool: self, index };
            }
            turns = self
                .changed
                .wait(turns)
                .unwrap_or_else(PoisonError::into_inner);
        }
    }

    /// The line for the slots. Its lock is only held to read and set a few numbers, so it is never
    /// poisoned in practice; if it were, the numbers are still whole.
    fn turns(&self) -> MutexGuard<'_, Turns> {
        self.turns.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Holds every slot, as long-running draws would, so tests can see what waits on the pool. The
    /// claims come in the order of their slots.
    #[cfg(test)]
    pub(crate) fn hold_all(&self) -> Vec<Claim<'_>> {
        (0..MAX_RENDERERS).map(|_| self.claim()).collect()
    }

    /// How many callers are waiting for a slot.
    #[cfg(test)]
    fn waiting(&self) -> u64 {
        let turns = self.turns();
        turns.next.wrapping_sub(turns.serving)
    }

    /// How many renderers have been built.
    #[cfg(test)]
    fn built(&self) -> usize {
        self.slots
            .iter()
            .filter(|slot| {
                slot.lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .is_some()
            })
            .count()
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use std::sync::mpsc;
    use std::thread;
    use std::time::Duration;

    use pdfcraft_render::Pixels;

    use super::*;

    /// A one-page document, as the engine shows it.
    fn one_page() -> Arc<Vec<u8>> {
        let bytes = pdfcraft_engine::Session::new()
            .create_from_text("fixture", "hello")
            .expect("a text page creates")
            .to_vec();
        Arc::new(bytes)
    }

    /// A two-page document with plenty of lines and words on each page, as the engine shows it.
    fn several_lines() -> Arc<Vec<u8>> {
        let page = |n: usize| {
            (0..30)
                .map(|i| {
                    format!(
                        "page {n} line {i}: the quick brown fox jumps over the lazy dog {}",
                        i * 37
                    )
                })
                .collect::<Vec<_>>()
                .join("\n")
        };
        let bytes = pdfcraft_engine::Session::new()
            .create_from_text("fixture", &format!("{}\u{c}{}", page(1), page(2)))
            .expect("text pages create")
            .to_vec();
        Arc::new(bytes)
    }

    fn draw_page_zero() -> RenderRequest {
        pixel_request(0, 0.25, None).expect("a valid request")
    }

    fn rect(width: u32, height: u32) -> Option<TileRect> {
        Some(TileRect {
            x: 7,
            y: 9,
            width,
            height,
        })
    }

    // ---- requests

    #[test]
    fn a_whole_page_request_has_no_tile() {
        let request = pixel_request(3, 1.5, None).unwrap();
        assert_eq!((request.page, request.scale, request.tile), (3, 1.5, None));
        assert_eq!(request.kind, RequestKind::Pixels);
        assert!(!request.preview, "a final render, not a thumbnail");
    }

    #[test]
    fn a_tile_request_carries_the_rect_in_device_pixels() {
        let request = pixel_request(0, 2.0, rect(256, 128)).unwrap();
        let tile = request.tile.unwrap();
        assert_eq!((tile.x, tile.y, tile.w, tile.h), (7, 9, 256, 128));
    }

    #[test]
    fn tile_sides_outside_1_to_4096_are_too_large() {
        for (w, h) in [(0, 8), (8, 0), (4097, 8), (8, 4097), (u32::MAX, u32::MAX)] {
            assert!(
                matches!(
                    pixel_request(0, 1.0, rect(w, h)),
                    Err(RenderError::TileTooLarge)
                ),
                "{w} x {h}"
            );
        }
        assert!(pixel_request(0, 1.0, rect(1, 1)).is_ok());
        assert!(pixel_request(0, 1.0, rect(4096, 4096)).is_ok());
    }

    #[test]
    fn a_scale_must_be_positive_and_fit_the_engines_single_precision() {
        for scale in [0.0, -1.0, f64::NAN, f64::INFINITY, 1e300, 1e-300] {
            let err = pixel_request(0, scale, None).unwrap_err();
            assert!(
                matches!(&err, RenderError::Failed { message } if message == "invalid scale"),
                "{scale}: {err:?}"
            );
        }
        assert!(pixel_request(0, f64::from(f32::MIN_POSITIVE), None).is_ok());
        assert!(pixel_request(0, f64::from(f32::MAX), None).is_ok());
    }

    #[test]
    fn a_tile_scale_must_be_within_the_range_the_engine_draws_tiles_at() {
        let low = f64::from(MIN_TILE_SCALE);
        let high = f64::from(MAX_TILE_SCALE);
        for scale in [
            low / 2.0,
            0.009,
            high + 0.5,
            f64::from(f32::MAX),
            f64::NAN,
            0.0,
        ] {
            let err = pixel_request(0, scale, rect(16, 16)).unwrap_err();
            assert!(
                matches!(&err, RenderError::Failed { message } if message == "invalid scale"),
                "{scale}: {err:?}"
            );
        }
        for scale in [low, 0.01, 1.0, high] {
            let request = pixel_request(0, scale, rect(16, 16)).unwrap();
            // What the engine is handed is a scale it does not change.
            assert_eq!(
                request.scale,
                request.scale.clamp(MIN_TILE_SCALE, MAX_TILE_SCALE)
            );
        }
        // A whole page may be drawn at a scale outside the range: the engine fits it to its limits.
        assert!(pixel_request(0, low / 2.0, None).is_ok());
        assert!(pixel_request(0, high * 2.0, None).is_ok());
    }

    #[test]
    fn a_text_request_asks_for_the_text_layer_of_one_page() {
        let request = text_request(3).unwrap();
        assert_eq!(request.page, 3);
        assert_eq!(request.kind, RequestKind::Text);
        assert_eq!(request.tile, None);
        assert!(!request.preview);
    }

    // ---- results

    fn drawn(width: u32, height: u32, words: Vec<u32>, error: Option<&str>) -> RenderedPage {
        RenderedPage {
            request: RenderRequest::default(),
            width,
            height,
            rgba: Pixels::from(words),
            error: error.map(str::to_owned),
            text: None,
            warnings: Vec::new(),
            millis: 0,
        }
    }

    /// One pixel as the engine stores it: its four bytes in R, G, B, A order in memory.
    fn pixel(rgba: [u8; 4]) -> u32 {
        u32::from_ne_bytes(rgba)
    }

    #[test]
    fn drawn_pixels_become_a_tile_of_the_same_size_and_bytes() {
        let page = drawn(
            2,
            1,
            vec![pixel([1, 2, 3, 255]), pixel([4, 5, 6, 255])],
            None,
        );
        let tile = into_tile(page).unwrap();
        assert_eq!((tile.width, tile.height), (2, 1));
        assert_eq!(tile.rgba, [1, 2, 3, 255, 4, 5, 6, 255]);
    }

    #[test]
    fn no_pixels_is_a_failure_that_carries_the_engines_reason() {
        let err = into_tile(drawn(
            0,
            0,
            Vec::new(),
            Some("page 1 has an empty page box"),
        ))
        .unwrap_err();
        assert!(
            matches!(&err, RenderError::Failed { message } if message == "page 1 has an empty page box"),
            "{err:?}"
        );
    }

    #[test]
    fn no_pixels_and_no_reason_is_still_a_failure_with_a_message() {
        let err = into_tile(drawn(0, 0, Vec::new(), None)).unwrap_err();
        assert!(matches!(&err, RenderError::Failed { message } if !message.is_empty()));
    }

    #[test]
    fn a_partial_drawing_is_returned_not_discarded() {
        let page = drawn(
            1,
            1,
            vec![pixel([9, 9, 9, 255])],
            Some("content was cut short"),
        );
        let tile = into_tile(page).unwrap();
        assert_eq!(
            (tile.width, tile.height, tile.rgba),
            (1, 1, vec![9, 9, 9, 255])
        );
    }

    #[test]
    fn pixels_that_do_not_fit_the_claimed_size_are_refused() {
        // 3 pixels cannot be a 2 x 2 picture; Swift would be handed a buffer shorter than promised.
        let err = into_tile(drawn(2, 2, vec![0; 3], None)).unwrap_err();
        assert!(matches!(err, RenderError::Failed { .. }), "{err:?}");
        let err = into_tile(drawn(u32::MAX, u32::MAX, vec![0; 3], None)).unwrap_err();
        assert!(matches!(err, RenderError::Failed { .. }), "{err:?}");
    }

    /// What the engine answers a text request with: the layer, or why there is none.
    fn extracted(
        text: Option<Arc<pdfcraft_render::PageText>>,
        error: Option<&str>,
    ) -> RenderedPage {
        RenderedPage {
            request: RenderRequest::default(),
            width: 0,
            height: 0,
            rgba: Pixels::default(),
            error: error.map(str::to_owned),
            text,
            warnings: Vec::new(),
            millis: 0,
        }
    }

    #[test]
    fn an_extracted_layer_is_handed_on_as_it_is() {
        let layer = Arc::new(pdfcraft_render::PageText::default());
        let text = into_text(extracted(Some(layer.clone()), None)).unwrap();
        assert!(Arc::ptr_eq(&layer, &text));
        // A page without text is a layer without glyphs, not a failure.
        assert!(text.glyphs.is_empty());
    }

    #[test]
    fn no_layer_is_a_failure_that_carries_the_engines_reason() {
        let err = into_text(extracted(None, Some("page 2 does not exist"))).unwrap_err();
        assert!(
            matches!(&err, RenderError::Failed { message } if message == "page 2 does not exist"),
            "{err:?}"
        );
    }

    #[test]
    fn no_layer_and_no_reason_is_still_a_failure_with_a_message() {
        let err = into_text(extracted(None, None)).unwrap_err();
        assert!(matches!(&err, RenderError::Failed { message } if !message.is_empty()));
    }

    // ---- the pool

    #[test]
    fn a_new_pool_has_built_nothing_and_remembers_its_revision() {
        let pool = RendererPool::new(7, one_page(), None);
        assert_eq!((pool.revision(), pool.built()), (7, 0));
    }

    #[test]
    fn renders_one_after_another_share_one_renderer() {
        let pool = RendererPool::new(0, one_page(), None);
        for _ in 0..3 {
            assert_eq!(pool.render(draw_page_zero()).error, None);
        }
        assert_eq!(pool.built(), 1, "an idle renderer is reused, not added to");
    }

    #[test]
    fn a_pages_text_is_read_by_the_renderer_that_draws_it() {
        let pool = RendererPool::new(0, one_page(), None);
        assert_eq!(pool.render(draw_page_zero()).error, None);
        let read = pool.render(text_request(0).unwrap());
        assert_eq!(read.error, None);
        assert_eq!(read.text.unwrap().plain_text(), "hello");
        assert_eq!(pool.built(), 1, "text is not read by a renderer of its own");
        // And a page the document does not have is the engine's failure to report.
        let missing = pool.render(text_request(5).unwrap());
        assert!(missing.text.is_none() && missing.error.is_some());
        assert!(matches!(
            into_text(missing),
            Err(RenderError::Failed { .. })
        ));
    }

    #[test]
    fn a_page_reads_the_same_whichever_renderer_reads_it() {
        // What a caller is told about a page's text is glyph indices. When the text cache lets go
        // of a page and it is read again, possibly by another renderer, the indices have to mean the
        // same glyphs: the layer has to come out identical, glyph for glyph and line for line.
        let bytes = several_lines();
        let pool = RendererPool::new(0, bytes.clone(), None);
        let read =
            |pool: &RendererPool, page: u32| pool.render(text_request(page).unwrap()).text.unwrap();
        let first: Vec<_> = (0..2).map(|page| read(&pool, page)).collect();
        assert!(first.iter().all(|text| text.glyphs.len() > 1_000));

        // With the first renderer busy the pool makes a second one, and that one reads.
        let busy = pool.claim();
        for page in 0..2 {
            assert_eq!(
                first[page as usize],
                read(&pool, page),
                "page {page}, second renderer"
            );
        }
        drop(busy);
        assert_eq!(
            pool.built(),
            2,
            "the second read was by a renderer of its own"
        );

        // And renderers of other pools, each of which parses the document afresh.
        for round in 0..3 {
            let other = RendererPool::new(0, bytes.clone(), None);
            for page in 0..2 {
                assert_eq!(
                    first[page as usize],
                    read(&other, page),
                    "page {page}, parse {round}"
                );
            }
        }
    }

    #[test]
    fn a_busy_renderer_is_not_waited_for_while_there_is_room_for_another() {
        let pool = Arc::new(RendererPool::new(0, one_page(), None));
        let first = pool.claim(); // the first renderer's slot, busy for the rest of the test
        let (finished, result) = mpsc::channel();
        let drawing = {
            let pool = pool.clone();
            thread::spawn(move || {
                let _ = finished.send(pool.render(draw_page_zero()).error);
            })
        };
        // If the pool waited for the first slot this would never arrive; the timeout turns a hang
        // into a failure.
        let error = result
            .recv_timeout(Duration::from_secs(60))
            .expect("the draw should have used a second renderer instead of waiting");
        assert_eq!(error, None);
        drawing.join().unwrap();
        drop(first);
        assert_eq!(pool.built(), 1, "only the second slot was filled");
    }

    #[test]
    fn a_caller_that_finds_both_renderers_busy_waits_instead_of_building_a_third() {
        let pool = Arc::new(RendererPool::new(0, one_page(), None));
        let first = pool.claim();
        let second = pool.claim();
        let (got_one, waiting) = mpsc::channel();
        let waiter = {
            let pool = pool.clone();
            thread::spawn(move || {
                let _slot = pool.claim();
                let _ = got_one.send(());
            })
        };
        assert!(
            waiting.recv_timeout(Duration::from_millis(200)).is_err(),
            "with both renderers busy and the pool full, the caller has to wait"
        );
        drop(first);
        waiting
            .recv_timeout(Duration::from_secs(60))
            .expect("the caller should proceed once a renderer is free");
        waiter.join().unwrap();
        drop(second);
        assert_eq!(pool.built(), 0, "nothing was drawn, so nothing was built");
    }

    /// Starts a thread that takes a slot of `pool`, sends which one it got, and keeps it until it is
    /// sent something (or the sender is dropped).
    fn take_a_slot(pool: &Arc<RendererPool>) -> (mpsc::Receiver<usize>, mpsc::Sender<()>) {
        let (took, taken) = mpsc::channel();
        let (release, released) = mpsc::channel::<()>();
        let pool = pool.clone();
        thread::spawn(move || {
            let claim = pool.claim();
            let _ = took.send(claim.index);
            let _ = released.recv();
        });
        (taken, release)
    }

    /// Waits until `pool` has `count` callers in line, for at most ten seconds.
    fn wait_for_waiting(pool: &RendererPool, count: u64) {
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while pool.waiting() != count {
            assert!(
                std::time::Instant::now() < deadline,
                "{} callers waiting, not {count}",
                pool.waiting()
            );
            thread::sleep(Duration::from_millis(1));
        }
    }

    #[test]
    fn with_the_first_renderer_busy_a_caller_takes_the_second_at_once() {
        let pool = Arc::new(RendererPool::new(0, one_page(), None));
        let first = pool.claim();
        assert_eq!(first.index, 0, "the lowest free slot is taken");
        let (taken, release) = take_a_slot(&pool);
        assert_eq!(
            taken
                .recv_timeout(Duration::from_secs(10))
                .expect("the caller should not wait while the second slot is free"),
            1
        );
        drop(release);
        drop(first);
    }

    #[test]
    fn a_caller_waiting_for_a_renderer_takes_whichever_is_let_go_of_first() {
        let pool = Arc::new(RendererPool::new(0, one_page(), None));
        let mut held = pool.hold_all();
        assert_eq!(held.iter().map(|c| c.index).collect::<Vec<_>>(), [0, 1]);
        let (taken, release) = take_a_slot(&pool);
        assert!(
            taken.recv_timeout(Duration::from_millis(200)).is_err(),
            "with both renderers busy the caller has to wait"
        );
        // The second renderer is let go of; the first stays busy for the rest of the test.
        drop(held.pop());
        assert_eq!(
            taken
                .recv_timeout(Duration::from_secs(10))
                .expect("the caller should take the second renderer as soon as it is free"),
            1
        );
        drop(release);
        drop(held);
    }

    #[test]
    fn callers_waiting_for_a_renderer_are_served_in_the_order_they_came() {
        let pool = Arc::new(RendererPool::new(0, one_page(), None));
        let mut held = pool.hold_all();
        let (first_taken, first_release) = take_a_slot(&pool);
        wait_for_waiting(&pool, 1);
        let (second_taken, second_release) = take_a_slot(&pool);
        wait_for_waiting(&pool, 2);

        // One slot comes free: it is the first caller's, though both are woken.
        drop(held.pop());
        assert_eq!(
            first_taken.recv_timeout(Duration::from_secs(10)).unwrap(),
            1
        );
        assert!(
            second_taken
                .recv_timeout(Duration::from_millis(200))
                .is_err(),
            "the second caller waits for the next slot to come free"
        );
        // A caller that comes now gets in line behind the one that is waiting.
        let (third_taken, third_release) = take_a_slot(&pool);
        wait_for_waiting(&pool, 2);

        drop(held.pop());
        assert_eq!(
            second_taken.recv_timeout(Duration::from_secs(10)).unwrap(),
            0
        );
        assert!(
            third_taken
                .recv_timeout(Duration::from_millis(200))
                .is_err()
        );
        drop(first_release);
        assert_eq!(
            third_taken.recv_timeout(Duration::from_secs(10)).unwrap(),
            1
        );
        drop((second_release, third_release));
        wait_for_waiting(&pool, 0);
    }

    #[test]
    fn many_callers_at_once_are_all_answered_by_at_most_two_renderers() {
        // Draws and text reads from several threads at once, as the tiles, the thumbnails and a
        // search make them: every one is answered, the pool never builds more than two renderers,
        // and every slot is given back.
        let pool = Arc::new(RendererPool::new(0, several_lines(), None));
        let threads: Vec<_> = (0..6)
            .map(|n| {
                let pool = pool.clone();
                thread::spawn(move || {
                    for round in 0..4 {
                        let request = if (n + round) % 2 == 0 {
                            draw_page_zero()
                        } else {
                            text_request(1).unwrap()
                        };
                        assert_eq!(
                            pool.render(request).error,
                            None,
                            "thread {n}, round {round}"
                        );
                    }
                })
            })
            .collect();
        for thread in threads {
            thread.join().unwrap();
        }
        assert_eq!(pool.waiting(), 0);
        assert_eq!(pool.turns().busy, [false; MAX_RENDERERS]);
        assert!((1..=MAX_RENDERERS).contains(&pool.built()));
    }
}
