# WindowDock

Group windows from different Mac apps into a workspace for each task. Switch between them with tabs, or split the workspace into panes to see windows side by side. Move or resize the workspace and its windows follow.

![WindowDock screenshot](docs/screenshot.png)

## Getting started

WindowDock requires macOS 13 or later.

**Install the release:** Download the DMG from [Releases](https://github.com/kamo-naoyuki/WindowDock/releases), drag WindowDock to Applications, and open it. If macOS blocks the first launch, go to **System Settings → Privacy & Security** and choose **Open Anyway**.

**Build from source:** With Xcode Command Line Tools (Swift 5.10 or later) installed, run:

```sh
git clone https://github.com/kamo-naoyuki/WindowDock.git
cd WindowDock
bash build-app.sh
open dist/WindowDock.app
```

On first launch, allow WindowDock to move and resize windows in **System Settings → Privacy & Security → Accessibility**. Screen Recording permission is not required. Click **+** in the tab bar to choose windows, or drag a window onto the tab bar.

When dragging a window onto a tab bar, the bar comes to the front and a translucent tab shows where it will be added.

## Using a workspace

- Click a tab to switch windows. The tab highlight updates as its window is brought forward. Use **Control+Tab** for the next tab or **Control+Shift+Tab** for the previous one.
- Bringing a managed window to the front outside WindowDock also selects its tab. In a split workspace, a window not currently shown replaces the Control+Tab target pane; pinned panes stay in place.
- Right-click a displayed tab or pane to open **Pane** options. With two or more panes, choose **Pin Pane** to keep its window in place while Control+Tab switches the last selected unpinned pane. Other displayed panes are skipped, so the target is unambiguous in layouts with three or more panes. Pinned panes show a pin icon; the tab-switch target has a highlighted outline.
- Right-click a displayed tab and choose **Pane → Split Left and Right / Split Top and Bottom** to split just that pane, up to four subdivisions in each direction. If an app’s window won’t fit in a pane, its name appears beside the disabled direction or in the warning when WindowDock returns to 1×1. The same actions are available on an empty pane or under **View → Pane**. Drag each divider to resize; **Close Pane** keeps its windows as tabs. The column/row controls return to a regular grid; custom layouts, divider positions, and pinned panes are saved.
- A window-fit warning clears after the window fits for a few seconds.
- Choose **Tab Bar Position** from the **View** menu or the workspace name menu to place tabs at the top, bottom, left, or right. **Automatically Hide Tab Bar** reclaims the space; move the pointer to that edge to reveal it. Control+Tab briefly reveals the bar too.
- Press **⌘N** to create another workspace. Drag tabs to reorder them or move them between workspaces; a workspace comes to the front when you drag a tab over it. When you drag a tab onto a pane, only the pane under the pointer is highlighted; the other windows stay visible.
- Dropping a tab outside all workspaces releases it by default. In a single-pane workspace, dropping below or beside the tab bar does the same. Under **Settings → When dropping a tab outside a workspace**, choose to create a workspace for the tab or do nothing instead.
- Right-click a tab and choose **Release Tab** to keep its window open, or **Close Window** to close it. If you cancel a save prompt, the tab stays in the workspace.
- A tab’s **×**, **⌘W**, and bulk releases leave windows open by default. To close them instead, enable **Settings → Close windows when releasing tabs**. Closing a workspace or quitting WindowDock still leaves its windows open.
- **Settings** also lets you disable **Control+Tab** switching (so the shortcut goes to the frontmost app), disable adding windows by dragging, or automatically hide the tab bar in newly created workspaces.
- Moving, maximizing, or minimizing a managed window is temporary: WindowDock returns it to its pane without taking focus from the app. To leave windows where you put them, turn off **Settings → Return moved, maximized, or minimized windows to their panes**; switching back to WindowDock still fits them into their panes. Full-screen windows stay full screen unless you enable **Settings → Also return full-screen windows to their panes** (off by default). Move the workspace itself by dragging the tab bar; minimizing the workspace still minimizes all its windows.

Use windows from the current Space. Windows that are already full screen and windows that can't be moved or resized aren't supported.

[MIT License](LICENSE)
