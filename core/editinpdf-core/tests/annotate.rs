#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod fixtures;
mod support;

use editinpdf_core::{
    AnnotationKind, Edit, EditError, MarkupKind, PdfDocument, Point, Rect, RgbColor, SaveMode,
    ShapeKind,
};
use support::{BLUE, RED, YELLOW, assert_rect_close, reopen};

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

#[test]
fn ink_on_rotated_page_comes_back_where_drawn() {
    let doc = PdfDocument::open(fixtures::rotated_doc("x"), None).unwrap();
    let stroke = (0..=20)
        .map(|i| Point {
            x: 100.0 + 5.0 * i as f64,
            y: 100.0 + 2.5 * i as f64,
        })
        .collect();
    doc.apply(
        Edit::AddInk {
            page: 0,
            strokes: vec![stroke],
            color: BLUE,
            width: 2.0,
        },
        0,
    )
    .unwrap();
    let a = &reopen(doc.save(SaveMode::Incremental).unwrap(), None).annotations()[0];
    assert_eq!(a.kind, AnnotationKind::Ink);
    // The stroke spans (100, 100) to (200, 150) as shown; the drawing's box keeps a margin of
    // half the line width and a point more on each side, so the line is not clipped.
    assert_rect_close(&a.rect, &grown(&STROKE_SPAN, 2.0), 1.0);
}

const STROKE_SPAN: Rect = Rect {
    x: 100.0,
    y: 100.0,
    width: 100.0,
    height: 50.0,
};

/// `r` with `margin` points more on every side.
fn grown(r: &Rect, margin: f64) -> Rect {
    Rect {
        x: r.x - margin,
        y: r.y - margin,
        width: r.width + 2.0 * margin,
        height: r.height + 2.0 * margin,
    }
}

/// What each drawing tool adds comes back, after a save, over the place it was drawn on the page
/// as shown, on the plain, turned, upside-down and cropped-and-turned page alike.
#[test]
fn drawings_come_back_where_drawn_at_every_rotation() {
    let r = Rect {
        x: 120.0,
        y: 90.0,
        width: 150.0,
        height: 60.0,
    };
    for (bytes, rotation) in every_orientation().into_iter().zip([0, 90, 180, 270]) {
        let doc = PdfDocument::open(bytes, None).unwrap();
        let edits = vec![
            Edit::AddInk {
                page: 0,
                strokes: vec![
                    vec![Point { x: 120.0, y: 90.0 }, Point { x: 270.0, y: 150.0 }],
                    vec![Point { x: 200.0, y: 100.0 }],
                ],
                color: BLUE,
                width: 2.0,
            },
            Edit::AddSignature {
                page: 0,
                strokes: vec![vec![
                    Point { x: 120.0, y: 90.0 },
                    Point { x: 270.0, y: 150.0 },
                ]],
                color: BLUE,
                width: 2.0,
            },
            Edit::AddShape {
                page: 0,
                kind: ShapeKind::Rectangle,
                rect: r,
                color: RED,
                fill: None,
                width: 2.0,
            },
            Edit::AddShape {
                page: 0,
                kind: ShapeKind::Oval,
                rect: r,
                color: RED,
                fill: Some(YELLOW),
                width: 1.0,
            },
            Edit::AddTextBox {
                page: 0,
                rect: r,
                text: "Hi".into(),
                font_size: 12.0,
                color: BLUE,
            },
            Edit::AddLine {
                page: 0,
                from: Point { x: 120.0, y: 90.0 },
                to: Point { x: 270.0, y: 150.0 },
                arrow: true,
                color: RED,
                width: 2.0,
            },
        ];
        let count = edits.len();
        for (i, edit) in edits.into_iter().enumerate() {
            doc.apply(edit, i as u64).unwrap();
        }
        let list = reopen(doc.save(SaveMode::Incremental).unwrap(), None).annotations();
        assert_eq!(list.len(), count, "{rotation}: {list:?}");
        for a in &list {
            // Boxes are exactly what was drawn. Drawings (ink and signatures, 2 pt wide) keep a
            // margin of half their width and a point; the arrow (2 pt wide) one of half its width,
            // its head (6 + 3 × width) and a point.
            let margin = match a.kind {
                AnnotationKind::Ink => 2.0,
                AnnotationKind::Line => 14.0,
                _ => 0.0,
            };
            let want = grown(&r, margin);
            let close = [
                (a.rect.x, want.x),
                (a.rect.y, want.y),
                (a.rect.width, want.width),
                (a.rect.height, want.height),
            ]
            .iter()
            .all(|(got, want)| (got - want).abs() <= 0.5);
            assert!(
                close,
                "{rotation}: {:?} is at {:?}, not {want:?}",
                a.kind, a.rect
            );
        }
    }
}

#[test]
fn text_box_shapes_line_and_arrow_persist() {
    let doc = PdfDocument::open(fixtures::text_doc(&["x"]), None).unwrap();
    let r = Rect {
        x: 50.0,
        y: 60.0,
        width: 200.0,
        height: 40.0,
    };
    let edits = vec![
        Edit::AddTextBox {
            page: 0,
            rect: r,
            text: "Hi there".into(),
            font_size: 14.0,
            color: BLUE,
        },
        Edit::AddShape {
            page: 0,
            kind: ShapeKind::Rectangle,
            rect: r,
            color: RED,
            fill: None,
            width: 2.0,
        },
        Edit::AddShape {
            page: 0,
            kind: ShapeKind::Oval,
            rect: r,
            color: RED,
            fill: Some(YELLOW),
            width: 1.0,
        },
        Edit::AddLine {
            page: 0,
            from: Point { x: 10.0, y: 10.0 },
            to: Point { x: 110.0, y: 60.0 },
            arrow: true,
            color: RED,
            width: 2.0,
        },
    ];
    for (i, e) in edits.into_iter().enumerate() {
        doc.apply(e, i as u64).unwrap();
    }
    let list = reopen(doc.save(SaveMode::Incremental).unwrap(), None).annotations();
    let kinds: Vec<_> = list.iter().map(|a| a.kind.clone()).collect();
    for k in [
        AnnotationKind::TextBox,
        AnnotationKind::Rectangle,
        AnnotationKind::Oval,
        AnnotationKind::Line,
    ] {
        assert!(kinds.contains(&k), "{k:?}");
    }
    let text_box = list
        .iter()
        .find(|a| a.kind == AnnotationKind::TextBox)
        .unwrap();
    assert_eq!(text_box.contents.as_deref(), Some("Hi there"));
    assert_eq!(text_box.author.as_deref().unwrap_or_default(), "");
}

#[test]
fn move_is_a_view_space_offset_on_any_rotation() {
    for bytes in every_orientation() {
        let doc = PdfDocument::open(bytes, None).unwrap();
        let r = Rect {
            x: 100.0,
            y: 100.0,
            width: 50.0,
            height: 30.0,
        };
        doc.apply(
            Edit::AddShape {
                page: 0,
                kind: ShapeKind::Rectangle,
                rect: r,
                color: RED,
                fill: None,
                width: 1.0,
            },
            0,
        )
        .unwrap();
        let before = doc.annotations()[0].rect;
        doc.apply(
            Edit::MoveAnnotation {
                page: 0,
                index: doc.annotations()[0].index,
                dx: 40.0,
                dy: -20.0,
            },
            1,
        )
        .unwrap();
        let after = reopen(doc.save(SaveMode::Incremental).unwrap(), None).annotations()[0].rect;
        assert!(
            (after.x - before.x - 40.0).abs() < 0.5
                && (after.y - before.y + 20.0).abs() < 0.5
                && (after.width - before.width).abs() < 0.5
                && (after.height - before.height).abs() < 0.5,
            "{before:?} → {after:?}"
        );
    }
}

#[test]
fn degenerate_drawings_are_invalid() {
    let doc = PdfDocument::open(fixtures::text_doc(&["x"]), None).unwrap();
    assert!(matches!(
        doc.apply(
            Edit::AddInk {
                page: 0,
                strokes: vec![vec![]],
                color: RED,
                width: 2.0
            },
            0
        ),
        Err(EditError::Invalid { .. })
    ));
    assert!(matches!(
        doc.apply(
            Edit::AddTextBox {
                page: 0,
                rect: Rect {
                    x: 0.0,
                    y: 0.0,
                    width: 0.0,
                    height: 10.0
                },
                text: "a".into(),
                font_size: 12.0,
                color: RED
            },
            0
        ),
        Err(EditError::Invalid { .. })
    ));
    assert!(matches!(
        doc.apply(
            Edit::AddInk {
                page: 0,
                strokes: vec![vec![Point { x: 1.0, y: 1.0 }]],
                color: RED,
                width: 0.0
            },
            0
        ),
        Err(EditError::Invalid { .. })
    ));
}

#[test]
fn drawings_out_of_bounds_are_invalid() {
    let doc = PdfDocument::open(fixtures::text_doc(&["x"]), None).unwrap();
    let invalid = |edit: Edit| {
        let result = doc.apply(edit.clone(), 0);
        assert!(
            matches!(result, Err(EditError::Invalid { .. })),
            "{edit:?}: {result:?}"
        );
    };
    let p = Point { x: 10.0, y: 10.0 };
    let r = Rect {
        x: 10.0,
        y: 10.0,
        width: 50.0,
        height: 50.0,
    };
    let ink = |strokes: Vec<Vec<Point>>, width: f64| Edit::AddInk {
        page: 0,
        strokes,
        color: RED,
        width,
    };
    invalid(ink(vec![], 2.0));
    invalid(ink(vec![vec![p; 10_001]], 2.0));
    invalid(ink(vec![vec![p]; 501], 2.0));
    invalid(ink(vec![vec![p]], 0.09));
    invalid(ink(vec![vec![p]], 50.1));
    invalid(ink(vec![vec![p]], f64::NAN));
    invalid(ink(
        vec![vec![
            p,
            Point {
                x: f64::INFINITY,
                y: 1.0,
            },
        ]],
        2.0,
    ));
    invalid(Edit::AddSignature {
        page: 0,
        strokes: vec![vec![], vec![]],
        color: RED,
        width: 2.0,
    });
    invalid(Edit::AddInk {
        page: 1,
        strokes: vec![vec![p]],
        color: RED,
        width: 2.0,
    });
    let text_box = |rect: Rect, font_size: f64| Edit::AddTextBox {
        page: 0,
        rect,
        text: "a".into(),
        font_size,
        color: RED,
    };
    invalid(text_box(r, 3.9));
    invalid(text_box(r, 144.1));
    invalid(text_box(r, f64::NAN));
    invalid(text_box(Rect { height: 0.9, ..r }, 12.0));
    let shape = |rect: Rect, fill: Option<RgbColor>, width: f64| Edit::AddShape {
        page: 0,
        kind: ShapeKind::Oval,
        rect,
        color: RED,
        fill,
        width,
    };
    invalid(shape(Rect { width: 0.5, ..r }, None, 2.0));
    invalid(shape(Rect { x: f64::NAN, ..r }, None, 2.0));
    invalid(shape(r, None, 51.0));
    invalid(shape(
        r,
        Some(RgbColor {
            red: f64::NAN,
            green: 0.0,
            blue: 0.0,
        }),
        2.0,
    ));
    let line = |to: Point, width: f64| Edit::AddLine {
        page: 0,
        from: p,
        to,
        arrow: false,
        color: RED,
        width,
    };
    invalid(line(p, 2.0));
    invalid(line(
        Point {
            x: 10.0,
            y: f64::NAN,
        },
        2.0,
    ));
    invalid(line(Point { x: 100.0, y: 10.0 }, 0.0));
    let moved = |dx: f64, dy: f64| Edit::MoveAnnotation {
        page: 0,
        index: 0,
        dx,
        dy,
    };
    invalid(moved(1.0, 1.0)); // the page has no comment
    assert_eq!(doc.revision(), 0, "nothing changed");
    doc.apply(shape(r, None, 2.0), 0).unwrap();
    let doc_invalid = |edit: Edit| {
        let result = doc.apply(edit.clone(), 1);
        assert!(
            matches!(result, Err(EditError::Invalid { .. })),
            "{edit:?}: {result:?}"
        );
    };
    doc_invalid(moved(f64::NAN, 1.0));
    doc_invalid(moved(1.0, f64::INFINITY));
    doc_invalid(Edit::MoveAnnotation {
        page: 1,
        index: 0,
        dx: 1.0,
        dy: 1.0,
    });
    assert_eq!(doc.revision(), 1, "nothing changed");
}

#[test]
fn a_step_cannot_both_change_pages_and_draw_or_move() {
    let doc = PdfDocument::open(fixtures::text_doc(&["one", "two"]), None).unwrap();
    let r = Rect {
        x: 10.0,
        y: 10.0,
        width: 50.0,
        height: 50.0,
    };
    doc.apply(
        Edit::AddShape {
            page: 0,
            kind: ShapeKind::Rectangle,
            rect: r,
            color: RED,
            fill: None,
            width: 2.0,
        },
        0,
    )
    .unwrap();
    let p = Point { x: 10.0, y: 10.0 };
    let q = Point { x: 60.0, y: 60.0 };
    let drawing = [
        Edit::AddInk {
            page: 0,
            strokes: vec![vec![p, q]],
            color: RED,
            width: 2.0,
        },
        Edit::AddSignature {
            page: 0,
            strokes: vec![vec![p, q]],
            color: RED,
            width: 2.0,
        },
        Edit::AddTextBox {
            page: 0,
            rect: r,
            text: "a".into(),
            font_size: 12.0,
            color: RED,
        },
        Edit::AddShape {
            page: 0,
            kind: ShapeKind::Oval,
            rect: r,
            color: RED,
            fill: None,
            width: 2.0,
        },
        Edit::AddLine {
            page: 0,
            from: p,
            to: q,
            arrow: false,
            color: RED,
            width: 2.0,
        },
        Edit::MoveAnnotation {
            page: 0,
            index: 0,
            dx: 5.0,
            dy: 5.0,
        },
    ];
    for edit in &drawing {
        let rotate = Edit::RotatePages {
            pages: vec![0],
            degrees: 90,
        };
        let result = doc.apply_all("x".into(), vec![rotate, edit.clone()], 1);
        assert!(
            matches!(result, Err(EditError::Invalid { .. })),
            "{edit:?}: {result:?}"
        );
    }
    // A move also addresses a comment by its place, which renumbering pages changes.
    let result = doc.apply_all(
        "x".into(),
        vec![
            Edit::MovePages {
                pages: vec![1],
                to: 0,
            },
            drawing[5].clone(),
        ],
        1,
    );
    assert!(
        matches!(result, Err(EditError::Invalid { .. })),
        "{result:?}"
    );
    assert_eq!(doc.revision(), 1, "nothing changed");
    // Drawing and moving together, without a page change, is one step.
    let ok = doc.apply_all("Draw".into(), drawing.to_vec(), 1);
    assert!(ok.is_ok(), "{ok:?}");
    assert_eq!(doc.annotations().len(), 6);
}
