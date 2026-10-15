//! The text layer: a page's text as the engine extracted it, and what the viewer does with it,
//! which is picking out a word or a range of glyphs and searching.
//!
//! The engine's layer ([`EnginePageText`]) holds a page's glyphs in reading order together with the
//! structure selection and search need: which line each glyph is on, and where the gaps between
//! words are. This module only reads it. What counts as a word, a line, a space or a match is the
//! engine's own (`word_at`, `line_at`, `text_of`, `find_opts`), not worked out again here, so the
//! text a selection reads as is the text a search matched.
//!
//! A glyph is named by its index in the layer. Those indices are what `TextSelection` and
//! `SearchHit` carry, and they stay the same for as long as the document's revision does.

use std::collections::HashMap;
use std::ops::Range;
use std::sync::Arc;

use crate::{Rect, SearchHit, TextSelection};

/// The text of one page as the engine extracts it. The bridge's own `PageText` is the part of it
/// that crosses to Swift.
pub(crate) type EnginePageText = pdfcraft_render::PageText;

/// The most characters a search hit's snippet has.
const SNIPPET_CHARS: usize = 80;

/// The text layers extracted so far, by page, for one revision of the document.
///
/// A layer belongs to the revision it was extracted from. When the revision changes (an edit), every
/// layer is out of date at once, and the next use of the cache for the new revision drops them all.
#[derive(Default)]
pub(crate) struct TextCache {
    /// The revision `pages` were extracted from.
    revision: u64,
    pages: HashMap<u32, Arc<EnginePageText>>,
}

impl TextCache {
    /// The layer of the 0-based `page` at `revision`, if it has been extracted.
    ///
    /// Asking for another revision than the one the cache holds drops what it holds first: those
    /// layers describe a document that has since changed.
    pub(crate) fn get(&mut self, revision: u64, page: u32) -> Option<Arc<EnginePageText>> {
        if self.revision != revision {
            self.pages.clear();
            self.revision = revision;
        }
        self.pages.get(&page).cloned()
    }

    /// Keeps `layer`, the text of `page` as extracted from `revision`.
    ///
    /// Ignored when the cache is no longer on that revision. The extraction runs without the
    /// document's state lock, so an edit can have been made while it did, and a layer of the
    /// document as it was must not be handed out for the document as it is.
    pub(crate) fn insert(&mut self, revision: u64, page: u32, layer: Arc<EnginePageText>) {
        if self.revision == revision {
            self.pages.insert(page, layer);
        }
    }
}

/// The word at the view-space point (`x`, `y`) of `layer`, the text of the 0-based `page`.
///
/// Nothing when the page has no text, when the point is not on or near a glyph, or when the glyph
/// it is on is a blank (the engine's idea of the word around a blank is the whole line).
pub(crate) fn select_word(
    page: u32,
    layer: &EnginePageText,
    x: f64,
    y: f64,
) -> Option<TextSelection> {
    // The engine's coordinates are single precision. A point that is not a finite number there
    // (not a number, or too far out to fit) is not on the page.
    let (x, y) = (x as f32, y as f32);
    if !(x.is_finite() && y.is_finite()) {
        return None;
    }
    // `nearest` always names a glyph when there are any, however far away; whether the point is
    // really on it is decided here.
    let nearest = layer.nearest(x, y)?;
    let glyph = layer.glyphs.get(nearest)?;
    if !is_near(glyph.rect, x, y) || glyph.text.trim().is_empty() {
        return None;
    }
    let (first, last) = layer.word_at(nearest)?;
    // The engine names a word by its first and last glyph, both included.
    Some(selection(page, layer, first..last.saturating_add(1)))
}

/// The glyphs `start` up to, but not including, `end` of `layer`, the text of the 0-based `page`.
///
/// An `end` past the last glyph is taken as the last, and a `start` past the `end` as the `end`, so
/// whatever the indices, the selection is a real (possibly empty) range of the page's glyphs.
pub(crate) fn select_range(
    page: u32,
    layer: &EnginePageText,
    start: u32,
    end: u32,
) -> TextSelection {
    let count = layer.glyphs.len();
    let end = usize::try_from(end).map_or(count, |end| end.min(count));
    let start = usize::try_from(start).map_or(end, |start| start.min(end));
    selection(page, layer, start..end)
}

/// Every place `query` occurs in `layer`, the text of the 0-based `page`, in reading order.
///
/// `query` is not blank (the caller skips the page altogether when it is). It is matched anywhere,
/// not only as a whole word.
pub(crate) fn search_page(
    page: u32,
    layer: &EnginePageText,
    query: &str,
    case_sensitive: bool,
) -> Vec<SearchHit> {
    layer
        .find_opts(query, case_sensitive, false)
        .into_iter()
        .map(|hit| SearchHit {
            page,
            start: index(hit.start),
            end: index(hit.end),
            rects: line_boxes(layer, hit.clone()),
            snippet: snippet(layer, &hit),
        })
        .collect()
}

/// Whether the view-space point (`x`, `y`) is on a glyph's box `[left, top, right, bottom]`, or
/// close enough to count as on it: within half the glyph's size of the box.
fn is_near(rect: [f32; 4], x: f32, y: f32) -> bool {
    let [left, top, right, bottom] = rect;
    // The size of a glyph is the larger side of its box. Across the line the box is as large as the
    // font; along it, as wide as the glyph's advance, which for a narrow letter is the smaller side.
    // Which side is which depends on the way the line runs, and on a page shown turned a line runs
    // down it, so the larger side keeps the reach the same on any page.
    let reach = (right - left).max(bottom - top) / 2.0;
    (left - reach..=right + reach).contains(&x) && (top - reach..=bottom + reach).contains(&y)
}

/// The selection record for the glyphs `glyphs` of `layer`, the text of the 0-based `page`.
fn selection(page: u32, layer: &EnginePageText, glyphs: Range<usize>) -> TextSelection {
    TextSelection {
        page,
        start: index(glyphs.start),
        end: index(glyphs.end),
        rects: line_boxes(layer, glyphs.clone()),
        text: layer.text_of(glyphs),
    }
}

/// The boxes that cover the glyphs `glyphs`: one for each line they run across.
fn line_boxes(layer: &EnginePageText, glyphs: Range<usize>) -> Vec<Rect> {
    layer
        .line_rects(glyphs)
        .into_iter()
        .map(Rect::from_engine)
        .collect()
}

/// A glyph index as the records carry it. (A page does not have four billion glyphs.)
fn index(glyph: usize) -> u32 {
    u32::try_from(glyph).unwrap_or(u32::MAX)
}

/// The text of the line the hit `hit` starts on, to show the hit in context: at most
/// [`SNIPPET_CHARS`] characters, cut around the hit when the line is longer.
fn snippet(layer: &EnginePageText, hit: &Range<usize>) -> String {
    let Some((first, last)) = layer.line_at(hit.start) else {
        // A hit starts on a glyph, and a glyph is on a line, so this is not reached for a hit the
        // engine found; if it ever is, the hit's own text is the best context there is.
        return snippet_around(&layer.text_of(hit.clone()), 0, 0);
    };
    let line_end = last.saturating_add(1);
    let line = layer.text_of(first..line_end);
    // Where the hit sits in the line, in characters. The line ends with the text from the hit's
    // first glyph on, written the same either way (only the space or break before that glyph is
    // left out), so the hit starts as many characters from the line's start as the line has more
    // than that text.
    let from_hit = layer.text_of(hit.start..line_end).chars().count();
    let hit_start = line.chars().count().saturating_sub(from_hit);
    // A hit that runs on to the next line is cut off at the end of this one.
    let hit_len = layer
        .text_of(hit.start..hit.end.min(line_end))
        .chars()
        .count();
    snippet_around(&line, hit_start, hit_len)
}

/// `line` trimmed and cut to at most [`SNIPPET_CHARS`] characters, keeping the part around the hit
/// that starts `hit_start` characters into `line` and is `hit_len` characters long.
///
/// The cut is on a character, never inside one. When the hit is shorter than the limit it ends up
/// in the middle of what is kept, and when the line ends close by, the room that leaves on that side
/// goes to the other one; a hit longer than the limit is kept from its start.
fn snippet_around(line: &str, hit_start: usize, hit_len: usize) -> String {
    let trimmed = line.trim();
    // The hit moves up by the blanks that were trimmed off the front.
    let blanks = line.chars().take_while(|c| c.is_whitespace()).count();
    let hit_start = hit_start.saturating_sub(blanks);
    let length = trimmed.chars().count();
    if length <= SNIPPET_CHARS {
        return trimmed.to_owned();
    }
    let room_around = SNIPPET_CHARS.saturating_sub(hit_len);
    let start = hit_start
        .saturating_sub(room_around / 2)
        .min(length - SNIPPET_CHARS);
    let kept: String = trimmed.chars().skip(start).take(SNIPPET_CHARS).collect();
    // The cut can leave a blank at either end.
    kept.trim().to_owned()
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// A text layer with one glyph for each character of `lines`: `size` points wide and high, the
    /// first line's glyphs starting at (10, 10) and each line `size + 2` below the one before it.
    /// Spaces are glyphs, as the engine draws them from a page that has them.
    fn layer(lines: &[&str], size: f32) -> EnginePageText {
        let mut layer = EnginePageText::default();
        for (n, line) in lines.iter().enumerate() {
            let top = 10.0 + n as f32 * (size + 2.0);
            for (k, c) in line.chars().enumerate() {
                let left = 10.0 + k as f32 * size;
                let rect = [left, top, left + size, top + size];
                layer.glyphs.push(pdfcraft_render::TextGlyph {
                    text: c.to_string(),
                    rect,
                    quad: [
                        [rect[0], rect[1]],
                        [rect[2], rect[1]],
                        [rect[2], rect[3]],
                        [rect[0], rect[3]],
                    ],
                    direction: [1.0, 0.0],
                });
                layer.line_of.push(n as u32);
                layer.space_before.push(false);
            }
        }
        layer
    }

    fn word(layer: &EnginePageText, x: f64, y: f64) -> Option<(u32, u32, String)> {
        select_word(3, layer, x, y).map(|s| (s.start, s.end, s.text))
    }

    fn some(start: u32, end: u32, text: &str) -> Option<(u32, u32, String)> {
        Some((start, end, text.to_owned()))
    }

    // ---- select_word

    #[test]
    fn a_point_on_a_glyph_selects_its_word() {
        // "ab cd": a, b, a blank, c, d; the glyphs are 10 wide from x = 10, and 10 high from y = 10.
        let layer = layer(&["ab cd"], 10.0);
        assert_eq!(word(&layer, 25.0, 15.0), some(0, 2, "ab"));
        assert_eq!(word(&layer, 12.0, 11.0), some(0, 2, "ab"));
        assert_eq!(word(&layer, 45.0, 15.0), some(3, 5, "cd"));
        assert_eq!(word(&layer, 59.0, 19.0), some(3, 5, "cd"));
    }

    #[test]
    fn the_selection_is_for_the_page_it_was_asked_on() {
        let layer = layer(&["ab"], 10.0);
        assert_eq!(select_word(3, &layer, 15.0, 15.0).unwrap().page, 3);
        assert_eq!(select_range(7, &layer, 0, 1).page, 7);
    }

    #[test]
    fn a_point_counts_as_on_a_glyph_up_to_half_its_size_away() {
        let layer = layer(&["ab cd"], 10.0); // reach: 5 points
        // Beyond the end of the line (the last glyph ends at x = 60).
        assert_eq!(word(&layer, 65.0, 15.0), some(3, 5, "cd"));
        assert_eq!(word(&layer, 65.1, 15.0), None);
        // Before its start (the first glyph starts at x = 10).
        assert_eq!(word(&layer, 5.0, 15.0), some(0, 2, "ab"));
        assert_eq!(word(&layer, 4.9, 15.0), None);
        // Above and below it (the line is y = 10 to 20).
        assert_eq!(word(&layer, 25.0, 5.0), some(0, 2, "ab"));
        assert_eq!(word(&layer, 25.0, 4.9), None);
        assert_eq!(word(&layer, 25.0, 25.0), some(0, 2, "ab"));
        assert_eq!(word(&layer, 25.0, 25.1), None);
        // And far from everything.
        assert_eq!(word(&layer, 500.0, 700.0), None);
    }

    #[test]
    fn the_glyph_nearest_the_point_decides_between_lines() {
        // Two lines 12 apart (10 high, 2 between them): the gap is y = 20 to 22.
        let layer = layer(&["ab", "cd"], 10.0);
        assert_eq!(word(&layer, 15.0, 19.0), some(0, 2, "ab"));
        assert_eq!(word(&layer, 15.0, 23.0), some(2, 4, "cd"));
    }

    #[test]
    fn a_blank_glyph_is_not_a_word() {
        let layer = layer(&["ab cd"], 10.0);
        // The blank is x = 30 to 40. The engine's word around a blank is the whole line.
        assert_eq!(layer.word_at(2), Some((0, 4)));
        assert_eq!(word(&layer, 35.0, 15.0), None);
        // Next to it, the words are there.
        assert_eq!(word(&layer, 29.0, 15.0), some(0, 2, "ab"));
        assert_eq!(word(&layer, 41.0, 15.0), some(3, 5, "cd"));
    }

    #[test]
    fn a_page_without_text_has_no_word() {
        let layer = EnginePageText::default();
        assert_eq!(word(&layer, 15.0, 15.0), None);
    }

    #[test]
    fn a_point_that_is_not_a_finite_number_is_on_nothing() {
        let layer = layer(&["ab"], 10.0);
        for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, 1e300, -1e300] {
            assert_eq!(word(&layer, bad, 15.0), None, "{bad}");
            assert_eq!(word(&layer, 15.0, bad), None, "{bad}");
        }
    }

    #[test]
    fn a_glyph_is_as_large_as_the_larger_side_of_its_box() {
        // A line that runs down the page (a page shown turned): each glyph's box is 10 across the
        // line and only 2 along it. The reach is half of 10, not half of 2.
        let mut layer = layer(&["ab"], 10.0);
        for (k, glyph) in layer.glyphs.iter_mut().enumerate() {
            let top = 10.0 + k as f32 * 2.0;
            glyph.rect = [10.0, top, 20.0, top + 2.0];
        }
        assert_eq!(word(&layer, 24.0, 11.0), some(0, 2, "ab"));
        assert_eq!(word(&layer, 26.0, 11.0), None);
    }

    #[test]
    fn a_word_stops_at_a_gap_the_engine_marked_without_a_glyph() {
        // "abcd" with a word gap before the third glyph and no blank glyph, as a page that moves
        // the pen instead of drawing a space has it.
        let mut layer = layer(&["abcd"], 10.0);
        layer.space_before[2] = true;
        assert_eq!(word(&layer, 15.0, 15.0), some(0, 2, "ab"));
        assert_eq!(word(&layer, 35.0, 15.0), some(2, 4, "cd"));
        // The text reads with the space the gap implies.
        assert_eq!(select_range(0, &layer, 0, 4).text, "ab cd");
    }

    // ---- select_range

    #[test]
    fn a_range_reads_and_boxes_the_glyphs_between_its_ends() {
        let layer = layer(&["ab cd", "ef"], 10.0);
        let sel = select_range(2, &layer, 1, 6);
        assert_eq!((sel.page, sel.start, sel.end), (2, 1, 6));
        assert_eq!(sel.text, "b cd\ne");
        assert_eq!(
            sel.rects,
            [
                Rect {
                    x: 20.0,
                    y: 10.0,
                    width: 40.0,
                    height: 10.0
                },
                Rect {
                    x: 10.0,
                    y: 22.0,
                    width: 10.0,
                    height: 10.0
                },
            ]
        );
    }

    #[test]
    fn a_range_is_clamped_to_the_glyphs_there_are() {
        let layer = layer(&["ab cd"], 10.0);
        for (start, end, expected) in [
            (0, 5, (0, 5)),
            (0, 99, (0, 5)),
            (3, u32::MAX, (3, 5)),
            (4, 2, (2, 2)),
            (9, 99, (5, 5)),
            (u32::MAX, u32::MAX, (5, 5)),
            (2, 2, (2, 2)),
            (0, 0, (0, 0)),
        ] {
            let sel = select_range(0, &layer, start, end);
            assert_eq!((sel.start, sel.end), expected, "{start}..{end}");
            if expected.0 == expected.1 {
                assert!(
                    sel.text.is_empty() && sel.rects.is_empty(),
                    "{start}..{end}"
                );
            }
        }
    }

    #[test]
    fn a_range_of_a_page_without_text_is_empty() {
        let sel = select_range(0, &EnginePageText::default(), 0, 10);
        assert_eq!((sel.start, sel.end), (0, 0));
        assert!(sel.text.is_empty() && sel.rects.is_empty());
    }

    // ---- search_page

    #[test]
    fn a_hit_carries_its_page_glyphs_boxes_and_line() {
        let layer = layer(&["an apple", "apple pie"], 10.0);
        let hits = search_page(4, &layer, "apple", false);
        assert_eq!(hits.len(), 2);
        assert!(hits.iter().all(|h| h.page == 4));
        assert_eq!((hits[0].start, hits[0].end), (3, 8));
        assert_eq!(hits[0].snippet, "an apple");
        assert_eq!(hits[0].rects.len(), 1);
        assert_eq!(hits[0].rects[0].x, 40.0);
        assert_eq!(hits[0].rects[0].width, 50.0);
        assert_eq!((hits[1].start, hits[1].end), (8, 13));
        assert_eq!(hits[1].snippet, "apple pie");
    }

    #[test]
    fn a_hit_may_run_on_to_the_next_line() {
        let layer = layer(&["an apple", "pie"], 10.0);
        let hits = search_page(0, &layer, "apple pie", false);
        assert_eq!(hits.len(), 1);
        assert_eq!((hits[0].start, hits[0].end), (3, 11));
        assert_eq!(hits[0].rects.len(), 2);
        assert_eq!(hits[0].snippet, "an apple");
    }

    #[test]
    fn case_matters_only_when_asked_to() {
        let layer = layer(&["Apple apple"], 10.0);
        assert_eq!(search_page(0, &layer, "apple", false).len(), 2);
        let exact = search_page(0, &layer, "apple", true);
        assert_eq!(exact.len(), 1);
        assert_eq!(exact[0].start, 6);
    }

    #[test]
    fn a_hit_in_the_middle_of_a_word_counts() {
        let layer = layer(&["pineapple"], 10.0);
        let hits = search_page(0, &layer, "apple", false);
        assert_eq!(hits.len(), 1);
        assert_eq!((hits[0].start, hits[0].end), (4, 9));
    }

    // ---- snippets

    fn the_line(before: usize, hit: &str, after: usize) -> String {
        format!("{}{hit}{}", "x".repeat(before), "y".repeat(after))
    }

    #[test]
    fn a_short_line_is_the_snippet_trimmed() {
        assert_eq!(snippet_around("an apple", 3, 5), "an apple");
        assert_eq!(snippet_around("  an apple \t", 5, 5), "an apple");
        assert_eq!(snippet_around("", 0, 1), "");
        assert_eq!(snippet_around("   ", 1, 1), "");
        let exactly = "z".repeat(SNIPPET_CHARS);
        assert_eq!(snippet_around(&exactly, 40, 3), exactly);
    }

    #[test]
    fn a_long_line_is_cut_around_the_hit() {
        let line = the_line(100, "NEEDLE", 100);
        // 74 characters are left over, and the hit gets half of them on each side.
        assert_eq!(snippet_around(&line, 100, 6), the_line(37, "NEEDLE", 37));
    }

    #[test]
    fn a_hit_near_the_ends_of_a_long_line_gets_the_rest_of_the_room_on_the_other_side() {
        let start = the_line(0, "NEEDLE", 150);
        assert_eq!(snippet_around(&start, 0, 6), the_line(0, "NEEDLE", 74));
        let end = the_line(150, "NEEDLE", 0);
        assert_eq!(snippet_around(&end, 150, 6), the_line(74, "NEEDLE", 0));
        let near_the_start = the_line(10, "NEEDLE", 150);
        assert_eq!(
            snippet_around(&near_the_start, 10, 6),
            the_line(10, "NEEDLE", 64)
        );
    }

    #[test]
    fn a_hit_longer_than_the_snippet_is_kept_from_its_start() {
        let line = format!("{}{}{}", "x".repeat(10), "H".repeat(100), "y".repeat(10));
        assert_eq!(snippet_around(&line, 10, 100), "H".repeat(SNIPPET_CHARS));
    }

    #[test]
    fn blanks_trimmed_off_the_front_do_not_move_the_cut() {
        let line = format!("   {}", the_line(100, "NEEDLE", 100));
        assert_eq!(snippet_around(&line, 103, 6), the_line(37, "NEEDLE", 37));
    }

    #[test]
    fn a_blank_left_at_a_cut_is_trimmed() {
        let line = format!("{} {}", "x".repeat(79), "y".repeat(79));
        // The first 80 characters end with the blank between the runs.
        let snippet = snippet_around(&line, 0, 1);
        assert_eq!(snippet, "x".repeat(79));
    }

    #[test]
    fn the_cut_is_between_characters_not_inside_them() {
        // Two-byte characters: 80 of them are 160 bytes.
        let line = "\u{e9}".repeat(120);
        let snippet = snippet_around(&line, 60, 1);
        assert_eq!(snippet.chars().count(), SNIPPET_CHARS);
        assert_eq!(snippet.len(), SNIPPET_CHARS * 2);
        // Four-byte characters, with the hit at the very end.
        let line = format!("{}!", "\u{1f600}".repeat(120));
        let snippet = snippet_around(&line, 120, 1);
        assert_eq!(snippet.chars().count(), SNIPPET_CHARS);
        assert!(snippet.ends_with('!'));
    }

    #[test]
    fn a_hits_snippet_is_cut_around_where_the_hit_is_in_its_line() {
        let line = the_line(100, "NEEDLE", 100);
        let layer = layer(&[line.as_str()], 1.0);
        let hits = search_page(0, &layer, "NEEDLE", true);
        assert_eq!(hits.len(), 1);
        assert_eq!((hits[0].start, hits[0].end), (100, 106));
        assert_eq!(hits[0].snippet, the_line(37, "NEEDLE", 37));
    }

    #[test]
    fn the_space_before_a_hit_counts_towards_where_it_is_in_the_line() {
        // The page draws no blank glyph before "NEEDLE": the engine marks a word gap instead, and
        // the line's text has a space there that the hit's own text does not.
        let line = the_line(100, "NEEDLE", 100);
        let mut layer = layer(&[line.as_str()], 1.0);
        layer.space_before[100] = true;
        let hits = search_page(0, &layer, "NEEDLE", true);
        assert_eq!(hits.len(), 1);
        assert_eq!(
            hits[0].snippet,
            format!("{} NEEDLE{}", "x".repeat(36), "y".repeat(37))
        );
    }

    #[test]
    fn a_hit_that_runs_on_to_the_next_line_is_shown_on_the_line_it_starts_on() {
        let first = format!("{}AB", "x".repeat(100));
        let second = format!("CD{}", "y".repeat(100));
        let layer = layer(&[first.as_str(), second.as_str()], 1.0);
        let hits = search_page(0, &layer, "AB CD", true);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].snippet, format!("{}AB", "x".repeat(78)));
    }

    #[test]
    fn a_hit_beyond_the_glyphs_has_an_empty_snippet_rather_than_a_panic() {
        // The engine has no line for a glyph that is not there, and no text either.
        let layer = layer(&["ab"], 10.0);
        assert_eq!(snippet(&layer, &(5..6)), "");
    }

    // ---- the cache

    fn text() -> Arc<EnginePageText> {
        Arc::new(EnginePageText::default())
    }

    #[test]
    fn a_layer_is_kept_for_its_page_and_revision() {
        let mut cache = TextCache::default();
        assert!(cache.get(0, 3).is_none(), "nothing is kept at first");
        let layer = text();
        cache.insert(0, 3, layer.clone());
        assert!(Arc::ptr_eq(&layer, &cache.get(0, 3).unwrap()));
        assert!(cache.get(0, 4).is_none(), "another page has no layer yet");
    }

    #[test]
    fn a_newer_revision_drops_every_layer() {
        let mut cache = TextCache::default();
        cache.insert(0, 1, text());
        cache.insert(0, 2, text());
        assert!(cache.get(1, 1).is_none());
        // Not just the page asked for: all of them are gone, and stay gone.
        assert!(cache.get(1, 2).is_none());
        assert!(cache.get(0, 1).is_none());
        assert!(cache.get(0, 2).is_none());
    }

    #[test]
    fn a_layer_from_before_an_edit_is_not_kept_after_it() {
        let mut cache = TextCache::default();
        assert!(
            cache.get(1, 0).is_none(),
            "the cache moves on to revision 1"
        );
        // An extraction that began at revision 0 finishes late.
        cache.insert(0, 0, text());
        assert!(cache.get(1, 0).is_none());
        // One from the revision the cache is on is kept.
        let current = text();
        cache.insert(1, 0, current.clone());
        assert!(Arc::ptr_eq(&current, &cache.get(1, 0).unwrap()));
    }

    #[test]
    fn a_layer_that_arrives_before_the_cache_has_moved_on_is_dropped_by_the_next_get() {
        // The revision changed while the extraction ran, and nothing has asked the cache about the
        // new revision yet: the late layer goes in, labelled with the revision it came from, and
        // the first question about revision 1 throws it out.
        let mut cache = TextCache::default();
        cache.insert(0, 0, text());
        assert!(cache.get(1, 0).is_none());
    }
}
