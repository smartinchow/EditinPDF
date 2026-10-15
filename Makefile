# EditinPDF developer entry points. Run from the repository root.

SHELL := /bin/zsh
export PATH := $(HOME)/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:$(PATH)

CORE      := core
IOS       := ios
SCHEME    := EditinPDF
SIM       := platform=iOS Simulator,name=iPhone 17 Pro
TAG       ?=

.PHONY: help setup core core-test xcframework project ios test update-upstream notices clean

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

xcframework: ## Build the Rust core for device + simulator and generate the Swift bindings
	$(CORE)/scripts/build-xcframework.sh

project: ## Generate ios/EditinPDF.xcodeproj from ios/project.yml
	cd $(IOS) && xcodegen generate

ios: project ## Build the app for the simulator
	cd $(IOS) && xcodebuild -project $(SCHEME).xcodeproj -scheme $(SCHEME) -destination '$(SIM)' build | tail -20

test: core-test project ## cargo test + Xcode unit tests on the simulator
	cd $(IOS) && xcodebuild -project $(SCHEME).xcodeproj -scheme $(SCHEME) -destination '$(SIM)' test | tail -40

update-upstream: ## Move the engine submodule to release TAG=vX.Y.Z and re-run the bridge tests
	@test -n "$(TAG)" || (echo "usage: make update-upstream TAG=vX.Y.Z"; exit 1)
	git -C upstream/pdfcraft fetch --tags origin
	git -C upstream/pdfcraft checkout $(TAG)
	cd $(CORE) && cargo test
	@echo "Engine now at $(TAG). Commit the submodule pointer: git add upstream/pdfcraft && git commit"

notices: ## Regenerate docs/THIRD-PARTY-NOTICES.md
	$(CORE)/scripts/notices.sh

clean:
	cd $(CORE) && cargo clean
	rm -rf $(IOS)/build $(IOS)/DerivedData $(CORE)/scripts/out
