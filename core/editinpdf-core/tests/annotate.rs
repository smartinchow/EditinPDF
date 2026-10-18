#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod fixtures;
mod support;

use editinpdf_core::{
    AnnotationKind, Edit, EditError, MarkupKind, PdfDocument, Point, Rect, RgbColor, SaveMode,
};
use support::{RED, YELLOW, assert_rect_close, reopen};

/// The plain page, the page turned a quarter, the page turned upside down, and the cropped page
/// turned three quarters.
fn every_orientation() -> [Vec<u8>; 4] {
    [
        fixtures::text_doc(&["hello world"]),
        fixtures::rotated_doc("hello world"),
        fixtures::upside_down_doc("hello world"),
        fixtures::cropped_rotated_doc("hello world"),
    ]
}

#[test]
fn highlight_on_rotated_page_comes_back_where_drawn() {
    for (bytes, rotation) in every_orientation().into_iter().zip([0, 90, 180, 270]) {
        let doc = PdfDocument::open(bytes, None).unwrap();
        assert_eq!(doc.page_info(0).unwrap().rotation_degrees, rotation);
        let sel = doc.select_range(0, 0, 5).unwrap(); // "hello"
        doc.apply(
            Edit::AddTextMarkup {
                page: 0,
                kind: MarkupKind::Highlight,
                rects: sel.rects.clone(),
                color: RgbColor {
                    red: 1.0,
                    green: 0.9,
                    blue: 0.0,
                },
                contents: String::new(),
            },
            0,
        )
        .unwrap();
        let back = reopen(doc.save(SaveMode::Incremental).unwrap(), None);
        let a = &back.annotations()[0];
        assert_eq!(a.kind, AnnotationKind::Highlight);
        assert_rect_close(&a.rect, &sel.rects[0], 2.0);
        assert_eq!(
            a.author.as_deref().unwrap_or_default(),
            "",
            "no personal data"
        );
        let color = a.color.unwrap();
        assert!((color.green - 0.9).abs() < 0.01, "{color:?}");
    }
}

#[test]
fn note_comes_back_where_tapped_at_every_rotation() {
    for bytes in every_orientation() {
        let doc = PdfDocument::open(bytes, None).unwrap();
        doc.apply(
            Edit::AddNote {
                page: 0,
                at: Point { x: 300.0, y: 200.0 },
                contents: "check".into(),
                color: YELLOW,
            },
            0,
        )
        .unwrap();
        let back = reopen(doc.save(SaveMode::Incremental).unwrap(), None);
        let n = &back.annotations()[0];
        assert_eq!(n.kind, AnnotationKind::Note);
        assert_rect_close(
            &n.rect,
            &Rect {
                x: 300.0,
                y: 200.0,
                width: 20.0,
                height: 20.0,
            },
            1.0,
        );
        assert_eq!(n.contents.as_deref(), Some("check"));
    }
}

#[test]
fn note_markup_kinds_contents_and_delete() {
    let doc = PdfDocument::open(fixtures::rotated_doc("hello world"), None).unwrap();
    doc.apply(
        Edit::AddNote {
            page: 0,
            at: Point { x: 300.0, y: 200.0 },
            contents: "check".into(),
            color: YELLOW,
        },
        0,
    )
    .unwrap();
    let n = doc
        .annotations()
        .into_iter()
        .find(|a| a.kind == AnnotationKind::Note)
        .unwrap();
    assert_rect_close(
        &n.rect,
        &Rect {
            x: 300.0,
            y: 200.0,
            width: 20.0,
            height: 20.0,
        },
        1.0,
    );
    doc.apply(
        Edit::SetAnnotationContents {
            page: 0,
            index: n.index,
            contents: "done".into(),
        },
        1,
    )
    .unwrap();
    for (i, kind) in [MarkupKind::Underline, MarkupKind::StrikeOut]
        .into_iter()
        .enumerate()
    {
        let sel = doc.select_range(0, 6, 11).unwrap();
        doc.apply(
            Edit::AddTextMarkup {
                page: 0,
                kind,
                rects: sel.rects,
                color: RED,
                contents: String::new(),
            },
            2 + i as u64,
        )
        .unwrap();
    }
    let back = reopen(doc.save(SaveMode::Incremental).unwrap(), None);
    let list = back.annotations();
    assert_eq!(list.len(), 3);
    assert_eq!(
        list.iter()
            .find(|a| a.kind == AnnotationKind::Note)
            .unwrap()
            .contents
            .as_deref(),
        Some("done")
    );
    for kind in [AnnotationKind::Underline, AnnotationKind::StrikeOut] {
        assert!(list.iter().any(|a| a.kind == kind), "{kind:?} is listed");
    }
    doc.apply(
        Edit::DeleteAnnotation {
            page: 0,
            index: n.index,
        },
        4,
    )
    .unwrap();
    assert_eq!(doc.annotations().len(), 2);
    doc.undo().unwrap();
    assert_eq!(doc.annotations().len(), 3);
}

#[test]
fn annotations_are_listed_top_to_bottom() {
    let doc = PdfDocument::open(fixtures::text_doc(&["one", "two"]), None).unwrap();
    for (revision, (page, y)) in [(1, 400.0), (0, 500.0), (0, 100.0)].into_iter().enumerate() {
        doc.apply(
            Edit::AddNote {
                page,
                at: Point { x: 50.0, y },
                contents: String::new(),
                color: YELLOW,
            },
            revision as u64,
        )
        .unwrap();
    }
    let order: Vec<(u32, f64)> = doc
        .annotations()
        .iter()
        .map(|a| (a.page, a.rect.y.round()))
        .collect();
    assert_eq!(order, vec![(0, 100.0), (0, 500.0), (1, 400.0)]);
}

#[test]
fn bad_annotation_edits_are_invalid() {
    let doc = PdfDocument::open(fixtures::text_doc(&["x"]), None).unwrap();
    let invalid = |edit: Edit| {
        let result = doc.apply(edit.clone(), 0);
        assert!(
            matches!(result, Err(EditError::Invalid { .. })),
            "{edit:?}: {result:?}"
        );
    };
    invalid(Edit::DeleteAnnotation { page: 0, index: 0 });
    invalid(Edit::SetAnnotationContents {
        page: 0,
        index: 0,
        contents: "x".into(),
    });
    invalid(Edit::AddTextMarkup {
        page: 0,
        kind: MarkupKind::Highlight,
        rects: vec![],
        color: YELLOW,
        contents: String::new(),
    });
    invalid(Edit::AddTextMarkup {
        page: 0,
        kind: MarkupKind::Highlight,
        rects: vec![Rect {
            x: 1.0,
            y: f64::INFINITY,
            width: 1.0,
            height: 1.0,
        }],
        color: YELLOW,
        contents: String::new(),
    });
    invalid(Edit::AddNote {
        page: 0,
        at: Point {
            x: f64::NAN,
            y: 0.0,
        },
        contents: String::new(),
        color: YELLOW,
    });
    invalid(Edit::AddNote {
        page: 0,
        at: Point { x: 1.0, y: 1.0 },
        contents: String::new(),
        color: RgbColor {
            red: f64::NAN,
            green: 0.0,
            blue: 0.0,
        },
    });
    invalid(Edit::AddNote {
        page: 1,
        at: Point { x: 1.0, y: 1.0 },
        contents: String::new(),
        color: YELLOW,
    });
    assert_eq!(doc.revision(), 0, "nothing changed");
}

#[test]
fn a_step_cannot_both_change_pages_and_place_an_annotation() {
    let doc = PdfDocument::open(fixtures::text_doc(&["x"]), None).unwrap();
    let result = doc.apply_all(
        "x".into(),
        vec![
            Edit::RotatePages {
                pages: vec![0],
                degrees: 90,
            },
            Edit::AddNote {
                page: 0,
                at: Point { x: 1.0, y: 1.0 },
                contents: String::new(),
                color: YELLOW,
            },
        ],
        0,
    );
    assert!(
        matches!(result, Err(EditError::Invalid { .. })),
        "{result:?}"
    );
    assert_eq!(doc.revision(), 0);
    assert_eq!(doc.page_info(0).unwrap().rotation_degrees, 0);
    let ok = doc.apply_all(
        "y".into(),
        vec![Edit::AddNote {
            page: 0,
            at: Point { x: 1.0, y: 1.0 },
            contents: String::new(),
            color: YELLOW,
        }],
        0,
    );
    assert!(ok.is_ok(), "{ok:?}");
    // Deleting a comment carries no position, so it can go with a page change.
    let mixed = doc.apply_all(
        "z".into(),
        vec![
            Edit::DeleteAnnotation { page: 0, index: 0 },
            Edit::RotatePages {
                pages: vec![0],
                degrees: 90,
            },
        ],
        1,
    );
    assert!(mixed.is_ok(), "{mixed:?}");
    assert!(doc.annotations().is_empty());
}

#[test]
fn a_step_cannot_both_renumber_pages_and_address_a_comment() {
    let doc = PdfDocument::open(fixtures::text_doc(&["one", "two"]), None).unwrap();
    for page in [0, 1] {
        doc.apply(
            Edit::AddNote {
                page,
                at: Point { x: 50.0, y: 50.0 },
                contents: String::new(),
                color: YELLOW,
            },
            u64::from(page),
        )
        .unwrap();
    }
    let renumbering = [
        Edit::DeletePages { pages: vec![0] },
        Edit::MovePages {
            pages: vec![1],
            to: 0,
        },
        Edit::InsertBlankPage {
            at: 0,
            width_pt: 100.0,
            height_pt: 100.0,
        },
        Edit::InsertPagesFrom {
            name: "x.pdf".into(),
            bytes: fixtures::text_doc(&["x"]),
            pages: None,
            at: 0,
        },
    ];
    let addressing = [
        Edit::DeleteAnnotation { page: 0, index: 0 },
        Edit::SetAnnotationContents {
            page: 0,
            index: 0,
            contents: "x".into(),
        },
    ];
    for pages in &renumbering {
        for comment in &addressing {
            let result = doc.apply_all("x".into(), vec![pages.clone(), comment.clone()], 2);
            assert!(
                matches!(result, Err(EditError::Invalid { .. })),
                "{pages:?} + {comment:?}: {result:?}"
            );
        }
    }
    assert_eq!(doc.revision(), 2, "nothing changed");
    assert_eq!(doc.page_count(), 2);
    assert_eq!(doc.annotations().len(), 2);
}
