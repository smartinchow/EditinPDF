//! Writes the fixture documents that the apps' own tests need as files, so they are checked in
//! next to those tests rather than rebuilt there: the Swift package's tests open `hello.pdf`; the
//! app's unit tests open `hello.pdf` too, `rotated.pdf` (one page turned by `/Rotate 90`),
//! `form.pdf` (a page of form fields) and `annotated.pdf` (a page with a highlight and a note); and
//! the app's UI tests open `sample.pdf` (three readable pages), `locked.pdf` (one page behind a
//! password), `garbage.pdf` (not a PDF at all) and `form.pdf`.
//!
//! These tests are ignored, so a normal `cargo test` never touches the working tree. Run them
//! with `cargo test -p editinpdf-core --test fixtures_export -- --ignored`, from anywhere in the
//! workspace, and commit what changed. The fixtures are built with a fixed clock, so the same
//! engine writes the same bytes, with two exceptions, which every run writes differently
//! (`git checkout` them if the run was for another file): `locked.pdf` is encrypted, and the engine
//! draws its encryption keys and salts from OS randomness; and `annotated.pdf`'s comments carry
//! ids (`/NM`) that the engine mixes the time of day into, fixed clock or not.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod fixtures;

use std::fs;
use std::path::PathBuf;

/// The Swift package's fixture folder, `ios/EditinPDFCore/Tests/EditinPDFCoreTests/Fixtures`.
fn swift_fixtures() -> PathBuf {
    let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    crate_dir.join("../../ios/EditinPDFCore/Tests/EditinPDFCoreTests/Fixtures")
}

/// The app's unit-test fixture folder, `ios/EditinPDFTests/Fixtures`. Only the unit-test bundle
/// carries what is in it; the app never does.
fn app_test_fixtures() -> PathBuf {
    let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    crate_dir.join("../../ios/EditinPDFTests/Fixtures")
}

/// The app's UI-test fixture folder, `ios/EditinPDFUITests/Fixtures`. The Debug build of the app
/// bundles what is in it too, for `-openFixture` to put in its Documents folder.
fn ui_test_fixtures() -> PathBuf {
    let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    crate_dir.join("../../ios/EditinPDFUITests/Fixtures")
}

#[test]
#[ignore = "writes into the working tree; run with `-- --ignored dump_fixtures`"]
fn dump_fixtures() {
    // One page reading "Hello world": the Swift bridge tests and the app's unit tests count its pages,
    // draw it and search it.
    let hello = fixtures::text_doc(&["Hello world"]);
    let dir = swift_fixtures();
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("hello.pdf"), &hello).unwrap();

    let dir = app_test_fixtures();
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("hello.pdf"), &hello).unwrap();
    // One Letter page with `/Rotate 90`, so it is shown landscape, reading "Rotated page": the app's
    // unit tests check that a search hit's box, laid out and drawn the way the viewer does, lands on
    // the text of a turned page.
    fs::write(
        dir.join("rotated.pdf"),
        fixtures::rotated_doc("Rotated page"),
    )
    .unwrap();
    // One page of form fields (`fixtures::form_doc`: a text field, a check box, a two-button radio
    // group, a combo box and a read-only text field, all empty): the app's tests list and fill them.
    let form = fixtures::form_doc();
    fs::write(dir.join("form.pdf"), &form).unwrap();
    // One page reading "Marked page" with a highlight over that line and a sticky note
    // (`fixtures::annotated_doc`): the app's tests list, select and delete comments.
    fs::write(dir.join("annotated.pdf"), fixtures::annotated_doc()).unwrap();
    // Opens with no password but has an owner password (`fixtures::restricted_doc`): extracting its
    // pages drops that protection, which the app says.
    fs::write(
        dir.join("owner-only.pdf"),
        fixtures::restricted_doc(&["Owner only"], "owner"),
    )
    .unwrap();

    let dir = ui_test_fixtures();
    fs::create_dir_all(&dir).unwrap();
    // The same form: the UI tests fill it in.
    fs::write(dir.join("form.pdf"), &form).unwrap();
    // Three pages, each saying which it is: the viewer is scrolled, zoomed and searched through it.
    fs::write(
        dir.join("sample.pdf"),
        fixtures::text_doc(&["Page one", "Page two", "Page three"]),
    )
    .unwrap();
    // One page, opened by the password "hunter2": the UI tests are asked for it, refused, and given it.
    fs::write(
        dir.join("locked.pdf"),
        fixtures::encrypted_doc(&["secret"], "hunter2"),
    )
    .unwrap();
    // Not a PDF: 2 KB of the same line over and over, the same bytes every time. The app says it
    // could not open it.
    fs::write(dir.join("garbage.pdf"), not_a_pdf(2048)).unwrap();
}

/// `len` bytes of text that is not a PDF: "not a pdf" lines, cut off wherever `len` falls.
fn not_a_pdf(len: usize) -> Vec<u8> {
    "not a pdf\n".bytes().cycle().take(len).collect()
}
