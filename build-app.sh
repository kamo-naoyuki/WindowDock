#!/bin/bash
# Builds dist/WindowDock.app. Set VERSION (e.g. 0.2.0) to stamp the bundle version,
# and ARCHS="--arch arm64 --arch x86_64" for a universal binary.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC2086
swift build -c release ${ARCHS:-}
# shellcheck disable=SC2086
bin_dir="$(swift build -c release ${ARCHS:-} --show-bin-path)"
app="dist/WindowDock.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin_dir/WindowDock" "$app/Contents/MacOS/WindowDock"
cp Support/Info.plist "$app/Contents/Info.plist"
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
ditto "$bin_dir/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/WindowDock"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$app/Contents/Info.plist"
fi
fw="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$fw"/XPCServices/*.xpc "$fw/Autoupdate" "$fw/Updater.app" "$app/Contents/Frameworks/Sparkle.framework"; do
  [ -e "$item" ] && codesign --force --sign - "$item"
done
codesign --force --sign - -r='designated => identifier "local.WindowDock"' "$app"
codesign --verify --strict --deep "$app"
printf 'Built: %s/%s\nRun: open "%s/%s"\n' "$PWD" "$app" "$PWD" "$app"
