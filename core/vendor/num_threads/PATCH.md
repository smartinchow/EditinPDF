# num_threads 0.1.7: EditinPDF patch

Vendored copy of [`num_threads`](https://crates.io/crates/num_threads) 0.1.7 (MIT OR Apache-2.0;
`LICENSE-Apache` and `LICENSE-MIT` are the upstream files, unchanged). It replaces the registry copy
through `[patch.crates-io]` in `core/Cargo.toml` and is kept out of the workspace by
`exclude = ["vendor"]` there. Only `src/apple.rs` differs from the published crate.

## Why

`src/apple.rs` calls `libc::mach_task_self()`. libc (0.2.190, the newest 0.2.x) declares
`mach_task_self_` and `mach_task_self()` only under `#[cfg(target_os = "macos")]` (both are deprecated
there in favour of the `mach2` crate), so the crate does not compile for iOS:

```
error[E0425]: cannot find function `mach_task_self` in crate `libc`
  --> num_threads-0.1.7/src/apple.rs:34:31
   |
34 |     let task = unsafe { libc::mach_task_self() };
   |                               ^^^^^^^^^^^^^^ not found in `libc`
```

The crate is reached through editinpdf-core -> pdfcraft-engine -> pdfcraft-js -> boa_engine 0.22 ->
time 0.3.55 (feature `local-offset`) -> num_threads 0.1.7. `cargo update` cannot fix it: num_threads
0.1.7, time 0.3.55 and libc 0.2.190 are each the newest release in their series.

## The change

Two marked edits (`EditinPDF patch:`), both in `src/apple.rs`:

1. Declare `static mut mach_task_self_: mach_port_t;` in the crate's existing `extern "C"` block.
   libSystem exports `_mach_task_self_` on every Apple platform (checked in the iPhoneOS, iPhoneSimulator
   and MacOSX 27.0 SDKs), and `mach_task_self()` is only a macro over it in `<mach/mach_init.h>`.
2. Read that variable (`unsafe { mach_task_self_ }`) instead of calling `libc::mach_task_self()`.

On macOS this is the same variable libc's function returned, so behaviour is unchanged there. The patch
only has to make the crate compile: its sole caller, `time::util::refresh_tz()`, is never called by boa or
the engine, so the code is dead-stripped from the linked app.

## Removing it

Delete this directory, the `num_threads` line under `[patch.crates-io]`, and `exclude = ["vendor"]` in
`core/Cargo.toml` once num_threads (or libc) ships a fix. The change should be proposed upstream
(github.com/jhpratt/num_threads); that has not been done yet.
