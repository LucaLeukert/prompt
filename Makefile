SHELL := /bin/sh
.DEFAULT_GOAL := help

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
GHOSTTY := $(ROOT)/Vendor/ghostty
GHOSTTY_BUILD := $(ROOT)/.build/ghostty
PROJECT := $(ROOT)/Prompt.xcodeproj
CONFIGURATION ?= Debug
XCFRAMEWORK_TARGET ?= $(if $(filter Debug,$(CONFIGURATION)),native,universal)
DERIVED_DATA := $(ROOT)/DerivedData
ARTIFACT_DIR := $(ROOT)/Artifacts/$(CONFIGURATION)
APP := $(ARTIFACT_DIR)/Prompt.app
EXECUTABLE := $(APP)/Contents/MacOS/Prompt
# Set ZIG to use a custom executable. Otherwise prepare resolves Homebrew's
# prefix after it installs zig@0.15, so first-time setup works on either CPU.
ZIG ?=

.PHONY: help build run test test-prepared lint format lint-install xcode clean prepare sync patch-check project check-app check-ghostty-build check-vendor

help:
	@echo "Prompt local development"
	@echo
	@echo "  make run    Rebuild and launch $(APP)"
	@echo "  make build  Build the complete app bundle"
	@echo "  make test   Run the Prompt test suite"
	@echo "  make lint   Check formatting, project generation, patches, and Actions"
	@echo "  make patch-check  Verify every Prompt patch against pinned Ghostty"
	@echo "  make format Apply the repository Swift formatting rules"
	@echo "  make lint-install  Install local build and lint tools"
	@echo "  make xcode  Prepare and open the Prompt-owned Xcode project"
	@echo "  make clean  Remove repo-local generated output"
	@echo
	@echo "Override the Xcode configuration with CONFIGURATION=Release."

# Prepare an isolated Ghostty worktree. The pinned submodule always remains
# pristine, and every sync starts from its exact commit before applying Prompt's
# small, ordered integration patches.
sync:
	@set -eu; \
	if [ ! -d "$(GHOSTTY)/.git" ] && [ ! -f "$(GHOSTTY)/.git" ]; then \
		git -C "$(ROOT)" submodule update --init --recursive; \
	fi; \
	if [ ! -d "$(GHOSTTY)/.git" ] && [ ! -f "$(GHOSTTY)/.git" ]; then \
		echo "Ghostty submodule is missing after initialization." >&2; \
		exit 1; \
	fi; \
	$(MAKE) --no-print-directory check-vendor; \
	if [ ! -e "$(GHOSTTY_BUILD)/.git" ]; then \
		mkdir -p "$(ROOT)/.build"; \
		git -C "$(GHOSTTY)" worktree add --detach "$(GHOSTTY_BUILD)" HEAD; \
	fi; \
	git -C "$(GHOSTTY_BUILD)" reset --hard "$$(git -C "$(GHOSTTY)" rev-parse HEAD)" >/dev/null; \
	for patch in "$(ROOT)"/Patches/ghostty/*.patch; do \
		echo "Applying $${patch#$(ROOT)/}"; \
		git -C "$(GHOSTTY_BUILD)" apply --check "$$patch"; \
		git -C "$(GHOSTTY_BUILD)" apply "$$patch"; \
	done

patch-check: sync

project: sync
	@command -v xcodegen >/dev/null || { echo "Missing xcodegen; run: make lint-install" >&2; exit 1; }
	xcodegen generate --spec "$(ROOT)/project.yml" --project "$(ROOT)"
	@mkdir -p "$(PROJECT)/project.xcworkspace/xcshareddata/swiftpm"
	@cp "$(ROOT)/Config/Package.resolved" \
		"$(PROJECT)/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

prepare: project
	@set -eu; \
	if [ -n "$(ZIG)" ]; then \
		zig="$(ZIG)"; \
	else \
		if ! brew list --versions zig@0.15 >/dev/null 2>&1; then \
			HOMEBREW_NO_AUTO_UPDATE=1 brew install zig@0.15; \
		fi; \
		zig="$$(brew --prefix zig@0.15)/bin/zig"; \
	fi; \
	if [ ! -x "$$zig" ]; then \
		echo "Zig executable is missing: $$zig" >&2; \
		exit 1; \
	fi; \
	cd "$(GHOSTTY_BUILD)"; \
	env -u SWIFT_DEBUG_INFORMATION_FORMAT -u SWIFT_DEBUG_INFORMATION_VERSION \
	"$$zig" build -Demit-xcframework=true -Demit-macos-app=false \
		-Dxcframework-target="$(XCFRAMEWORK_TARGET)"; \
	if [ ! -d "$(GHOSTTY_BUILD)/zig-out/share/terminfo" ]; then \
		if [ ! -d "/Applications/Ghostty.app/Contents/Resources" ]; then \
			echo "Ghostty resources are missing; install Ghostty.app once to seed them." >&2; \
			exit 1; \
		fi; \
		mkdir -p "$(GHOSTTY_BUILD)/zig-out/share"; \
		cp -R "/Applications/Ghostty.app/Contents/Resources/." "$(GHOSTTY_BUILD)/zig-out/share/"; \
	fi

build: prepare
	rm -rf "$(APP)" "$(APP).dSYM"
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme Prompt \
		-configuration "$(CONFIGURATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		CONFIGURATION_BUILD_DIR="$(ARTIFACT_DIR)" \
		-disableAutomaticPackageResolution \
		-onlyUsePackageVersionsFromResolvedFile \
		CODE_SIGNING_ALLOWED=NO \
		build
	$(MAKE) --no-print-directory check-app

check-app:
	@set -eu; \
	for required_path in \
		"$(EXECUTABLE)" \
		"$(APP)/Contents/Resources/Fonts/Geist-Variable.ttf" \
		"$(APP)/Contents/Resources/Fonts/GeistMono-Variable.ttf"; \
	do \
		if [ ! -e "$$required_path" ]; then \
			echo "Required app resource is missing: $$required_path" >&2; \
			exit 1; \
		fi; \
	done; \
	echo; \
	echo "Prompt is ready: $(APP)"

run: build
	pkill -f "^$(EXECUTABLE)$$" 2>/dev/null || true
	open -na "$(APP)"

test: prepare test-prepared

test-prepared: check-ghostty-build
	xcodebuild test \
		-project "$(PROJECT)" \
		-scheme Prompt \
		-configuration "$(CONFIGURATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		CONFIGURATION_BUILD_DIR="$(ARTIFACT_DIR)" \
		-disableAutomaticPackageResolution \
		-onlyUsePackageVersionsFromResolvedFile \
		CODE_SIGNING_ALLOWED=NO $(XCODEBUILD_SETTINGS)

check-ghostty-build:
	@set -eu; \
	for required_path in \
		"$(GHOSTTY_BUILD)/macos/GhosttyKit.xcframework" \
		"$(GHOSTTY_BUILD)/zig-out/share/terminfo"; \
	do \
		if [ ! -e "$$required_path" ]; then \
			echo "Prepared Ghostty output is missing: $$required_path" >&2; \
			exit 1; \
		fi; \
	done

lint:
	@command -v swiftformat >/dev/null || { echo "Missing swiftformat; run: make lint-install" >&2; exit 1; }
	@command -v swiftlint >/dev/null || { echo "Missing swiftlint; run: make lint-install" >&2; exit 1; }
	@command -v actionlint >/dev/null || { echo "Missing actionlint; run: make lint-install" >&2; exit 1; }
	@command -v xcodegen >/dev/null || { echo "Missing xcodegen; run: make lint-install" >&2; exit 1; }
	swiftformat Sources Tests --lint --reporter github-actions-log
	swiftlint lint --strict
	actionlint
	$(MAKE) --no-print-directory project
	git diff --check
	$(MAKE) --no-print-directory check-vendor

format:
	@command -v swiftformat >/dev/null || { echo "Missing swiftformat; run: make lint-install" >&2; exit 1; }
	swiftformat Sources Tests

lint-install:
	HOMEBREW_NO_AUTO_UPDATE=1 brew install swiftformat swiftlint actionlint xcodegen

xcode: prepare
	open "$(PROJECT)"

clean:
	@set -eu; \
	if [ -e "$(GHOSTTY_BUILD)/.git" ]; then \
		git -C "$(GHOSTTY)" worktree remove --force "$(GHOSTTY_BUILD)"; \
	fi; \
	rm -rf "$(ROOT)/Artifacts" "$(ROOT)/DerivedData" "$(ROOT)/Prompt.xcodeproj"

check-vendor:
	@set -eu; \
	status="$$(git -C "$(GHOSTTY)" status --porcelain)"; \
	if [ -n "$$status" ]; then \
		echo "Vendor/ghostty must remain pristine; generated integration belongs in .build/ghostty." >&2; \
		printf '%s\n' "$$status" >&2; \
		exit 1; \
	fi
