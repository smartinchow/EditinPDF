# EditinPDF developer entry points. Run from the repository root.
#
# No recipe pipes xcodebuild into another command. macOS ships GNU Make 3.81, which ignores
# .SHELLFLAGS (added in 3.82), so `xcodebuild ... | tail` would report tail's exit status and a failed build
# or test would look like a pass. -quiet keeps xcodebuild's own output to warnings and errors instead.

SHELL := /bin/zsh
export PATH := $(HOME)/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:$(PATH)

CORE      := core
IOS       := ios
SCHEME    := EditinPDF
# `make test XCFLAGS=` prints xcodebuild's full output.
XCFLAGS   ?= -quiet
XCODEBUILD = xcodebuild $(XCFLAGS) -project $(SCHEME).xcodeproj -scheme $(SCHEME)
# Where `make test` leaves its result bundle, relative to $(IOS) (git-ignored; `open` it in Xcode).
RESULT    := build/$(SCHEME).xcresult
# The simulator `make test` runs on: the first available iPhone on the newest iOS runtime that is installed
# (scripts/pick-simulator.sh). Pin one with `make test SIM_UDID=<udid>`; `xcrun simctl list devices available`
# lists them.
SIM_UDID  ?=
TAG       ?=

.PHONY: help setup core core-test lint xcframework project ios test release-check update-upstream notices clean

help:
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/'

setup: ## Install the toolchain (rustup + iOS targets, cmake, xcodegen) and fetch the engine submodule
	brew install rustup cmake xcodegen
	rustup default stable
	rustup target add aarch64-apple-ios aarch64-apple-ios-sim
	git submodule update --init

core: ## Build the Rust core for the host (fast check)
	cd $(CORE) && cargo build

core-test: ## Run the bridge test-suite
	cd $(CORE) && cargo test

lint: ## cargo fmt --check and clippy with warnings denied (CI runs both before the tests)
	cd $(CORE) && cargo fmt --check
	cd $(CORE) && cargo clippy -p editinpdf-core --all-targets --locked -- -D warnings

xcframework: ## Build the Rust core for device + simulator and generate the Swift bindings
	$(CORE)/scripts/build-xcframework.sh

project: ## Generate ios/EditinPDF.xcodeproj from ios/project.yml
	cd $(IOS) && xcodegen generate

ios: project ## Build the app for the simulator
	cd $(IOS) && $(XCODEBUILD) -destination 'generic/platform=iOS Simulator' build

test: core-test project ## cargo test, the Swift package tests, then all of the app's Xcode tests (unit and UI) on a simulator
	cd $(IOS)/EditinPDFCore && swift test
	udid='$(SIM_UDID)'; \
	if [ -z "$$udid" ]; then udid=$$(scripts/pick-simulator.sh) || exit 1; fi; \
	rm -rf $(IOS)/$(RESULT); \
	cd $(IOS) && $(XCODEBUILD) -destination "platform=iOS Simulator,id=$$udid" -resultBundlePath $(RESULT) test

release-check: project ## Build Release for the simulator and fail if the .app ships any PDF (the UI-test fixtures are Debug-only)
	scripts/check-release-bundle.sh

update-upstream: ## Move the engine submodule to release TAG=vX.Y.Z and re-run the bridge tests
	@test -n "$(TAG)" || (echo "usage: make update-upstream TAG=vX.Y.Z"; exit 1)
	git -C upstream/pdfcraft fetch --tags origin
	git -C upstream/pdfcraft checkout $(TAG)
	cd $(CORE) && cargo test
	@echo "Engine now at $(TAG). Commit the submodule pointer: git add upstream/pdfcraft && git commit"

# Not implemented yet: the Licenses screen and docs/THIRD-PARTY-NOTICES.md arrive with milestone M4, and the
# generator (cargo about or cargo deny list, see the design spec, section 7) with them. Fails rather than
# pretending to have written the file.
notices: ## (milestone M4, not implemented yet) Regenerate docs/THIRD-PARTY-NOTICES.md
	@echo "make notices: not implemented until milestone M4; docs/THIRD-PARTY-NOTICES.md is a stub until then." >&2
	@exit 1

clean:
	cd $(CORE) && cargo clean
	rm -rf $(IOS)/build $(IOS)/DerivedData $(CORE)/scripts/out
