#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod fixtures;
use editinpdf_core::{OpenError, PdfDocument};

#[test]
fn opens_and_counts_pages() {
    let doc = PdfDocument::open(fixtures::text_doc(&["one", "two", "three"]), None).unwrap();
    assert_eq!(doc.page_count(), 3);
    let p = doc.page_info(1).unwrap();
    assert_eq!(p.index, 1);
    assert!((p.width_pt - 612.0).abs() < 0.5 && (p.height_pt - 792.0).abs() < 0.5);
    assert!(doc.page_info(3).is_none());
}

#[test]
fn garbage_is_corrupt_not_panic() {
    let err = PdfDocument::open(b"<html>not a pdf</html>".to_vec(), None).unwrap_err();
    assert!(matches!(err, OpenError::Corrupt { .. }));
    let err = PdfDocument::open(vec![0u8; 100_000], None).unwrap_err();
    assert!(matches!(err, OpenError::Corrupt { .. }));
}

#[test]
fn password_flow() {
    let bytes = fixtures::encrypted_doc(&["secret"], "hunter2");
    assert!(matches!(
        PdfDocument::open(bytes.clone(), None),
        Err(OpenError::NeedsPassword)
    ));
    for _ in 0..3 {
        assert!(matches!(
            PdfDocument::open(bytes.clone(), Some("nope".into())),
            Err(OpenError::WrongPassword)
        ));
    }
    let doc = PdfDocument::open(bytes, Some("hunter2".into())).unwrap();
    assert_eq!(doc.page_count(), 1);
}

#[test]
fn rotated_page_swaps_dimensions() {
    let doc = PdfDocument::open(fixtures::rotated_doc("r"), None).unwrap();
    let p = doc.page_info(0).unwrap();
    assert_eq!(p.rotation_degrees, 90);
    assert!(
        p.width_pt > p.height_pt,
        "view-space width should be the long side after /Rotate 90"
    );
    assert!((p.width_pt - 792.0).abs() < 0.5 && (p.height_pt - 612.0).abs() < 0.5);
}

#[test]
fn unrotated_pages_report_rotation_zero() {
    let doc = PdfDocument::open(fixtures::text_doc(&["flat"]), None).unwrap();
    assert_eq!(doc.page_info(0).unwrap().rotation_degrees, 0);
}

#[test]
fn image_only_document_opens_as_one_letter_page() {
    let doc = PdfDocument::open(fixtures::image_only_doc(), None).unwrap();
    assert_eq!(doc.page_count(), 1);
    let p = doc.page_info(0).unwrap();
    assert!((p.width_pt - 612.0).abs() < 0.5 && (p.height_pt - 792.0).abs() < 0.5);
}

#[test]
fn pages_without_a_defined_label_have_none() {
    let doc = PdfDocument::open(fixtures::text_doc(&["a", "b"]), None).unwrap();
    assert_eq!(doc.page_info(0).unwrap().label, None);
    assert_eq!(doc.page_info(1).unwrap().label, None);
}

#[test]
fn a_freshly_opened_document_is_revision_zero() {
    let doc = PdfDocument::open(fixtures::text_doc(&["a"]), None).unwrap();
    assert_eq!(doc.revision(), 0);
}

#[test]
fn empty_input_is_corrupt() {
    let err = PdfDocument::open(Vec::new(), None).unwrap_err();
    let OpenError::Corrupt { message } = err else {
        panic!("expected Corrupt, got {err:?}")
    };
    assert!(!message.is_empty(), "the error should say what was wrong");
}

#[test]
fn a_truncated_pdf_is_never_a_password_error() {
    let bytes = fixtures::text_doc(&["one", "two"]);
    for keep in [bytes.len() / 2, bytes.len() - 20] {
        // The engine may repair a cut-off file or refuse it; either way it must not panic or
        // mistake it for a locked document.
        let opened = PdfDocument::open(bytes[..keep].to_vec(), None);
        assert!(
            matches!(opened, Ok(_) | Err(OpenError::Corrupt { .. })),
            "kept {keep} of {} bytes: {opened:?}",
            bytes.len()
        );
    }
}
