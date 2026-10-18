#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod fixtures;
mod support;

use editinpdf_core::{Edit, EditError, OpenError, PdfDocument, SaveMode, blank_document};
use support::{reopen, text_of};

#[test]
fn insert_pages_from_another_pdf() {
    let doc = PdfDocument::open(fixtures::text_doc(&["one", "two"]), None).unwrap();
    let src = fixtures::text_doc(&["alpha", "beta", "gamma"]);
    doc.apply(
        Edit::InsertPagesFrom {
            name: "src.pdf".into(),
            bytes: src.clone(),
            pages: Some(vec![2, 0]),
            at: 1,
        },
        0,
    )
    .unwrap();
    assert_eq!(doc.page_count(), 4);
    assert!(text_of(&doc, 1).contains("gamma") && text_of(&doc, 2).contains("alpha"));
    let out = doc.undo().unwrap();
    assert!(out.label.contains("src.pdf"));
    assert_eq!(doc.page_count(), 2);
    doc.apply(
        Edit::InsertPagesFrom {
            name: "src.pdf".into(),
            bytes: src,
            pages: None,
            at: 2,
        },
        2,
    )
    .unwrap();
    assert_eq!(
        reopen(doc.save(SaveMode::Incremental).unwrap(), None).page_count(),
        5
    );
}

#[test]
fn unusable_sources_are_typed_errors() {
    let doc = PdfDocument::open(fixtures::text_doc(&["one"]), None).unwrap();
    let locked = fixtures::encrypted_doc(&["x"], "pw");
    assert!(matches!(
        doc.apply(
            Edit::InsertPagesFrom {
                name: "l.pdf".into(),
                bytes: locked,
                pages: None,
                at: 0
            },
            0
        ),
        Err(EditError::SourceNeedsPassword)
    ));
    assert!(matches!(
        doc.apply(
            Edit::InsertPagesFrom {
                name: "g.pdf".into(),
                bytes: b"nope".to_vec(),
                pages: None,
                at: 0
            },
            0
        ),
        Err(EditError::SourceUnreadable { .. })
    ));
    assert_eq!(doc.revision(), 0);
}

#[test]
fn inserting_into_an_encrypted_document_keeps_it_encrypted() {
    let doc = PdfDocument::open(
        fixtures::encrypted_doc(&["secret"], "hunter2"),
        Some("hunter2".into()),
    )
    .unwrap();
    doc.apply(
        Edit::InsertPagesFrom {
            name: "s.pdf".into(),
            bytes: fixtures::text_doc(&["plain"]),
            pages: None,
            at: 1,
        },
        0,
    )
    .unwrap();
    let bytes = doc.save(SaveMode::Incremental).unwrap();
    assert!(matches!(
        PdfDocument::open(bytes.clone(), None),
        Err(OpenError::NeedsPassword)
    ));
    assert_eq!(reopen(bytes, Some("hunter2")).page_count(), 2);
}

#[test]
fn extract_selected_pages() {
    let doc = PdfDocument::open(fixtures::text_doc(&["one", "two", "three"]), None).unwrap();
    let out = reopen(doc.extract_pages(vec![0, 2]).unwrap(), None);
    assert_eq!(out.page_count(), 2);
    assert!(text_of(&out, 1).contains("three"));
    // Extracting is not an edit.
    assert_eq!(doc.revision(), 0);
    assert!(!doc.is_dirty());
    assert!(matches!(
        doc.extract_pages(vec![]),
        Err(EditError::Invalid { .. })
    ));
    assert!(matches!(
        doc.extract_pages(vec![3]),
        Err(EditError::Invalid { .. })
    ));
}

#[test]
fn blank_document_has_one_page_of_that_size() {
    let doc = reopen(blank_document(595.0, 842.0).unwrap(), None);
    assert_eq!(doc.page_count(), 1);
    assert_eq!(doc.page_info(0).unwrap().width_pt.round(), 595.0);
    assert!(matches!(
        blank_document(0.0, 842.0),
        Err(EditError::Invalid { .. })
    ));
}

#[test]
fn extracted_pages_of_an_encrypted_document_open_without_its_password() {
    let doc = PdfDocument::open(
        fixtures::encrypted_doc(&["secret", "other"], "hunter2"),
        Some("hunter2".into()),
    )
    .unwrap();
    let out = reopen(doc.extract_pages(vec![1]).unwrap(), None);
    assert_eq!(out.page_count(), 1);
    assert!(text_of(&out, 0).contains("other"));
}

#[test]
fn a_source_that_forbids_copying_its_pages_is_not_permitted() {
    let doc = PdfDocument::open(fixtures::text_doc(&["one"]), None).unwrap();
    let source = fixtures::restricted_doc(&["kept"], "owner");
    assert!(matches!(
        doc.apply(
            Edit::InsertPagesFrom {
                name: "r.pdf".into(),
                bytes: source,
                pages: None,
                at: 0
            },
            0
        ),
        Err(EditError::SourceNotPermitted)
    ));
    assert_eq!(doc.revision(), 0);
    assert_eq!(doc.page_count(), 1);
}

#[test]
fn a_document_that_forbids_page_changes_refuses_before_reading_the_source() {
    let doc = PdfDocument::open(fixtures::restricted_doc(&["one"], "owner"), None).unwrap();
    assert!(!doc.capabilities().can_organize);
    // An unreadable source: the document's own refusal is the one reported.
    let insert = Edit::InsertPagesFrom {
        name: "g.pdf".into(),
        bytes: b"nope".to_vec(),
        pages: None,
        at: 0,
    };
    assert!(matches!(
        doc.apply(insert.clone(), 0),
        Err(EditError::NotPermitted { .. })
    ));
    assert!(matches!(
        doc.apply_all("Insert".into(), vec![insert], 0),
        Err(EditError::NotPermitted { .. })
    ));
    assert_eq!(doc.revision(), 0);
}
