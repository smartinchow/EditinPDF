//! Writes the fixture documents that the apps' own tests need as files, so they are checked in
//! next to those tests rather than rebuilt there: the Swift package's tests open `hello.pdf`; the
//! app's unit tests open `hello.pdf` too, `rotated.pdf` (one page turned by `/Rotate 90`),
//! `form.pdf` (a page of form fields), `form-kinds.pdf` (the other kinds of field),
//! `restricted-form.pdf` (`form.pdf`, not to be filled in), `truncated-form.pdf` (a drop-down list of
//! more options than are listed), `annotated.pdf` (a page with a highlight
//! and a note) and `locked-markup.pdf` (a rectangle and a text box the file locks); and
//! the app's UI tests open `sample.pdf` (three readable pages), `locked.pdf` (one page behind a
//! password), `garbage.pdf` (not a PDF at all), `form.pdf`, `form-kinds.pdf`, `truncated-form.pdf`
//! and `rotated.pdf`.
//!
//! These tests are ignored, so a normal `cargo test` never touches the working tree. Run them
//! with `cargo test -p editinpdf-core --test fixtures_export -- --ignored`, from anywhere in the
//! workspace, and commit what changed. The fixtures are built with a fixed clock, so the same
//! engine writes the same bytes, with some exceptions, which every run writes differently
//! (`git checkout` them if the run was for another file): `locked.pdf`, `owner-only.pdf` and
//! `restricted-form.pdf` are encrypted, and the engine draws its encryption keys and salts from OS
//! randomness; and `annotated.pdf`'s comments carry
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
    // the text of a turned page, and that a highlight comes back over the text it was made on.
    let rotated = fixtures::rotated_doc("Rotated page");
    fs::write(dir.join("rotated.pdf"), &rotated).unwrap();
    // One page of form fields (`fixtures::form_doc`: a text field, a check box, a two-button radio
    // group, a combo box and a read-only text field, all empty): the app's tests list and fill them.
    let form = fixtures::form_doc();
    fs::write(dir.join("form.pdf"), &form).unwrap();
    // Two pages with the other kinds of field (`fixtures::form_kinds_doc`: a text field taking at
    // most 5 characters, a combo box that takes typed text, a list box of several choices, a push
    // button, a signature field, a text field of several lines near the bottom of page 0, and a text
    // field on page 1): the app's tests decide what a tap on each does, and fill them in.
    let form_kinds = fixtures::form_kinds_doc();
    fs::write(dir.join("form-kinds.pdf"), &form_kinds).unwrap();
    // The form of `form.pdf`, whose security settings forbid filling it in
    // (`fixtures::restricted_form_doc`; encrypted, so its bytes differ from run to run): the app's
    // tests check that its fields are shown, and that a tap says why they can't be filled in.
    fs::write(
        dir.join("restricted-form.pdf"),
        fixtures::restricted_form_doc(),
    )
    .unwrap();
    // A drop-down list of more options than the bridge lists (`fixtures::truncated_form_doc`): the
    // app's tests check that the model says the form is listed short, and the screen's note.
    let truncated_form = fixtures::truncated_form_doc();
    fs::write(dir.join("truncated-form.pdf"), &truncated_form).unwrap();
    // One page reading "Marked page" with a highlight over that line and a sticky note
    // (`fixtures::annotated_doc`): the app's tests list, select and delete comments.
    fs::write(dir.join("annotated.pdf"), fixtures::annotated_doc()).unwrap();
    // One page with a rectangle and a text box that the file locks, the rectangle in a way only the
    // engine's changes see (`fixtures::locked_markup_doc`): the app's tests check what a refused move
    // and a refused delete leave.
    fs::write(dir.join("locked-markup.pdf"), fixtures::locked_markup_doc()).unwrap();
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
    // The same other kinds of field: the UI tests fill them in (`-openFixture form-kinds.pdf`):
    // `testTheKeyboardDoesNotCoverTheFieldBeingFilled`, where the keyboard comes up over the field near
    // the bottom of the page, and `testChoosingFromAMenuAndFromASheet`.
    fs::write(dir.join("form-kinds.pdf"), &form_kinds).unwrap();
    // The same list of too many options: the UI tests read the note that says the form is listed short.
    fs::write(dir.join("truncated-form.pdf"), &truncated_form).unwrap();
    // The same turned page: text is marked on it by hand in the simulator (`-openFixture rotated.pdf`).
    fs::write(dir.join("rotated.pdf"), &rotated).unwrap();
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
