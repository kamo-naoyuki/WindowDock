#!/bin/bash
# Builds and runs the AppKit smoke harnesses against real windows (not SwiftPM targets).
# Usage: Tests/WindowDockUITests/run-smoke.sh [--restore-only | --finder-scan-only | --new-window-only | --new-tab-only | --tab-layout-only | --hover-help-only | --tab-move-only | --window-drop-only | --activation-only | --shortcut-only | --nested-split-only | --focus-sync-only | --window-refit-only | --window-follow-only | --constraint-notice-only | --enhanced-ui-only | --empty-workspace-only | --auto-group-only | --audio-indicator-only | --stage-manager-only]
# --stage-manager-only turns Stage Manager on while it runs, which rearranges the desktop, so a full run skips it.
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

if [[ "${1:-}" == --stage-manager-only ]]; then
  previous_stage_manager="$(defaults read com.apple.WindowManager GloballyEnabled 2>/dev/null || echo unset)"
  restore_stage_manager() {
    case "$previous_stage_manager" in
      unset) defaults delete com.apple.WindowManager GloballyEnabled 2>/dev/null || true ;;
      1) defaults write com.apple.WindowManager GloballyEnabled -bool true ;;
      *) defaults write com.apple.WindowManager GloballyEnabled -bool false ;;
    esac
  }
  trap 'restore_stage_manager; rm -rf "$OUT"' EXIT
  defaults write com.apple.WindowManager GloballyEnabled -bool true
  sleep 2
  "$OUT/workspace-smoke" --stage-manager-only
  exit
fi

if [[ "${1:-}" == --tab-layout-only || "${1:-}" == --hover-help-only ]]; then
  "$OUT/tab-layout-smoke" "$@"
else
  "$OUT/workspace-smoke" "$@"
fi
if [[ $# -eq 0 || "${1:-}" == --new-tab-only ]]; then
  "$OUT/tab-layout-smoke" --new-tab-only
fi
if [[ $# -eq 0 ]]; then
  "$OUT/workspace-smoke" --activation-only
  "$OUT/tab-layout-smoke"
fi
