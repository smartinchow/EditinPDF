//! The text layer: a page's text as the engine extracted it, and what the viewer does with it,
//! which is picking out a word or a range of glyphs and searching.
//!
//! The engine's layer ([`EnginePageText`]) holds a page's glyphs in reading order together with the
//! structure selection and search need: which line each glyph is on, and where the gaps between
//! words are. This module only reads it. What counts as a word, a line, a space or a match is the
//! engine's own (`word_at`, `line_at`, `text_of`, `find_opts_limited`), not worked out again here, so
//! the text a selection reads as is the text a search matched.
//!
//! A glyph is named by its index in the layer. Those indices are what `TextSelection` and
//! `SearchHit` carry, and they stay the same for as long as the document's revision does: reading a
//! page again (after its layer was let go of by the cache) gives the same glyphs in the same order.
//!
//! The layer of a hostile page can have any number of glyphs, on one line or on many, and every
//! match in it can be a match of one character. So the work of a call is bounded by the size of the
//! page plus a fixed amount for each thing the call returns: a search stops at [`MAX_SEARCH_HITS`]
//! hits, a query is at most [`MAX_QUERY_CHARS`] characters, and a hit's snippet is cut from a window
//! of a few hundred glyphs around it, never from the whole line.

use std::ops::Range;

use crate::{Rect, SearchHit, TextSelection};

/// The text of one page as the engine extracts it. The bridge's own `PageText` is the part of it
/// that crosses to Swift.
pub(crate) type EnginePageText = pdfcraft_render::PageText;

/// The most hits one search returns: the first ones, in page order and in reading order within a
/// page. A search that finds this many has stopped looking, and there may be more.
///
/// Without a limit a one-letter query returns a hit for every letter of the document, each with its
/// boxes and its snippet, and a crafted page makes that as many as it has glyphs.
pub const MAX_SEARCH_HITS: usize = 1_000;

/// The longest query a search looks for, in characters (not counting the blanks at its ends). A
/// longer one finds nothing.
///
/// Finding a query takes work in proportion to its length for every position in the text, so the
/// length of a query that a page can be searched for has to be bounded.
pub const MAX_QUERY_CHARS: usize = 256;

/// The most characters a search hit's snippet has.
const SNIPPET_CHARS: usize = 80;

/// What to look for when a search is asked for `query`: the query without the blanks at its ends.
///
/// Nothing when there is nothing to look for (the query is blank) or when the query is longer than
/// [`MAX_QUERY_CHARS`] characters, the blanks at its ends not counted.
pub(crate) fn search_text(query: &str) -> Option<&str> {
    let query = query.trim();
    // Counting stops one past the limit: a query of a million characters is not read to its end.
    let too_long = query.chars().take(MAX_QUERY_CHARS + 1).count() > MAX_QUERY_CHARS;
    (!query.is_empty() && !too_long).then_some(query)
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

/// The first `limit` places `query` occurs in `layer`, the text of the 0-based `page`, in reading
/// order.
///
/// `query` is not blank (see [`search_text`]). It is matched anywhere, not only as a whole word.
pub(crate) fn search_page(
    page: u32,
    layer: &EnginePageText,
    query: &str,
    case_sensitive: bool,
    limit: usize,
) -> Vec<SearchHit> {
    layer
        .find_opts_limited(query, case_sensitive, false, limit)
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

/// The stretch of a hit's line that its snippet is cut from.
#[derive(Debug, PartialEq)]
struct Window {
    /// The glyphs of the stretch.
    glyphs: Range<usize>,
    /// Whether the line goes on beyond it.
    goes_on: GoesOn,
}

/// Whether a line goes on before and after the stretch of it that a snippet is cut from.
#[derive(Clone, Copy, Debug, PartialEq)]
struct GoesOn {
    before: bool,
    after: bool,
}

/// The stretch of a hit's line that its snippet is cut from: as far as [`SNIPPET_CHARS`] glyphs
/// before the hit's first glyph and as far after it, or to the ends of the line when they are
/// nearer. Nothing when `hit` does not start on a glyph.
///
/// That is all a snippet can show of the line. It is at most [`SNIPPET_CHARS`] characters, taken from
/// no more than that before the hit and no more than that from its start, and a glyph is at least
/// one character. The line itself can be as long as the page has glyphs, so it is not walked: the
/// edges of the window are found by walking out from the hit, a bounded number of steps, until the
/// line ends or the window is wide enough.
fn snippet_window(layer: &EnginePageText, hit: &Range<usize>) -> Option<Window> {
    let line = layer.line_of.get(hit.start)?;
    // A line's glyphs are consecutive, so the line ends at the first glyph that is on another one.
    let on_line = |glyph: usize| layer.line_of.get(glyph) == Some(line);
    let mut first = hit.start;
    while first > hit.start.saturating_sub(SNIPPET_CHARS) && on_line(first - 1) {
        first -= 1;
    }
    let mut end = hit.start;
    while end < hit.start.saturating_add(SNIPPET_CHARS) && on_line(end) {
        end += 1;
    }
    Some(Window {
        glyphs: first..end,
        goes_on: GoesOn {
            before: first.checked_sub(1).is_some_and(on_line),
            after: on_line(end),
        },
    })
}

/// The text of the line the hit `hit` starts on, to show the hit in context: at most
/// [`SNIPPET_CHARS`] characters, cut around the hit when the line is longer.
///
/// The work is bounded by the window [`snippet_window`] gives, whatever the length of the line or of
/// the hit.
fn snippet(layer: &EnginePageText, hit: &Range<usize>) -> String {
    let Some(Window { glyphs, goes_on }) = snippet_window(layer, hit) else {
        // A hit starts on a glyph, and a glyph is on a line, so this is not reached for a hit the
        // engine found. There is no line to show for one that is not on the page's glyphs.
        return String::new();
    };
    let text = layer.text_of(glyphs.clone());
    // Where the hit sits in `text`, in characters. `text` ends with the text from the hit's first
    // glyph on, written the same either way (only the space or break before that glyph is left out),
    // so the hit starts as many characters from the start of `text` as `text` has more than that.
    let from_hit = layer.text_of(hit.start..glyphs.end).chars().count();
    let hit_start = text.chars().count().saturating_sub(from_hit);
    // How long the hit is in characters, as far as the window goes: a hit that runs on to the next
    // line is cut off at the end of this one, and one of [`SNIPPET_CHARS`] glyphs or more is at least
    // [`SNIPPET_CHARS`] characters long, which is as long as it matters.
    let hit_len = layer
        .text_of(hit.start..hit.end.min(glyphs.end))
        .chars()
        .count();
    snippet_around(&text, hit_start, hit_len, goes_on)
}

/// `text`, a stretch of a line, trimmed and cut to at most [`SNIPPET_CHARS`] characters, keeping the
/// part around the hit that starts `hit_start` characters into `text` and is `hit_len` characters
/// long. `goes_on` says whether the line goes on beyond `text`.
///
/// The cut is on a character, never inside one. When the hit is shorter than the limit it ends up
/// in the middle of what is kept, and when the line ends close by, the room that leaves on that side
/// goes to the other one; a hit longer than the limit is kept from its start.
///
/// Blanks are trimmed where the line ends and not where `text` is only cut off from the rest of it:
/// there they are as much part of the line as the letters are, and the snippet is what it would be
/// if cut from the whole line.
fn snippet_around(text: &str, hit_start: usize, hit_len: usize, goes_on: GoesOn) -> String {
    let (trimmed, blanks) = match (goes_on.before, goes_on.after) {
        (false, false) => (text.trim(), leading_blanks(text)),
        (false, true) => (text.trim_start(), leading_blanks(text)),
        (true, false) => (text.trim_end(), 0),
        (true, true) => (text, 0),
    };
    // The hit moves up by the blanks that were trimmed off the front.
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

/// How many characters of `text` are blanks before the first that is not.
fn leading_blanks(text: &str) -> usize {
    text.chars().take_while(|c| c.is_whitespace()).count()
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use std::time::{Duration, Instant};

    use super::*;

    /// A line given whole: nothing of it goes on beyond the text.
    const WHOLE_LINE: GoesOn = GoesOn {
        before: false,
        after: false,
    };

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

    /// Every hit of `query` on the page, however many.
    fn search_all(
        page: u32,
        layer: &EnginePageText,
        query: &str,
        case_sensitive: bool,
    ) -> Vec<SearchHit> {
        search_page(page, layer, query, case_sensitive, usize::MAX)
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
        let hits = search_all(4, &layer, "apple", false);
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
        let hits = search_all(0, &layer, "apple pie", false);
        assert_eq!(hits.len(), 1);
        assert_eq!((hits[0].start, hits[0].end), (3, 11));
        assert_eq!(hits[0].rects.len(), 2);
        assert_eq!(hits[0].snippet, "an apple");
    }

    #[test]
    fn case_matters_only_when_asked_to() {
        let layer = layer(&["Apple apple"], 10.0);
        assert_eq!(search_all(0, &layer, "apple", false).len(), 2);
        let exact = search_all(0, &layer, "apple", true);
        assert_eq!(exact.len(), 1);
        assert_eq!(exact[0].start, 6);
    }

    #[test]
    fn a_hit_in_the_middle_of_a_word_counts() {
        let layer = layer(&["pineapple"], 10.0);
        let hits = search_all(0, &layer, "apple", false);
        assert_eq!(hits.len(), 1);
        assert_eq!((hits[0].start, hits[0].end), (4, 9));
    }

    // ---- snippets

    fn the_line(before: usize, hit: &str, after: usize) -> String {
        format!("{}{hit}{}", "x".repeat(before), "y".repeat(after))
    }

    #[test]
    fn a_short_line_is_the_snippet_trimmed() {
        assert_eq!(snippet_around("an apple", 3, 5, WHOLE_LINE), "an apple");
        assert_eq!(
            snippet_around("  an apple \t", 5, 5, WHOLE_LINE),
            "an apple"
        );
        assert_eq!(snippet_around("", 0, 1, WHOLE_LINE), "");
        assert_eq!(snippet_around("   ", 1, 1, WHOLE_LINE), "");
        let exactly = "z".repeat(SNIPPET_CHARS);
        assert_eq!(snippet_around(&exactly, 40, 3, WHOLE_LINE), exactly);
    }

    #[test]
    fn a_long_line_is_cut_around_the_hit() {
        let line = the_line(100, "NEEDLE", 100);
        // 74 characters are left over, and the hit gets half of them on each side.
        assert_eq!(
            snippet_around(&line, 100, 6, WHOLE_LINE),
            the_line(37, "NEEDLE", 37)
        );
    }

    #[test]
    fn a_hit_near_the_ends_of_a_long_line_gets_the_rest_of_the_room_on_the_other_side() {
        let start = the_line(0, "NEEDLE", 150);
        assert_eq!(
            snippet_around(&start, 0, 6, WHOLE_LINE),
            the_line(0, "NEEDLE", 74)
        );
        let end = the_line(150, "NEEDLE", 0);
        assert_eq!(
            snippet_around(&end, 150, 6, WHOLE_LINE),
            the_line(74, "NEEDLE", 0)
        );
        let near_the_start = the_line(10, "NEEDLE", 150);
        assert_eq!(
            snippet_around(&near_the_start, 10, 6, WHOLE_LINE),
            the_line(10, "NEEDLE", 64)
        );
    }

    #[test]
    fn a_hit_longer_than_the_snippet_is_kept_from_its_start() {
        let line = format!("{}{}{}", "x".repeat(10), "H".repeat(100), "y".repeat(10));
        assert_eq!(
            snippet_around(&line, 10, 100, WHOLE_LINE),
            "H".repeat(SNIPPET_CHARS)
        );
    }

    #[test]
    fn blanks_trimmed_off_the_front_do_not_move_the_cut() {
        let line = format!("   {}", the_line(100, "NEEDLE", 100));
        assert_eq!(
            snippet_around(&line, 103, 6, WHOLE_LINE),
            the_line(37, "NEEDLE", 37)
        );
    }

    #[test]
    fn blanks_are_trimmed_only_where_the_line_ends() {
        let goes_on = |before, after| GoesOn { before, after };
        // The same stretch of a line, cut off from the rest of it on the sides that go on.
        let text = "  an apple  ";
        assert_eq!(
            snippet_around(text, 5, 5, goes_on(false, false)),
            "an apple"
        );
        assert_eq!(
            snippet_around(text, 5, 5, goes_on(true, false)),
            "  an apple"
        );
        assert_eq!(
            snippet_around(text, 5, 5, goes_on(false, true)),
            "an apple  "
        );
        assert_eq!(snippet_around(text, 5, 5, goes_on(true, true)), text);
    }

    #[test]
    fn a_blank_at_a_cut_end_is_not_the_end_of_the_line() {
        // 80 letters, then a hit longer than a snippet: the text is cut off 80 glyphs after the hit's
        // start, and its last character is a blank.
        let text = format!("{}{} ", "x".repeat(80), "H".repeat(79));
        // The line goes on. The blank is one of the 80 characters from the hit's start, and the
        // snippet starts at the hit.
        let goes_on = GoesOn {
            before: true,
            after: true,
        };
        assert_eq!(snippet_around(&text, 80, 100, goes_on), "H".repeat(79));
        // The line ends there. The blank is trimmed, and with the end of the line that close the
        // snippet starts a character before the hit, to make up its 80.
        let ends = GoesOn {
            before: true,
            after: false,
        };
        assert_eq!(
            snippet_around(&text, 80, 100, ends),
            format!("x{}", "H".repeat(79))
        );
    }

    #[test]
    fn a_blank_left_at_a_cut_is_trimmed() {
        let line = format!("{} {}", "x".repeat(79), "y".repeat(79));
        // The first 80 characters end with the blank between the runs.
        let snippet = snippet_around(&line, 0, 1, WHOLE_LINE);
        assert_eq!(snippet, "x".repeat(79));
    }

    #[test]
    fn the_cut_is_between_characters_not_inside_them() {
        // Two-byte characters: 80 of them are 160 bytes.
        let line = "\u{e9}".repeat(120);
        let snippet = snippet_around(&line, 60, 1, WHOLE_LINE);
        assert_eq!(snippet.chars().count(), SNIPPET_CHARS);
        assert_eq!(snippet.len(), SNIPPET_CHARS * 2);
        // Four-byte characters, with the hit at the very end.
        let line = format!("{}!", "\u{1f600}".repeat(120));
        let snippet = snippet_around(&line, 120, 1, WHOLE_LINE);
        assert_eq!(snippet.chars().count(), SNIPPET_CHARS);
        assert!(snippet.ends_with('!'));
    }

    #[test]
    fn a_hits_snippet_is_cut_around_where_the_hit_is_in_its_line() {
        let line = the_line(100, "NEEDLE", 100);
        let layer = layer(&[line.as_str()], 1.0);
        let hits = search_all(0, &layer, "NEEDLE", true);
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
        let hits = search_all(0, &layer, "NEEDLE", true);
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
        let hits = search_all(0, &layer, "AB CD", true);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].snippet, format!("{}AB", "x".repeat(78)));
    }

    #[test]
    fn a_hit_beyond_the_glyphs_has_an_empty_snippet_rather_than_a_panic() {
        // The engine has no line for a glyph that is not there, and no text either.
        let layer = layer(&["ab"], 10.0);
        assert_eq!(snippet(&layer, &(5..6)), "");
    }

    #[test]
    fn the_limits_are_the_ones_the_documentation_names() {
        // `PdfDocument::search` says 1,000 hits and 256 characters in the docs Swift gets.
        assert_eq!(MAX_SEARCH_HITS, 1_000);
        assert_eq!(MAX_QUERY_CHARS, 256);
        assert_eq!(SNIPPET_CHARS, 80);
    }

    // ---- the hit limit

    #[test]
    fn a_page_gives_the_first_hits_up_to_the_limit() {
        let layer = layer(&["pie pie pie pie"], 10.0);
        let places = |limit| {
            let hits = search_page(0, &layer, "pie", false, limit);
            hits.iter().map(|h| (h.start, h.end)).collect::<Vec<_>>()
        };
        assert_eq!(places(3), [(0, 3), (4, 7), (8, 11)]);
        assert_eq!(places(1), [(0, 3)]);
        assert_eq!(places(4).len(), 4);
        assert_eq!(
            places(99).len(),
            4,
            "a limit above the hits there are changes nothing"
        );
        assert!(places(0).is_empty());
    }

    // ---- the query

    #[test]
    fn a_query_is_what_is_between_its_blanks() {
        assert_eq!(search_text("apple"), Some("apple"));
        assert_eq!(search_text("  apple pie \n"), Some("apple pie"));
    }

    #[test]
    fn a_blank_query_is_nothing_to_look_for() {
        for query in ["", " ", "\t\n ", "\u{a0}", "\u{2003}\u{3000}"] {
            assert_eq!(search_text(query), None, "{query:?}");
        }
    }

    #[test]
    fn a_query_may_be_as_long_as_the_cap_and_no_longer() {
        let longest = "a".repeat(MAX_QUERY_CHARS);
        assert_eq!(search_text(&longest), Some(longest.as_str()));
        assert_eq!(search_text(&"a".repeat(MAX_QUERY_CHARS + 1)), None);
        // Characters are counted, not bytes: these are two bytes each.
        let wide = "\u{e9}".repeat(MAX_QUERY_CHARS);
        assert_eq!(search_text(&wide), Some(wide.as_str()));
        assert_eq!(search_text(&"\u{e9}".repeat(MAX_QUERY_CHARS + 1)), None);
        // The blanks at its ends are not part of it, blanks inside it are.
        assert_eq!(
            search_text(&format!("  {longest}\n ")),
            Some(longest.as_str())
        );
        let spaced = format!("{} {}", "a".repeat(128), "b".repeat(MAX_QUERY_CHARS - 128));
        assert_eq!(search_text(&spaced), None, "one character too many");
    }

    #[test]
    fn a_huge_query_is_refused() {
        assert_eq!(search_text(&"a".repeat(5_000_000)), None);
        assert_eq!(search_text(&" ".repeat(5_000_000)), None);
    }

    // ---- the window a snippet is cut from

    /// The window `glyphs`, with the line going on before it and after it as given.
    fn window(glyphs: Range<usize>, before: bool, after: bool) -> Option<Window> {
        Some(Window {
            glyphs,
            goes_on: GoesOn { before, after },
        })
    }

    #[test]
    fn a_hits_window_reaches_as_far_as_a_snippet_can_use() {
        let line = "x".repeat(1_000);
        let layer = layer(&[line.as_str()], 1.0);
        // A snippet shows at most SNIPPET_CHARS characters, from no more than that before the hit to
        // no more than that after its first glyph. The line goes on both ways.
        assert_eq!(
            snippet_window(&layer, &(500..503)),
            window(420..580, true, true)
        );
        assert_eq!(
            snippet_window(&layer, &(500..900)),
            window(420..580, true, true)
        );
    }

    #[test]
    fn a_hits_window_stops_at_the_ends_of_its_line() {
        let (first, second, third) = ("x".repeat(100), "y".repeat(50), "z".repeat(100));
        let layer = layer(&[first.as_str(), second.as_str(), third.as_str()], 1.0);
        // The middle line is glyphs 100 to 149, and it is all there is of it: the line does not go
        // on beyond the window, though there are glyphs before and after.
        assert_eq!(
            snippet_window(&layer, &(120..123)),
            window(100..150, false, false)
        );
        assert_eq!(
            snippet_window(&layer, &(100..101)),
            window(100..150, false, false)
        );
        assert_eq!(
            snippet_window(&layer, &(149..155)),
            window(100..150, false, false)
        );
        // The first line's end is not reached from 80 glyphs after the hit, and its start is.
        assert_eq!(
            snippet_window(&layer, &(10..12)),
            window(0..90, false, true)
        );
        // The last line is glyphs 150 to 249: its start is not reached from 80 glyphs before the hit,
        // and its end is.
        assert_eq!(
            snippet_window(&layer, &(240..242)),
            window(160..250, true, false)
        );
    }

    #[test]
    fn a_hit_that_is_not_on_a_glyph_has_no_window() {
        let layer = layer(&["ab"], 10.0);
        assert_eq!(snippet_window(&layer, &(2..3)), None);
        assert_eq!(snippet_window(&layer, &(usize::MAX - 1..usize::MAX)), None);
    }

    #[test]
    fn a_snippet_does_not_depend_on_what_is_far_from_the_hit() {
        let near = the_line(100, "NEEDLE", 100);
        let far = format!("{}{near}{}", "z".repeat(5_000), "w".repeat(5_000));
        let (near, far) = (layer(&[near.as_str()], 1.0), layer(&[far.as_str()], 1.0));
        let near = search_all(0, &near, "NEEDLE", true);
        let far = search_all(0, &far, "NEEDLE", true);
        assert_eq!(near[0].snippet, the_line(37, "NEEDLE", 37));
        assert_eq!(far[0].snippet, near[0].snippet);
    }

    #[test]
    fn a_snippet_stays_on_its_line_even_when_the_neighbours_are_close() {
        let above = "x".repeat(100);
        let line = format!("{}NEEDLE{}", "b".repeat(10), "c".repeat(10));
        let below = "y".repeat(100);
        let layer = layer(&[above.as_str(), line.as_str(), below.as_str()], 1.0);
        let hits = search_all(0, &layer, "NEEDLE", true);
        assert_eq!(hits[0].snippet, line);
    }

    #[test]
    fn a_hit_longer_than_the_snippet_on_a_long_line_is_kept_from_its_start() {
        let line = format!("{}{}{}", "z".repeat(500), "H".repeat(100), "z".repeat(500));
        let layer = layer(&[line.as_str()], 1.0);
        let hits = search_all(0, &layer, &"H".repeat(100), true);
        assert_eq!(hits.len(), 1);
        assert_eq!((hits[0].start, hits[0].end), (500, 600));
        assert_eq!(hits[0].snippet, "H".repeat(SNIPPET_CHARS));
        // The boxes cover the whole hit, though the snippet shows part of it.
        assert_eq!(hits[0].rects.len(), 1);
        assert_eq!(hits[0].rects[0].width, 100.0);
    }

    #[test]
    fn a_hit_with_a_glyph_of_several_characters_still_fits_its_snippet() {
        // Every glyph a ligature of three characters: the window of 80 glyphs is 240 characters.
        let mut layer = layer(&[&"a".repeat(300)], 1.0);
        for glyph in &mut layer.glyphs {
            glyph.text = "ffi".to_owned();
        }
        let hits = search_all(0, &layer, "ffi", true);
        assert_eq!(hits.len(), 300);
        assert!(
            hits.iter()
                .all(|h| h.snippet.chars().count() <= SNIPPET_CHARS)
        );
        assert_eq!(hits[150].snippet.chars().count(), SNIPPET_CHARS);
    }

    /// The snippet as it was cut before it had a window: from the whole line, which costs as much as
    /// the line is long. What the windowed one has to give, hit for hit.
    fn snippet_from_the_whole_line(layer: &EnginePageText, hit: &Range<usize>) -> String {
        let Some((first, last)) = layer.line_at(hit.start) else {
            return String::new();
        };
        let line_end = last + 1;
        let line = layer.text_of(first..line_end);
        let from_hit = layer.text_of(hit.start..line_end).chars().count();
        let hit_start = line.chars().count().saturating_sub(from_hit);
        let hit_len = layer
            .text_of(hit.start..hit.end.min(line_end))
            .chars()
            .count();
        snippet_around(&line, hit_start, hit_len, WHOLE_LINE)
    }

    #[test]
    fn the_windowed_snippet_is_the_one_cut_from_the_whole_line() {
        // Lines of letters, blanks (glyphs of their own) and word gaps the engine marks without a
        // glyph, of every length from nothing to several windows, with hits of every length that
        // start and end on a letter and may run on to the next line.
        let mut state: u64 = 0x9e37_79b9_7f4a_7c15;
        let mut next = move |bound: u64| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            usize::try_from(state % bound).unwrap()
        };
        let mut compared = 0;
        for _ in 0..4_000 {
            let lines: Vec<String> = (0..1 + next(3))
                .map(|_| {
                    let length = [10, 70, 120, 250, 600][next(5)] + next(40);
                    (0..length)
                        .map(|_| ['a', 'b', 'c', ' ', 'd', 'e'][next(6)])
                        .collect()
                })
                .collect();
            let mut layer = layer(&lines.iter().map(String::as_str).collect::<Vec<_>>(), 1.0);
            for glyph in 1..layer.glyphs.len() {
                let letters = |k: usize| !layer.glyphs[k].text.trim().is_empty();
                if layer.line_of[glyph] == layer.line_of[glyph - 1]
                    && letters(glyph)
                    && letters(glyph - 1)
                    && next(7) == 0
                {
                    layer.space_before[glyph] = true;
                }
            }
            let count = layer.glyphs.len();
            if count == 0 {
                continue;
            }
            for _ in 0..8 {
                let start = next(count as u64);
                let mut end = (start + 1 + next(130)).min(count);
                // A hit starts and ends on a letter, as the engine's matches do.
                let blank = |k: usize| layer.glyphs[k].text.trim().is_empty();
                while end > start + 1 && blank(end - 1) {
                    end -= 1;
                }
                if blank(start) || blank(end - 1) {
                    continue;
                }
                let hit = start..end;
                assert_eq!(
                    snippet(&layer, &hit),
                    snippet_from_the_whole_line(&layer, &hit),
                    "hit {hit:?} of lines of {:?} glyphs",
                    lines.iter().map(|l| l.len()).collect::<Vec<_>>()
                );
                compared += 1;
            }
        }
        assert!(compared > 10_000, "only {compared} hits were compared");
    }

    #[test]
    fn every_hit_on_a_very_long_line_costs_about_the_same() {
        // 60,000 glyphs on one line, a hit on each of them: the work for a snippet is bounded by
        // what the snippet shows, not by the length of the line. (It was the length of the line, and
        // this took ten seconds.)
        let line = "l".repeat(60_000);
        let layer = layer(&[line.as_str()], 1.0);
        let started = Instant::now();
        let hits = search_all(0, &layer, "l", false);
        let took = started.elapsed();
        assert_eq!(hits.len(), 60_000);
        assert!(
            hits.iter()
                .all(|h| h.snippet.chars().count() <= SNIPPET_CHARS)
        );
        assert!(
            took < Duration::from_secs(3),
            "{} hits took {took:?}",
            hits.len()
        );
    }
}
