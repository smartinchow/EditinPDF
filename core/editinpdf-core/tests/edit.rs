#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod fixtures;
mod support;

use editinpdf_core::{Edit, EditError, OpenError, PdfDocument, Point, SaveError, SaveMode};
use support::{YELLOW, reopen, text_of};

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
            && !caps.rewrites_on_save
    );
    assert_eq!(caps.read_only_reason, None);
}

#[test]
fn capabilities_say_whether_the_document_is_password_protected() {
    let plain = PdfDocument::open(fixtures::text_doc(&["x"]), None).unwrap();
    assert!(!plain.capabilities().is_encrypted);
    let locked =
        PdfDocument::open(fixtures::encrypted_doc(&["x"], "pw"), Some("pw".into())).unwrap();
    assert!(locked.capabilities().is_encrypted);
    // An owner password alone: it opens with no password, and is still protected.
    let owner_only = PdfDocument::open(fixtures::restricted_doc(&["x"], "owner"), None).unwrap();
    assert!(owner_only.capabilities().is_encrypted);
}

fn rotate(page: u32) -> Edit {
    Edit::RotatePages {
        pages: vec![page],
        degrees: 90,
    }
}

#[test]
fn an_empty_step_is_invalid_and_changes_nothing() {
    let doc = PdfDocument::open(fixtures::text_doc(&["one"]), None).unwrap();
    assert!(matches!(
        doc.apply_all("Nothing".into(), Vec::new(), 0),
        Err(EditError::Invalid { .. })
    ));
    assert_eq!(doc.revision(), 0);
    assert!(!doc.can_undo() && !doc.is_dirty());
}

/// A file whose cross-reference data the engine had to rebuild has no chain of revisions to append
/// to: saving it writes the whole file, so the bytes as opened are not kept as a prefix. That is a
/// whole save of what the reader sees, and editing it stays allowed.
#[test]
fn a_document_whose_cross_reference_data_was_rebuilt_is_written_out_in_full() {
    let original = fixtures::with_damaged_startxref(fixtures::text_doc(&["one", "two"]));
    let doc = PdfDocument::open(original.clone(), None).unwrap();
    let caps = doc.capabilities();
    assert!(caps.rewrites_on_save);
    assert!(caps.can_edit && caps.can_organize && caps.can_annotate && caps.can_fill_forms);
    assert_eq!(caps.read_only_reason, None);
    assert_eq!(
        doc.save(SaveMode::Incremental).unwrap(),
        original,
        "unchanged, it comes back as it was opened"
    );

    doc.apply(rotate(1), 0).unwrap();
    let saved = doc.save(SaveMode::Incremental).unwrap();
    assert!(!saved.starts_with(&original), "written out in full");
    let back = reopen(saved, None);
    assert_eq!(back.page_count(), 2);
    assert_eq!(back.page_info(1).unwrap().rotation_degrees, 90);
    assert!(text_of(&back, 1).contains("two"));
    assert!(
        !back.capabilities().rewrites_on_save,
        "what was written is whole again, and the next save appends to it"
    );
}

/// The same damage in a signed file: the first change saved would rewrite it and break its
/// signatures, so the bridge refuses every change, and every save, and says why.
#[test]
fn a_signed_document_whose_cross_reference_data_was_rebuilt_is_read_only() {
    let doc = PdfDocument::open(
        fixtures::with_damaged_startxref(fixtures::signed_doc()),
        None,
    )
    .unwrap();
    let caps = doc.capabilities();
    assert!(caps.is_signed && caps.rewrites_on_save);
    assert!(!caps.can_edit && !caps.can_organize && !caps.can_annotate && !caps.can_fill_forms);
    assert!(
        caps.read_only_reason
            .is_some_and(|reason| reason.contains("signatures"))
    );

    let note = Edit::AddNote {
        page: 0,
        at: Point { x: 50.0, y: 50.0 },
        contents: "x".into(),
        color: YELLOW,
    };
    for edit in [rotate(0), note.clone()] {
        let result = doc.apply(edit, 0);
        assert!(
            matches!(result, Err(EditError::ReadOnly { .. })),
            "{result:?}"
        );
    }
    let result = doc.apply_all("Two".into(), vec![note.clone(), note], 0);
    assert!(
        matches!(result, Err(EditError::ReadOnly { .. })),
        "{result:?}"
    );
    assert_eq!(doc.revision(), 0);
    assert!(!doc.is_dirty() && !doc.can_undo());
    for mode in [SaveMode::Incremental, SaveMode::Full] {
        assert_eq!(doc.save(mode), Err(SaveError::Signed), "{mode:?}");
    }
    // Taking pages out into a new PDF changes nothing here.
    assert!(doc.extract_pages(vec![0]).is_ok());
}

/// An intact signed file is appended to, which keeps its signatures; a full rewrite is refused.
#[test]
fn a_signed_document_is_saved_incrementally_and_never_rewritten() {
    let original = fixtures::signed_doc();
    let doc = PdfDocument::open(original.clone(), None).unwrap();
    let caps = doc.capabilities();
    assert!(caps.is_signed && !caps.rewrites_on_save && caps.can_edit);
    doc.apply(rotate(0), 0).unwrap();
    assert!(
        doc.save(SaveMode::Incremental)
            .unwrap()
            .starts_with(&original)
    );
    assert_eq!(doc.save(SaveMode::Full), Err(SaveError::Signed));
}

/// A file the engine can show but not edit: every change is refused for the document's own
/// reason, and the capabilities say so.
#[test]
fn a_document_the_engine_cannot_edit_refuses_every_change() {
    let original = fixtures::read_only_doc("Read only");
    let doc = PdfDocument::open(original.clone(), None).unwrap();
    assert_eq!(doc.page_count(), 1);
    assert!(text_of(&doc, 0).contains("Read only"), "it is shown");
    let caps = doc.capabilities();
    assert!(!caps.can_edit && !caps.can_organize && !caps.can_annotate && !caps.can_fill_forms);
    assert!(!caps.is_signed && !caps.rewrites_on_save);
    assert!(
        caps.read_only_reason
            .is_some_and(|reason| !reason.is_empty())
    );

    let edits = [
        rotate(0),
        Edit::AddNote {
            page: 0,
            at: Point { x: 50.0, y: 50.0 },
            contents: "x".into(),
            color: YELLOW,
        },
        Edit::SetInfo {
            key: "Title".into(),
            value: "x".into(),
        },
        Edit::InsertPagesFrom {
            name: "other.pdf".into(),
            bytes: fixtures::text_doc(&["other"]),
            pages: None,
            at: 0,
        },
    ];
    for edit in edits.clone() {
        let result = doc.apply(edit, 0);
        assert!(
            matches!(result, Err(EditError::ReadOnly { .. })),
            "{result:?}"
        );
    }
    let result = doc.apply_all("All".into(), edits[1..3].to_vec(), 0);
    assert!(
        matches!(result, Err(EditError::ReadOnly { .. })),
        "{result:?}"
    );
    assert_eq!(doc.revision(), 0);
    assert!(matches!(doc.undo(), Err(EditError::NothingToUndo)));
    // Saving keeps the file as it is: an incremental save gives the bytes back, a rewrite is refused,
    // and so is taking pages out of it.
    assert_eq!(doc.save(SaveMode::Incremental).unwrap(), original);
    assert!(matches!(
        doc.save(SaveMode::Full),
        Err(SaveError::ReadOnly { .. })
    ));
    assert!(matches!(
        doc.extract_pages(vec![0]),
        Err(EditError::ReadOnly { .. })
    ));
}
