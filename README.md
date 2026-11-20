# WindowDock

A native macOS app that groups the windows of different apps by project and lets you switch between them with browser-style tabs.

![WindowDock screenshot](docs/screenshot.png)

Working on one task usually means a browser, an editor, a terminal, and more, all scattered across the screen. WindowDock collects those windows into one **project**, a single workspace with a tab bar. Click a tab to bring that app's window forward, just like switching tabs in a browser. Use a separate project for each task and keep them apart.

- One project = one set of windows from any apps, switched with tabs
- Split the workspace into up to 4×4 panes to view several windows side by side
- Move and resize the workspace and all its windows follow, using the standard window buttons (including the green button's tiling menu)

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
- **⌘O**: add windows, **⌘W**: release the selected tab
- **⌘N**: new project (another WindowDock window), **⇧⌘W**: close the project

## Projects

Each WindowDock window is a project: one task's worth of windows, shown as tabs. Create more with ⌘N and switch between them with the usual macOS tools (Mission Control, Spaces). The **Project** menu lists every project and its windows; choose one to bring it to the front, or rename/close the project. A window can belong to only one project.

## How It Works

WindowDock doesn't embed other apps' windows. It uses the Accessibility API to align the position, size, and stacking of ordinary windows, so each app stays fully usable.

Full-screen windows, windows in other Spaces, and apps that can't be moved or resized are not supported. Tabs are not saved, but each project's split layout is, and at launch the add-window dialog opens with the windows from the last session pre-selected, one project at a time (matched by app, then title and position).

## License

[MIT](LICENSE)
