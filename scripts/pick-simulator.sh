#!/bin/bash
# Prints the UDID of the simulator the app's Xcode tests should run on: the first available iPhone on the
# newest iOS runtime that is installed. No device name is written down anywhere, because the set of
# devices differs between developer machines and CI runner images (an "iPhone 17 Pro" exists on iOS 26
# images and not on the iOS 27 one).
#
#   udid=$(scripts/pick-simulator.sh)
#   xcodebuild test ... -destination "platform=iOS Simulator,id=$udid"
#
# stdout is the UDID and nothing else; what was picked goes to stderr. Exits 1 when there is no iPhone
# simulator on any iOS runtime, after listing what there is.
set -euo pipefail

devices="$(xcrun simctl list devices available --json)"

# One entry per iOS runtime ("...SimRuntime.iOS-26-5" is iOS 26.5) that has at least one available iPhone,
# newest version first by sort (versions compare as number lists, so 26.10 is above 26.5), and the first
# iPhone of the newest runtime in simctl's own order.
picked="$(jq -r '
  def runtime_version: capture("SimRuntime\\.iOS-(?<v>[0-9]+(-[0-9]+)*)$").v | split("-") | map(tonumber);
  [ .devices | to_entries[]
    | select(.key | test("SimRuntime\\.iOS-[0-9]+(-[0-9]+)*$"))
    | { version: (.key | runtime_version),
        iphones: [ .value[] | select(.isAvailable != false and (.name | startswith("iPhone"))) ] }
    | select(.iphones | length > 0) ]
  | sort_by(.version) | last
  | select(. != null)
  | [ .iphones[0].udid, .iphones[0].name, (.version | map(tostring) | join(".")) ]
  | @tsv
' <<<"$devices")"

if [[ -z "$picked" ]]; then
  echo "pick-simulator: no available iPhone simulator on an iOS runtime. What is installed:" >&2
  xcrun simctl list devices available >&2 || true
  exit 1
fi

IFS=$'\t' read -r udid name version <<<"$picked"
echo "pick-simulator: $name, iOS $version ($udid)" >&2
echo "$udid"
