# WindowDock

A native macOS app that groups the windows of different apps into workspaces and lets you switch between them with browser-style tabs.

![WindowDock screenshot](docs/screenshot.png)

Working on one task usually means a browser, an editor, a terminal, and more, all scattered across the screen. WindowDock collects those windows into one **workspace** with a tab bar. Click a tab to bring that window forward, just like switching tabs in a browser; the app's other, unregistered windows stay where they are. Use a separate workspace for each task and keep them apart.

- One workspace = one set of windows from any apps, switched with tabs
- Short tab titles use only the width their content needs (including the app icon). Longer tabs share the remaining toolbar space and shrink as more tabs are added; at their minimum width, scroll horizontally to reach more tabs.
- A size/position constraint warning stays visible while its tab is selected and is hidden on other tabs. It is retained until that window is released. It only reports the mismatch and suggests no fix: apps such as Terminal snap their size to character cells, so enlarging the workspace doesn't make them fit exactly.
- Drag a tab across the tab bar; the tab follows the pointer and neighbors slide aside, with the new order committed on drop. When the workspace is split, drag below the tab row to move/swap its window into a pane; with a single pane there is no pane target, so the tab keeps reordering anywhere over the workspace.
- Drop a tab on or within 24 points of another workspace to move it there, even when ordinary app windows cover that workspace. Overlapping destinations use the frontmost workspace (excluding the source). The tab bar inserts the tab, and a pane of a split workspace displays it there; a single-pane workspace shows the insertion line and inserts the tab wherever it is dropped. Release elsewhere outside the source workspace to leave the tab unchanged in its original workspace; Escape also cancels. No workspace is created and no tab is released by an outside drop. Ownership changes only on a successful drop, and an emptied source workspace stays open.
- Drag another app's window onto a visible workspace tab bar to add it; an empty workspace also accepts drops in its main area. Ordinary window addition highlights the receiving toolbar in blue with a release-to-add message. Cross-workspace tab moves retain the thin insertion line. These different indicators do not change their respective front/back eligibility rules.
- Dragging a WindowDock workspace does not offer its following application windows to another workspace.
- Dragging an already registered app window by its own titlebar never shows the window-addition bar in any workspace. Use its tab to move it between workspaces; unregistered windows from the same app can still be added normally.
- Split the workspace into up to 4×4 panes to view several windows side by side
- Move and resize the workspace and all its windows follow, using the standard window buttons (including the green button's tiling menu). Every edge, corner (including the top edge and top corners in the titlebar area), and the bottom-right grip resizes, even while a size-constraint warning is shown; the top edge stops at the menu bar.
- After clicking or dragging the workspace's titlebar, or resizing from an edge, releasing the mouse returns focus to the selected pane's app window. The next click can operate that window without an extra activation click. Toolbar controls and menus keep their normal focus behavior.

During window alignment, overlapping covered areas remain visible without blanking the whole pane. Coverage is confirmed against WindowServer's rendered window positions, rather than relying only on Accessibility coordinates.
Native position and frame changes also constrain the transparent area before moving, keeping exposed edges opaque during fast movement.
Titlebar dragging uses the same application-controlled movement path, rather than server-side dragging that can move transparent areas ahead of the managed windows.

Requires macOS 13 or later. No screen recording. The only network access is the update check by Sparkle.

## Getting Started

Download the DMG from [Releases](https://github.com/kamo-naoyuki/WindowDock/releases), or build from source:

```sh
bash build-app.sh
open dist/WindowDock.app
```

1. Allow **WindowDock** in System Settings → Privacy & Security → Accessibility.
2. Click "+" in the tab bar and choose the windows you want to gather.

The app is not notarized, so on first launch right-click it and choose "Open".

## Shortcuts

- **Control+Tab** / **Control+Shift+Tab**: next / previous tab (also in the Window menu)
- Switching tabs by keyboard brings the selected window's app to the front, including when consecutive tabs belong to different apps; only the selected window comes forward, not the app's other windows. Focus failures are reported in the workspace.
- **⌘O**: add windows, **⌘W**: release the selected tab
- **⌘N**: new workspace (another WindowDock window), **⇧⌘W**: close the workspace

## Workspaces

Each WindowDock window is a workspace: one task's worth of windows, shown as tabs. Create more with ⌘N and switch between them with the usual macOS tools (Mission Control, Spaces). The **Workspace** menu lists every workspace and its windows, and the Dock icon's menu lists every workspace; choose one to bring it to the front while the other workspaces move behind your other apps' windows. The Workspace menu can also rename/close the workspace. A window can belong to only one workspace.

Moving a tab between workspaces retains the window's original position and minimized state, so releasing it from its new workspace still restores its pre-registration state.

## How It Works

WindowDock doesn't embed other apps' windows. It uses the Accessibility API to align the position, size, and stacking of ordinary windows, so each app stays fully usable.

Full-screen windows, windows in other Spaces, and apps that can't be moved or resized are not supported. Tabs are not saved, but each workspace's split layout is, and at launch the add-window dialog opens with the windows from the last session pre-selected, one workspace at a time (matched by app, then title and position).

## License

[MIT](LICENSE)
