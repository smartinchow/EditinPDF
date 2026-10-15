#!/bin/zsh
# Builds editinpdf-core for iOS device, iOS simulator and macOS, generates the Swift bindings
# and assembles ios/EditinPDFCore/EditinPDFCoreFFI.xcframework. Run from anywhere.
#   PROFILE=release (default) | debug
#   CARGO_TARGET_DIR=<dir>   honoured (a relative one is relative to where the script is run, as for cargo)
#   CI=<anything>            builds with --locked: a stale Cargo.lock fails the build instead of being rewritten
set -euo pipefail
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:$PATH"
# Stamp the libraries with the app's minimum OS (iOS 17.0, the Swift package's macOS 14). Without it the
# C objects (aws-lc-sys) carry the SDK's own version, 27.0, and linking them into an iOS 17 app prints
# one "built for newer 'iOS' version" warning per object (371). See docs/adr/0001-ios-build-spike.md.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORE="$ROOT/core"; OUT="$CORE/scripts/out"; PKG="$ROOT/ios/EditinPDFCore"
# Where cargo writes. The libraries and the dylib are read back from there below, so the script and cargo
# must agree on it: resolve it once, to an absolute path (before the `cd`, so a relative CARGO_TARGET_DIR
# means what it means to the caller), and hand that same path to every cargo call.
TARGET_DIR="${${CARGO_TARGET_DIR:-$CORE/target}:A}"
export CARGO_TARGET_DIR="$TARGET_DIR"
LIB=libeditinpdf_core.a
DYLIB=libeditinpdf_core.dylib
FFI=EditinPDFCoreFFI.xcframework
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)
PROFILE="${PROFILE:-release}"
case "$PROFILE" in
  release) PROFILE_FLAG=(--release) ;;
  debug)   PROFILE_FLAG=() ;;   # cargo's default profile; its output directory is <target dir>/<triple>/debug
  *) echo "PROFILE must be 'release' or 'debug', got '$PROFILE'" >&2; exit 2 ;;
esac
LOCKED=()
if [[ -n "${CI:-}" ]]; then LOCKED=(--locked); fi

cd "$CORE"
for t in $TARGETS; do cargo build $LOCKED $PROFILE_FLAG -p editinpdf-core --target $t; done

# Library mode: uniffi-bindgen reads the exported API from the host build's dylib.
rm -rf "$OUT"; mkdir -p "$OUT/headers" "$OUT/stage" "$PKG/Sources/EditinPDFCore"
cargo run -q $LOCKED -p uniffi-bindgen -- generate \
  --library "$TARGET_DIR/aarch64-apple-darwin/$PROFILE/$DYLIB" \
  --language swift --out-dir "$OUT/bindings"
cp "$OUT/bindings/EditinPDFCore.swift" "$PKG/Sources/EditinPDFCore/EditinPDFCore.swift"
cp "$OUT/bindings/EditinPDFCoreFFI.h" "$OUT/headers/"
cp "$OUT/bindings/EditinPDFCoreFFI.modulemap" "$OUT/headers/module.modulemap"

# Assemble in a scratch directory and move the result into place only once xcodebuild has succeeded, so a
# failed run never leaves the package without an xcframework. (The scratch directory is under $OUT, on the
# same volume as the package, so the move is a rename.)
xcodebuild -create-xcframework \
  -library "$TARGET_DIR/aarch64-apple-ios/$PROFILE/$LIB"     -headers "$OUT/headers" \
  -library "$TARGET_DIR/aarch64-apple-ios-sim/$PROFILE/$LIB" -headers "$OUT/headers" \
  -library "$TARGET_DIR/aarch64-apple-darwin/$PROFILE/$LIB"  -headers "$OUT/headers" \
  -output "$OUT/stage/$FFI"
rm -rf "$PKG/$FFI"
mv "$OUT/stage/$FFI" "$PKG/$FFI"
echo "OK: $PKG/$FFI"
