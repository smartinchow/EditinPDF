#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod fixtures;
mod support;

use editinpdf_core::{Edit, EditError, OpenError, PdfDocument, SaveMode};
use support::{reopen, text_of};

#[test]
fn rotate_persists_after_incremental_save() {
    let doc = PdfDocument::open(fixtures::text_doc(&["one", "two", "three"]), None).unwrap();
    let out = doc
        .apply(
            Edit::RotatePages {
                pages: vec![1],
                degrees: 90,
            },
            0,
        )
        .unwrap();
    assert_eq!(out.revision, 1);
    assert_eq!(doc.revision(), 1);
    let back = reopen(doc.save(SaveMode::Incremental).unwrap(), None);
    assert_eq!(back.page_info(1).unwrap().rotation_degrees, 90);
    assert_eq!(back.page_info(0).unwrap().rotation_degrees, 0);
}

#[test]
fn delete_move_insert_blank_and_undo_redo() {
    let doc = PdfDocument::open(fixtures::text_doc(&["one", "two", "three"]), None).unwrap();
    doc.apply(
        Edit::MovePages {
            pages: vec![2],
            to: 0,
        },
        0,
    )
    .unwrap();
    assert!(text_of(&doc, 0).contains("three"));
    doc.apply(Edit::DeletePages { pages: vec![1] }, 1).unwrap(); // deletes "one"
    assert_eq!(doc.page_count(), 2);
    doc.apply(
        Edit::InsertBlankPage {
            at: 2,
            width_pt: 300.0,
            height_pt: 400.0,
        },
        2,
    )
    .unwrap();
    assert_eq!(doc.page_info(2).unwrap().width_pt.round(), 300.0);
    assert!(text_of(&doc, 2).is_empty());
    assert!(doc.can_undo() && !doc.can_redo());
    doc.undo().unwrap();
    doc.undo().unwrap();
    assert_eq!(doc.page_count(), 3);
    assert_eq!(doc.revision(), 5);
    doc.redo().unwrap();
    assert_eq!(doc.page_count(), 2);
    doc.undo().unwrap();
    doc.undo().unwrap();
    assert!(matches!(doc.undo(), Err(EditError::NothingToUndo)));
    assert!(text_of(&doc, 0).contains("one"));
}

#[test]
fn rendering_follows_the_revision() {
    // The pool is rebuilt: a tile of a rotated page has its size swapped.
    let doc = PdfDocument::open(fixtures::text_doc(&["one"]), None).unwrap();
    let before = doc.render_tile(0, 0.25, None).unwrap();
    doc.apply(
        Edit::RotatePages {
            pages: vec![0],
            degrees: 90,
        },
        0,
    )
    .unwrap();
    let after = doc.render_tile(0, 0.25, None).unwrap();
    assert_eq!((after.width, after.height), (before.height, before.width));
}

#[test]
fn an_edit_for_an_old_revision_is_refused() {
    let doc = PdfDocument::open(fixtures::text_doc(&["one", "two"]), None).unwrap();
    doc.apply(Edit::DeletePages { pages: vec![1] }, 0).unwrap();
    let err = doc
        .apply(
            Edit::RotatePages {
                pages: vec![1],
                degrees: 90,
            },
            0,
        )
        .unwrap_err();
    assert!(matches!(err, EditError::Stale { current: 1 }));
    assert_eq!(doc.revision(), 1);
}

#[test]
fn bad_edits_are_typed_errors_and_change_nothing() {
    let doc = PdfDocument::open(fixtures::text_doc(&["one", "two"]), None).unwrap();
    assert!(matches!(
        doc.apply(Edit::DeletePages { pages: vec![0, 1] }, 0),
        Err(EditError::WouldRemoveAllPages)
    ));
    assert!(matches!(
        doc.apply(
            Edit::RotatePages {
                pages: vec![7],
                degrees: 90
            },
            0
        ),
        Err(EditError::Invalid { .. })
    ));
    assert!(matches!(
        doc.apply(
            Edit::RotatePages {
                pages: vec![0],
                degrees: 45
            },
            0
        ),
        Err(EditError::Invalid { .. })
    ));
    assert_eq!(doc.revision(), 0);
    assert!(!doc.is_dirty());
}

#[test]
fn a_failing_batch_changes_nothing() {
    let doc = PdfDocument::open(fixtures::text_doc(&["one", "two", "three"]), None).unwrap();
    let err = doc
        .apply_all(
            "Organize".into(),
            vec![
                Edit::RotatePages {
                    pages: vec![0],
                    degrees: 90,
                },
                Edit::DeletePages { pages: vec![9] },
            ],
            0,
        )
        .unwrap_err();
    assert!(matches!(err, EditError::Invalid { .. }));
    assert_eq!(doc.page_info(0).unwrap().rotation_degrees, 0);
    assert_eq!(doc.revision(), 0);
    doc.apply_all(
        "Delete pages".into(),
        vec![
            Edit::DeletePages { pages: vec![2] },
            Edit::DeletePages { pages: vec![1] },
        ],
        0,
    )
    .unwrap();
    assert_eq!(doc.page_count(), 1);
    doc.undo().unwrap();
    assert_eq!(doc.page_count(), 3); // one undo step
}

#[test]
fn unedited_save_is_the_original_bytes() {
    let original = fixtures::text_doc(&["one", "two"]);
    let doc = PdfDocument::open(original.clone(), None).unwrap();
    assert_eq!(doc.save(SaveMode::Incremental).unwrap(), original);
}

#[test]
fn edited_incremental_save_appends_to_the_original() {
    let original = fixtures::text_doc(&["one", "two"]);
    let doc = PdfDocument::open(original.clone(), None).unwrap();
    doc.apply(
        Edit::RotatePages {
            pages: vec![0],
            degrees: 180,
        },
        0,
    )
    .unwrap();
    let saved = doc.save(SaveMode::Incremental).unwrap();
    assert!(saved.len() > original.len() && saved.starts_with(&original));
    assert!(doc.is_dirty()); // save does not mark saved (see Task 8)
    let full = doc.save(SaveMode::Full).unwrap();
    assert_eq!(
        reopen(full, None).page_info(0).unwrap().rotation_degrees,
        180
    );
}

#[test]
fn saves_racing_edits_always_reopen_whole() {
    let doc = PdfDocument::open(fixtures::text_doc(&["one", "two", "three"]), None).unwrap();
    let editor = {
        let doc = doc.clone();
        std::thread::spawn(move || {
            for _ in 0..20 {
                let r = doc.revision();
                doc.apply(
                    Edit::RotatePages {
                        pages: vec![0, 1, 2],
                        degrees: 90,
                    },
                    r,
                )
                .unwrap();
            }
        })
    };
    // At least one save, even when the editor finishes first, so the test never checks nothing.
    let mut saves = vec![doc.save(SaveMode::Incremental).unwrap()];
    while !editor.is_finished() {
        saves.push(doc.save(SaveMode::Incremental).unwrap());
    }
    editor.join().unwrap();
    for bytes in saves {
        let back = reopen(bytes, None);
        assert_eq!(back.page_count(), 3);
        let r: Vec<u32> = (0..3)
            .map(|p| back.page_info(p).unwrap().rotation_degrees)
            .collect();
        assert!(
            r.iter().all(|d| *d == r[0]),
            "a save saw a half-applied rotate: {r:?}"
        );
    }
}

#[test]
fn encrypted_document_stays_encrypted_after_edit_and_save() {
    let doc = PdfDocument::open(
        fixtures::encrypted_doc(&["secret", "two"], "hunter2"),
        Some("hunter2".into()),
    )
    .unwrap();
    doc.apply(Edit::DeletePages { pages: vec![1] }, 0).unwrap();
    for mode in [SaveMode::Incremental, SaveMode::Full] {
        let bytes = doc.save(mode).unwrap();
        assert!(matches!(
            PdfDocument::open(bytes.clone(), None),
            Err(OpenError::NeedsPassword)
        ));
        assert_eq!(reopen(bytes, Some("hunter2")).page_count(), 1);
    }
}

#[test]
fn capabilities_of_a_plain_document() {
    let caps = PdfDocument::open(fixtures::text_doc(&["one"]), None)
        .unwrap()
        .capabilities();
    assert!(
        caps.can_edit
            && caps.can_organize
            && caps.can_annotate
            && caps.can_fill_forms
            && !caps.is_signed
    );
    assert_eq!(caps.read_only_reason, None);
}
