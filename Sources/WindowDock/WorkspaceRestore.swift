import AppKit

@MainActor
enum WorkspaceRestore {
    /// Collect every choice before adding any windows: raising a restored window would cover the next page.
    static func start(_ workspaces: [SavedWorkspace], makeWorkspace: @escaping (String?) -> WorkspaceController) {
        guard !workspaces.isEmpty else {
            // A fresh launch (or declining the workspace chooser) still starts with an empty workspace.
            _ = makeWorkspace(nil)
            return
        }
        var chosen: [(controller: WorkspaceController, saved: SavedWorkspace, windows: [WindowCandidate])] = []
        func next(_ remaining: ArraySlice<SavedWorkspace>) {
            guard let saved = remaining.first else {
                let open = chosen.filter { !$0.controller.quitting }
                for (controller, saved, windows) in open.reversed() {
                    controller.restoreLayout(saved)
                    // A window can be claimed elsewhere while the user reviews the later workspaces.
                    let available = windows.filter { !controller.session.isClaimedElsewhere($0) }
                    if !available.isEmpty { controller.session.add(available) }
                }
                open.first?.controller.present()
                return
            }
            let controller = makeWorkspace(saved.name)
            if let hidden = saved.autoHideTabs { controller.setAutoHideTabs(hidden) }
            let reserved = chosen.filter { !$0.controller.quitting }.flatMap(\.windows)
            controller.collectRestoration(saved, excluding: reserved) { [weak controller] windows in
                if let controller, !controller.quitting { chosen.append((controller, saved, windows)) }
                next(remaining.dropFirst())
            }
        }
        next(workspaces[...])
    }
}
