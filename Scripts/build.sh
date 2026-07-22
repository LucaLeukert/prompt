#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ghostty_root="$repo_root/Vendor/ghostty"
framework="$ghostty_root/macos/GhosttyKit.xcframework"
dependencies="$repo_root/DerivedData/PromptDependencies"
mkdir -p "$dependencies"

"$repo_root/Scripts/sync-ghostty.sh"

zig_bin=/opt/homebrew/opt/zig@0.15/bin/zig
if [ ! -x "$zig_bin" ]; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew install zig@0.15
fi

# Prompt extends libghostty. Always regenerate the native XCFramework so the
# Swift application cannot silently link an older prebuilt terminal core.
(cd "$ghostty_root" && "$zig_bin" build \
    -Demit-xcframework=true \
    -Demit-macos-app=false \
    -Dxcframework-target=native)

if [ ! -d "$ghostty_root/zig-out/share/terminfo" ]; then
    installed_resources=/Applications/Ghostty.app/Contents/Resources
    if [ ! -d "$installed_resources" ]; then
        echo "Ghostty resources are missing; install Ghostty.app once to seed terminal resources." >&2
        exit 1
    fi
    mkdir -p "$ghostty_root/zig-out/share"
    cp -R "$installed_resources/." "$ghostty_root/zig-out/share/"
fi

xcodebuild \
    -project "$ghostty_root/macos/Ghostty.xcodeproj" \
    -scheme Prompt \
    -configuration Debug \
    -derivedDataPath "$repo_root/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    build

geist_root="$dependencies/geist-1.7.2"
if [ ! -f "$geist_root/GeistMono/variable/GeistMono[wght].ttf" ]; then
    archive="$dependencies/geist-font-v1.7.2.zip"
    curl -fL https://github.com/vercel/geist-font/releases/download/v1.7.2/geist-font-v1.7.2.zip -o "$archive"
    unpack=$(mktemp -d)
    unzip -q "$archive" -d "$unpack"
    mv "$unpack/geist-font" "$geist_root"
fi

font_resources="$repo_root/DerivedData/Build/Products/Debug/Prompt.app/Contents/Resources/Fonts"
mkdir -p "$font_resources"
cp "$geist_root/Geist/variable/Geist[wght].ttf" "$font_resources/Geist-Variable.ttf"
cp "$geist_root/GeistMono/variable/GeistMono[wght].ttf" "$font_resources/GeistMono-Variable.ttf"
cp "$geist_root/OFL.txt" "$font_resources/Geist-OFL.txt"
