#!/bin/bash
# Builds and runs the AppKit smoke harnesses against real windows (not SwiftPM targets).
# Usage: Tests/WindowDockUITests/run-smoke.sh [--tab-layout-only | --tab-move-only | --window-drop-only | --activation-only | --shortcut-only | --nested-split-only | --focus-sync-only | --window-refit-only | --constraint-notice-only | --enhanced-ui-only | --empty-workspace-only]
set -euo pipefail
cd "$(dirname "$0")/../.."

swift build --build-system native --target WindowDockCore
BIN="$(swift build --build-system native --show-bin-path)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

APP_SOURCES=()
for source in Sources/WindowDock/*.swift; do
  [[ "$(basename "$source")" == App.swift ]] || APP_SOURCES+=("$source")
done

build() {
  swiftc -parse-as-library -module-name WindowDockSmoke -I "$BIN/Modules" -I "$BIN" \
    "${APP_SOURCES[@]}" "$BIN"/WindowDockCore.build/*.o "$@"
}

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
