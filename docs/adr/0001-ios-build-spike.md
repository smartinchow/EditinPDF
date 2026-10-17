# ADR 0001: The PdfCraft engine builds and runs on iOS (M0 spike)

- Status: accepted
- Date: 2026-10-15
- Context: M0 of the design spec asks three questions: can every engine crate that `editinpdf-core`
  pulls in compile for `aarch64-apple-ios` and `aarch64-apple-ios-sim`, how big is the result, and can
  one `PageRenderer` be shared across threads. Spec: `docs/superpowers/specs/2026-10-15-editinpdf-ios-design.md`.
  Plan: `docs/superpowers/plans/2026-10-15-m1-viewer.md` (Task 1).

## Answer

Yes to all three, with one workaround. Everything compiles for iOS device, iOS simulator and macOS from a
cold `target/` in about 75 s per target. One crate, `num_threads 0.1.7`, does not compile for iOS; it is
replaced by a vendored copy with a two-edit patch (`core/vendor/num_threads`). `PageRenderer` is `Send + Sync`,
but its `render` takes `&mut self`, so the bridge keeps a pool of two per document revision, each behind its own
`Mutex` (see "Decision: renderer sharing"). The engine's open path links to about 23 MiB, inside the 40 MB
budget. The bridge links and runs in the iOS Simulator.

## Environment

| Item | Value |
|---|---|
| Machine | Apple M5, 10 cores, 16 GiB, macOS 26.6.2 (25G83) |
| Rust | rustc 1.99.0 (b940084d7 2026-09-28), cargo 1.99.0 (5f94df478 2026-08-27), rustup 1.29.1 |
| Targets | `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `aarch64-apple-darwin` |
| Apple | Xcode 27.0 (27A266a), iPhoneOS / iPhoneSimulator / MacOSX 27.0 SDKs |
| Other tools | cmake 4.4.4 (installed, not invoked by any build, see below), UniFFI 0.32.2 |
| Engine | PdfCraft v0.7.1, submodule `upstream/pdfcraft` at 7163ba3d (never edited) |
| Profile | `[profile.release]` of `core/Cargo.toml`: opt-level 3, thin LTO, 16 codegen units, `strip = "debuginfo"`, `panic = "unwind"` |
| Deployment targets | `IPHONEOS_DEPLOYMENT_TARGET=17.0`, `MACOSX_DEPLOYMENT_TARGET=14.0` (set by the script, see Findings) |

## Results

Times are cargo's own "Finished in" for `cargo build --release -p editinpdf-core --target <t>` inside one
run of `core/scripts/build-xcframework.sh` from a cold `target/` (after `cargo clean`), in the order the
script builds them. The first build also compiles the host-side build scripts and proc macros, which the
other two reuse.

| Target | Result | Cold build | `libeditinpdf_core.a` | cdylib (`libeditinpdf_core.dylib`) |
|---|---|---|---|---|
| `aarch64-apple-ios` | builds | 1 m 19 s | 351,259,672 B (335.0 MiB) | 23,625,536 B (22.5 MiB) |
| `aarch64-apple-ios-sim` | builds | 1 m 12 s | 350,910,680 B (334.6 MiB) | 24,041,536 B (22.9 MiB) |
| `aarch64-apple-darwin` | builds | 1 m 13 s | 352,028,296 B (335.7 MiB) | 24,249,952 B (23.1 MiB) |

- Zero warnings in any build, including the vendored crate (cargo shows warnings for path dependencies).
- Other timings: host `cargo check -p editinpdf-core` 45 s from cold; whole script cold 277 s (the three
  builds, then about 53 s to build `uniffi-bindgen`, generate the Swift and assemble the xcframework);
  script re-run with everything built 6 s; touching `lib.rs` and rebuilding one target about 2 s (the
  spike crate is tiny; this will grow). `PROFILE=debug` also works end to end: 356 s for the whole script,
  but each `.a` is about 890 MiB and the xcframework 2.6 GiB, so use it only when debugging the bridge.
- Size. The `.a` files are archives of every dependency's objects and say little about the app: three
  slices make a 1.0 GiB xcframework (git-ignored). What the app pays is the linked, dead-stripped image.
  The cdylib rustc links for each target is the best proxy: 22.5 MiB on device. A manual
  `clang -dynamiclib -dead_strip` of the device `.a`, keeping only the bridge's exported symbols, gives 24.3 MB.
  The image contains the JS engine (boa), the renderer (hayro, vello_cpu), lopdf, signing and aws-lc;
  `rten`/`ocrs` (OCR) and `craft-print` are not reachable from the bridge today and are stripped, so they
  add size only when a later milestone exposes them. Well inside the 40 MB budget; no change to the
  release profile is needed yet. Re-measure the cdylib after Task 4.
- Dependency count. `cargo tree -p editinpdf-core --target aarch64-apple-ios -e normal --prefix none | sort -u | wc -l`
  prints 419, but that counts a crate twice when it also appears with a `(*)` repeat marker. Unique crate
  versions: 331 for `aarch64-apple-ios` and `-ios-sim`, 334 for `aarch64-apple-darwin` (it adds
  `core-foundation`, `security-framework` and `security-framework-sys`). 35 of the 331 are path crates
  (28 `pdfcraft-*`, the five patched hayro and lopdf copies from upstream's `vendor/`, `editinpdf-core`
  and `num_threads`) and one is a git crate (`craft-print`, storytold/craft-libs rev d991bf67).

## The one blocker: `num_threads 0.1.7`

Both iOS targets failed to compile:

```
error[E0425]: cannot find function `mach_task_self` in crate `libc`
  --> num_threads-0.1.7/src/apple.rs:34:31
   |
34 |     let task = unsafe { libc::mach_task_self() };
   |                               ^^^^^^^^^^^^^^ not found in `libc`
```

Chain: `editinpdf-core` -> `pdfcraft-engine` -> `pdfcraft-js` -> `boa_engine 0.22` -> `time 0.3.55`
(feature `local-offset`) -> `num_threads 0.1.7` -> `libc 0.2.190`. libc declares `mach_task_self_` and
`mach_task_self()` only under `#[cfg(target_os = "macos")]` (src/unix/bsd/apple/mod.rs, both deprecated
there in favour of `mach2`), while the iOS SDK header (`<mach/mach_init.h>`) declares `mach_task_self_` and
`libSystem.B.tbd` exports it in the iPhoneOS and iPhoneSimulator SDKs.

Options, in the controller's order:

1. `cargo update -p ...`: not possible. `cargo update --dry-run --verbose` locks 0 packages and lists no
   newer release of any of the three: num_threads 0.1.7, time 0.3.55 and libc 0.2.190 are each the newest
   (libc 1.0.0-alpha.5 is a pre-release of another major version).
2. Vendored, patched copy: chosen. `core/vendor/num_threads/` is the registry crate with its licence files,
   plus `PATCH.md`. Only `src/apple.rs` differs: declare `static mut mach_task_self_: mach_port_t;` in the
   crate's existing `extern "C"` block and read it instead of calling `libc::mach_task_self()` (both edits
   marked `EditinPDF patch:`). It is the same variable libc's function returned on macOS, so macOS behaviour
   is unchanged. Wired in with `[patch.crates-io] num_threads = { path = "vendor/num_threads" }` in
   `core/Cargo.toml`, and `exclude = ["vendor"]` keeps it out of the workspace (as upstream does for its
   own `vendor/`).
3. (not needed.)

No other crate needed a workaround on any target. `aws-lc-sys 0.46.0` built with its own `cc` builder
using Xcode's clang (no `CMakeCache.txt` in its out dir; cmake is only the fallback), and `craft-print`,
`boa_engine 0.22`, `rten`/`ocrs` and `vello_cpu` compiled unmodified. The change has not been proposed
upstream yet (github.com/jhpratt/num_threads); drop the vendored copy when a release fixes it.

## Thread-safety probes

Compile-time assertions in a temporary `#[cfg(test)] mod spike` in `editinpdf-core` (removed again; the
crate's `lib.rs` is byte-identical to the scaffold). A failing bound is a compile error.

| Probe | Result |
|---|---|
| `pdfcraft_render::PageRenderer: Send + Sync` | pass |
| `PageRenderer: Send` | pass |
| `PageRenderer: Sync` | pass |
| `pdfcraft_engine::Session: Send` | pass |
| `pdfcraft_render::RenderPool: Send` | pass |
| `Session: Sync` | compile error: `RefCell<PageRenderer>` cannot be shared between threads safely |
| `RenderPool: Sync` | compile error: same |

`cargo test -p editinpdf-core spike` with the two failing probes removed: 5 passed, 0 failed. The two failures
share one cause: `RenderPool` (raster.rs:706) holds `inline: Option<RefCell<PageRenderer>>` (raster.rs:719),
and every engine `Document` owns a `RenderPool` (engine/src/lib.rs:307), so `Session` inherits `!Sync`.

The plan and the brief spell the type `pdfcraft_render::raster::PageRenderer`. `raster` is a private module
(render/src/lib.rs:13); the types are re-exported at the crate root (lib.rs:23), so use
`pdfcraft_render::{PageRenderer, RenderConfig, RenderRequest, RequestKind, Tile}`.

## Decision: renderer sharing (Task 3)

`PageRenderer` is `Send + Sync`, but its only rendering entry point is `render(&mut self, ...)`
(raster.rs:437), so an `Arc<PageRenderer>` cannot render and `Sync` buys nothing; `Send` is what counts,
because it makes `Mutex<PageRenderer>` shareable. Task 3 therefore keeps one renderer per document revision
as `Arc<Mutex<PageRenderer>>` in `Inner`, built lazily from `doc.display` and dropped when the revision
changes. `render_tile` clones the `Arc` out of the `Inner` lock, releases that lock, then locks the
renderer for the duration of the render, so page-info, text and search calls never wait for a render and
different documents render in parallel. Renders of one document serialize. That is acceptable for M1 and is
the first thing to measure in Task 7 (CATiledLayer draws tiles on several threads); if it limits scrolling,
replace the single renderer with a small checkout pool (`Mutex<Vec<PageRenderer>>`, two or three instances,
each a separate parse of the same `Arc<Vec<u8>>`). The API does not change either way, and the thread-local
fallback in the spec is not needed. Two constraints go with it. `Session` is `Send` but not `Sync`, so
`PdfDocument` keeps it in a `Mutex` (as planned) and must never hold that lock across a render. The engine's
own pool (`Document.renderer`) is not a substitute: it is a latest-wins queue (`set_queue` replaces pending
work, results come back through `try_recv`) and cannot serve concurrent synchronous callers.

Update 2026-10-16 (Task 3). Superseded by the Task 3 ruling: a lazily grown pool of up to 2 `Mutex<PageRenderer>`
per revision, so CATiledLayer's concurrent tile draws do not serialise on one core. It is `RendererPool` in
`core/editinpdf-core/src/render.rs`: two slots, each a `Mutex<Option<PageRenderer>>` that is filled the first time
a caller takes it. Task 3 took the first slot whose `try_lock` succeeded and, with both busy, blocked on slot 0
(the ruling called this round-robin; it was not). `PdfDocument` keeps the pool in `Inner` as an
`Option<Arc<RendererPool>>` tagged with the revision it was built for; `render_tile` takes the `Inner` lock only to
check the page and clone that `Arc` (making an empty pool first when the revision has changed), then draws with the
lock released.

Update 2026-10-18 (final M1 review, I2). Blocking on slot 0 made a tile wait 190-240 ms behind a 73 ms render
while slot 1 sat idle. The pool now keeps the slots' busy flags and a ticket line under one `Mutex` with a
`Condvar`: a caller takes the lowest free slot, or waits for whichever is let go of first, and waiting callers are
served in the order they came, so none can be passed over for ever. That lock is held only to read and set the
flags, never while a renderer draws; a slot's own `Mutex` is locked only by the caller holding the slot, so it is
never waited for. The lowest free slot is the one taken, so the second renderer is still built only when the
first is busy, and never a third. Measured with the review's probe (release build, Apple M5: one thread drawing a
6120 x 7920 px whole page over and over, three drawing 256 px tiles, for 4 s): the slowest tile took 219-324 ms
before and 10-11 ms after. The line is fair, and that has a price: the whole-page drawer now gets its turns (102
drawings in the 4 s instead of 24-25), so the tiles' median rose from 3 ms to 9 ms in that test. Tiles have no
priority over thumbnails and search's text reads; if the M4 device check shows that they need it, a priority lane
for tiles is the next step.

Baseline render time (Task 3): `whole_page_dimensions_follow_scale`, one line of text on a 612 x 792 pt page at
scale 0.5 (306 x 396 px), `cargo test` profile on the Apple M5: the first `render_tile` call takes 0.25 ms (it
includes parsing the document into the first renderer), the second 0.12 ms, the whole test about 1.0 ms with the
fixture and the open; the page is nearly blank, so this is a floor, to be re-measured with a real document in Task 7.

Tile render on the simulator (Task 7): one 1024 x 1024 tile of a text page (`renderTile` + `TileRenderer.image`, `ContinuousClock`, release Rust core, Debug app, iPhone 17 Pro simulator on iOS 26.5, Apple M5) takes 5.9 ms median uncontended (4.9-6.3 ms over 30 calls; the `CGImage` 0.004 ms, no copy), and 9.6 ms median (p90 16 ms, 160 tiles) while `CATiledLayer` draws several at once and a third waits for one of the two renderers; the cost is linear in pixels (about 5.7 ns each; a whole 306 x 396 page takes 0.7 ms), and Task 3 measured 0.8 ms for the engine's own drawing of such a tile, so most of it is moving the 4 MiB of pixels through the bridge (it copies them several times).

## Findings for later tasks

- Deployment target. Without `IPHONEOS_DEPLOYMENT_TARGET`, the 371 C objects of `aws-lc-sys` are stamped
  `minos 27.0` (the SDK's own version) in every slice, and linking the device `.a` into an iOS 17 image
  printed 371 `object file ... was built for newer 'iOS' version (27.0) than being linked (17.0)`
  warnings. `build-xcframework.sh` now exports `IPHONEOS_DEPLOYMENT_TARGET=17.0` and
  `MACOSX_DEPLOYMENT_TARGET=14.0` (the spec's iOS minimum and the Swift package's macOS platform) unless
  already set; the same link now prints none. The 391 objects per slice stamped older than that are the
  toolchain's precompiled sysroot crates (`compiler_builtins`, `std`, `core`, ...), which carry rustc's
  defaults (iOS 10.0, simulator 14.0, macOS 11.0); an older stamp never warns.
- Native libraries (`rustc --print native-static-libs`): iOS device and simulator
  `-framework CoreFoundation -liconv -lSystem -lc -lm`; macOS also `-framework Security` (from
  `security-framework`, which only the macOS build pulls in). Linking the spike from Swift needed none of
  them explicitly on the macOS and simulator slices (the Swift link already brings in Foundation, hence
  CoreFoundation and, on macOS, Security). A binary target carries no link flags, so the Swift package
  declares them in its `linkerSettings` (`ios/EditinPDFCore/Package.swift`): CoreFoundation and iconv on every
  slice, Security on macOS.
- `uniffi-bindgen --library` reads the macOS `.dylib` directly (the `UNIFFI_META_*` symbols survive
  `strip = "debuginfo"`), so the `.a` fallback is not needed. With `core/editinpdf-core/uniffi.toml` the
  generated files are `EditinPDFCore.swift`, `EditinPDFCoreFFI.h` and `EditinPDFCoreFFI.modulemap`, as the
  script expects. For the spike they expose only `engineVersion()` and `probePageCount(bytes:)`.
- The xcframework has the three slices `ios-arm64`, `ios-arm64-simulator` and `macos-arm64`.
- Run check. A throwaway Swift tool (generated Swift plus the xcframework slice) printed
  `editinpdf-core 0.1.0 / pdfcraft v0.7.1`, a page count of 1 for upstream's 1.7 KB `form.pdf`, 0 for
  non-PDF bytes, and the same counts from 8 concurrent calls, both on macOS and inside the booted iPhone 17
  Pro simulator (iOS 26.5, `xcrun simctl spawn`). Not exercised: a physical device.
- The `num_threads` patch matters at compile time only. Its sole caller in the tree is `time::util::refresh_tz()`,
  which nothing in boa or the engine calls (boa's local-time hook uses `UtcOffset::local_offset_at`, which
  calls `localtime_r` directly), so the crate is dead-stripped: the linked iOS image has no `num_threads`
  or `mach_task_self` symbol.
- `Session::open` starts a `RenderPool` of `available_parallelism().clamp(2, 8) - 1` worker threads per
  document (engine/src/lib.rs:775 and 3088); workers parse lazily on their first request (raster.rs:1002).
  Expect one to seven idle threads per open document on iOS.
- Plan details for Task 3: `RequestKind` has `Pixels` and `Text` (there is no `Raster`); `RenderRequest.scale`
  is `f32` device pixels per point and `Tile { x, y, w, h }` is in device pixels at that scale.

## Status at M1

M1 (the viewer) is complete at commit 8befba6, plus the CI and documentation commit after it and the fix wave that
followed the whole-branch review. This section records the end state in numbers, all measured on 2026-10-18 on the
Mac of the Environment table, except that Xcode is now 27.1 (27A9275; the spike used 27.0). The simulator is an
iPhone 17 Pro on iOS 26.5 (23F77), the Xcode project is generated with XcodeGen 2.45.4, and the engine is still
PdfCraft v0.7.1. The test counts are those after the fix wave; the sizes were measured before it.

| Item | Value |
|---|---|
| Rust tests, `cargo test -p editinpdf-core --locked` | 160 passed, 0 failed, 1 ignored: 107 unit tests, 10 in `tests/open.rs`, 18 in `tests/render.rs`, 25 in `tests/text.rs`. The ignored one is `dump_fixtures` (`tests/fixtures_export.rs`), which writes the PDFs the apps' tests open |
| Swift package tests, `swift test` in `ios/EditinPDFCore` (macOS) | 4 passed |
| App tests, `xcodebuild test`, scheme EditinPDF, iPhone 17 Pro simulator | 276 passed, 0 failed: 269 unit tests (16 files in `ios/EditinPDFTests`) and 7 UI tests. Testing takes 117 s, almost all of it the UI tests; `make lint test release-check` takes 138 s with everything built already |
| Tile render, one 1024 x 1024 px tile of a text page | 5.9 ms median uncontended, 9.6 ms median (p90 16 ms) while `CATiledLayer` draws several at once. Measured in Task 7 (see "Tile render on the simulator" above); not measured again since |
| `libeditinpdf_core.a`, release | `ios-arm64` 352,085,640 B (335.8 MiB), `ios-arm64-simulator` 351,736,656 B (335.4 MiB), `macos-arm64` 352,851,792 B (336.5 MiB): 0.8 MiB more per slice than the spike's |
| `EditinPDFCoreFFI.xcframework`, three slices (git-ignored) | 1,032,016 KiB (0.98 GiB) |
| cdylib, release (the spike's proxy for the linked size) | 23,752,760 B (22.7 MiB) for `aarch64-apple-ios`, 24,169,632 B (23.0 MiB) for `aarch64-apple-ios-sim`, 24,361,664 B (23.2 MiB) for `aarch64-apple-darwin`: about 0.1 MiB more than the spike's, so the real API (open, render, text, search) cost next to nothing. Well inside the 40 MB budget |
| `EditinPDF.app`, Release, for the simulator (arm64) | 25,040 KiB (24.5 MiB) in 5 files, the executable being 25,623,872 B; no PDF in it (`make release-check`) |
| Cold Rust pipeline, fresh target directory, `CI=1` | `cargo fmt --check` 0 s, clippy 47 s, `cargo test` 110 s, `build-xcframework.sh` 253 s: 7 minutes. `core/target` is 9.5 GiB afterwards: 4.4 GiB of host debug build, 1.6 GiB for each of the three release builds |

CI. `.github/workflows/ci.yml` runs these steps on GitHub's `xcode-27` runner image, the only hosted image with
Xcode 27 on 2026-10-18 (`macos-26`, and so `macos-latest`, ships Xcode 26.x; `xcode-27` is a public preview).
That runner is documented as 3 cores, 7 GB of RAM and a 14 GB disk, which is why the workflow does not cache
`core/target` (9.5 GiB) and deletes it before the Xcode steps. The workflow has been checked with actionlint
1.7.12 and its commands run on this Mac, but it has not run on a hosted runner: there is no GitHub remote yet. The
first run is also the first on an iOS 27 simulator; this Mac only has the iOS 26.5 runtime.

## Reproduce

```
core/scripts/build-xcframework.sh        # from any directory; PROFILE=debug for a dev build
cd core && cargo check -p editinpdf-core
make lint test release-check             # the M1 checks that CI runs (needs the XCFramework: make xcframework)
```
