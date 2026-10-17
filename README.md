# EditinPDF

A free, native iOS app for reading, organizing and annotating PDFs — fully offline, no account, no telemetry.

**Status: milestone M1, the viewer (pre-release).** Nothing is on the App Store yet, and the app only reads PDFs
so far.

<!-- CI badge: enable it once the GitHub repository exists (the workflow is .github/workflows/ci.yml).
[![CI](https://github.com/smartinchow/EditinPDF/actions/workflows/ci.yml/badge.svg)](https://github.com/smartinchow/EditinPDF/actions/workflows/ci.yml)
-->

EditinPDF is based on [PdfCraft](https://github.com/storytold/pdfcraft) by the ArtCraft team, an open-source
PDF engine written in pure Rust. EditinPDF is an independent project and is not affiliated with or endorsed by
the ArtCraft team or Adobe Inc.

<!-- Screenshots: to be added with the store listing (milestone M4). -->

## What works today

The viewer opens PDFs read-only, on iPhone and iPad (iOS 17 and later; so far tested on the iOS 26.5 simulator
only, see below):

- **Open** a PDF from the Files document browser. A password-protected file asks for its password; a file that
  is not a readable PDF says so and closes.
- **Read**: scroll through the pages and pinch to zoom, up to 8x. Pages are drawn in tiles, so deep zoom stays
  sharp, and the page indicator shows where you are.
- **Thumbnails**: a sheet of page thumbnails; tap one to jump to that page.
- **Search** for text: hits are highlighted on the pages, and you can step through them or pick one from the list.
- **Select and copy** text: long-press a word, drag the handles to extend the selection, then Copy.

Still to come: organizing pages (M2), annotations and forms (M3), and the app icon, Licenses screen and
TestFlight build (M4). The privacy manifest ships already: no tracking and no data collected.

Tested on the iOS 26.5 simulator only: the app is built for iOS 17 and later, but iOS 17 and 18 are untested
(Xcode 27 offers no iOS 17 simulator runtime to download), and nothing has run on a physical device yet.

## Building

Requirements: macOS with Xcode 27 (iOS 27 SDK), [Homebrew](https://brew.sh).

```sh
git clone --recurse-submodules https://github.com/smartinchow/EditinPDF
cd EditinPDF
make setup          # rustup + iOS targets, cmake, xcodegen, and the engine submodule
make xcframework    # builds the Rust core for device, simulator and macOS, generates the Swift bindings
make ios            # generates EditinPDF.xcodeproj and builds for the simulator
```

Then open `ios/EditinPDF.xcodeproj` in Xcode and run. The XCFramework and the generated Swift bindings are build
output, not committed: run `make xcframework` again after changing anything in `core/` or `upstream/`.

`make help` lists the targets:

| Target | What it does |
|---|---|
| `make setup` | Installs rustup, cmake and XcodeGen with Homebrew, selects stable Rust with the iOS targets, fetches the engine submodule |
| `make core` | Builds the Rust core for the Mac (a fast check) |
| `make core-test` | Runs the Rust test suite of the bridge |
| `make lint` | `cargo fmt --check` and clippy with warnings denied |
| `make xcframework` | Builds the Rust core for device, simulator and macOS, generates the Swift bindings, assembles the XCFramework |
| `make project` | Generates `ios/EditinPDF.xcodeproj` from `ios/project.yml` |
| `make ios` | Builds the app for the simulator |
| `make test` | `cargo test`, the Swift package's tests, then the app's unit and UI tests on a simulator: the first iPhone on the newest iOS runtime installed (pin one with `SIM_UDID=<udid>`). The result bundle is `ios/build/EditinPDF.xcresult` |
| `make release-check` | Builds Release for the simulator and fails if the app contains any PDF (the UI tests' sample documents are Debug-only) |
| `make update-upstream TAG=v0.8.0` | Moves the engine to a newer PdfCraft release and re-runs the bridge tests |
| `make clean` | Removes the build output |
| `make notices` | Placeholder: the third-party notices are generated in milestone M4 |

The Xcode targets print only warnings and errors (`-quiet`); `make test XCFLAGS=` prints everything.

## Project layout

The Rust core in `core/` wraps the engine and exposes a typed API to Swift through
[UniFFI](https://mozilla.github.io/uniffi-rs/); the SwiftUI app in `ios/` (iPhone and iPad, iOS 17+) links it as an
XCFramework, through a Swift package.

```
core/                    Rust workspace
  editinpdf-core/        the bridge crate: wraps the engine, exposes a typed API to Swift through UniFFI
  uniffi-bindgen/        the binding generator, run by core/scripts/build-xcframework.sh
  scripts/               build-xcframework.sh: device, simulator and macOS libraries -> Swift bindings -> XCFramework
  vendor/num_threads/    a patched copy of one dependency that does not compile for iOS (docs/adr/0001)
ios/
  project.yml            XcodeGen spec; EditinPDF.xcodeproj is generated from it and committed
  EditinPDF/             the SwiftUI app
  EditinPDFCore/         Swift package around the XCFramework (the bindings and the XCFramework are build output)
  EditinPDFTests/        unit tests
  EditinPDFUITests/      UI tests, and the sample PDFs only Debug builds bundle
scripts/                 helpers shared by make and CI: pick-simulator.sh, check-release-bundle.sh
upstream/pdfcraft/       the PdfCraft engine, a git submodule pinned to a release tag, never modified here
docs/                    design spec, plans and architecture decision records (ADRs)
.github/workflows/       CI
```

Design notes live in [docs/superpowers/specs](docs/superpowers/specs/); the build spike and its numbers are in
[docs/adr/0001-ios-build-spike.md](docs/adr/0001-ios-build-spike.md).

## Continuous integration

`.github/workflows/ci.yml` runs on every push to `main` and every pull request, on GitHub's `xcode-27` macOS
image (Xcode 27 is in public preview there and not on `macos-latest` yet). It checks Rust formatting, clippy and
the Rust tests; builds the XCFramework; runs the Swift package tests; checks that the committed Xcode project is
what `project.yml` generates; runs the app's unit and UI tests on a simulator chosen from what the runner has; and
builds Release to check that no PDF ships in the app. `make lint test release-check` runs the same checks on
your Mac; after `make project`, `git status` shows whether the committed Xcode project was out of date.

## Contributing, and updating the engine

Run `make lint test release-check` before sending a change. Two files are generated from others, so change the
source and regenerate: `ios/EditinPDF.xcodeproj` from `ios/project.yml` (`make project`; commit both), and the
Swift bindings from the Rust API (`make xcframework`; not committed).

The engine lives in `upstream/pdfcraft/` and is never edited here: a change it needs goes into the bridge in
`core/`, or upstream. To move to a newer release:

```sh
make update-upstream TAG=v0.8.0    # fetches tags, checks the release out, re-runs the Rust tests
make xcframework test              # rebuild the libraries, then run the app's tests against them
git add upstream/pdfcraft core/Cargo.lock && git commit
```

If upstream's own `[patch.crates-io]` entries change, mirror them in `core/Cargo.toml`: Cargo only honours patches
declared in the root workspace. The vendored `num_threads` copy can go once a release of that crate compiles for
iOS.

## License

EditinPDF's own code is dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
The PdfCraft engine and the fonts and other assets it bundles keep their own licenses. The full list will ship in
the app's Licenses screen and in `docs/THIRD-PARTY-NOTICES.md` with milestone M4; the file is a stub until then.
