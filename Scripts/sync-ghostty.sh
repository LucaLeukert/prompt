#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ghostty_root="$repo_root/Vendor/ghostty"

if [ ! -d "$ghostty_root/.git" ] && [ ! -f "$ghostty_root/.git" ]; then
    echo "Ghostty submodule is missing. Run: git submodule update --init --recursive" >&2
    exit 1
fi

# Prompt-owned files stay in this repository. Copy them into the pinned
# Ghostty checkout before building, then apply the small integration patch.
rm -rf "$ghostty_root/macos/Sources/Prompt" "$ghostty_root/macos/Sources/GhosttyAppKit"
mkdir -p "$ghostty_root/macos/Sources" "$ghostty_root/macos/Tests" "$ghostty_root/macos/Resources"
cp -R "$repo_root/Sources/Prompt" "$ghostty_root/macos/Sources/Prompt"
cp -R "$repo_root/Sources/GhosttyAppKit" "$ghostty_root/macos/Sources/GhosttyAppKit"
cp "$repo_root/Tests/PromptAITests.swift" "$repo_root/Tests/PromptModelTests.swift" "$ghostty_root/macos/Tests/"
rm -rf "$ghostty_root/macos/Resources/Prompt"
cp -R "$repo_root/Resources/Prompt" "$ghostty_root/macos/Resources/Prompt"
mkdir -p "$ghostty_root/macos/Ghostty.xcodeproj/xcshareddata/xcschemes"
cp "$repo_root/Sources/Prompt.xcscheme" "$ghostty_root/macos/Ghostty.xcodeproj/xcshareddata/xcschemes/Prompt.xcscheme"

patch_file="$repo_root/Patches/ghostty/0001-prompt-integration.patch"
if git -C "$ghostty_root" apply --reverse --check "$patch_file" 2>/dev/null; then
    exit 0
fi
git -C "$ghostty_root" apply "$patch_file"
