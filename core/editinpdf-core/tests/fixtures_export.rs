//! Writes the fixture documents that the apps' own tests need as files, so they are checked in
//! next to those tests rather than rebuilt there: the Swift package's tests open `hello.pdf`.
//!
//! These tests are ignored, so a normal `cargo test` never touches the working tree. Run them
//! with `cargo test -p editinpdf-core -- --ignored dump_fixtures`, from anywhere in the workspace,
//! and commit what changed. The fixtures are built with a fixed clock, so the same engine writes
//! the same bytes and a run that changes nothing leaves `git status` clean.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod fixtures;

use std::fs;
use std::path::PathBuf;

/// The Swift package's fixture folder, `ios/EditinPDFCore/Tests/EditinPDFCoreTests/Fixtures`.
fn swift_fixtures() -> PathBuf {
    let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    crate_dir.join("../../ios/EditinPDFCore/Tests/EditinPDFCoreTests/Fixtures")
}

#[test]
#[ignore = "writes into the working tree; run with `-- --ignored dump_fixtures`"]
fn dump_fixtures() {
    let dir = swift_fixtures();
    fs::create_dir_all(&dir).unwrap();
    // One page reading "Hello world": the Swift bridge tests count its pages, draw it and search it.
    fs::write(dir.join("hello.pdf"), fixtures::text_doc(&["Hello world"])).unwrap();
}
