SHELL := /bin/sh
.DEFAULT_GOAL := help

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
GHOSTTY := $(ROOT)/Vendor/ghostty
PROJECT := $(GHOSTTY)/macos/Ghostty.xcodeproj
CONFIGURATION ?= Debug
XCFRAMEWORK_TARGET ?= $(if $(filter Debug,$(CONFIGURATION)),native,universal)
DERIVED_DATA := $(ROOT)/DerivedData
ARTIFACT_DIR := $(ROOT)/Artifacts/$(CONFIGURATION)
APP := $(ARTIFACT_DIR)/Prompt.app
EXECUTABLE := $(APP)/Contents/MacOS/Prompt
ZIG := /opt/homebrew/opt/zig@0.15/bin/zig

.PHONY: help build run test xcode clean prepare sync check-app

help:
	@echo "Prompt local development"
	@echo
	@echo "  make run    Rebuild and launch $(APP)"
	@echo "  make build  Build the complete app bundle"
	@echo "  make test   Run the Prompt test suite"
	@echo "  make xcode  Prepare and open the native Xcode workspace"
	@echo "  make clean  Remove repo-local generated output"
	@echo
	@echo "Override the Xcode configuration with CONFIGURATION=Release."

sync:
	@set -eu; \
	if [ ! -d "$(GHOSTTY)/.git" ] && [ ! -f "$(GHOSTTY)/.git" ]; then \
		git -C "$(ROOT)" submodule update --init --recursive; \
	fi; \
	if [ ! -d "$(GHOSTTY)/.git" ] && [ ! -f "$(GHOSTTY)/.git" ]; then \
		echo "Ghostty submodule is missing after initialization." >&2; \
		exit 1; \
	fi; \
	rm -rf "$(GHOSTTY)/macos/Sources/Prompt" "$(GHOSTTY)/macos/Sources/GhosttyAppKit"; \
	mkdir -p "$(GHOSTTY)/macos/Sources" "$(GHOSTTY)/macos/Tests" \
		"$(GHOSTTY)/macos/Resources" \
		"$(GHOSTTY)/macos/Ghostty.xcodeproj/xcshareddata/xcschemes"; \
	cp -R "$(ROOT)/Sources/Prompt" "$(GHOSTTY)/macos/Sources/Prompt"; \
	cp -R "$(ROOT)/Sources/GhosttyAppKit" "$(GHOSTTY)/macos/Sources/GhosttyAppKit"; \
	cp "$(ROOT)/Tests/PromptAITests.swift" "$(ROOT)/Tests/PromptModelTests.swift" \
		"$(GHOSTTY)/macos/Tests/"; \
	rm -rf "$(GHOSTTY)/macos/Resources/Prompt" "$(GHOSTTY)/images/Prompt.icon"; \
	cp -R "$(ROOT)/Resources/Prompt" "$(GHOSTTY)/macos/Resources/Prompt"; \
	cp -R "$(ROOT)/Resources/Prompt.icon" "$(GHOSTTY)/images/Prompt.icon"; \
	cp "$(ROOT)/Sources/Prompt.xcscheme" \
		"$(GHOSTTY)/macos/Ghostty.xcodeproj/xcshareddata/xcschemes/Prompt.xcscheme"; \
	if ! git -C "$(GHOSTTY)" apply --reverse --check \
		"$(ROOT)/Patches/ghostty/0001-prompt-integration.patch" 2>/dev/null; then \
		git -C "$(GHOSTTY)" apply "$(ROOT)/Patches/ghostty/0001-prompt-integration.patch"; \
	fi

prepare: sync
	@set -eu; \
	if [ ! -x "$(ZIG)" ]; then \
		HOMEBREW_NO_AUTO_UPDATE=1 brew install zig@0.15; \
	fi; \
	rm -rf "$(GHOSTTY)/macos/GhosttyKit.xcframework"; \
	cd "$(GHOSTTY)"; \
	env -u SWIFT_DEBUG_INFORMATION_FORMAT -u SWIFT_DEBUG_INFORMATION_VERSION \
	"$(ZIG)" build -Demit-xcframework=true -Demit-macos-app=false \
		-Dxcframework-target="$(XCFRAMEWORK_TARGET)"; \
	if [ ! -d "$(GHOSTTY)/zig-out/share/terminfo" ]; then \
		if [ ! -d "/Applications/Ghostty.app/Contents/Resources" ]; then \
			echo "Ghostty resources are missing; install Ghostty.app once to seed them." >&2; \
			exit 1; \
		fi; \
		mkdir -p "$(GHOSTTY)/zig-out/share"; \
		cp -R "/Applications/Ghostty.app/Contents/Resources/." "$(GHOSTTY)/zig-out/share/"; \
	fi

build: prepare
	rm -rf "$(APP)" "$(APP).dSYM"
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme Prompt \
		-configuration "$(CONFIGURATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		CONFIGURATION_BUILD_DIR="$(ARTIFACT_DIR)" \
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

test: prepare
	xcodebuild test \
		-project "$(PROJECT)" \
		-scheme Prompt \
		-configuration "$(CONFIGURATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		CONFIGURATION_BUILD_DIR="$(ARTIFACT_DIR)" \
		-disableAutomaticPackageResolution \
		-onlyUsePackageVersionsFromResolvedFile \
		CODE_SIGNING_ALLOWED=NO

xcode: prepare
	open "$(ROOT)/Prompt.xcworkspace"

clean:
	rm -rf "$(ROOT)/Artifacts" "$(ROOT)/DerivedData"
