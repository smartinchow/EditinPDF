#!/bin/bash
# A Release build must not ship the UI tests' sample documents: ios/EditinPDFUITests/Fixtures is a
# Debug-only resource folder (ios/project.yml excludes it from Release). This builds the Release
# configuration for the iOS Simulator and fails if the resulting EditinPDF.app contains a PDF anywhere.
# `make release-check` and the CI workflow both run it.
#
#   scripts/check-release-bundle.sh              build Release into ios/build/release-check, check that app
#   scripts/check-release-bundle.sh path/to.app  check an existing bundle only, no build
#
# Needs ios/EditinPDF.xcodeproj (make project) and the XCFramework (make xcframework) when it builds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/ios"
SCHEME=EditinPDF

if (( $# > 1 )); then
  echo "usage: $0 [path/to/$SCHEME.app]" >&2
  exit 2
fi

if (( $# == 1 )); then
  APP="$1"
else
  [[ -d "$IOS/$SCHEME.xcodeproj" ]] || { echo "check-release-bundle: no ios/$SCHEME.xcodeproj; run 'make project'" >&2; exit 1; }
  [[ -d "$IOS/EditinPDFCore/EditinPDFCoreFFI.xcframework" ]] || { echo "check-release-bundle: no XCFramework; run 'make xcframework'" >&2; exit 1; }
  DERIVED="$IOS/build/release-check"
  APP="$DERIVED/Build/Products/Release-iphonesimulator/$SCHEME.app"
  # An incremental build can leave files from an earlier one in the bundle; start from no bundle, so the
  # one checked below is the one this build made.
  rm -rf "$APP"
  # Generic destination: the Rust core is arm64-only for the simulator (project.yml excludes x86_64).
  xcodebuild -quiet -project "$IOS/$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" build
fi

if [[ ! -f "$APP/Info.plist" ]]; then
  echo "FAIL: $APP is not an app bundle (no Info.plist), so nothing was checked" >&2
  exit 1
fi

pdfs="$(find "$APP" -iname '*.pdf')"
if [[ -n "$pdfs" ]]; then
  echo "FAIL: the Release bundle ships PDF files (UI-test fixtures must stay out of Release):" >&2
  echo "  ${pdfs//$'\n'/$'\n'  }" >&2
  exit 1
fi

files="$(find "$APP" -type f | wc -l | tr -d ' ')"
size="$(du -sk "$APP" | cut -f1)"
echo "OK: $(basename "$APP") has $files files ($(( size / 1024 )) MiB) and no *.pdf"
