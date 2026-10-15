//! In-memory fixture documents for the bridge tests.
//!
//! Every document is built here, in memory, with the engine's own create / edit / save API, so no
//! binary files are checked in. This module is the single place that knows how to make a PDF.
//!
//! Each integration-test crate compiles this module on its own and uses only some helpers, hence
//! the `dead_code` allowance; the clippy allowances mirror the ones the test files carry.
#![allow(dead_code, clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::sync::Arc;

use pdfcraft_engine::{Algorithm, Edit, ImageResolution, Protection, Session};

/// The fixtures' session clock. Fixed, so the plain fixtures' bytes (their `/ModDate`) are the same
/// on every run and one dumped to disk does not churn. (An encrypted one still differs: the engine
/// draws its encryption keys and salts from OS randomness.)
const FIXTURE_CLOCK: i64 = 1_700_000_000;

/// A 17x22 px, 8-bit grey PNG (74 bytes): a flat light-grey rectangle, no resolution chunk.
/// Written as a literal so the tests need no image encoder.
#[rustfmt::skip]
const GREY_PNG: [u8; 74] = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x11, 0x00, 0x00, 0x00, 0x16,
    0x08, 0x00, 0x00, 0x00, 0x00, 0x03, 0x03, 0x28, 0x9E, 0x00, 0x00, 0x00,
    0x11, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0xB8, 0x80, 0x0E, 0x18,
    0x46, 0x45, 0x06, 0x48, 0x04, 0x00, 0x16, 0x91, 0x2F, 0xF0, 0x8D, 0x6F,
    0xD8, 0x2A, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42,
    0x60, 0x82,
];

fn session() -> Session {
    Session::new().with_clock(|| FIXTURE_CLOCK)
}

/// Opens `bytes` in a fresh session, applies `edit`, and returns the saved (fully rewritten) result.
fn edited(bytes: Vec<u8>, edit: Edit) -> Vec<u8> {
    let mut session = session();
    let id = session
        .open("fixture.pdf", None, Arc::new(bytes), None)
        .expect("the fixture opens");
    session.apply(id, edit).expect("the edit applies");
    session
        .save_full_bytes(id)
        .expect("the result saves")
        .to_vec()
}

/// A document with one page per entry, each page showing that text (Helvetica 11 pt, US Letter).
///
/// Each entry must fit on one page (about 47 short lines); the engine starts a new page at every
/// form feed, which is how the entries are separated.
pub fn text_doc(pages: &[&str]) -> Vec<u8> {
    assert!(!pages.is_empty(), "a text document needs at least one page");
    let bytes = session()
        .create_from_text("fixture", &pages.join("\u{c}"))
        .expect("text pages create")
        .to_vec();
    // Pin the contract: one page per entry, so a long entry can't silently add pages.
    let mut check = session();
    let id = check
        .open("fixture.pdf", None, Arc::new(bytes.clone()), None)
        .expect("the fixture opens");
    assert_eq!(
        check.get(id).expect("the fixture is open").info.pages.len(),
        pages.len(),
        "each entry must fit on one page"
    );
    bytes
}

/// `text_doc` protected with `password` as its open (user) password: AES-256, nothing else restricted.
pub fn encrypted_doc(pages: &[&str], password: &str) -> Vec<u8> {
    let protection = Protection {
        open_password: Some(password.to_owned()),
        ..Protection::default()
    };
    edited(text_doc(pages), Edit::Protect(protection))
}

/// `text_doc` protected at the given compatibility level with a different open (user) password and
/// permissions (owner) password. Either one opens it.
pub fn protected_doc(pages: &[&str], user: &str, owner: &str, algorithm: Algorithm) -> Vec<u8> {
    let protection = Protection {
        open_password: Some(user.to_owned()),
        permissions_password: Some(owner.to_owned()),
        algorithm,
        ..Protection::default()
    };
    edited(text_doc(pages), Edit::Protect(protection))
}

/// A one-page document (US Letter on file) whose page has `/Rotate 90`, so it is shown landscape.
pub fn rotated_doc(text: &str) -> Vec<u8> {
    // Edits count pages from 0.
    edited(
        text_doc(&[text]),
        Edit::RotatePages {
            pages: vec![0],
            degrees: 90,
        },
    )
}

/// A one-page document containing only an image, so its page has no text layer. The 17x22 px grey
/// PNG is placed at 2 dpi, which makes the page US Letter (612 x 792 pt) like `text_doc`'s.
pub fn image_only_doc() -> Vec<u8> {
    let image = ("scan.png".to_owned(), GREY_PNG.to_vec());
    session()
        .create_from_images_with_resolution(&[image], ImageResolution::Dpi(2.0))
        .expect("the image page creates")
        .to_vec()
}
