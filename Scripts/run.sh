#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
prompt_app="$repo_root/DerivedData/Build/Products/Debug/Prompt.app"
prompt_executable="$prompt_app/Contents/MacOS/Prompt"

"$repo_root/Scripts/build.sh"

# Never let an older process keep a pre-build image alive under the same bundle ID.
pkill -f "^${prompt_executable}$" 2>/dev/null || true
open -na "$prompt_app"
