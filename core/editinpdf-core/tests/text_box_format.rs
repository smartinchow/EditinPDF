//! A text box's look: its text size, colour, background and border, as `AddTextBox` makes them,
//! `annotations()` reports them, and `RestyleTextBox` changes them.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod fixtures;
mod support;

use editinpdf_core::{
    AnnotationInfo, AnnotationKind, Edit, EditError, PdfDocument, Rect, RgbColor, SaveMode,
    ShapeKind,
};
use support::{BLUE, RED, YELLOW, reopen};

const BOX: Rect = Rect {
    x: 72.0,
    y: 100.0,
    width: 120.0,
    height: 24.0,
};

const PALE: RgbColor = RgbColor {
    red: 1.0,
    green: 0.97,
    blue: 0.8,
};

fn text_box(fill: Option<RgbColor>, border_width: f64) -> Edit {
    Edit::AddTextBox {
        page: 0,
        rect: BOX,
        text: "Hello there".into(),
        font_size: 12.0,
        color: BLUE,
        fill,
        border_width,
    }
}

fn restyle(
    index: u32,
    font_size: f64,
    color: RgbColor,
    fill: Option<RgbColor>,
    border: f64,
) -> Edit {
    Edit::RestyleTextBox {
        page: 0,
        index,
        font_size: Some(font_size),
        color,
        fill,
        border_width: Some(border),
    }
}

fn only_text_box(doc: &PdfDocument) -> AnnotationInfo {
    let boxes: Vec<_> = doc
        .annotations()
        .into_iter()
        .filter(|a| a.kind == AnnotationKind::TextBox)
        .collect();
    assert_eq!(boxes.len(), 1, "{boxes:?}");
    boxes.into_iter().next().unwrap()
}

fn assert_color_close(a: Option<RgbColor>, b: RgbColor) {
    let a = a.expect("a colour");
    let close = (a.red - b.red).abs() < 0.01
        && (a.green - b.green).abs() < 0.01
        && (a.blue - b.blue).abs() < 0.01;
    assert!(close, "{a:?} is not {b:?}");
}

fn one_page() -> std::sync::Arc<PdfDocument> {
    PdfDocument::open(fixtures::text_doc(&["x"]), None).unwrap()
}

#[test]
fn a_text_box_with_a_background_and_a_border_reports_them_and_keeps_them_when_saved() {
    let doc = one_page();
    doc.apply(
        Edit::AddTextBox {
            page: 0,
            rect: BOX,
            text: "Boxed".into(),
            font_size: 18.0,
            color: BLUE,
            fill: Some(PALE),
            border_width: 1.5,
        },
        0,
    )
    .unwrap();
    for doc in [
        doc.clone(),
        reopen(doc.save(SaveMode::Incremental).unwrap(), None),
    ] {
        let info = only_text_box(&doc);
        assert_eq!(info.font_size, Some(18.0));
        assert_color_close(info.color, BLUE);
        assert_color_close(info.fill, PALE);
        assert_eq!(info.border_width, Some(1.5));
    }
}

#[test]
fn a_plain_text_box_has_no_background_and_no_border_and_other_kinds_report_none_of_it() {
    let doc = one_page();
    doc.apply(text_box(None, 0.0), 0).unwrap();
    doc.apply(
        Edit::AddShape {
            page: 0,
            kind: ShapeKind::Rectangle,
            rect: BOX,
            color: RED,
            fill: Some(YELLOW),
            width: 2.0,
        },
        1,
    )
    .unwrap();
    let info = only_text_box(&doc);
    assert_eq!(info.font_size, Some(12.0));
    assert_eq!(info.fill, None);
    assert_eq!(info.border_width, Some(0.0));
    let shape = doc
        .annotations()
        .into_iter()
        .find(|a| a.kind == AnnotationKind::Rectangle)
        .unwrap();
    assert_eq!(
        (shape.font_size, shape.fill, shape.border_width),
        (None, None, None)
    );
}

/// Text boxes other apps wrote: a gray text colour, a size and a border in `/Border`, a background
/// of one gray component, no size at all (the engine draws 12), a border style with no width (the
/// engine draws 1).
#[test]
fn text_boxes_written_elsewhere_report_what_the_engine_draws() {
    let doc = PdfDocument::open(
        fixtures::hand_annotated_doc(
            &[
                "<< /Type /Annot /Subtype /FreeText /Rect [100 600 300 640] /Contents (a) \
                 /DA (/Helv 9.5 Tf 0.5 g) /Border [0 0 2] /C [0.9] >>",
                "<< /Type /Annot /Subtype /FreeText /Rect [100 500 300 540] /Contents (b) \
                 /DA (0 0 1 rg) /BS << /S /S >> >>",
                "<< /Type /Annot /Subtype /FreeText /Rect [100 400 300 440] /Contents (c) \
                 /DA (/Helv 0 Tf) /BS << /W 3 >> /Border [0 0 7] /C [] >>",
            ],
            &[],
        ),
        None,
    )
    .unwrap();
    let list = doc.annotations();
    let by_text = |text: &str| {
        list.iter()
            .find(|a| a.contents.as_deref() == Some(text))
            .unwrap()
            .clone()
    };
    let a = by_text("a");
    assert_eq!(a.font_size, Some(9.5));
    assert_eq!(a.border_width, Some(2.0));
    assert_color_close(
        a.fill,
        RgbColor {
            red: 0.9,
            green: 0.9,
            blue: 0.9,
        },
    );
    let b = by_text("b");
    assert_eq!(b.font_size, Some(12.0), "no size: the engine's 12");
    assert_eq!(b.border_width, Some(1.0), "a border style with no width");
    assert_eq!(b.fill, None);
    let c = by_text("c");
    assert_eq!(c.font_size, Some(12.0), "a size of 0 is no size");
    assert_eq!(c.border_width, Some(3.0), "/BS before /Border");
    assert_eq!(c.fill, None, "an empty /C is no background");
}

#[test]
fn border_widths_are_checked() {
    let doc = one_page();
    for bad in [0.3, 12.5, -1.0, f64::NAN, f64::INFINITY] {
        assert!(
            matches!(
                doc.apply(text_box(None, bad), 0),
                Err(EditError::Invalid { .. })
            ),
            "{bad}"
        );
        assert!(
            matches!(
                doc.apply(restyle(0, 12.0, BLUE, None, bad), 0),
                Err(EditError::Invalid { .. })
            ),
            "{bad}"
        );
    }
    let bad_fill = RgbColor {
        red: f64::NAN,
        green: 0.0,
        blue: 0.0,
    };
    assert!(matches!(
        doc.apply(text_box(Some(bad_fill), 0.0), 0),
        Err(EditError::Invalid { .. })
    ));
    assert_eq!(doc.revision(), 0);
    for (i, good) in [0.0, 0.5, 12.0].into_iter().enumerate() {
        doc.apply(text_box(None, good), i as u64).unwrap();
    }
}

/// A box, then a rectangle after it on the page: the box is at place 0, the rectangle at 1.
fn box_then_rectangle() -> std::sync::Arc<PdfDocument> {
    let doc = one_page();
    doc.apply(text_box(None, 0.0), 0).unwrap();
    doc.apply(
        Edit::AddShape {
            page: 0,
            kind: ShapeKind::Rectangle,
            rect: Rect {
                x: 300.0,
                y: 300.0,
                width: 50.0,
                height: 50.0,
            },
            color: RED,
            fill: None,
            width: 2.0,
        },
        1,
    )
    .unwrap();
    doc
}

fn rectangle(doc: &PdfDocument) -> AnnotationInfo {
    doc.annotations()
        .into_iter()
        .find(|a| a.kind == AnnotationKind::Rectangle)
        .unwrap()
}

#[test]
fn a_new_colour_and_border_are_made_in_place_and_one_undo_takes_them_back() {
    let doc = box_then_rectangle();
    let before = only_text_box(&doc);
    assert_eq!(before.index, 0);
    let outcome = doc.apply(restyle(0, 12.0, RED, None, 2.0), 2).unwrap();
    assert_eq!(outcome.revision, 3);
    let after = only_text_box(&doc);
    assert_eq!(after.index, 0, "in place: the box keeps its place");
    assert_eq!(rectangle(&doc).index, 1);
    assert_eq!(after.font_size, Some(12.0));
    assert_color_close(after.color, RED);
    assert_eq!(after.border_width, Some(2.0));
    assert_eq!(after.contents.as_deref(), Some("Hello there"));
    doc.undo().unwrap();
    let undone = only_text_box(&doc);
    assert_color_close(undone.color, BLUE);
    assert_eq!(undone.border_width, Some(0.0));
    assert!(doc.can_undo(), "only the restyle was taken back");
}

#[test]
fn a_new_size_or_background_adds_the_box_again_and_one_undo_takes_it_back() {
    let doc = box_then_rectangle();
    let before = only_text_box(&doc);
    doc.apply(restyle(0, 24.0, BLUE, Some(PALE), 1.0), 2)
        .unwrap();
    let after = only_text_box(&doc);
    assert_eq!(after.index, 1, "added again, at the end of the page's list");
    assert_eq!(rectangle(&doc).index, 0);
    assert_eq!(after.font_size, Some(24.0));
    assert_color_close(after.color, BLUE);
    assert_color_close(after.fill, PALE);
    assert_eq!(after.border_width, Some(1.0));
    assert_eq!(after.contents.as_deref(), Some("Hello there"));
    // The top-left stays; the width grows with the text, so the lines break where they did, and the
    // height fits the text.
    assert!((after.rect.x - before.rect.x).abs() < 0.5, "{after:?}");
    assert!((after.rect.y - before.rect.y).abs() < 0.5, "{after:?}");
    assert!(after.rect.width > before.rect.width * 1.8, "{after:?}");
    assert!(after.rect.height >= 24.0 * 1.2, "{after:?}");
    doc.undo().unwrap();
    let undone = only_text_box(&doc);
    assert_eq!(undone.index, 0);
    assert_eq!(undone.font_size, Some(12.0));
    assert_eq!(undone.fill, None);
    assert_eq!(rectangle(&doc).index, 1);
    doc.redo().unwrap();
    assert_eq!(only_text_box(&doc).font_size, Some(24.0));
    let saved = reopen(doc.save(SaveMode::Incremental).unwrap(), None);
    let kept = only_text_box(&saved);
    assert_eq!(kept.font_size, Some(24.0));
    assert_color_close(kept.fill, PALE);
}

#[test]
fn taking_the_background_away_adds_the_box_again_without_one() {
    let doc = one_page();
    doc.apply(text_box(Some(PALE), 0.0), 0).unwrap();
    doc.apply(restyle(0, 12.0, BLUE, None, 0.0), 1).unwrap();
    let info = only_text_box(&doc);
    assert_eq!(info.fill, None);
    assert_eq!(info.contents.as_deref(), Some("Hello there"));
}

#[test]
fn the_author_and_the_text_written_elsewhere_are_kept_when_the_box_is_added_again() {
    let doc = PdfDocument::open(
        fixtures::hand_annotated_doc(
            &[
                "<< /Type /Annot /Subtype /FreeText /Rect [100 600 300 640] \
               /Contents (Two\\rlines) /T (Ada) /DA (/Helv 10 Tf 0 0 0 rg) >>",
            ],
            &[],
        ),
        None,
    )
    .unwrap();
    doc.apply(restyle(0, 14.0, RED, Some(PALE), 0.0), 0)
        .unwrap();
    let info = only_text_box(&doc);
    assert_eq!(info.author.as_deref(), Some("Ada"));
    assert_eq!(info.contents.as_deref(), Some("Two\nlines"));
    assert_eq!(info.font_size, Some(14.0));
}

#[test]
fn a_locked_box_is_not_restyled() {
    let doc = PdfDocument::open(fixtures::locked_markup_doc(), None).unwrap();
    let locked = only_text_box(&doc);
    assert!(locked.locked);
    for edit in [
        restyle(locked.index, 12.0, RED, None, 0.0),
        restyle(locked.index, 20.0, RED, Some(PALE), 1.0),
    ] {
        let refused = doc.apply(edit, 0);
        assert!(
            matches!(refused, Err(EditError::Invalid { .. })),
            "{refused:?}"
        );
    }
    assert_eq!(doc.revision(), 0);
}

#[test]
fn only_a_text_box_is_restyled_and_its_values_are_checked() {
    let doc = box_then_rectangle();
    let not_a_box = doc.apply(restyle(1, 12.0, RED, None, 0.0), 2);
    assert!(
        matches!(not_a_box, Err(EditError::Invalid { .. })),
        "{not_a_box:?}"
    );
    let nowhere = doc.apply(restyle(7, 12.0, RED, None, 0.0), 2);
    assert!(
        matches!(nowhere, Err(EditError::Invalid { .. })),
        "{nowhere:?}"
    );
    let no_page = doc.apply(
        Edit::RestyleTextBox {
            page: 4,
            index: 0,
            font_size: Some(12.0),
            color: RED,
            fill: None,
            border_width: Some(0.0),
        },
        2,
    );
    assert!(
        matches!(no_page, Err(EditError::Invalid { .. })),
        "{no_page:?}"
    );
    for size in [2.0, 200.0, f64::NAN] {
        assert!(matches!(
            doc.apply(restyle(0, size, RED, None, 0.0), 2),
            Err(EditError::Invalid { .. })
        ));
    }
    let not_a_colour = RgbColor {
        red: f64::INFINITY,
        green: 0.0,
        blue: 0.0,
    };
    assert!(matches!(
        doc.apply(restyle(0, 12.0, not_a_colour, None, 0.0), 2),
        Err(EditError::Invalid { .. })
    ));
    assert_eq!(doc.revision(), 2);
}

/// On a page shown turned, adding the box again would set its text upright in the file: only the
/// colour and the border are changed there.
#[test]
fn on_a_turned_page_only_the_colour_and_the_border_change() {
    let doc = PdfDocument::open(fixtures::rotated_doc("hello"), None).unwrap();
    doc.apply(text_box(None, 0.0), 0).unwrap();
    doc.apply(restyle(0, 12.0, RED, None, 1.0), 1).unwrap();
    assert_color_close(only_text_box(&doc).color, RED);
    let refused = doc.apply(restyle(0, 20.0, RED, None, 1.0), 2);
    assert!(
        matches!(refused, Err(EditError::Invalid { .. })),
        "{refused:?}"
    );
}

#[test]
fn a_step_with_a_restyle_follows_the_place_rules() {
    let doc = box_then_rectangle();
    // Adding the box again moves the places after it: nothing else may address that page's comments.
    let clash = doc.apply_all(
        "x".into(),
        vec![
            restyle(0, 20.0, RED, None, 0.0),
            Edit::SetAnnotationContents {
                page: 0,
                index: 1,
                contents: "y".into(),
            },
        ],
        2,
    );
    assert!(matches!(clash, Err(EditError::Invalid { .. })), "{clash:?}");
    let renumbered = doc.apply_all(
        "x".into(),
        vec![
            restyle(0, 20.0, RED, None, 0.0),
            Edit::DeletePages { pages: vec![0] },
        ],
        2,
    );
    assert!(
        matches!(renumbered, Err(EditError::Invalid { .. })),
        "{renumbered:?}"
    );
    assert_eq!(doc.revision(), 2);
    // Adding a comment to the page goes with it, and so does a delete followed by a new box (it is
    // placed by its box, not by a place in the list).
    doc.apply_all(
        "x".into(),
        vec![restyle(0, 20.0, RED, None, 0.0), text_box(None, 0.0)],
        2,
    )
    .unwrap();
    let rectangle_at = rectangle(&doc).index;
    doc.apply_all(
        "y".into(),
        vec![
            Edit::DeleteAnnotation {
                page: 0,
                index: rectangle_at,
            },
            text_box(Some(PALE), 1.0),
        ],
        3,
    )
    .unwrap();
    assert_eq!(doc.annotations().len(), 3);
}

/// A file's numbers are not trusted: a huge border, size, box or colour is held to a range, or the
/// restyle is refused, and nothing panics.
#[test]
fn hostile_numbers_in_a_text_box_are_bounded_and_never_panic() {
    let doc = PdfDocument::open(
        fixtures::hand_annotated_doc(
            &[
                "<< /Type /Annot /Subtype /FreeText /Rect [100 600 300 640] /Contents (a) \
                 /DA (/Helv 1e308 Tf 9e99 -5 0.5 rg) /BS << /W 1e308 >> /C [1e308 -1e308 0.5] >>",
                "<< /Type /Annot /Subtype /FreeText /Rect [-1e308 -1e308 1e308 1e308] /Contents (b) \
                 /DA (/Helv 12 Tf 0 g) /Border [0 0 99999999999999999999] >>",
            ],
            &[],
        ),
        None,
    )
    .unwrap();
    let list = doc.annotations();
    let a = list
        .iter()
        .find(|x| x.contents.as_deref() == Some("a"))
        .unwrap();
    assert_eq!(a.font_size, Some(400.0), "the engine's largest");
    assert_eq!(a.border_width, Some(144.0));
    let fill = a.fill.unwrap();
    assert_eq!((fill.red, fill.green, fill.blue), (1.0, 0.0, 0.5));
    let b = list
        .iter()
        .find(|x| x.contents.as_deref() == Some("b"))
        .unwrap();
    assert_eq!(b.border_width, Some(144.0));
    assert!(
        [b.rect.x, b.rect.y, b.rect.width, b.rect.height]
            .iter()
            .all(|n| n.is_finite()),
        "a huge /Rect is listed as a finite box: {:?}",
        b.rect
    );
    // Restyling either by adding it again: the first, held to its ranges, is made; the second, whose
    // box is far off any page, is refused; no panic.
    let first = doc.apply(restyle(a.index, 20.0, RED, Some(PALE), 1.0), 0);
    assert!(first.is_ok(), "{first:?}");
    let at = doc.revision();
    let b_index = doc
        .annotations()
        .into_iter()
        .find(|x| x.contents.as_deref() == Some("b"))
        .unwrap()
        .index;
    let second = doc.apply(restyle(b_index, 20.0, RED, Some(PALE), 1.0), at);
    assert!(
        matches!(second, Err(EditError::Invalid { .. })),
        "{second:?}"
    );
}

/// A restyle that changes nothing (the colour read back from the file in single precision, say) is
/// refused, so no empty step is made: no revision, nothing to undo.
#[test]
fn a_restyle_that_changes_nothing_makes_no_step() {
    let doc = one_page();
    let red = RgbColor {
        red: 0.9,
        green: 0.1,
        blue: 0.1,
    };
    doc.apply(
        Edit::AddTextBox {
            page: 0,
            rect: BOX,
            text: "Same".into(),
            font_size: 14.0,
            color: red,
            fill: Some(PALE),
            border_width: 1.0,
        },
        0,
    )
    .unwrap();
    let info = only_text_box(&doc);
    let read_back = info.color.unwrap();
    assert_ne!(read_back, red, "the file keeps it in single precision");
    for edit in [
        restyle(0, 14.0, red, Some(PALE), 1.0),
        restyle(0, 14.0, read_back, info.fill, 1.0),
        Edit::RestyleTextBox {
            page: 0,
            index: 0,
            font_size: None,
            color: red,
            fill: Some(PALE),
            border_width: None,
        },
    ] {
        let refused = doc.apply(edit, 1);
        assert!(
            matches!(refused, Err(EditError::Invalid { .. })),
            "{refused:?}"
        );
    }
    assert_eq!(doc.revision(), 1);
    doc.undo().unwrap();
    assert!(!doc.can_undo(), "only the box's add was on the history");
}

/// A colour alone changes in place and keeps what is not asked for as the file has it: a size the
/// apps could not give (300 points) and a border thinner than they offer (0.2 point).
#[test]
fn a_colour_alone_keeps_the_size_and_border_the_file_gave() {
    let doc = PdfDocument::open(
        fixtures::hand_annotated_doc(
            &[
                "<< /Type /Annot /Subtype /FreeText /Rect [100 300 500 700] /Contents (Big) \
               /DA (/Helv 300 Tf 0 0 0 rg) /BS << /W 0.2 >> >>",
            ],
            &[],
        ),
        None,
    )
    .unwrap();
    let before = only_text_box(&doc);
    assert_eq!(before.font_size, Some(300.0));
    assert_eq!(before.border_width, Some(0.2));
    doc.apply(
        Edit::RestyleTextBox {
            page: 0,
            index: 0,
            font_size: None,
            color: RED,
            fill: None,
            border_width: None,
        },
        0,
    )
    .unwrap();
    let after = only_text_box(&doc);
    assert_eq!(after.index, before.index, "in place");
    assert_eq!(after.font_size, Some(300.0));
    assert_eq!(after.border_width, Some(0.2));
    assert_eq!(after.rect, before.rect);
    assert_color_close(after.color, RED);
}

/// A box with replies, or whose text is all rich text, is not added again (that would lose them):
/// a new size or background is refused, the list says it can only be restyled in place, and a new
/// colour or border still works.
#[test]
fn a_box_a_re_add_would_lose_data_from_is_restyled_in_place_only() {
    let doc = PdfDocument::open(
        fixtures::hand_annotated_doc(
            &[
                "<< /Type /Annot /Subtype /FreeText /Rect [100 600 300 640] /Contents (Replied) \
                 /NM (box) /DA (/Helv 12 Tf 0 0 0 rg) >>",
                "<< /Type /Annot /Subtype /Text /Rect [100 600 120 620] /Contents (A reply) \
                 /IRT 4 0 R >>",
                "<< /Type /Annot /Subtype /FreeText /Rect [100 400 300 440] /Contents () \
                 /RC (<body><p>Rich</p></body>) /DA (/Helv 12 Tf 0 0 0 rg) >>",
                "<< /Type /Annot /Subtype /FreeText /Rect [100 200 300 240] /Contents (Plain) \
                 /DA (/Helv 12 Tf 0 0 0 rg) >>",
            ],
            &[],
        ),
        None,
    )
    .unwrap();
    let boxes: Vec<_> = doc
        .annotations()
        .into_iter()
        .filter(|a| a.kind == AnnotationKind::TextBox)
        .collect();
    let by_index = |i: u32| boxes.iter().find(|a| a.index == i).unwrap().clone();
    assert!(by_index(0).restyle_in_place_only, "replies");
    assert!(by_index(2).restyle_in_place_only, "all rich text");
    assert!(!by_index(3).restyle_in_place_only);
    for index in [0, 2] {
        let at = doc.revision();
        let refused = doc.apply(restyle(index, 20.0, BLUE, None, 0.0), at);
        assert!(
            matches!(refused, Err(EditError::Invalid { .. })),
            "{refused:?}"
        );
        let refused = doc.apply(restyle(index, 12.0, BLUE, Some(PALE), 0.0), at);
        assert!(
            matches!(refused, Err(EditError::Invalid { .. })),
            "{refused:?}"
        );
        doc.apply(restyle(index, 12.0, BLUE, None, 1.0), at)
            .unwrap();
    }
    assert_eq!(
        doc.annotations().len(),
        3,
        "the reply is still there, under its box"
    );
}

/// A comment's date is the file's own, with its time zone: `/M`, else `/CreationDate`.
#[test]
fn dates_are_the_files_own_with_their_time_zone() {
    let doc = PdfDocument::open(
        fixtures::hand_annotated_doc(
            &[
                "<< /Type /Annot /Subtype /Square /Rect [100 600 200 700] /M (D:20261021090500-05'00') >>",
                "<< /Type /Annot /Subtype /Square /Rect [100 400 200 500] \
                 /CreationDate (D:20261021160500+02'00') >>",
                "<< /Type /Annot /Subtype /Square /Rect [100 200 200 300] >>",
            ],
            &[],
        ),
        None,
    )
    .unwrap();
    let dates: Vec<_> = doc.annotations().into_iter().map(|a| a.modified).collect();
    assert_eq!(
        dates,
        vec![
            Some("D:20261021090500-05'00'".to_owned()),
            Some("D:20261021160500+02'00'".to_owned()),
            None,
        ]
    );
}

/// A page of many text boxes, each with a reply: every one is found to have replies, and the list
/// is read in linear time (one pass over the page's comments for their replies, not one per box).
#[test]
fn many_text_boxes_with_replies_are_listed_quickly_and_correctly() {
    const BOXES: usize = 1_500;
    let mut annots: Vec<String> = (0..BOXES)
        .map(|i| {
            format!(
                "<< /Type /Annot /Subtype /FreeText /Rect [100 {y} 300 {top}] /Contents (Box {i}) \
                 /DA (/Helv 12 Tf 0 0 0 rg) >>",
                y = 100 + i % 600,
                top = 120 + i % 600
            )
        })
        .collect();
    // A reply to every other box, and to none past them.
    annots.extend((0..BOXES).step_by(2).map(|i| {
        format!(
            "<< /Type /Annot /Subtype /Text /Rect [100 100 120 120] /Contents (Reply) /IRT {} 0 R >>",
            4 + i
        )
    }));
    let refs: Vec<&str> = annots.iter().map(String::as_str).collect();
    let doc = PdfDocument::open(fixtures::hand_annotated_doc(&refs, &[]), None).unwrap();
    let start = std::time::Instant::now();
    let boxes: Vec<_> = doc
        .annotations()
        .into_iter()
        .filter(|a| a.kind == AnnotationKind::TextBox)
        .collect();
    let took = start.elapsed();
    assert_eq!(boxes.len(), BOXES);
    for info in &boxes {
        assert_eq!(
            info.restyle_in_place_only,
            info.index % 2 == 0,
            "box at place {} (replies to every other box)",
            info.index
        );
    }
    // Loose: a pass per box over the page's 2,250 comments would be millions of reads.
    assert!(took.as_secs() < 5, "listing took {took:?}");
}
