# WindowDock – Guide for Code Agents

macOS 13+ AppKit app (Swift 5.10, SwiftPM). It groups other apps' windows into a "project" and aligns them via the Accessibility API; it never embeds them. UI strings are Japanese keys passed through `L(...)`.

## Build / test

- `swift build` – debug build. `bash build-app.sh` → `dist/WindowDock.app` (signs, embeds Sparkle). `build-dmg.sh` → DMG.
- `swift test` – runs only `Tests/WindowDockCoreTests` (needs full Xcode for XCTest).
- `Tests/WindowDockUITests/*Smoke.swift` are manual smoke harnesses against real windows; they are **not** SwiftPM targets.
- `dist/` is build output; don't edit it.

## Targets

- `WindowDockCore` (`Sources/WindowDockCore`): pure, AppKit-free logic that is unit-testable. Put new pure logic here and test it.
  - `GridReflow.swift` – how window cells are reflowed when the grid size changes.
  - `WindowGeometry.swift` – frame/geometry math.
  - `LanguageResolver.swift` – picks the UI language from preferred languages.
- `WindowDock` (`Sources/WindowDock`): the app (depends on Core and Sparkle).

## Where things are (`Sources/WindowDock`)

| Concern | File |
|---|---|
| Entry point (`@main`), `AppDelegate`: menus, project list, restore on launch, global key/mouse monitors, cross-app window-drag polling, quit/restore | `App.swift` |
| One project = one `WorkspaceController` (owns the NSWindow, wires `WindowSession` ↔ views, NSWindowDelegate, picker, drop handling) | `WorkspaceController.swift` |
| Model/state of a project: managed windows, grid cells, selection, sync/align/raise, suspend/resume, restore originals | `WindowSession.swift` |
| All Accessibility API calls (`WindowAccess`), `WindowAccessClient` (injectable for tests), `WindowCandidate`, window scanning, window-server list | `Accessibility.swift` |
| Workspace NSWindow (`WorkspaceWindow`), resize/drag background view, coverage | `WorkspaceBackgroundView.swift` |
| Tab bar, grid selectors, notices, drop-target UI, tab context menu (`WorkspaceChromeView`), `WorkspaceNotice`, `WorkspaceSplitLayout` | `WorkspaceChromeView.swift` |
| Tab button, tab-move drag session, per-pane tab drop overlay | `WorkspaceTabDrag.swift` |
| Pane grid layout (`WorkspaceGridSize` up to 4×4, `WorkspaceGridView`) | `WorkspaceGridView.swift` |
| Ctrl+Tab shortcut context, window-drag tracker (`WorkspaceWindowDragTracker`, `WindowServerWindow`) | `WorkspaceInput.swift` |
| "Add windows" sheet | `WindowPicker.swift` |
| Persisted last session (`SavedProject`, `SavedLayout`, stored in UserDefaults key `lastWindows`) | `SavedLayout.swift` |
| `L()` string lookup, en/zh/ko/es tables (Japanese text is the key) | `Localization.swift` |

Other: `Support/Info.plist`, `Support/AppIcon.*` (bundle resources), `Package.swift`, `build-app.sh`, `build-dmg.sh`.

## Data flow

1. `AppDelegate` creates a `WorkspaceController` per project (⌘N / restore).
2. The controller owns a `WindowSession` (model) and a `WorkspaceChromeView` (view). The session reports via callbacks (`onChange`, `onMessage`, `onPresentedFrames`, …) that the controller sets in `wireSession()`; the controller re-renders tabs (`renderTabs()`) and supplies target frames (`targetFrames()`).
3. Moving/resizing the workspace window → controller `windowDidMove/Resize` → `session.sync()` → `Accessibility.swift` sets positions/sizes of managed windows.
4. `AppDelegate` global monitors handle Ctrl+Tab and focus-by-click; a 50 ms timer tracks dragging of foreign windows into a workspace (`pollWindowDrag`).

## Conventions and gotchas

- UI and session code is `@MainActor`. Keep Accessibility calls behind `WindowAccessClient` so they can be faked.
- Add every user-visible string through `L("<Japanese key>")` and add its en/zh/ko/es entries in `Localization.swift`.
- A window may belong to only one project; `WindowSession.contains` enforces it.
- Windows must be restored to their original frames on release/quit (`restoreAll`, `ManagedWindow.restore`).
- Window-server coordinates (AX, top-left origin) differ from AppKit (bottom-left); see `pollWindowDrag` for the conversion.
- Update `README.md` when user-facing behavior or shortcuts change.
