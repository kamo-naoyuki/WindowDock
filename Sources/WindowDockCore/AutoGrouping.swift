import Foundation

/// Which workspace collects the new windows of each app. An app belongs to at most one workspace.
public struct AutoGroupRules<Workspace: Hashable> {
    public struct Entry {
        public var workspace: Workspace
        public var bundleIDs: [String]

        public init(workspace: Workspace, bundleIDs: [String]) {
            self.workspace = workspace
            self.bundleIDs = bundleIDs
        }
    }

    public private(set) var entries: [Entry] = []

    /// When the same app is listed by several workspaces, the earliest entry keeps it.
    public init(_ entries: [Entry]) {
        var seen = Set<String>()
        for entry in entries {
            let ids = entry.bundleIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
            if let index = self.entries.firstIndex(where: { $0.workspace == entry.workspace }) {
                self.entries[index].bundleIDs += ids
            } else {
                self.entries.append(Entry(workspace: entry.workspace, bundleIDs: ids))
            }
        }
    }

    public var allBundleIDs: Set<String> { Set(entries.flatMap(\.bundleIDs)) }

    public func workspace(for bundleID: String) -> Workspace? {
        entries.first { $0.bundleIDs.contains(bundleID) }?.workspace
    }

    public func bundleIDs(in workspace: Workspace) -> [String] {
        entries.first { $0.workspace == workspace }?.bundleIDs ?? []
    }

    /// Moves the app to `workspace` and returns the workspace that collected it before, if it was another one.
    @discardableResult
    public mutating func assign(_ bundleID: String, to workspace: Workspace) -> Workspace? {
        guard !bundleID.isEmpty else { return nil }
        let previous = self.workspace(for: bundleID)
        guard previous != workspace else { return nil }
        unassign(bundleID)
        if let index = entries.firstIndex(where: { $0.workspace == workspace }) {
            entries[index].bundleIDs.append(bundleID)
        } else {
            entries.append(Entry(workspace: workspace, bundleIDs: [bundleID]))
        }
        return previous
    }

    /// Returns the workspace that collected the app.
    @discardableResult
    public mutating func unassign(_ bundleID: String) -> Workspace? {
        guard let index = entries.firstIndex(where: { $0.bundleIDs.contains(bundleID) }) else { return nil }
        entries[index].bundleIDs.removeAll { $0 == bundleID }
        return entries[index].workspace
    }
}

/// Remembers which windows of one running app have already been seen, so only windows opened later are collected.
public struct AutoGroupWindowLedger<WindowID: Hashable> {
    private var known = Set<WindowID>()
    public private(set) var isBaselined = false
    /// Changes whenever the baseline is replaced; results read before that are stale.
    public private(set) var epoch = 0

    public init() {}

    /// Windows that already exist are never collected. A failed listing (`nil`) keeps waiting for a baseline.
    public mutating func setBaseline(_ windows: [WindowID]?) {
        guard let windows else { return }
        known = Set(windows)
        isBaselined = true
        epoch += 1
    }

    /// Stops offering windows until a new baseline is set; results read before this are stale.
    public mutating func invalidate() {
        isBaselined = false
        epoch += 1
    }

    /// Returns windows that weren't seen before and remembers them, so each window is offered only once.
    public mutating func takeNew(from windows: [WindowID], epoch: Int) -> [WindowID] {
        guard isBaselined, epoch == self.epoch else { return [] }
        var new: [WindowID] = []
        for window in windows where known.insert(window).inserted {
            new.append(window)
        }
        return new
    }

    public mutating func remember(_ window: WindowID) {
        known.insert(window)
    }

    public func contains(_ window: WindowID) -> Bool {
        known.contains(window)
    }
}
