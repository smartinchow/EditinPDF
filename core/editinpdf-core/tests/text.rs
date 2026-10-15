#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod fixtures;
use std::time::{Duration, Instant};

use editinpdf_core::{MAX_QUERY_CHARS, MAX_SEARCH_HITS, PdfDocument, RenderError};

/// All of a page's glyph texts, one after another.
fn glyph_text(doc: &PdfDocument, page: u32) -> String {
    doc.page_text(page)
        .unwrap()
        .glyphs
        .iter()
        .map(|g| g.text.as_str())
        .collect()
}

#[test]
fn glyphs_have_text_and_boxes_inside_the_page() {
    let doc = PdfDocument::open(fixtures::text_doc(&["Hello world"]), None).unwrap();
    let t = doc.page_text(0).unwrap();
    let s: String = t.glyphs.iter().map(|g| g.text.as_str()).collect();
    assert!(s.replace(' ', "").contains("Helloworld"), "got {s:?}");
    for g in &t.glyphs {
        assert!(
            g.rect.x >= 0.0
                && g.rect.y >= 0.0
                && g.rect.x + g.rect.width <= 612.5
                && g.rect.y + g.rect.height <= 792.5
        );
    }
}

#[test]
fn rotated_page_glyphs_are_in_view_space() {
    let doc = PdfDocument::open(fixtures::rotated_doc("Rotated"), None).unwrap();
    let p = doc.page_info(0).unwrap();
    for g in doc.page_text(0).unwrap().glyphs {
        assert!(
            g.rect.x + g.rect.width <= p.width_pt + 0.5
                && g.rect.y + g.rect.height <= p.height_pt + 0.5
        );
    }
}

#[test]
fn image_only_page_has_no_text() {
    let doc = PdfDocument::open(fixtures::image_only_doc(), None).unwrap();
    assert!(doc.page_text(0).unwrap().glyphs.is_empty());
    assert!(doc.select_word(0, 100.0, 100.0).unwrap().is_none());
    assert!(doc.search("anything".into(), false).is_empty());
}

#[test]
fn select_word_and_range() {
    let doc = PdfDocument::open(fixtures::text_doc(&["Hello world"]), None).unwrap();
    let g = &doc.page_text(0).unwrap().glyphs[0];
    let sel = doc
        .select_word(0, g.rect.x + 1.0, g.rect.y + g.rect.height / 2.0)
        .unwrap()
        .unwrap();
    assert_eq!(sel.text, "Hello");
    assert_eq!(sel.rects.len(), 1);
    let all = doc
        .select_range(0, 0, doc.page_text(0).unwrap().glyphs.len() as u32)
        .unwrap();
    assert_eq!(all.text.trim(), "Hello world");
}

#[test]
fn search_finds_hits_on_each_page() {
    let doc = PdfDocument::open(
        fixtures::text_doc(&["apple pie", "no fruit", "Apple tart"]),
        None,
    )
    .unwrap();
    let hits = doc.search("apple".into(), false);
    assert_eq!(hits.iter().map(|h| h.page).collect::<Vec<_>>(), vec![0, 2]);
    assert!(hits[0].snippet.to_lowercase().contains("apple"));
    assert!(!hits[0].rects.is_empty());
    assert_eq!(doc.search("apple".into(), true).len(), 1);
    assert!(doc.search("".into(), false).is_empty());
}

// ---- beyond the brief's five

#[test]
fn text_calls_on_a_page_the_document_lacks_are_out_of_range() {
    let doc = PdfDocument::open(fixtures::text_doc(&["one"]), None).unwrap();
    assert!(matches!(
        doc.page_text(1),
        Err(RenderError::PageOutOfRange { page: 1 })
    ));
    assert!(matches!(
        doc.select_word(1, 80.0, 80.0),
        Err(RenderError::PageOutOfRange { page: 1 })
    ));
    assert!(matches!(
        doc.select_range(u32::MAX, 0, 1),
        Err(RenderError::PageOutOfRange { page: u32::MAX })
    ));
}

#[test]
fn a_point_away_from_the_text_selects_nothing() {
    let doc = PdfDocument::open(fixtures::text_doc(&["Hello world"]), None).unwrap();
    // The first glyph, "H", is 7.9 wide and 11 high: a point has to be within half of that 11 (5.5)
    // of its box to count as on it.
    let h = doc.page_text(0).unwrap().glyphs[0].rect;
    let (middle, below) = (h.y + h.height / 2.0, h.y + h.height);

    assert!(doc.select_word(0, 500.0, 700.0).unwrap().is_none());
    assert!(doc.select_word(0, 5.0, 5.0).unwrap().is_none());
    assert!(doc.select_word(0, h.x - 4.0, middle).unwrap().is_some());
    assert!(doc.select_word(0, h.x - 8.0, middle).unwrap().is_none());
    assert!(
        doc.select_word(0, h.x + 1.0, below + 4.0)
            .unwrap()
            .is_some()
    );
    assert!(
        doc.select_word(0, h.x + 1.0, below + 8.0)
            .unwrap()
            .is_none()
    );
    for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, 1e300] {
        assert!(doc.select_word(0, bad, middle).unwrap().is_none(), "{bad}");
        assert!(doc.select_word(0, h.x, bad).unwrap().is_none(), "{bad}");
    }
}

#[test]
fn a_blank_between_words_is_not_a_word() {
    let doc = PdfDocument::open(fixtures::text_doc(&["Hello world"]), None).unwrap();
    let glyphs = doc.page_text(0).unwrap().glyphs;
    // The engine draws the space between the two words as a glyph of its own.
    let space = &glyphs[glyphs.iter().position(|g| g.text == " ").unwrap()].rect;
    let (x, y) = (space.x + space.width / 2.0, space.y + space.height / 2.0);
    assert!(doc.select_word(0, x, y).unwrap().is_none());
    // Either side of it, the words are there.
    let second = &glyphs[glyphs.iter().position(|g| g.text == "w").unwrap()].rect;
    let sel = doc
        .select_word(0, second.x + 1.0, second.y + second.height / 2.0)
        .unwrap()
        .unwrap();
    assert_eq!(sel.text, "world");
}

#[test]
fn a_word_is_selected_by_the_glyph_under_the_point_and_reports_its_glyphs() {
    let doc = PdfDocument::open(fixtures::text_doc(&["Hello world"]), None).unwrap();
    let glyphs = doc.page_text(0).unwrap().glyphs;
    // "Hello world" is 11 glyphs, the space among them: "world" is glyphs 6 to 10.
    let d = &glyphs[10].rect;
    let sel = doc
        .select_word(0, d.x + d.width / 2.0, d.y + d.height / 2.0)
        .unwrap()
        .unwrap();
    assert_eq!((sel.page, sel.start, sel.end), (0, 6, 11));
    assert_eq!(sel.text, "world");
    // The box is the union of the five glyph boxes.
    let (first, last) = (&glyphs[6].rect, &glyphs[10].rect);
    assert_eq!(sel.rects.len(), 1);
    assert_eq!(sel.rects[0].x, first.x);
    assert_eq!(sel.rects[0].x + sel.rects[0].width, last.x + last.width);
}

#[test]
fn select_range_clamps_its_indices() {
    let doc = PdfDocument::open(fixtures::text_doc(&["Hello world"]), None).unwrap();
    let n = u32::try_from(doc.page_text(0).unwrap().glyphs.len()).unwrap();
    assert_eq!(n, 11);

    let tail = doc.select_range(0, 6, 1000).unwrap();
    assert_eq!((tail.page, tail.start, tail.end), (0, 6, n));
    assert_eq!(tail.text, "world");

    // A start past the end is taken as the end: an empty selection, not an error.
    for (start, end, at) in [(9, 4, 4), (500, 600, n), (3, 3, 3)] {
        let sel = doc.select_range(0, start, end).unwrap();
        assert_eq!((sel.start, sel.end), (at, at), "{start}..{end}");
        assert!(
            sel.text.is_empty() && sel.rects.is_empty(),
            "{start}..{end}"
        );
    }
}

#[test]
fn a_selection_over_two_lines_has_a_box_and_a_line_break_per_line() {
    let doc = PdfDocument::open(fixtures::text_doc(&["Hello world\nsecond line"]), None).unwrap();
    let n = u32::try_from(doc.page_text(0).unwrap().glyphs.len()).unwrap();
    let all = doc.select_range(0, 0, n).unwrap();
    assert_eq!(all.text, "Hello world\nsecond line");
    assert_eq!(all.rects.len(), 2);
    assert!(all.rects[0].y < all.rects[1].y, "{:?}", all.rects);
    // From the middle of the first line to the middle of the second.
    let part = doc.select_range(0, 6, 17).unwrap();
    assert_eq!(part.text, "world\nsecond");
    assert_eq!(part.rects.len(), 2);
}

#[test]
fn a_hit_names_its_glyphs_and_boxes() {
    let doc = PdfDocument::open(fixtures::text_doc(&["apple pie"]), None).unwrap();
    let glyphs = doc.page_text(0).unwrap().glyphs;
    let hits = doc.search("PIE".into(), false);
    assert_eq!(hits.len(), 1);
    let hit = &hits[0];
    // "apple pie" is 9 glyphs, the space among them: "pie" is glyphs 6 to 8.
    assert_eq!((hit.page, hit.start, hit.end), (0, 6, 9));
    assert_eq!(hit.snippet, "apple pie");
    assert_eq!(hit.rects.len(), 1);
    let (first, last) = (&glyphs[6].rect, &glyphs[8].rect);
    assert_eq!(hit.rects[0].x, first.x);
    assert_eq!(hit.rects[0].x + hit.rects[0].width, last.x + last.width);
    // The glyph indices select the same text.
    assert_eq!(doc.select_range(0, hit.start, hit.end).unwrap().text, "pie");
}

#[test]
fn hits_come_in_reading_order_within_a_page() {
    let doc = PdfDocument::open(fixtures::text_doc(&["pie and pie\nmore pie"]), None).unwrap();
    let hits = doc.search("pie".into(), true);
    assert_eq!(hits.len(), 3);
    assert!(hits.iter().all(|h| h.page == 0));
    assert!(hits.windows(2).all(|w| w[0].end <= w[1].start), "{hits:?}");
    assert!(hits[2].rects[0].y > hits[0].rects[0].y);
}

#[test]
fn a_hit_across_a_line_break_has_a_box_per_line() {
    let doc = PdfDocument::open(fixtures::text_doc(&["apple\npie"]), None).unwrap();
    let hits = doc.search("apple pie".into(), false);
    assert_eq!(hits.len(), 1);
    assert_eq!((hits[0].start, hits[0].end), (0, 8));
    assert_eq!(hits[0].rects.len(), 2);
    // The snippet is the line the hit starts on.
    assert_eq!(hits[0].snippet, "apple");
}

#[test]
fn a_long_lines_snippet_is_cut_around_the_hit() {
    // 128 characters on one line (narrow letters, so the engine does not wrap it), the hit starting
    // at the 102nd.
    let line = format!("{} needle {}", "l".repeat(100), "l".repeat(20));
    let doc = PdfDocument::open(fixtures::text_doc(&[line.as_str()]), None).unwrap();
    let hits = doc.search("needle".into(), false);
    assert_eq!(hits.len(), 1);
    let snippet = &hits[0].snippet;
    assert!(snippet.chars().count() <= 80, "{snippet:?}");
    assert!(snippet.contains("needle"), "{snippet:?}");
    assert!(snippet.len() < line.len());
}

#[test]
fn a_blank_query_finds_nothing() {
    let doc = PdfDocument::open(fixtures::text_doc(&["apple pie"]), None).unwrap();
    for query in ["", " ", "  \t ", "\n"] {
        assert!(doc.search(query.into(), false).is_empty(), "{query:?}");
    }
}

#[test]
fn text_and_hits_keep_non_ascii_characters_whole() {
    let doc = PdfDocument::open(fixtures::text_doc(&["caf\u{e9} na\u{ef}ve"]), None).unwrap();
    assert_eq!(glyph_text(&doc, 0), "caf\u{e9} na\u{ef}ve");
    let hits = doc.search("NA\u{ef}VE".into(), false);
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].snippet, "caf\u{e9} na\u{ef}ve");
}

#[test]
fn selecting_on_a_rotated_page_uses_view_space_points() {
    // On this page the text runs downwards at its right edge.
    let doc = PdfDocument::open(fixtures::rotated_doc("Rotated"), None).unwrap();
    let glyphs = doc.page_text(0).unwrap().glyphs;
    let r = &glyphs[0].rect;
    let sel = doc
        .select_word(0, r.x + r.width / 2.0, r.y + r.height / 2.0)
        .unwrap()
        .unwrap();
    assert_eq!(sel.text, "Rotated");
    // Where the text is on the unrotated page there is nothing.
    assert!(doc.select_word(0, 80.0, 80.0).unwrap().is_none());
    // A glyph's size along the line is its advance: the "t" here is 3 points of it and 11 across.
    // A point 4 points beside the line is still on it.
    let t = &glyphs[2].rect;
    assert!(t.height < 4.0 && t.width > 10.0, "{t:?}");
    let beside = doc.select_word(0, t.x - 4.0, t.y + t.height / 2.0);
    assert_eq!(beside.unwrap().unwrap().text, "Rotated");
}

#[test]
fn the_text_of_an_encrypted_document_is_read_with_its_password() {
    let bytes = fixtures::encrypted_doc(&["secret words"], "hunter2");
    let doc = PdfDocument::open(bytes, Some("hunter2".into())).unwrap();
    assert_eq!(glyph_text(&doc, 0), "secret words");
    assert_eq!(doc.search("WORDS".into(), false).len(), 1);
}

#[test]
fn asking_twice_gives_the_same_answer() {
    // The second call is served from the text cache; it must say what the first did.
    let doc = PdfDocument::open(fixtures::text_doc(&["one two", "three"]), None).unwrap();
    let first = doc.page_text(0).unwrap();
    let again = doc.page_text(0).unwrap();
    assert_eq!(first.glyphs.len(), again.glyphs.len());
    assert!(
        first
            .glyphs
            .iter()
            .zip(&again.glyphs)
            .all(|(a, b)| a.text == b.text && a.rect == b.rect)
    );
    let places = |doc: &PdfDocument| {
        let hits = doc.search("t".into(), false);
        hits.iter()
            .map(|h| (h.page, h.start, h.end))
            .collect::<Vec<_>>()
    };
    assert_eq!(places(&doc), places(&doc));
    assert_eq!(places(&doc).len(), 2, "the t of two and the t of three");
    assert_eq!(glyph_text(&doc, 1), "three");
}

// ---- bounded work on hostile pages

#[test]
fn a_one_letter_query_on_a_very_long_line_is_answered_quickly() {
    // One line of 60,000 glyphs, every one of them a match for a one-letter query: "l" for the first
    // 59,000 and "i" for the last 1,000. Building a hit's snippet used to cost as much as the line is
    // long, so a search for either took ten seconds.
    let line = format!("{}{}", "l".repeat(59_000), "i".repeat(1_000));
    let doc = PdfDocument::open(fixtures::one_line_doc(&line), None).unwrap();
    let glyphs = doc.page_text(0).unwrap().glyphs.len();
    assert_eq!(glyphs, 60_000, "the engine keeps every glyph of the line");
    let whole = doc.select_range(0, 0, 60_000).unwrap();
    assert_eq!(whole.rects.len(), 1, "and lays them out as one line");

    // Ten searches for each in a row, with the page's text already read. The cap on hits keeps one
    // search short whatever a hit costs, and it takes the first hits: those of "l" are at the start
    // of the line and those of "i" at its end. Ten of each make a cost per hit that depends on how
    // far the hit is from either end of the line show.
    let started = Instant::now();
    for query in ["l", "i"] {
        for _ in 0..10 {
            let hits = doc.search(query.into(), false);
            assert_eq!(hits.len(), MAX_SEARCH_HITS, "{query}");
            assert!(hits.iter().all(|h| h.snippet.chars().count() <= 80));
        }
    }
    let took = started.elapsed();
    assert!(
        took < Duration::from_secs(1),
        "twenty searches of one line of {glyphs} glyphs took {took:?}"
    );
}

#[test]
fn a_search_returns_the_first_hits_and_stops_at_the_cap() {
    // 45 lines of 90 "l": 4,050 glyphs, each of them a match for "l".
    let page = vec!["l".repeat(90); 45].join("\n");
    let doc = PdfDocument::open(fixtures::text_doc(&[page.as_str()]), None).unwrap();
    assert_eq!(glyph_text(&doc, 0).len(), 4_050);
    let hits = doc.search("l".into(), false);
    assert_eq!(hits.len(), MAX_SEARCH_HITS);
    // They are the first ones, in reading order: the hit at position i is glyph i.
    for (i, hit) in hits.iter().enumerate() {
        let i = u32::try_from(i).unwrap();
        assert_eq!((hit.page, hit.start, hit.end), (0, i, i + 1));
    }
}

#[test]
fn the_cap_runs_across_pages_in_page_order() {
    // Three pages of 630 matches each. A search takes all of page 0, the first 370 of page 1, and
    // never looks at page 2.
    let page = vec!["l".repeat(90); 7].join("\n");
    let doc = PdfDocument::open(fixtures::text_doc(&[&page, &page, &page]), None).unwrap();
    let hits = doc.search("l".into(), false);
    assert_eq!(hits.len(), MAX_SEARCH_HITS);
    let on = |page| hits.iter().filter(|h| h.page == page).count();
    assert_eq!((on(0), on(1), on(2)), (630, 370, 0));
    assert!(
        hits.windows(2)
            .all(|w| (w[0].page, w[0].start) < (w[1].page, w[1].start))
    );
}

#[test]
fn a_search_with_fewer_hits_than_the_cap_returns_them_all() {
    // 11 lines of 90 and a last one of 9 or 10: 999 or 1,000 matches.
    for last in [9, 10] {
        let mut lines = vec!["l".repeat(90); 11];
        lines.push("l".repeat(last));
        let page = lines.join("\n");
        let doc = PdfDocument::open(fixtures::text_doc(&[page.as_str()]), None).unwrap();
        assert_eq!(doc.search("l".into(), false).len(), 990 + last);
    }
}

#[test]
fn a_query_longer_than_the_cap_finds_nothing_even_where_the_page_has_it() {
    // A sentence of 499 characters, which the page wraps over several lines.
    let sentence = (0..100)
        .map(|i| format!("w{i:03}"))
        .collect::<Vec<_>>()
        .join(" ");
    let doc = PdfDocument::open(fixtures::text_doc(&[sentence.as_str()]), None).unwrap();
    let glyphs = u32::try_from(doc.page_text(0).unwrap().glyphs.len()).unwrap();
    let on_the_page = doc.select_range(0, 0, glyphs).unwrap().text;
    assert_eq!(on_the_page.replace('\n', " "), sentence, "the page has it");

    let longest = &sentence[..MAX_QUERY_CHARS];
    let hits = doc.search(longest.into(), true);
    assert_eq!((hits.len(), hits[0].start), (1, 0));
    assert!(
        doc.search(sentence[..=MAX_QUERY_CHARS].into(), true)
            .is_empty()
    );
    assert!(doc.search(sentence.clone(), true).is_empty());
    // The blanks around a query are not counted against it.
    assert_eq!(doc.search(format!("  {longest}\n "), true).len(), 1);
}
