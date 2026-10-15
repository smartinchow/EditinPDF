# EditinPDF

A free, native iOS app for reading, organizing and annotating PDFs — fully offline, no account, no telemetry.

**Status: in development (pre-release).** Nothing is on the App Store yet.

EditinPDF is based on [PdfCraft](https://github.com/storytold/pdfcraft) by the ArtCraft team, an open-source
PDF engine written in pure Rust. EditinPDF is an independent project and is not affiliated with or endorsed by
the ArtCraft team or Adobe Inc.

## How it's built

- `upstream/pdfcraft/` — the PdfCraft engine as a git submodule, pinned to a release tag and never modified here.
- `core/` — `editinpdf-core`, a small Rust crate that wraps the engine and exposes a typed API to Swift via
  [UniFFI](https://mozilla.github.io/uniffi-rs/).
- `ios/` — the SwiftUI app (iPhone and iPad, iOS 17+). The Rust core is built into an XCFramework that the app
  links as a Swift package.

Design notes live in [docs/superpowers/specs](docs/superpowers/specs/).

## Building

Requirements: macOS with Xcode 27 (iOS 27 SDK), [Homebrew](https://brew.sh).

```sh
git clone --recurse-submodules https://github.com/smartinchow/EditinPDF
cd EditinPDF
make setup          # rustup + iOS targets, cmake, xcodegen
make xcframework    # builds the Rust core for device + simulator and generates the Swift bindings
make ios            # generates EditinPDF.xcodeproj and builds for the simulator
```

Then open `ios/EditinPDF.xcodeproj` in Xcode and run.

```sh
make test                        # cargo test + Xcode unit tests
make update-upstream TAG=v0.8.0  # move the engine to a newer PdfCraft release and re-run the bridge tests
```

## License

EditinPDF's own code is dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
The PdfCraft engine and the fonts and other assets it bundles keep their own licenses; the full list ships in
the app's Licenses screen and in `docs/THIRD-PARTY-NOTICES.md`.
