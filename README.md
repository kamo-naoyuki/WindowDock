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

On first launch, allow WindowDock to move and resize windows in **System Settings → Privacy & Security → Accessibility**.

Click **+** (or press **⌘T** in WindowDock) to open a new tab. Pick an existing window by its preview, app icon and title, or click an app in the **Installed Apps** grid below to open a **new window**. Recently used apps appear first, followed by apps with no known usage in name order. If the app isn't running, WindowDock launches it. If it's already running, WindowDock uses its New Window command; apps without one can't be opened this way, and WindowDock won't reuse an old window instead. The new window takes the place of the new tab. Click **Select Apps** to check several apps, then open a new window of each or have their new windows added to the workspace automatically.

To add several windows as separate tabs, **⌘-click** individual thumbnails or **Shift-click** the first and last thumbnails of a range, then click **Add**. You can also click **Select Multiple** and check thumbnails without holding a key. To include every available window of an app, check one of its thumbnails and click **Select All Windows of App** before adding.

Window previews are still images, not live video. Screen Recording permission is optional: without it, pick by app icon and window title. You can also use **⌘O** to add multiple windows at once, or drag a window onto the tab bar.

On startup, choose which saved workspaces to reopen if there is more than one. Each workspace shows an inline tab with matching open windows checked in saved tab order. Adjust the selection and click **Restore**, or skip the workspace’s tabs without erasing its saved layout. WindowDock adds the selected windows after you review the last workspace, using each workspace’s saved panes and pins. With no saved workspaces selected, you start in an empty workspace.

When dragging a window onto a tab bar, the bar comes to the front and a translucent tab shows where it will be added.

## Using a workspace

- Rest the pointer on a tab to see the app name and full window title, or on the workspace name to read it in full. No click is needed, even while working in another app. Hovering over **×** highlights the close button. Click a tab to switch windows; use **Control+Tab** for the next tab or **Control+Shift+Tab** for the previous one. When tabs open or close, the others slide into place unless **Reduce motion** is enabled in macOS.
- Tabs share the available width equally, with titles aligned to the left. When you click **×**, the next tab slides its **×** under the pointer and **+** moves in after the last tab; widths adjust once the pointer leaves the bar. Closing the rightmost tab resizes the remaining tabs right away. Enable **Settings → Wrap crowded tabs into two rows** to use a second row before scrolling in a top or bottom tab bar.
- A speaker icon appears on the tabs of an app that is playing sound (macOS 14.4 or later). macOS reports sound for each app rather than each window, so all of that app's tabs show it, and an app that keeps its audio output open may show it while silent.
- Bringing a managed window to the front outside WindowDock also selects its tab. In a split workspace, a window not currently shown replaces the Control+Tab target pane; pinned panes stay in place.
- To add an app's new windows automatically, right-click one of its tabs and choose **Automatically Add New “App” Windows to This Workspace**, or select apps on a new tab and choose to add their new windows automatically. To change several apps at once, choose **Workspaces → Apps Whose New Windows Are Added Automatically…** (also in the workspace name menu) and check or uncheck apps. Windows the app opens from now on join the workspace as tabs in the background, without taking focus or switching tabs; windows already open are added only if you choose to when asked. Each app is collected by one workspace at a time. Choose the menu item again, uncheck the app, or click **Remove** on a new tab to stop; existing tabs stay. Nothing is collected while the workspace is minimized or hidden, or while it asks which windows to restore.
- By default (**Settings → When moving a window directly → Move the workspace with it**), the workspace follows a managed window while you drag it: moving it moves the workspace and its other panes, and resizing it resizes its pane by moving the workspace edge or pane divider. Maximizing it maximizes the workspace, and minimizing it minimizes the workspace; restoring any of its windows brings the workspace back. Choose **Return to pane** to put windows back into their panes instead, or **Do nothing**.
- Right-click a displayed tab or pane to open **Pane** options. With two or more panes, choose **Pin Pane** to keep its window in place while Control+Tab switches the last selected unpinned pane. Other displayed panes are skipped, so the target is unambiguous in layouts with three or more panes. Pinned panes show a pin icon; the tab-switch target has a highlighted outline.
- Right-click a displayed tab and choose **Pane → Split Left and Right / Split Top and Bottom** to split just that pane, up to four subdivisions in each direction. If an app’s window won’t fit in a pane, its name appears beside the disabled direction or in the warning when WindowDock returns to 1×1. The same actions are available on an empty pane or under **View → Pane**. Drag each divider to resize; **Close Pane** keeps its windows as tabs. The column/row controls return to a regular grid; custom layouts, divider positions, and pinned panes are saved.
- A window-fit warning clears after the window fits for a few seconds.
- Choose **Tab Bar Position** from the **View** menu or the workspace name menu to place tabs at the top, bottom, left, or right. **Automatically Hide Tab Bar** reclaims the space, leaving a thin strip at that edge; move the pointer onto it to reveal the bar. Control+Tab briefly reveals the bar too.
- Press **⌘N** to create another workspace. Press **Control+Option+Tab** or **Control+Option+Shift+Tab** (**Workspaces → Next Workspace / Previous Workspace**) to switch workspaces. **Workspaces → Merge All Workspaces into This One** moves every tab into the current workspace and closes the others. Drag tabs to reorder them or move them between workspaces; a workspace comes to the front when you drag a tab over it. When you drag a tab onto a pane, only the pane under the pointer is highlighted; the other windows stay visible.
- Dropping a tab outside all workspaces releases it by default. In a single-pane workspace, dropping below or beside the tab bar does the same. Under **Settings → When dropping a tab outside a workspace**, choose to create a workspace for the tab or do nothing instead.
- Right-click a tab and choose **Release Tab** to keep its window open, or **Close Window** to close it. If you cancel a save prompt, the tab stays in the workspace.
- A tab’s **×**, **⌘W**, and bulk releases leave windows open by default. To close them instead, enable **Settings → Close windows when releasing tabs**. Closing a workspace or quitting WindowDock still leaves its windows open.
- Enable **Settings → Automatically delete workspaces when they become empty** (off by default) to delete a workspace, including its saved layout, after its last tab is released, moved away, or closed. Newly created empty workspaces are kept. Deleting the last workspace leaves the app running; click its Dock icon or press **⌘N** to create another.
- **Settings** also lets you show only app icons in tabs (rest the pointer on a tab for its window name), disable **Control+Tab** switching (so the shortcut goes to the frontmost app), disable adding windows by dragging, or automatically hide the tab bar in newly created workspaces.
- With **Return to pane** selected, moving, resizing, maximizing, or minimizing a managed window is temporary: WindowDock returns it to its pane without taking focus from the app. With **Do nothing**, the window stays where you put it until WindowDock next fits it into its pane. Full-screen windows stay full screen unless you enable **Settings → Also return full-screen windows to their panes** (off by default). Move the workspace itself by dragging the tab bar; minimizing the workspace still minimizes all its windows.

Use windows from the current Space. Windows that are already full screen and windows that can't be moved or resized aren't supported.

With Stage Manager, a workspace and its tab bar stay on the stage together with the window shown in it. Stage Manager still keeps each app in its own set, so to see windows of different apps side by side in split panes, drag those apps from the strip onto the stage to group them.

[MIT License](LICENSE)
