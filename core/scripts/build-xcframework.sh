#!/bin/zsh
# Builds editinpdf-core for iOS device, iOS simulator and macOS, generates the Swift bindings
# and assembles ios/EditinPDFCore/EditinPDFCoreFFI.xcframework. Run from anywhere.
#   PROFILE=release (default) | debug
set -euo pipefail
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:$PATH"
# Stamp the libraries with the app's minimum OS (iOS 17.0, the Swift package's macOS 14). Without it the
# C objects (aws-lc-sys) carry the SDK's own version, 27.0, and linking them into an iOS 17 app prints
# one "built for newer 'iOS' version" warning per object (371). See docs/adr/0001-ios-build-spike.md.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORE="$ROOT/core"; OUT="$CORE/scripts/out"; PKG="$ROOT/ios/EditinPDFCore"
LIB=libeditinpdf_core.a
DYLIB=libeditinpdf_core.dylib
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)
PROFILE="${PROFILE:-release}"
case "$PROFILE" in
  release) PROFILE_FLAG=(--release) ;;
  debug)   PROFILE_FLAG=() ;;   # cargo's default profile; its output directory is target/<triple>/debug
  *) echo "PROFILE must be 'release' or 'debug', got '$PROFILE'" >&2; exit 2 ;;
esac

cd "$CORE"
for t in $TARGETS; do cargo build $PROFILE_FLAG -p editinpdf-core --target $t; done

# Library mode: uniffi-bindgen reads the exported API from the host build's dylib.
rm -rf "$OUT"; mkdir -p "$OUT/headers" "$PKG/Sources/EditinPDFCore"
cargo run -q -p uniffi-bindgen -- generate \
  --library "target/aarch64-apple-darwin/$PROFILE/$DYLIB" \
  --language swift --out-dir "$OUT/bindings"
cp "$OUT/bindings/EditinPDFCore.swift" "$PKG/Sources/EditinPDFCore/EditinPDFCore.swift"
cp "$OUT/bindings/EditinPDFCoreFFI.h" "$OUT/headers/"
cp "$OUT/bindings/EditinPDFCoreFFI.modulemap" "$OUT/headers/module.modulemap"

rm -rf "$PKG/EditinPDFCoreFFI.xcframework"
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-ios/$PROFILE/$LIB"     -headers "$OUT/headers" \
  -library "target/aarch64-apple-ios-sim/$PROFILE/$LIB" -headers "$OUT/headers" \
  -library "target/aarch64-apple-darwin/$PROFILE/$LIB"  -headers "$OUT/headers" \
  -output "$PKG/EditinPDFCoreFFI.xcframework"
echo "OK: $PKG/EditinPDFCoreFFI.xcframework"
