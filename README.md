# WindowDock

WindowDock is a native macOS app that gathers windows from multiple apps into a single workspace with tabs. It requires macOS 13 or later. It does not use screen recording. The only network access is the update check by [Sparkle](https://sparkle-project.org), which fetches `appcast.xml` from GitHub Releases.

The UI language follows the macOS preferred-language list (System Settings → General → Language & Region), chosen at launch: Japanese, English, Simplified Chinese, Korean, and Spanish. Other languages fall back to English. Strings live in `Sources/WindowDock/Localization.swift`.

## Getting Started

```sh
bash build-app.sh
open dist/WindowDock.app
```

1. Click "+" in the tab bar.
2. Open System Settings → Privacy & Security → Accessibility and allow **WindowDock**. If it isn't listed, add `dist/WindowDock.app`.
3. Click "+" again and choose from your open windows. **Command-click selects multiple windows; Shift-click selects a range.** Windows from different apps can be selected together.
4. Click "Add N" to register the selected windows in list order. The last tab that was added is shown. While the view is split, windows fill the empty panes starting from the active one. If some windows fail to register, the ones that succeeded stay and an error is shown.

### Distribution

Download the DMG from [Releases](https://github.com/kamo-naoyuki/WindowDock/releases). Release builds are produced by [release.yml](.github/workflows/release.yml). The app is not notarized, so on first launch right-click it and choose "Open" (or run `xattr -cr /Applications/WindowDock.app`).

### Updates

WindowDock checks for updates automatically and via **WindowDock → Check for Updates…**. Updates are verified with an EdDSA signature. Releases need the repository secret `SPARKLE_PRIVATE_KEY` (the exported private key; create it with Sparkle's `generate_keys` and put the matching public key in `SUPublicEDKey` in [Info.plist](Support/Info.plist)). Pushing a `v*` tag builds the release, stamps the version from the tag, and uploads `appcast.xml`.

The code signature requirement is fixed to the bundle identifier, so the Accessibility permission should survive updates.

### If the permission stops working after a rebuild

Prototype builds use an ad-hoc signature, so a rebuilt app may no longer match the Accessibility permission granted earlier, even if the switch still looks on.

1. Quit WindowDock normally.
2. Reset the old permission for **WindowDock only**:

   ```sh
   tccutil reset Accessibility local.WindowDock
   ```

3. Open System Settings → Privacy & Security → Accessibility. If an old WindowDock entry remains, remove it with "−".
4. Click "+", choose the current `dist/WindowDock.app`, and turn it on. In the file picker, press Command + Shift + G to type a folder path.
5. Launch that same app:

   ```sh
   open dist/WindowDock.app
   ```

Always launch WindowDock from the `.app`, not from a debugger or `swift run`.

## Using WindowDock

- **Tab bar**: From left to right: window controls, tabs, "+", column/row selectors, and the permission button. Hover over the permission icon for usage hints. With many tabs, the tab row scrolls horizontally.
- **Click a tab**: Brings that window to the front in the shared area. While split, selecting a visible tab makes its pane active; selecting a hidden tab swaps it into the active pane. Clicking inside a pane also makes it active. If an app doesn't receive keyboard focus automatically, click its content before typing.
- **Split view**: Choose **1–4** columns and **1–4** rows (up to 16 panes). Drag the borders to adjust widths and heights. Panes have a minimum size (about 240×180 pt, larger if the app requires it). If a layout doesn't fit, WindowDock explains why and returns to 1×1. Set both to 1 to show the selected tab full size.
- **Rearrange panes**: Drag a tab onto another pane to swap or move it, or right-click a tab to choose a destination pane.
- **Add by dragging a window**: Drag an unregistered window by its title bar toward the top of WindowDock. When a banner appears, move the mouse pointer onto it and release where it turns blue ("Release here to add as a tab"). Orange means Accessibility permission is needed. Use the same Space, and use "+" for windows that can't be dragged.
- **Control + Tab / Control + Shift + Tab**: Next / previous tab. This needs Accessibility permission. Some apps may also use the shortcut themselves; in that case, select tabs with the mouse.
- **Move and resize**: Drag the empty area at the top of the workspace to move it. Drag the edges or the bottom-right grip to resize. All registered windows follow.
- **Green button / double-click the top empty area**: Maximize to the screen area (excluding the Dock and menu bar); do it again to restore. This is not full-screen mode.
- **× on a tab**: Releases the window (it is not closed) and restores its original position, size, and minimized state.
- **Yellow button**: Minimizes WindowDock and all registered windows. They return when you restore it. Windows you had minimized yourself stay minimized.
- **Red button**: Restores all registered windows and quits. Errors are shown if restoring fails.
- **Gear icon**: Opens the Accessibility settings.

## Limitations

WindowDock cannot truly embed other apps' windows. It uses the Accessibility API to position and raise ordinary windows to match the tabbed area. The windows are the real apps, so you can type and interact normally.

- Only ordinary windows are supported. Exit full-screen first and keep windows in the same Space as WindowDock.
- Apps that don't allow moving, resizing, or minimizing their windows can't be registered. If an app's minimum size is large, enlarge the workspace.
- Inactive tabs sit behind the selected window, so they may show through transparent areas or corners, and they remain in Mission Control and each app's window list. Dialogs and helper windows are not managed.
- Windows move slightly after the frame, so brief gaps may appear. More tabs can mean slower following.
- Move and resize using WindowDock's frame. If you move a window by its own title bar, select its tab again to snap it back.
- Dock icons remain per app, and registered windows still appear in the app's window list.
- Tabs and split layouts are not saved or re-registered automatically. After a crash or force quit, restoring is manual: bring back windows from each app's window list, or minimized ones from the Dock.
