# WindowDock – Guide for Code Agents

macOS 13+ AppKit app (Swift 5.10, SwiftPM). It groups other apps' windows into a "workspace" and aligns them via the Accessibility API; it never embeds them. UI strings are Japanese keys passed through `L(...)`.

## Build / test

- `swift build` – debug build. `bash build-app.sh` → `dist/WindowDock.app` (signs, embeds Sparkle). `build-dmg.sh` → DMG.
- `swift test` – runs only `Tests/WindowDockCoreTests` (needs full Xcode for XCTest).
- `Tests/WindowDockUITests/*Smoke.swift` are manual smoke harnesses against real windows; they are **not** SwiftPM targets. Run them with `Tests/WindowDockUITests/run-smoke.sh` (compiles them with every app source except `App.swift`, so move logic worth testing out of `App.swift`; `--tab-move-only` / `--window-drop-only` / `--activation-only` run subsets). They open real windows, so other apps' windows moving in front can cause hit-test failures.
- If `xcode-select -p` points at the Command Line Tools and `swift` fails, prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- `dist/` is build output; don't edit it.

## Formatting

Use the `nicklockwood/SwiftFormat` pre-commit hook, pinned in `.pre-commit-config.yaml`.
The first run builds and caches the formatter using the local Swift toolchain.
Install the commit hook once per clone:

```sh
uv tool install pre-commit
pre-commit install
```

The hook formats staged Swift files using `.swiftformat` (4-space indentation, 120-column line length).
Only whitespace and layout rules are enabled; code-refactoring rules are intentionally excluded.
If formatting changes a file, the commit stops: review the changes, stage them, and commit again.
Unstaged changes are temporarily stashed by `pre-commit`; if they conflict with formatting, the formatting changes are rolled back.
To format a file manually with the same version as CI, run `pre-commit run swiftformat --files <file.swift>`.
Use `pre-commit run swiftformat --all-files` to format all tracked Swift files.
The upstream hook declares `language: swift`, which lets pre-commit.ci load its Swift toolchain and run the formatter; do not replace it with `language: system` or skip it in CI.
The formatter version is pinned to the one used by pre-commit.ci's Swift runner test; both `swiftlang/swift-format` and newer SwiftFormat builds exceeded its 120-second environment-build limit. Check the actual CI build before updating the pin.

## Fixing bugs

When you find or are asked to fix a bug, follow this order:

1. Write a test that reproduces the bug: a unit test in `Tests/WindowDockCoreTests` (move the logic into `WindowDockCore` if needed), or a smoke check in `Tests/WindowDockUITests` for AppKit/Accessibility behavior.
2. Run it against the **unfixed** code and confirm it fails because of the bug.
3. Fix the code.
4. Rerun the test (`swift test` or `run-smoke.sh`) and confirm it passes, along with the existing tests.

## Targets

- `WindowDockCore` (`Sources/WindowDockCore`): pure, AppKit-free logic that is unit-testable. Put new pure logic here and test it.
  - `GridReflow.swift` – how window cells are reflowed when the grid size changes.
  - `WindowGeometry.swift` – frame/geometry math.
  - `WorkspaceResize.swift` – workspace resize edge/grip hit areas and resized-frame math.
  - `LanguageResolver.swift` – picks the UI language from preferred languages.
  - `WindowDragTracking.swift` – `WindowServerWindow` and `WorkspaceWindowDragTracker`, which detects foreign-window drags from sampled WindowServer frames.
  - `WorkspaceTabDragRoute.swift` – decides whether a dragged tab stays in its workspace, transfers to another, or does nothing.
  - `WindowHitTesting.swift` – recognizes a click on an own window that just activated the app.
  - `AudioPlayback.swift` – which applications a process playing audio counts for (itself, its responsible process, their ancestors), and how long a stopped application stays audible.
- `WindowDock` (`Sources/WindowDock`): the app (depends on Core and Sparkle).

## Where things are (`Sources/WindowDock`)

| Concern | File |
|---|---|
| Entry point (`@main`), `AppDelegate`: menus, workspace list, restore on launch, global key/mouse monitors, cross-app window-drag polling, quit/restore | `App.swift` |
| Which workspace comes forward on app activation, Dock click/menu or Workspace menu, and sending the other workspaces back (`WorkspaceActivation`) | `WorkspaceActivation.swift` |
| One workspace = one `WorkspaceController` (owns the NSWindow, wires `WindowSession` ↔ views, NSWindowDelegate, picker, drop handling, returns moved/zoomed/minimized windows via `WindowEventObserver`; returning full-screen windows is opt-in) | `WorkspaceController.swift` |
| Model/state of a workspace: managed windows, grid cells, selection, sync/align/raise, suspend/resume, restore originals | `WindowSession.swift` |
| All Accessibility API calls (`WindowAccess`), `WindowAccessClient` (injectable for tests), `WindowCandidate`, window scanning, window-server list | `Accessibility.swift` |
| Workspace NSWindow (`WorkspaceWindow`), resize/drag background view, coverage | `WorkspaceBackgroundView.swift` |
| Tab bar, grid selectors, notices, drop-target UI, tab context menu (`WorkspaceChromeView`), `WorkspaceNotice`, `WorkspaceSplitLayout` | `WorkspaceChromeView.swift` |
| Tab button (including its speaker while the app plays audio), tab-move drag session, per-pane tab drop overlay | `WorkspaceTabDrag.swift` |
| Applications playing audio, from Core Audio process objects (macOS 14.4+; notification-driven, no polling), for tab speakers (`AudioPlaybackMonitor`) | `AudioPlaybackMonitor.swift` |
| Pane grid layout (`WorkspaceGridSize` up to 4×4, `WorkspaceGridView`) | `WorkspaceGridView.swift` |
| Ctrl+Tab shortcut context, registered-window check for window drags (`WorkspaceWindowDragRegistration`) | `WorkspaceInput.swift` |
| "Add windows" sheet | `WindowPicker.swift` |
| Saved-tab restore (collect selections before registering any windows), inline thumbnail page shared with + | `WorkspaceRestore.swift`, `NewTabPage.swift` (`run-smoke.sh --restore-only` uses fixture windows and isolated defaults) |
| Persisted last session (`SavedWorkspace`, `SavedLayout`, stored in UserDefaults key `lastWindows`) | `SavedLayout.swift` |
| `L()` string lookup, en/zh/ko/es tables (Japanese text is the key) | `Localization.swift` |

Other: `Support/Info.plist`, `Support/AppIcon.*` (bundle resources), `Package.swift`, `build-app.sh`, `build-dmg.sh`.

## Data flow

1. `AppDelegate` creates a `WorkspaceController` per workspace (⌘N / restore).
2. The controller owns a `WindowSession` (model) and a `WorkspaceChromeView` (view). The session reports via callbacks (`onChange`, `onMessage`, `onPresentedFrames`, …) that the controller sets in `wireSession()`; the controller re-renders tabs (`renderTabs()`) and supplies target frames (`targetFrames()`).
3. Moving/resizing the workspace window → controller `windowDidMove/Resize` → `session.sync()` → `Accessibility.swift` sets positions/sizes of managed windows.
4. `AppDelegate` global monitors handle Ctrl+Tab and focus-by-click; a 50 ms timer tracks dragging of foreign windows into a workspace (`pollWindowDrag`).

## Conventions and gotchas

- UI and session code is `@MainActor`. Keep Accessibility calls behind `WindowAccessClient` so they can be faked.
- Add every user-visible string through `L("<Japanese key>")` and add its en/zh/ko/es entries in `Localization.swift`.
- A window may belong to only one workspace; `WindowSession.contains` enforces it.
- Windows must be restored to their original frames on release/quit (`restoreAll`, `ManagedWindow.restore`).
- Window-server coordinates (AX, top-left origin) differ from AppKit (bottom-left); see `pollWindowDrag` for the conversion.
- Update `README.md` when user-facing behavior or shortcuts change.
- When committing, do not add a `Co-authored-by` trailer to commit messages.
