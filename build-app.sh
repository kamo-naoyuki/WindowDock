#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app="dist/WindowDock.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/WindowDock" "$app/Contents/MacOS/WindowDock"
cp Support/Info.plist "$app/Contents/Info.plist"
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
printf 'Built: %s/%s\nRun: open "%s/%s"\n' "$PWD" "$app" "$PWD" "$app"
