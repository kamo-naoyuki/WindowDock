#!/bin/bash
# Builds and runs the AppKit smoke harnesses against real windows (not SwiftPM targets).
# Usage: Tests/WindowDockUITests/run-smoke.sh [--restore-only | --finder-scan-only | --new-window-only | --new-tab-only | --tab-layout-only | --tab-move-only | --window-drop-only | --activation-only | --shortcut-only | --nested-split-only | --focus-sync-only | --window-refit-only | --constraint-notice-only | --enhanced-ui-only | --empty-workspace-only]
set -euo pipefail
cd "$(dirname "$0")/../.."

swift build --build-system native --target WindowDockCore
BIN="$(swift build --build-system native --show-bin-path)"
OUT=".build/ui-smoke-$$"
mkdir "$OUT"
trap 'rm -rf "$OUT"' EXIT

APP_SOURCES=()
for source in Sources/WindowDock/*.swift; do
  [[ "$(basename "$source")" == App.swift ]] || APP_SOURCES+=("$source")
done

build() {
  swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library -module-name WindowDockSmoke -I "$BIN/Modules" -I "$BIN" \
    "${APP_SOURCES[@]}" "$BIN"/WindowDockCore.build/*.o "$@"
}

if [[ "${1:-}" == --restore-only ]]; then
  # A distinct bundle gives the fake windows an app identity and isolates saved layouts from WindowDock.
  APP="$OUT/RestoreSmoke.app/Contents"
  mkdir -p "$APP/MacOS"
  cat > "$APP/Info.plist" <<PLIST
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.WindowDock.RestoreSmoke.p$$</string>
<key>CFBundleExecutable</key><string>restore-smoke</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
  build Tests/WindowDockUITests/StartupRestoreSmoke.swift -o "$APP/MacOS/restore-smoke"
  "$APP/MacOS/restore-smoke"
  exit
fi

build Tests/WindowDockUITests/WorkspaceBackgroundSmoke.swift Tests/WindowDockUITests/WindowSessionSmoke.swift \
  Tests/WindowDockUITests/WorkspaceActivationSmoke.swift -o "$OUT/workspace-smoke"
build Tests/WindowDockUITests/TabLayoutSmoke.swift -o "$OUT/tab-layout-smoke"

if [[ "${1:-}" == --tab-layout-only ]]; then
  "$OUT/tab-layout-smoke"
else
  "$OUT/workspace-smoke" "$@"
fi
if [[ $# -eq 0 ]]; then
  "$OUT/workspace-smoke" --activation-only
  "$OUT/tab-layout-smoke"
fi
