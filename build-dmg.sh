#!/bin/bash
# Builds dist/WindowDock.app (run build-app.sh first) and packages it as a DMG.
set -euo pipefail
cd "$(dirname "$0")"
version="${1:-dev}"
app="dist/WindowDock.app"
dmg="dist/WindowDock-${version}.dmg"
[ -d "$app" ] || bash build-app.sh
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -volname "WindowDock" -srcfolder "$stage" -ov -format UDZO "$dmg"
printf 'Created: %s/%s\n' "$PWD" "$dmg"
