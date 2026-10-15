//! The text layers read so far, kept for reuse within a budget.
//!
//! Reading a page's text takes the engine a few milliseconds, and selecting a word or stepping
//! through search results asks for it again and again, so each page's layer is kept. What is kept
//! is bounded: a layer costs about a hundred bytes for every glyph on its page, and a long document
//! (or a hostile one, with a page of a million glyphs) must not be able to fill the device's memory
//! just by being searched. The cache holds layers up to a total number of glyphs, and lets go of the
//! one used longest ago when a new one does not fit.
//!
//! The cache is only ever used with the document's state lock held, so it must not make anything wait
//! on that lock for long. Freeing a layer is thousands of small deallocations, so the cache never
//! frees one itself: a layer it lets go of is handed back by [`TextCache::take_retired`] for the
//! caller to drop once the lock is released.

use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

use crate::text::EnginePageText;

/// The most glyphs the cache keeps, counted over all the pages it holds a layer for: about 55 MB of
/// text, enough for a hundred and fifty pages of a book. A page counts for its glyphs, or for one when
/// it has none, since the cache holds an entry for it all the same.
///
/// A layer of more glyphs than this is not kept at all. Its caller still gets it, and reading that
/// page again reads it again.
pub const TEXT_CACHE_GLYPH_BUDGET: usize = 500_000;

/// The text layers of one revision of the document, within a glyph budget, least recently used
/// first out.
///
/// A layer belongs to the revision it was extracted from. When the revision changes (an edit), every
/// layer is out of date at once, and the next use of the cache for the new revision lets them all go.
pub(crate) struct TextCache {
    /// The revision `pages` were extracted from.
    revision: u64,
    /// The most glyphs `pages` may add up to.
    budget: usize,
    /// What `pages` add up to: the sum of every entry's `cost`.
    cost: usize,
    /// Counts uses. Each use of a layer gives it the next number, so the smallest is the layer used
    /// longest ago.
    clock: u64,
    pages: HashMap<u32, Entry>,
    /// The pages by the number of their last use, the least recently used first. It has one entry for
    /// each of `pages`, and finding the one to let go of is a lookup, not a scan.
    by_use: BTreeMap<u64, u32>,
    /// The layers the cache has let go of since they were last collected.
    retired: Vec<Arc<EnginePageText>>,
}

/// One page's layer in the cache.
struct Entry {
    layer: Arc<EnginePageText>,
    /// What the layer counts for against the budget.
    cost: usize,
    /// The number of its last use, which is also its key in `TextCache::by_use`.
    used: u64,
}

impl Default for TextCache {
    fn default() -> Self {
        Self::with_budget(TEXT_CACHE_GLYPH_BUDGET)
    }
}

impl TextCache {
    /// A cache that holds layers up to `budget` glyphs. (Tests use a small one; the document's is
    /// [`TEXT_CACHE_GLYPH_BUDGET`].)
    pub(crate) fn with_budget(budget: usize) -> Self {
        Self {
            revision: 0,
            budget,
            cost: 0,
            clock: 0,
            pages: HashMap::new(),
            by_use: BTreeMap::new(),
            retired: Vec::new(),
        }
    }

    /// The layer of the 0-based `page` at `revision`, if the cache holds it; asking counts as using
    /// it.
    ///
    /// Asking for another revision than the one the cache holds lets go of every layer it holds
    /// first: they describe a document that has since changed.
    pub(crate) fn get(&mut self, revision: u64, page: u32) -> Option<Arc<EnginePageText>> {
        self.follow(revision);
        let entry = self.pages.get_mut(&page)?;
        self.clock += 1;
        self.by_use.remove(&entry.used);
        entry.used = self.clock;
        self.by_use.insert(self.clock, page);
        Some(entry.layer.clone())
    }

    /// Keeps `layer`, the text of `page` as extracted from `revision`, letting go of the layers used
    /// longest ago as far as it takes to fit it in the budget.
    ///
    /// Ignored when the cache is no longer on that revision. The extraction runs without the
    /// document's state lock, so an edit can have been made while it did, and a layer of the document
    /// as it was must not be handed out for the document as it is. Ignored too when the layer alone is
    /// more than the budget (it would push everything else out and still not fit), and when the cache
    /// already holds a layer for the page: two callers that both missed read it twice, and the layers
    /// are the same, so the first stays.
    pub(crate) fn insert(&mut self, revision: u64, page: u32, layer: Arc<EnginePageText>) {
        if self.revision != revision {
            return;
        }
        let cost = layer.glyphs.len().max(1);
        if cost > self.budget {
            return;
        }
        if self.pages.contains_key(&page) {
            // Counts as a use, like a lookup does.
            let _ = self.get(revision, page);
            return;
        }
        while self.cost + cost > self.budget {
            if !self.let_go_of_the_oldest() {
                break;
            }
        }
        self.clock += 1;
        self.by_use.insert(self.clock, page);
        self.pages.insert(
            page,
            Entry {
                layer,
                cost,
                used: self.clock,
            },
        );
        self.cost += cost;
    }

    /// The layers the cache has let go of since this was last called, for the caller to drop. They
    /// are the cache's to free no longer, and freeing them takes long enough that the caller should
    /// do it with the document's state lock released.
    pub(crate) fn take_retired(&mut self) -> Vec<Arc<EnginePageText>> {
        std::mem::take(&mut self.retired)
    }

    /// Switches the cache to `revision`, letting go of the layers of any other.
    fn follow(&mut self, revision: u64) {
        if self.revision == revision {
            return;
        }
        // The layers move to the retired list, which is a handful of pointers each; their
        // deallocation is left to whoever collects them.
        let old = std::mem::take(&mut self.pages);
        self.retired
            .extend(old.into_values().map(|entry| entry.layer));
        self.by_use.clear();
        self.cost = 0;
        self.revision = revision;
    }

    /// Lets go of the layer used longest ago. False when the cache holds none.
    fn let_go_of_the_oldest(&mut self) -> bool {
        let Some((_, page)) = self.by_use.pop_first() else {
            return false;
        };
        if let Some(entry) = self.pages.remove(&page) {
            self.cost = self.cost.saturating_sub(entry.cost);
            self.retired.push(entry.layer);
        }
        true
    }

    /// The layer of `page`, when the cache is on `revision`, without counting as a use.
    #[cfg(test)]
    fn peek(&self, revision: u64, page: u32) -> Option<&Arc<EnginePageText>> {
        if self.revision != revision {
            return None;
        }
        self.pages.get(&page).map(|entry| &entry.layer)
    }

    /// Panics unless the cache's books are straight: the costs add up, within the budget, and the
    /// order of use has one entry for each page and agrees with the pages.
    #[cfg(test)]
    fn check(&self) {
        assert_eq!(
            self.cost,
            self.pages.values().map(|entry| entry.cost).sum::<usize>(),
            "the cost is the sum of the entries'"
        );
        assert!(self.cost <= self.budget, "over budget");
        assert_eq!(self.by_use.len(), self.pages.len(), "one use for each page");
        for (used, page) in &self.by_use {
            let entry = self.pages.get(page);
            assert_eq!(
                entry.map(|entry| entry.used),
                Some(*used),
                "page {page} is held and its use is the one in the order"
            );
            assert!(*used <= self.clock, "no use is in the future");
        }
        for entry in self.pages.values() {
            assert_eq!(
                entry.cost,
                entry.layer.glyphs.len().max(1),
                "an entry's cost"
            );
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use std::sync::Weak;

    use super::*;

    /// A layer of `glyphs` glyphs, all on one line.
    fn layer(glyphs: usize) -> Arc<EnginePageText> {
        Arc::new(EnginePageText {
            glyphs: (0..glyphs)
                .map(|_| pdfcraft_render::TextGlyph {
                    text: "x".to_owned(),
                    rect: [0.0; 4],
                    quad: [[0.0; 2]; 4],
                    direction: [1.0, 0.0],
                })
                .collect(),
            line_of: vec![0; glyphs],
            space_before: vec![false; glyphs],
        })
    }

    /// The pages the cache holds a layer for, in page order.
    fn kept(cache: &TextCache, revision: u64, pages: u32) -> Vec<u32> {
        (0..pages)
            .filter(|page| cache.peek(revision, *page).is_some())
            .collect()
    }

    // ---- by page and revision

    #[test]
    fn a_layer_is_kept_for_its_page_and_revision() {
        let mut cache = TextCache::default();
        assert!(cache.get(0, 3).is_none(), "nothing is kept at first");
        let text = layer(3);
        cache.insert(0, 3, text.clone());
        assert!(Arc::ptr_eq(&text, &cache.get(0, 3).unwrap()));
        assert!(cache.get(0, 4).is_none(), "another page has no layer yet");
    }

    #[test]
    fn a_newer_revision_drops_every_layer() {
        let mut cache = TextCache::default();
        cache.insert(0, 1, layer(3));
        cache.insert(0, 2, layer(3));
        assert!(cache.get(1, 1).is_none());
        // Not just the page asked for: all of them are gone, and stay gone.
        assert!(cache.get(1, 2).is_none());
        assert!(cache.get(0, 1).is_none());
        assert!(cache.get(0, 2).is_none());
        cache.check();
    }

    #[test]
    fn a_layer_from_before_an_edit_is_not_kept_after_it() {
        let mut cache = TextCache::default();
        assert!(
            cache.get(1, 0).is_none(),
            "the cache moves on to revision 1"
        );
        // An extraction that began at revision 0 finishes late.
        cache.insert(0, 0, layer(3));
        assert!(cache.get(1, 0).is_none());
        // One from the revision the cache is on is kept.
        let current = layer(3);
        cache.insert(1, 0, current.clone());
        assert!(Arc::ptr_eq(&current, &cache.get(1, 0).unwrap()));
        cache.check();
    }

    #[test]
    fn a_layer_that_arrives_before_the_cache_has_moved_on_is_dropped_by_the_next_get() {
        // The revision changed while the extraction ran, and nothing has asked the cache about the
        // new revision yet: the late layer goes in, labelled with the revision it came from, and
        // the first question about revision 1 throws it out.
        let mut cache = TextCache::default();
        cache.insert(0, 0, layer(3));
        assert!(cache.get(1, 0).is_none());
        cache.check();
    }

    #[test]
    fn a_page_read_twice_is_kept_once_and_the_first_layer_stays() {
        // Two callers that both missed for a page both read it and both insert.
        let mut cache = TextCache::with_budget(10);
        let (first, second) = (layer(4), layer(4));
        cache.insert(0, 1, first.clone());
        cache.insert(0, 1, second);
        assert!(Arc::ptr_eq(&first, &cache.get(0, 1).unwrap()));
        assert_eq!(cache.cost, 4, "counted once");
        cache.check();
    }

    // ---- the budget

    #[test]
    fn the_budget_is_the_documented_one() {
        assert_eq!(TEXT_CACHE_GLYPH_BUDGET, 500_000);
        assert_eq!(TextCache::default().budget, TEXT_CACHE_GLYPH_BUDGET);
    }

    #[test]
    fn layers_are_kept_while_their_glyphs_fit_the_budget() {
        let mut cache = TextCache::with_budget(10);
        cache.insert(0, 0, layer(4));
        cache.insert(0, 1, layer(6));
        assert_eq!(kept(&cache, 0, 2), [0, 1], "10 glyphs fit a budget of 10");
        assert_eq!(cache.cost, 10);
        assert!(cache.take_retired().is_empty(), "nothing was let go");
        cache.check();
    }

    #[test]
    fn the_layer_used_longest_ago_goes_first() {
        let mut cache = TextCache::with_budget(10);
        cache.insert(0, 0, layer(4));
        cache.insert(0, 1, layer(4));
        // Using page 0 makes page 1 the one used longest ago.
        assert!(cache.get(0, 0).is_some());
        cache.insert(0, 2, layer(4));
        assert_eq!(kept(&cache, 0, 3), [0, 2]);
        assert_eq!(cache.cost, 8);
        assert_eq!(cache.take_retired().len(), 1, "page 1's layer was let go");
        cache.check();
    }

    #[test]
    fn as_many_layers_go_as_the_new_one_needs() {
        let mut cache = TextCache::with_budget(10);
        for page in 0..5 {
            cache.insert(0, page, layer(2));
        }
        assert_eq!(cache.cost, 10);
        // Needs 7 of the 10: 4 of the 5 old layers have to go, the oldest first.
        cache.insert(0, 5, layer(7));
        assert_eq!(kept(&cache, 0, 6), [4, 5]);
        assert_eq!(cache.cost, 9);
        assert_eq!(cache.take_retired().len(), 4);
        cache.check();
    }

    #[test]
    fn a_layer_larger_than_the_budget_is_not_kept_and_costs_the_others_nothing() {
        let mut cache = TextCache::with_budget(10);
        cache.insert(0, 0, layer(4));
        cache.insert(0, 1, layer(11));
        assert_eq!(
            kept(&cache, 0, 2),
            [0],
            "the big one is not kept, the old one stays"
        );
        assert_eq!(cache.cost, 4);
        assert!(cache.take_retired().is_empty());
        cache.check();
    }

    #[test]
    fn a_layer_as_large_as_the_budget_is_kept_alone() {
        let mut cache = TextCache::with_budget(10);
        cache.insert(0, 0, layer(4));
        cache.insert(0, 1, layer(4));
        cache.insert(0, 2, layer(10));
        assert_eq!(kept(&cache, 0, 3), [2]);
        assert_eq!(cache.cost, 10);
        cache.check();
    }

    #[test]
    fn a_page_without_text_still_counts_for_something() {
        // An empty layer is not free: the cache holds an entry for it. Counted as one glyph each,
        // a budget of 3 holds the last three of five empty pages.
        let mut cache = TextCache::with_budget(3);
        for page in 0..5 {
            cache.insert(0, page, layer(0));
        }
        assert_eq!(kept(&cache, 0, 5), [2, 3, 4]);
        cache.check();
    }

    #[test]
    fn a_page_that_is_the_whole_budget_can_be_read_over_and_over() {
        // A layer as large as the budget pushes everything else out and is itself pushed out by
        // the next page; each is still returned to its caller by the document.
        let mut cache = TextCache::with_budget(10);
        for round in 0..20 {
            cache.insert(0, round % 2, layer(10));
            assert_eq!(kept(&cache, 0, 2), [round % 2]);
        }
        cache.check();
    }

    // ---- what is let go is handed back, not freed

    #[test]
    fn the_layers_of_an_old_revision_are_handed_back_and_not_freed_in_place() {
        let mut cache = TextCache::default();
        let text = layer(3);
        let alive: Weak<EnginePageText> = Arc::downgrade(&text);
        cache.insert(0, 1, text);
        assert!(cache.get(1, 1).is_none());
        assert!(
            alive.upgrade().is_some(),
            "still there, waiting to be freed"
        );
        let retired = cache.take_retired();
        assert_eq!(retired.len(), 1);
        assert!(cache.take_retired().is_empty(), "handed back once");
        drop(retired);
        assert!(alive.upgrade().is_none());
    }

    #[test]
    fn an_evicted_layer_is_handed_back_and_not_freed_in_place() {
        let mut cache = TextCache::with_budget(5);
        let text = layer(4);
        let alive: Weak<EnginePageText> = Arc::downgrade(&text);
        cache.insert(0, 0, text);
        cache.insert(0, 1, layer(4));
        assert!(alive.upgrade().is_some(), "evicted, but not yet freed");
        drop(cache.take_retired());
        assert!(alive.upgrade().is_none());
    }

    // ---- the books stay straight

    #[test]
    fn the_accounting_survives_a_long_run_of_mixed_use() {
        // A fixed pseudo-random run of lookups, inserts of every size (some too big to keep) and
        // revision changes; after each step the cache has to be consistent and within its budget.
        let mut cache = TextCache::with_budget(40);
        let mut state: u64 = 0x2545_f491_4f6c_dd1d;
        let mut next = move |bound: u64| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state % bound
        };
        let mut revision = 0;
        for _ in 0..5_000 {
            let page = u32::try_from(next(12)).unwrap();
            match next(10) {
                0 => revision += next(2),
                1..=4 => {
                    cache.get(revision, page);
                }
                _ => {
                    let glyphs = usize::try_from(next(50)).unwrap();
                    // Mostly the current revision, sometimes a late arrival from the one before.
                    let from = if next(8) == 0 {
                        revision.saturating_sub(1)
                    } else {
                        revision
                    };
                    cache.insert(from, page, layer(glyphs));
                }
            }
            assert!(cache.cost <= 40, "over budget: {}", cache.cost);
            cache.check();
            drop(cache.take_retired());
        }
    }
}
