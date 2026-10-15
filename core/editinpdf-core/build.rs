//! Exposes the pinned PdfCraft version to the crate as `PDFCRAFT_VERSION`, read from the
//! submodule's workspace manifest so it follows `make update-upstream` automatically.

use std::{env, fs, path::Path};

fn main() {
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap_or_default();
    let upstream = Path::new(&manifest_dir).join("../../upstream/pdfcraft/Cargo.toml");
    println!("cargo:rerun-if-changed={}", upstream.display());

    let version = fs::read_to_string(&upstream)
        .ok()
        .and_then(|toml| {
            toml.lines()
                .map(str::trim)
                .find(|l| l.starts_with("version") && l.contains('='))
                .and_then(|l| l.split('"').nth(1).map(str::to_owned))
        })
        .unwrap_or_else(|| "unknown".to_owned());

    println!("cargo:rustc-env=PDFCRAFT_VERSION={version}");
}
