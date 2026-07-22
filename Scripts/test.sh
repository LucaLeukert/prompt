#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ghostty_root="$repo_root/Vendor/ghostty"

"$repo_root/Scripts/sync-ghostty.sh"

xcodebuild test \
    -project "$ghostty_root/macos/Ghostty.xcodeproj" \
    -scheme Prompt \
    -configuration Debug \
    -derivedDataPath "$repo_root/DerivedData" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGNING_ALLOWED=NO \
    -only-testing:PromptTests/PromptAITests
