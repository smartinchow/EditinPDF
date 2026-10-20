//! Deleting several comments of a page in one change (`Edit::DeleteAnnotations`), on files whose
//! `/Annots` lists a comment's pop-up or replies before other comments: the order files made
//! elsewhere can have, which the engine never writes.

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod fixtures;
mod support;

use std::sync::Arc;

use editinpdf_core::{Edit, EditError, PdfDocument, Point, SaveMode};
use support::YELLOW;

/// `/Annots [4 5 6 7]`: 4 is note 6's pop-up, listed before it; 5 is note "B"; 6 is note "A", whose
/// pop-up 4 is; 7 is the widget of the form's text field `w`. The apps list only B (index 1) and A
/// (index 2). `lock_b` locks B (`/F 128`).
fn popup_first(lock_b: bool) -> Vec<u8> {
    let b = if lock_b {
        "<< /Type /Annot /Subtype /Text /Rect [100 700 120 720] /Contents (B) /NM (b) /F 128 >>"
    } else {
        "<< /Type /Annot /Subtype /Text /Rect [100 700 120 720] /Contents (B) /NM (b) >>"
    };
    fixtures::hand_annotated_doc(
        &[
            "<< /Type /Annot /Subtype /Popup /Rect [300 600 450 700] /Parent 6 0 R >>",
            b,
            "<< /Type /Annot /Subtype /Text /Rect [100 500 120 520] /Contents (A) /NM (a) /Popup 4 0 R >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (w) /Rect [100 100 300 120] /P 3 0 R >>",
        ],
        &[7],
    )
}

/// `/Annots [4 5 6 7 8]`: 4 is a reply (`/IRT`) to note 6, listed before it; 5 is a rectangle; 6 is
/// the note, which has no `/NM`, so its replies are not known as replies and are listed as comments
/// of their own; 7 is another reply to 6, listed after it; 8 is a link. The apps list 4, 5, 6 and 7
/// (indexes 0 to 3). `lock_reply` locks the reply after the note (`/F 128`).
fn replies_around(lock_reply: bool) -> Vec<u8> {
    let after = if lock_reply {
        "<< /Type /Annot /Subtype /Text /Rect [100 400 120 420] /Contents (after) /IRT 6 0 R /F 128 >>"
    } else {
        "<< /Type /Annot /Subtype /Text /Rect [100 400 120 420] /Contents (after) /IRT 6 0 R >>"
    };
    fixtures::hand_annotated_doc(
        &[
            "<< /Type /Annot /Subtype /Text /Rect [100 700 120 720] /Contents (before) /IRT 6 0 R >>",
            "<< /Type /Annot /Subtype /Square /Rect [200 600 260 660] /Contents (C) >>",
            "<< /Type /Annot /Subtype /Text /Rect [100 500 120 520] /Contents (P) >>",
            after,
            "<< /Type /Annot /Subtype /Link /Rect [100 100 300 120] /Border [0 0 0] \
             /A << /S /URI /URI (https://example.com/) >> >>",
        ],
        &[],
    )
}

/// The object numbers of page 0's `/Annots` entries, in order, as `doc` is now (what an incremental
/// save of it writes). Empty when the page lists none.
fn annots(doc: &PdfDocument) -> Vec<u32> {
    let bytes = doc.save(SaveMode::Incremental).unwrap();
    let cos = pdfcraft_cos::Document::open(Arc::new(bytes)).unwrap();
    let page = pdfcraft_annot::page_refs(&cos).unwrap()[0];
    let Some(list) = cos
        .get(page)
        .as_dict()
        .and_then(|d| d.get(b"Annots").cloned())
    else {
        return Vec::new();
    };
    cos.resolve(&list)
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| entry.as_ref().expect("every entry is a reference").num)
        .collect()
}

/// The indexes of the comments the apps list on page 0, in order.
fn listed(doc: &PdfDocument) -> Vec<u32> {
    let mut indices: Vec<u32> = doc.annotations().iter().map(|a| a.index).collect();
    indices.sort_unstable();
    indices
}

fn delete(indices: &[u32]) -> Edit {
    Edit::DeleteAnnotations {
        page: 0,
        indices: indices.to_vec(),
    }
}

#[test]
fn comments_whose_pop_up_is_listed_first_are_deleted_and_nothing_else() {
    let doc = PdfDocument::open(popup_first(false), None).unwrap();
    assert_eq!(
        listed(&doc),
        vec![1, 2],
        "B and A; not the pop-up, nor the widget"
    );
    assert_eq!(doc.form_fields().len(), 1);

    let out = doc.apply(delete(&[2, 1]), 0).unwrap();
    assert_eq!(out.revision, 1, "one change");
    assert_eq!(
        annots(&doc),
        vec![7],
        "A, its pop-up and B are gone; the widget stays"
    );
    assert!(doc.annotations().is_empty());
    assert_eq!(doc.form_fields()[0].name, "w", "the field keeps its widget");

    // One step: one undo brings back all three, and there is nothing before it.
    doc.undo().unwrap();
    assert_eq!(annots(&doc), vec![4, 5, 6, 7]);
    assert!(!doc.can_undo());

    // The same in a step of its own, with an index given twice, in any order.
    let out = doc
        .apply_all("Erase".into(), vec![delete(&[1, 2, 2])], 2)
        .unwrap();
    assert_eq!(out.revision, 3);
    assert_eq!(annots(&doc), vec![7]);
    doc.undo().unwrap();
    assert_eq!(annots(&doc), vec![4, 5, 6, 7]);
}

#[test]
fn replies_listed_before_and_after_go_with_their_comment_and_nothing_else() {
    let doc = PdfDocument::open(replies_around(false), None).unwrap();
    assert_eq!(
        listed(&doc),
        vec![0, 1, 2, 3],
        "the replies to a comment without /NM are listed on their own"
    );

    // The note and the rectangle: the note takes both its replies with it.
    doc.apply(delete(&[2, 1]), 0).unwrap();
    assert_eq!(annots(&doc), vec![8], "only the link is left");
    doc.undo().unwrap();

    // The note, the rectangle and the reply after the note, which the note's delete takes first.
    doc.apply(delete(&[1, 2, 3]), 2).unwrap();
    assert_eq!(annots(&doc), vec![8]);
    doc.undo().unwrap();

    // The reply before the note on its own: just it.
    doc.apply(delete(&[0]), 4).unwrap();
    assert_eq!(annots(&doc), vec![5, 6, 7, 8]);
}

/// Pop-ups linked one way only: `/Annots [4 5 6 7 8 9]`, where note 4 names its pop-up 5 (`/Popup`)
/// but 5 does not name it back, pop-up 7 names its note 6 (`/Parent`) but 6 does not name it, 8 is a
/// rectangle and 9 is the widget of the form's text field `w`. The apps list 4, 6 and 8 (indexes 0, 2
/// and 4). Each delete takes a pop-up listed before the next comment, through one link or the other.
#[test]
fn pop_ups_linked_either_way_go_with_their_comment() {
    let doc = PdfDocument::open(
        fixtures::hand_annotated_doc(
            &[
                "<< /Type /Annot /Subtype /Text /Rect [100 700 120 720] /Contents (A) /Popup 5 0 R >>",
                "<< /Type /Annot /Subtype /Popup /Rect [300 600 450 700] >>",
                "<< /Type /Annot /Subtype /Text /Rect [100 600 120 620] /Contents (B) >>",
                "<< /Type /Annot /Subtype /Popup /Rect [300 500 450 600] /Parent 6 0 R >>",
                "<< /Type /Annot /Subtype /Square /Rect [200 300 260 360] /Contents (C) >>",
                "<< /Type /Annot /Subtype /Widget /FT /Tx /T (w) /Rect [100 100 300 120] /P 3 0 R >>",
            ],
            &[9],
        ),
        None,
    )
    .unwrap();
    assert_eq!(listed(&doc), vec![0, 2, 4]);
    doc.apply(delete(&[4, 2, 0]), 0).unwrap();
    assert_eq!(annots(&doc), vec![9], "only the widget is left");
}

/// Notes the engine made, each listed with its pop-up right after it: deleting the first takes its
/// pop-up too, so the second note's place is one less by then than it was.
#[test]
fn notes_the_engine_made_go_with_their_pop_ups() {
    let doc = PdfDocument::open(fixtures::text_doc(&["x"]), None).unwrap();
    for (revision, y) in [100.0, 300.0].into_iter().enumerate() {
        doc.apply(
            Edit::AddNote {
                page: 0,
                at: Point { x: 50.0, y },
                contents: String::new(),
                color: YELLOW,
            },
            revision as u64,
        )
        .unwrap();
    }
    assert_eq!(annots(&doc).len(), 4, "two notes, each with its pop-up");
    assert_eq!(listed(&doc), vec![0, 2]);
    doc.apply(delete(&[0, 2]), 2).unwrap();
    assert!(annots(&doc).is_empty(), "{:?}", annots(&doc));
    assert!(doc.annotations().is_empty());
}

/// The working file is read again with the document's own password.
#[test]
fn an_encrypted_documents_comments_are_deleted_too() {
    let bytes = fixtures::encrypted_doc(&["x"], "secret");
    let doc = PdfDocument::open(bytes, Some("secret".into())).unwrap();
    for (revision, y) in [100.0, 300.0].into_iter().enumerate() {
        doc.apply(
            Edit::AddNote {
                page: 0,
                at: Point { x: 50.0, y },
                contents: String::new(),
                color: YELLOW,
            },
            revision as u64,
        )
        .unwrap();
    }
    assert_eq!(listed(&doc), vec![0, 2]);
    doc.apply(delete(&[2, 0]), 2).unwrap();
    assert!(doc.annotations().is_empty());
}

/// What `DeleteAnnotations` is for, pinned as documentation: the engine's own deletes in one step,
/// addressed by the places the list had before the step, highest first (as the apps used to send an
/// eraser stroke), delete the wrong annotation when a comment's pop-up or reply is listed before
/// another comment deleted in the same step. Each delete takes those out with its comment, which moves
/// the next one's place. If this starts failing, the engine has changed how it deletes; look again at
/// `DeleteAnnotations` before changing the test.
/// Single deletes addressed by the places before the first of them, highest first, hit the wrong
/// annotation: which is why a step does not take more than one of them on a page, and
/// `DeleteAnnotations` exists.
#[test]
fn deletes_by_the_places_before_the_step_highest_first_hit_the_wrong_annotation() {
    // Each delete is its own step here, at the revision the one before it left, with the places as
    // they were before the first: what one step of them would have done.
    let old_way = |doc: &PdfDocument, indices: &[u32]| {
        for (revision, &index) in (0..).zip(indices) {
            doc.apply(Edit::DeleteAnnotation { page: 0, index }, revision)
                .unwrap();
        }
    };

    // A (2) goes with its pop-up (0), so B moves from 1 to 0, and "delete 1" takes the form's widget.
    let doc = PdfDocument::open(popup_first(false), None).unwrap();
    old_way(&doc, &[2, 1]);
    assert_eq!(annots(&doc), vec![5], "B is left, and the widget is gone");

    // The note (2) goes with the reply before it (0), so the rectangle moves from 1 to 0, and
    // "delete 1" takes the link.
    let doc = PdfDocument::open(replies_around(false), None).unwrap();
    old_way(&doc, &[3, 2, 1]);
    assert_eq!(
        annots(&doc),
        vec![5],
        "the rectangle is left, and the link is gone"
    );

    // In one step they are refused.
    let doc = PdfDocument::open(popup_first(false), None).unwrap();
    let both = [2, 1].map(|index| Edit::DeleteAnnotation { page: 0, index });
    let result = doc.apply_all("Erase".into(), both.to_vec(), 0);
    assert!(
        matches!(result, Err(EditError::Invalid { .. })),
        "{result:?}"
    );
    assert_eq!(doc.revision(), 0);
}

#[test]
fn bad_deletes_are_invalid_and_change_nothing() {
    let doc = PdfDocument::open(popup_first(false), None).unwrap();
    let invalid = |edit: Edit| {
        let result = doc.apply(edit.clone(), 0);
        assert!(
            matches!(result, Err(EditError::Invalid { .. })),
            "{:?}: {result:?}",
            edit
        );
    };
    invalid(delete(&[]));
    invalid(delete(&[1, 4]));
    invalid(delete(&[u32::MAX]));
    invalid(Edit::DeleteAnnotations {
        page: 1,
        indices: vec![1],
    });
    invalid(delete(&vec![1; 10_001]));
    assert_eq!(doc.revision(), 0, "nothing changed");
    assert_eq!(annots(&doc), vec![4, 5, 6, 7]);
    // At the step's limit, the same index throughout, it is one delete.
    doc.apply(delete(&vec![1; 10_000]), 0).unwrap();
    assert_eq!(annots(&doc), vec![4, 6, 7]);
}

#[test]
fn a_locked_comment_among_those_deleted_refuses_them_all() {
    // As a single delete is refused.
    let doc = PdfDocument::open(popup_first(true), None).unwrap();
    let single = doc.apply(Edit::DeleteAnnotation { page: 0, index: 1 }, 0);
    assert!(
        matches!(single, Err(EditError::Invalid { .. })),
        "{single:?}"
    );
    let result = doc.apply(delete(&[1, 2]), 0);
    assert!(
        matches!(result, Err(EditError::Invalid { .. })),
        "{result:?}"
    );
    assert_eq!(doc.revision(), 0);
    assert_eq!(annots(&doc), vec![4, 5, 6, 7], "A is not deleted either");

    // A locked reply asked for along with its comment, listed after it: the comment's delete would
    // take it out before its own delete came, so the engine would never see it.
    let doc = PdfDocument::open(replies_around(true), None).unwrap();
    let result = doc.apply(delete(&[3, 2]), 0);
    assert!(
        matches!(result, Err(EditError::Invalid { .. })),
        "{result:?}"
    );
    assert_eq!(annots(&doc), vec![4, 5, 6, 7, 8]);
}

/// Its places are read as the page's list is before the step, so nothing else in the step may address
/// a comment on that page by its place; one on another page, a page turn, and comments added before
/// it (at the end of the list) may.
#[test]
fn a_step_that_deletes_several_comments_of_a_page_addresses_no_other_there() {
    let doc = PdfDocument::open(popup_first(false), None).unwrap();
    let others = [
        Edit::DeleteAnnotation { page: 0, index: 1 },
        Edit::SetAnnotationContents {
            page: 0,
            index: 1,
            contents: "x".into(),
        },
        Edit::MoveAnnotation {
            page: 0,
            index: 1,
            dx: 5.0,
            dy: 5.0,
        },
        delete(&[1]),
    ];
    for other in others {
        for edits in [
            vec![other.clone(), delete(&[2])],
            vec![delete(&[2]), other.clone()],
        ] {
            let result = doc.apply_all("x".into(), edits, 0);
            assert!(
                matches!(result, Err(EditError::Invalid { .. })),
                "{other:?}: {result:?}"
            );
        }
    }
    assert_eq!(doc.revision(), 0);

    let turned = doc.apply_all(
        "x".into(),
        vec![
            delete(&[2, 1]),
            Edit::RotatePages {
                pages: vec![0],
                degrees: 90,
            },
        ],
        0,
    );
    assert!(turned.is_ok(), "{turned:?}");
    assert_eq!(annots(&doc), vec![7]);
    assert_eq!(doc.page_info(0).unwrap().rotation_degrees, 90);

    let doc = PdfDocument::open(popup_first(false), None).unwrap();
    let added = doc.apply_all(
        "x".into(),
        vec![
            Edit::AddNote {
                page: 0,
                at: Point { x: 300.0, y: 300.0 },
                contents: "new".into(),
                color: YELLOW,
            },
            delete(&[2, 1]),
        ],
        0,
    );
    assert!(added.is_ok(), "{added:?}");
    let left = doc.annotations();
    assert_eq!(left.len(), 1);
    assert_eq!(left[0].contents.as_deref(), Some("new"));
    assert_eq!(annots(&doc)[0], 7, "the widget stays");

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
    let other_page = doc.apply_all(
        "x".into(),
        vec![
            Edit::DeleteAnnotations {
                page: 0,
                indices: vec![0],
            },
            Edit::DeleteAnnotation { page: 1, index: 0 },
        ],
        2,
    );
    assert!(other_page.is_ok(), "{other_page:?}");
    assert!(doc.annotations().is_empty());
}

/// Deleting one comment moves the places of those after it, so a step that deletes a comment of a
/// page addresses no other comment there either. Adding one, and changing other pages, still go.
#[test]
fn a_step_that_deletes_a_comment_of_a_page_addresses_no_other_there() {
    let doc = PdfDocument::open(popup_first(false), None).unwrap();
    let delete_b = Edit::DeleteAnnotation { page: 0, index: 1 };
    let others = [
        Edit::DeleteAnnotation { page: 0, index: 2 },
        Edit::SetAnnotationContents {
            page: 0,
            index: 2,
            contents: "x".into(),
        },
        Edit::MoveAnnotation {
            page: 0,
            index: 2,
            dx: 5.0,
            dy: 5.0,
        },
    ];
    for other in others {
        for edits in [
            vec![other.clone(), delete_b.clone()],
            vec![delete_b.clone(), other.clone()],
        ] {
            let result = doc.apply_all("x".into(), edits, 0);
            assert!(
                matches!(result, Err(EditError::Invalid { .. })),
                "{other:?}: {result:?}"
            );
        }
    }
    assert_eq!(doc.revision(), 0);

    let added = doc.apply_all(
        "x".into(),
        vec![
            delete_b.clone(),
            Edit::AddNote {
                page: 0,
                at: Point { x: 300.0, y: 300.0 },
                contents: "new".into(),
                color: YELLOW,
            },
        ],
        0,
    );
    assert!(added.is_ok(), "{added:?}");
    let mut left: Vec<String> = doc
        .annotations()
        .into_iter()
        .filter_map(|a| a.contents)
        .collect();
    left.sort();
    assert_eq!(left, ["A", "new"], "B went, and the note came");

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
    let other_page = doc.apply_all(
        "x".into(),
        vec![
            Edit::DeleteAnnotation { page: 0, index: 0 },
            Edit::SetAnnotationContents {
                page: 1,
                index: 0,
                contents: "kept".into(),
            },
        ],
        2,
    );
    assert!(other_page.is_ok(), "{other_page:?}");
    let left = doc.annotations();
    assert_eq!(left.len(), 1);
    assert_eq!(
        (left[0].page, left[0].contents.as_deref()),
        (1, Some("kept"))
    );
}
