//! What the apps need to take a highlight, underline or strikethrough off part of the text it covers:
//! the boxes of each mark's lines (`AnnotationInfo::quads`), and one step that deletes the mark and adds
//! back the parts of it that stay, in the mark's colour, opacity and text (`Edit::AddTextMarkup`'s
//! `opacity_of`).

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod fixtures;
mod support;

use editinpdf_core::{AnnotationKind, Edit, EditError, MarkupKind, PdfDocument, Rect, SaveMode};
use support::{RED, assert_rect_close, reopen};

/// The view-space boxes of glyphs `start..end` of page 0, one for each line.
fn line_boxes(doc: &PdfDocument, start: u32, end: u32) -> Vec<Rect> {
    doc.select_range(0, start, end).unwrap().rects
}

fn underline(rects: Vec<Rect>, opacity_of: Option<u32>, contents: &str) -> Edit {
    Edit::AddTextMarkup {
        page: 0,
        kind: MarkupKind::Underline,
        rects,
        color: RED,
        contents: contents.to_owned(),
        opacity_of,
    }
}

#[test]
fn a_marks_quads_are_listed_where_its_lines_are() {
    for bytes in [
        fixtures::text_doc(&["First line\nSecond line"]),
        fixtures::rotated_doc("hello world"),
    ] {
        let doc = PdfDocument::open(bytes, None).unwrap();
        let count = doc.page_text(0).unwrap().glyphs.len() as u32;
        let lines = line_boxes(&doc, 0, count);
        doc.apply(underline(lines.clone(), None, ""), 0).unwrap();
        doc.apply(
            Edit::AddNote {
                page: 0,
                at: editinpdf_core::Point { x: 300.0, y: 300.0 },
                contents: String::new(),
                color: RED,
            },
            1,
        )
        .unwrap();
        let list = doc.annotations();
        let mark = list
            .iter()
            .find(|a| a.kind == AnnotationKind::Underline)
            .unwrap();
        assert_eq!(mark.quads.len(), lines.len(), "one quad for each line");
        for (quad, line) in mark.quads.iter().zip(&lines) {
            assert_rect_close(quad, line, 0.5);
        }
        let note = list
            .iter()
            .find(|a| a.kind == AnnotationKind::Note)
            .unwrap();
        assert!(note.quads.is_empty(), "a note has no quads");
    }
}

#[test]
fn hostile_quads_are_finite_held_and_listed_all_or_none() {
    let many = "10 700 20 700 10 690 20 690 ".repeat(10_001);
    let doc = PdfDocument::open(
        fixtures::hand_annotated_doc(
            &[
                // Past single precision (infinite once narrowed), past the listed reach, and nine
                // numbers: two quads, the second of one number, which is no quad.
                "<< /Type /Annot /Subtype /Underline /Rect [0 0 10 10] \
                 /QuadPoints [1e39 700 -1e39 700 1e30 -1e30 5 5 7] >>",
                &format!(
                    "<< /Type /Annot /Subtype /Highlight /Rect [0 0 10 10] /QuadPoints [{many}] >>"
                ),
                "<< /Type /Annot /Subtype /StrikeOut /Rect [0 0 10 10] /QuadPoints 5 >>",
            ],
            &[],
        ),
        None,
    )
    .unwrap();
    let list = doc.annotations();
    let hostile = list
        .iter()
        .find(|a| a.kind == AnnotationKind::Underline)
        .unwrap();
    assert_eq!(hostile.quads.len(), 1, "{:?}", hostile.quads);
    for quad in &hostile.quads {
        for n in [quad.x, quad.y, quad.width, quad.height] {
            assert!(n.is_finite() && n.abs() <= 1.0e6, "{quad:?}");
        }
        assert!(quad.width >= 0.0 && quad.height >= 0.0, "{quad:?}");
    }
    let long = list
        .iter()
        .find(|a| a.kind == AnnotationKind::Highlight)
        .unwrap();
    assert!(
        long.quads.is_empty(),
        "a mark of more than 10,000 quads is listed with none, never with some"
    );
    let none = list
        .iter()
        .find(|a| a.kind == AnnotationKind::StrikeOut)
        .unwrap();
    assert!(none.quads.is_empty());
}

/// A mark over "First line" made shorter by "line": one step deletes it and adds "First" back, in its
/// colour and with its text, and one undo puts the whole mark back.
#[test]
fn a_mark_is_split_in_one_step_and_one_undo_restores_it() {
    let doc = PdfDocument::open(fixtures::text_doc(&["First line"]), None).unwrap();
    let whole = line_boxes(&doc, 0, 10);
    doc.apply(underline(whole.clone(), None, "note"), 0)
        .unwrap();
    let mark = doc.annotations().remove(0);
    let first = line_boxes(&doc, 0, 5);
    let outcome = doc
        .apply_all(
            "Remove Underline".to_owned(),
            vec![
                Edit::DeleteAnnotations {
                    page: 0,
                    indices: vec![mark.index],
                },
                underline(first.clone(), Some(mark.index), "note"),
            ],
            1,
        )
        .unwrap();
    assert_eq!(outcome.revision, 2);
    let list = doc.annotations();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].contents.as_deref(), Some("note"));
    assert_eq!(list[0].color, mark.color);
    assert_eq!(list[0].quads.len(), 1);
    assert_rect_close(&list[0].quads[0], &first[0], 0.5);
    doc.undo().unwrap();
    let list = doc.annotations();
    assert_eq!(list.len(), 1, "one undo takes the whole step back");
    assert_rect_close(&list[0].quads[0], &whole[0], 0.5);
    assert!(!doc.can_undo() || doc.undo().is_ok());
    assert!(doc.annotations().is_empty(), "the mark was the step before");
}

/// The pieces of a mark take its opacity (`/CA`), read from the file as it is before the step.
#[test]
fn a_piece_takes_the_opacity_of_the_mark_it_is_cut_from() {
    let doc = PdfDocument::open(
        fixtures::hand_annotated_doc(
            &[
                "<< /Type /Annot /Subtype /Underline /Rect [70 700 200 715] /C [0 0 1] /CA 0.25 \
               /QuadPoints [72 715 200 715 72 700 200 700] >>",
            ],
            &[],
        ),
        None,
    )
    .unwrap();
    let piece = vec![Rect {
        x: 72.0,
        y: 77.0,
        width: 40.0,
        height: 15.0,
    }];
    doc.apply_all(
        "Remove Underline".to_owned(),
        vec![
            Edit::DeleteAnnotations {
                page: 0,
                indices: vec![0],
            },
            underline(piece.clone(), Some(0), ""),
            underline(piece, None, ""),
        ],
        0,
    )
    .unwrap();
    let saved = doc.save(SaveMode::Full).unwrap();
    let cos = pdfcraft_cos::Document::open_with_password(std::sync::Arc::new(saved.clone()), None)
        .unwrap();
    let pages = pdfcraft_annot::page_refs(&cos).unwrap();
    let page = cos.get(pages[0]);
    let annots = cos.resolve(page.as_dict().unwrap().get(b"Annots").unwrap());
    let opacities: Vec<Option<f64>> = annots
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| {
            let annot = cos.resolve(entry);
            annot
                .as_dict()
                .unwrap()
                .get(b"CA")
                .and_then(|ca| cos.resolve(ca).as_f64())
        })
        .collect();
    assert_eq!(opacities, vec![Some(0.25), None], "{opacities:?}");
    assert_eq!(reopen(saved, None).annotations().len(), 2);
}

#[test]
fn opacity_of_a_comment_that_is_not_there_is_invalid() {
    let doc = PdfDocument::open(fixtures::text_doc(&["First line"]), None).unwrap();
    let rects = line_boxes(&doc, 0, 5);
    let added = doc.apply(underline(rects, Some(3), ""), 0);
    assert!(matches!(added, Err(EditError::Invalid { .. })), "{added:?}");
    assert_eq!(doc.revision(), 0);
}

/// A mark another comment replies to says so (`has_replies`): deleting it deletes the reply. A comment
/// no one replies to does not.
#[test]
fn a_mark_with_replies_says_so() {
    let doc = PdfDocument::open(
        fixtures::hand_annotated_doc(
            &[
                "<< /Type /Annot /Subtype /Highlight /Rect [70 700 200 715] /NM (h) \
                 /QuadPoints [72 715 200 715 72 700 200 700] >>",
                "<< /Type /Annot /Subtype /Text /Rect [100 600 120 620] /Contents (re) /IRT 4 0 R >>",
                "<< /Type /Annot /Subtype /Underline /Rect [70 500 200 515] /NM (u) \
                 /QuadPoints [72 515 200 515 72 500 200 500] >>",
            ],
            &[],
        ),
        None,
    )
    .unwrap();
    let list = doc.annotations();
    assert_eq!(
        list.len(),
        2,
        "the reply is not listed on its own: {list:?}"
    );
    let highlight = list
        .iter()
        .find(|a| a.kind == AnnotationKind::Highlight)
        .unwrap();
    let underline = list
        .iter()
        .find(|a| a.kind == AnnotationKind::Underline)
        .unwrap();
    assert!(highlight.has_replies);
    assert!(!underline.has_replies);
}
