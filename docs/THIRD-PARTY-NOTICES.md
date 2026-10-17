# Third-party notices

**Status: stub.** The complete notices are generated in milestone M4, together with the app's Licenses screen,
which shows this file (design spec, section 7). Nothing below is generated, and it is not the complete list.

## Where the licenses are until then

- EditinPDF's own code: MIT or Apache-2.0, at your option. See `LICENSE-MIT` and `LICENSE-APACHE` at the root of
  the repository.
- The PdfCraft engine, a git submodule at `upstream/pdfcraft/` (pinned to a release tag; see
  `git submodule status`): its license files, `NOTICE` and the credits for the fonts and other assets it
  bundles are `upstream/pdfcraft/LICENSE-MIT`, `LICENSE-APACHE`, `NOTICE` and `ATTRIBUTION.md`.
- The Rust crates the core is built from, and the one vendored copy, `core/vendor/num_threads/` (with its own
  `LICENSE-MIT` and `LICENSE-Apache`): the exact set is pinned in `core/Cargo.lock`, and each crate states its
  license in its own manifest.

## What M4 adds

`make notices` will list every crate and bundled asset that ends up in the app, with its license text, and write
the result here. That needs a generator (`cargo about` or `cargo deny list`) and a review of the output, and is
not started.
