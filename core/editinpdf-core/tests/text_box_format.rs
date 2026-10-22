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
        font_size,
        color,
        fill,
        border_width: border,
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
            font_size: 12.0,
            color: RED,
            fill: None,
            border_width: 0.0,
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
