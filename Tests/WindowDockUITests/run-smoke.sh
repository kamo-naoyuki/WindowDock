#!/bin/bash
# Builds and runs the AppKit smoke harnesses against real windows (not SwiftPM targets).
# Usage: Tests/WindowDockUITests/run-smoke.sh [--tab-move-only | --window-drop-only | --activation-only]
set -euo pipefail
cd "$(dirname "$0")/../.."

swift build --target WindowDockCore
BIN="$(swift build --show-bin-path)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

APP_SOURCES=()
for source in Sources/WindowDock/*.swift; do
  [[ "$(basename "$source")" == App.swift ]] || APP_SOURCES+=("$source")
done

build() {
  swiftc -parse-as-library -module-name WindowDockSmoke -I "$BIN" -I "$BIN/Modules" \
    "${APP_SOURCES[@]}" "$BIN"/WindowDockCore.build/*.o "$@"
}

build Tests/WindowDockUITests/WorkspaceBackgroundSmoke.swift Tests/WindowDockUITests/WindowSessionSmoke.swift \
  -o "$OUT/workspace-smoke"
build Tests/WindowDockUITests/TabLayoutSmoke.swift -o "$OUT/tab-layout-smoke"

"$OUT/workspace-smoke" "$@"
if [[ $# -eq 0 ]]; then
  "$OUT/workspace-smoke" --activation-only
  "$OUT/tab-layout-smoke"
fi
