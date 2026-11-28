import AppKit
import WindowDockCore

/// The windows that were registered when the app last quit, used only to suggest a selection.
struct SavedWindow: Codable {
    var bundleID: String
    var title: String
    var frame: CGRect
    var isTabPinned: Bool? = nil
}

/// A combined tab's panes.
struct SavedPaneGroup: Codable, Equatable {
    var columns: Int
    var rows: Int
    var paneLayout: PaneLayout?
    /// Indices into the workspace's saved windows; nil for an empty pane or a start page.
    var cells: [Int?]
    var activeCell: Int
    var pinnedPanes: [Int]
}

struct SavedWorkspace: Codable {
    var name: String
    var windows: [SavedWindow]
    var columns: Int?
    var rows: Int?
    var autoHideTabs: Bool?
    var paneLayout: PaneLayout?
    var pinnedPanes: [Int]?
    var tabBarPosition: TabBarPosition? = nil
    /// Apps whose new windows are collected into this workspace.
    var autoGroupBundleIDs: [String]? = nil
    var paneGroups: [SavedPaneGroup]? = nil
    /// The saved window that was selected when the workspace was last saved.
    var selectedWindowIndex: Int? = nil
    /// The workspace window's frame in AppKit screen coordinates.
    var frame: CGRect? = nil

    var gridSize: WorkspaceGridSize? {
        guard let columns, let rows else { return nil }
        let size = WorkspaceGridSize(columns: columns, rows: rows)
        return size.isValid ? size : nil
    }
}

enum SavedLayout {
    private static let key = "lastWindows"

    static func save(_ workspaces: [SavedWorkspace]) {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Replaces workspaces with the same name and appends new ones, keeping every other saved workspace.
    static func upsert(_ workspaces: [SavedWorkspace]) {
        var all = load()
        for workspace in workspaces {
            if let index = all.firstIndex(where: { $0.name == workspace.name }) {
                all[index] = workspace
            } else {
                all.append(workspace)
            }
        }
        save(all)
    }

    static func remove(named name: String) {
        save(load().filter { $0.name != name })
    }

    /// Updates only the apps collected by an existing saved workspace.
    static func setAutoGroupBundleIDs(_ ids: [String], forWorkspaceNamed name: String) {
        var all = load()
        guard let index = all.firstIndex(where: { $0.name == name }) else { return }
        all[index].autoGroupBundleIDs = ids.isEmpty ? nil : ids
        save(all)
    }

    static func load() -> [SavedWorkspace] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        if let workspaces = try? JSONDecoder().decode([SavedWorkspace].self, from: data) { return workspaces }
        // Earlier versions saved a flat window list.
        if let windows = try? JSONDecoder().decode([SavedWindow].self, from: data) {
            return [SavedWorkspace(name: L("ワークスペース %d", 1), windows: windows)]
        }
        return []
    }

    /// Titles change easily, so the app is the hard requirement and title/position only rank candidates.
    static func suggest(
        _ saved: [SavedWindow], among candidates: [WindowCandidate],
        frameOf: (AXUIElement) throws -> CGRect = WindowAccess.frame
    ) -> [Int] {
        let matched = matches(saved, among: candidates, frameOf: frameOf)
        return saved.indices.compactMap { matched[$0] }
    }

    /// The candidate index each saved window matches, keyed by the saved window's index.
    static func matches(
        _ saved: [SavedWindow], among candidates: [WindowCandidate],
        frameOf: (AXUIElement) throws -> CGRect = WindowAccess.frame
    ) -> [Int: Int] {
        var matches: [Int: Int] = [:]
        var claimed = Set<Int>()
        let bundles = Set(saved.map(\.bundleID))
        let frames = candidates.map { candidate -> CGRect? in
            guard let id = candidate.application.bundleIdentifier, bundles.contains(id) else { return nil }
            return try? frameOf(candidate.element)
        }
        for (savedIndex, entry) in saved.enumerated() {
            var best: (index: Int, score: Int)?
            for (index, candidate) in candidates.enumerated()
                where !claimed.contains(index) && candidate.application.bundleIdentifier == entry.bundleID {
                var score = 0
                if !entry.title.isEmpty, candidate.title == entry.title { score += 4 }
                if let frame = frames[index] {
                    let distance =
                        abs(frame.minX - entry.frame.minX) + abs(frame.minY - entry.frame.minY)
                            + abs(frame.width - entry.frame.width) + abs(frame.height - entry.frame.height)
                    if distance < 40 { score += 3 } else if distance < 400 { score += 1 }
                }
                if best == nil || score > best!.score { best = (index, score) }
            }
            if let best {
                claimed.insert(best.index)
                matches[savedIndex] = best.index
            }
        }
        return matches
    }

    /// Matched thumbnails lead in saved tab order; any extras keep scan order.
    static func restoreChoices(
        _ saved: [SavedWindow],
        among candidates: [WindowCandidate],
        frameOf: (AXUIElement) throws -> CGRect
    ) -> (windows: [WindowCandidate], checked: IndexSet) {
        let matches = suggest(saved, among: candidates, frameOf: frameOf)
        let matched = IndexSet(matches)
        return ((matches + candidates.indices.filter { !matched.contains($0) }).map { candidates[$0] },
                IndexSet(integersIn: 0 ..< matches.count))
    }
}
