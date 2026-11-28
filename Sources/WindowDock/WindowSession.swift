import AppKit
import WindowDockCore

struct ManagedWindow {
    let id: UUID
    var candidate: WindowCandidate
    let originalFrame: CGRect
    let originallyMinimized: Bool
    // A close can open a save sheet. Until it actually closes, only follow this exact window, never a title match.
    var closingWindowID: CGWindowID?

    func restore(using access: WindowAccessClient) throws {
        guard !candidate.application.isTerminated else { return }
        do {
            _ = try access.minimize(candidate.element, false)
            try access.setFrame(candidate.element, originalFrame)
            _ = try access.minimize(candidate.element, originallyMinimized)
        } catch let error as WindowAccessError where error.code == .invalidUIElement {
            // A closed window no longer has any state to restore.
            return
        }

    }
}

enum PaneSplitRestriction: Error {
    case layout
    case minimumSize(apps: String)
}

/// A pane layout and the tabs its panes show.
struct PaneState {
    var gridSize: WorkspaceGridSize
    var customLayout: PaneLayout?
    var cells: [UUID?]
    var activeCell: Int
    var pinnedCells: Set<Int>
    var lastUnpinnedCell: Int
    /// The panes hidden tabs wait behind.
    var assignments: [UUID: Int]
}

@MainActor
final class WindowSession {
    private static let frameRoundingTolerance = CGSize(width: 12, height: 20)
    private static let framePositionTolerance: CGFloat = 1
    private static let lateFrameRequestInterval: TimeInterval = 3
    private static let constraintRecoveryDelay: TimeInterval = 3

    // Every tab has a position and a pane assignment. Start pages don't own an AX window.
    private(set) var tabIDs: [UUID] = []
    private(set) var managedByID: [UUID: ManagedWindow] = [:]
    var windows: [ManagedWindow] { tabIDs.compactMap { managedByID[$0] } }
    var onFocusStartPage: (() -> Void)?
    var onAddedApplication: ((NSRunningApplication) -> Void)?
    /// Called for every window that becomes a tab, however it was added.
    var onAddedWindow: ((WindowCandidate) -> Void)?
    // The last regular-grid preset; customLayout takes precedence when present.
    private(set) var gridSize = WorkspaceGridSize.single
    private(set) var customLayout: PaneLayout?
    private(set) var cells: [UUID?] = [nil]
    private(set) var activeCell = 0
    private(set) var pinnedCells: Set<Int> = []
    private var lastUnpinnedCell = 0
    private var previousSelectedID: UUID?
    private var pinnedTabIDs: Set<UUID> = []
    /// Combined tabs. Each keeps the pane state it shows; the live panes are the state of `activeGroupID`.
    /// A window belongs to at most one combined tab: the one whose panes show it.
    private var paneGroups: [UUID: PaneState] = [:]
    private(set) var activeGroupID: UUID?
    /// The panes of the tabs outside combined tabs, kept while a combined tab is shown.
    private var baseState: PaneState?
    var onChange: (() -> Void)?
    var closesWindowsOnRelease = false {
        didSet { if oldValue != closesWindowsOnRelease { onChange?() } }
    }
    var onMessage: ((WorkspaceNotice) -> Void)?
    var onConstraintWarningCleared: ((String) -> Void)?
    var onPresentedFrame: ((CGRect?) -> Void)?
    var onPresentedFrames: (([UUID: CGRect]) -> Void)?
    var targetFrame: (() -> CGRect?)?
    var secondaryTargetFrame: (() -> CGRect?)?
    var targetFrames: (() -> [Int: CGRect])?
    var fitMinimumSizes: (([Int: CGSize]) -> Bool)?
    let access: WindowAccessClient
    private var requestedFrames: [UUID: CGRect] = [:]
    private var suspendedWindowIDs: Set<UUID> = []
    private var assignments: [UUID: Int] = [:]
    private var minimumSizes: [UUID: CGSize] = [:]
    private var constraintWarningIDs: Set<UUID> = []
    private var constraintRecoveryTimers: [UUID: (timer: Timer, fitted: Bool)] = [:]
    /// The frames last passed to `onPresentedFrames`, which the workspace shows through.
    private var presentedFrames: [UUID: CGRect] = [:]
    /// The frames windows had once they were last aligned, to notice when they are moved, resized or maximized outside WindowDock.
    private var alignedFrames: [UUID: CGRect] = [:]
    /// Frames recently requested for each window: a busy app can apply an earlier request after a later one.
    private var recentFrameRequests: [UUID: [(frame: CGRect, time: TimeInterval)]] = [:]
    private var isSynchronizing = false
    private var resyncRequested = false
    private var resyncExcluding: UUID?
    private var pendingWindowLaunches: [UUID: (page: UUID, pid: pid_t)] = [:]
    /// Apps a start page is opening a window for; automatic grouping must leave their new windows to it.
    private var pendingLaunchBundleIDs: [UUID: String] = [:]

    init(access: WindowAccessClient = WindowAccessClient()) {
        self.access = access
    }

    var selectedID: UUID? { cells[activeCell] }
    var numberedTabTargets: [UUID] {
        let currentTab = activeGroupID ?? selectedID
        return tabEntries.filter { $0 != currentTab }
    }

    var canSelectPreviousUsedTab: Bool {
        previousSelectedID.map { $0 != selectedID && tabIDs.contains($0) } ?? false
    }

    var tabSwitchCell: Int? {
        guard !cells.isEmpty else { return nil }
        if cells.indices.contains(lastUnpinnedCell), !pinnedCells.contains(lastUnpinnedCell) {
            return lastUnpinnedCell
        }
        return cells.indices.first { !pinnedCells.contains($0) }
    }

    func managedWindowID(forTabEntry tabID: UUID) -> UUID? {
        if paneGroups[tabID] != nil {
            return groupMembers(tabID).first { managedByID[$0] != nil }
        }
        return managedByID[tabID] == nil ? nil : tabID
    }

    func isTabPinned(_ tabID: UUID) -> Bool {
        if paneGroups[tabID] != nil {
            return groupMembers(tabID).contains { pinnedTabIDs.contains($0) }
        }
        return pinnedTabIDs.contains(tabID)
    }

    func setTabPinned(_ pinned: Bool, for tabID: UUID) {
        guard let windowID = managedWindowID(forTabEntry: tabID) else { return }
        guard isTabPinned(tabID) != pinned else { return }
        if pinned {
            pinnedTabIDs.insert(windowID)
        } else {
            let members = paneGroups[tabID] == nil ? [windowID] : groupMembers(tabID)
            for id in members { pinnedTabIDs.remove(id) }
        }
        let previousOrder = tabIDs
        reorderTabEntries(tabEntries)
        if tabIDs == previousOrder { onChange?() }
    }
    var primaryID: UUID? { cells.first ?? nil }
    var secondaryID: UUID? { cells.count > 1 ? cells[1] : nil }
    var splitLayout: WorkspaceSplitLayout { gridSize.columns == 1 ? .stacked : .sideBySide }
    var selected: ManagedWindow? { windows.first { $0.id == selectedID } }
    var isSplit: Bool { cells.count > 1 }
    var paneLayout: PaneLayout {
        customLayout
            ?? .grid(
                columnWeights: Array(repeating: 1, count: gridSize.columns),
                rowWeights: Array(repeating: 1, count: gridSize.rows))
    }
    var visibleWindows: [ManagedWindow] {
        windows.filter { cells.contains($0.id) }
    }

    func setSplit(_ enabled: Bool, layout: WorkspaceSplitLayout = .sideBySide) {
        setGrid(
            enabled
                ? WorkspaceGridSize(columns: layout == .sideBySide ? 2 : 1, rows: layout == .stacked ? 2 : 1)
                : .single)
    }

    func setGrid(_ size: WorkspaceGridSize) {
        guard size.isValid else {
            onMessage?(.attention(L("分割数は縦・横それぞれ1〜4にしてください。")))
            return
        }
        guard size != gridSize || customLayout != nil else { return }
        configureGrid(size)
        clearPresentation()
        onChange?()
        presentVisibleWindows()
    }

    private func configureGrid(_ size: WorkspaceGridSize) {
        let result = GridReflow.reflow(
            oldColumns: customLayout == nil ? gridSize.columns : cells.count,
            oldCells: cells,
            activeCell: activeCell,
            newColumns: customLayout == nil ? size.columns : size.cellCount,
            newRows: customLayout == nil ? size.rows : 1,
            windowIDs: tabIDs,
            assignments: assignments,
            fillIDs: paneFillIDs)
        cells = result.cells
        activeCell = result.activeCell
        assignments = result.assignments
        gridSize = size
        customLayout = nil
        // Collapsing to one pane, e.g. when a window doesn't fit, must not keep that pane pinned.
        normalizePaneSwitchState()
    }

    func setCustomLayout(_ layout: PaneLayout) {
        guard layout.isValid else {
            onMessage?(.attention(L("ペインの配置を変更できませんでした。")))
            return
        }
        guard layout != customLayout else { return }
        let result = GridReflow.reflow(
            oldColumns: cells.count, oldCells: cells, activeCell: activeCell,
            newColumns: layout.paneCount, newRows: 1,
            windowIDs: tabIDs, assignments: assignments, fillIDs: paneFillIDs)
        pinnedCells = Set(pinnedCells.filter { $0 < layout.paneCount })
        applyPaneLayout(layout, reflow: result)
    }

    func splitRestriction(at index: Int, axis: PaneLayout.Axis, currentLayout: PaneLayout?) -> PaneSplitRestriction? {
        if case .failure(let reason) = plannedPaneSplit(at: index, axis: axis, currentLayout: currentLayout) {
            return reason
        }
        return nil
    }

    private func plannedPaneSplit(
        at index: Int, axis: PaneLayout.Axis,
        currentLayout: PaneLayout?)
        -> Result<(layout: PaneLayout, reflow: GridReflowResult<UUID>), PaneSplitRestriction> {
        let layout = currentLayout ?? paneLayout
        guard layout.isValid, layout.paneCount == cells.count,
              let split = layout.splittingPane(at: index, axis: axis),
              let result = PaneReflow.split(
                  cells: cells, activeCell: activeCell, at: index,
                  windowIDs: paneFillIDs, assignments: assignments)
        else { return .failure(.layout) }
        if !minimumSizes.isEmpty {
            let bounds = currentTargets().values.reduce(CGRect.null) { $0.union($1) }
            let sizes = minimums(for: result.assignments)
            guard !bounds.isNull,
                  let minimum = split.minimumSize(sizes, dividerThickness: PaneLayout.dividerThickness)
            else { return .failure(.layout) }
            if minimum.width > bounds.width || minimum.height > bounds.height {
                let ids = split.minimumSizeBlockers(
                    in: bounds, paneMinimums: sizes, windowMinimums: minimumSizes, assignments: result.assignments)
                guard let apps = constraintAppNames(for: ids) else { return .failure(.layout) }
                return .failure(.minimumSize(apps: apps))
            }
        }
        return .success((split, result))
    }

    func splitPane(at index: Int, axis: PaneLayout.Axis, currentLayout: PaneLayout? = nil) {
        switch plannedPaneSplit(at: index, axis: axis, currentLayout: currentLayout) {
        case .failure(.layout):
            onMessage?(.attention(L("ペインの配置を変更できませんでした。")))
        case .failure(.minimumSize(let apps)):
            onMessage?(.attention(L("%@のウィンドウがペインに収まらないため、この方向には分割できません。", apps)))
        case .success(let plan):
            pinnedCells = Set(pinnedCells.map { $0 > index ? $0 + 1 : $0 })
            if lastUnpinnedCell > index { lastUnpinnedCell += 1 }
            applyPaneLayout(plan.layout, reflow: plan.reflow)
        }
    }

    func closePane(at index: Int, currentLayout: PaneLayout? = nil) {
        let layout = currentLayout ?? paneLayout
        guard layout.isValid, layout.paneCount == cells.count,
              let removal = layout.removingPane(at: index),
              let result = PaneReflow.close(
                  cells: cells, activeCell: activeCell, at: index,
                  destination: removal.destination, assignments: assignments)
        else {
            onMessage?(.attention(L("ペインの配置を変更できませんでした。")))
            return
        }
        pinnedCells = Set(pinnedCells.compactMap { $0 == index ? nil : ($0 > index ? $0 - 1 : $0) })
        if lastUnpinnedCell == index {
            lastUnpinnedCell = removal.destination
        } else if lastUnpinnedCell > index {
            lastUnpinnedCell -= 1
        }
        applyPaneLayout(removal.layout, reflow: result)
        // Raising alone can leave the closed pane's window focused when the survivor belongs to another app.
        if selectedID != nil { raiseSelected(activate: true) }
    }

    func updatePaneProportions(_ layout: PaneLayout) {
        guard customLayout != nil, layout.isValid, layout.paneCount == cells.count else {
            onMessage?(.attention(L("ペインの配置を変更できませんでした。")))
            return
        }
        customLayout = layout
    }

    @discardableResult
    func equalizePaneSplit(at index: Int) -> Bool {
        guard let customLayout,
              let equalized = customLayout.equalizingSplit(containingPaneAt: index),
              equalized != customLayout
        else { return false }
        self.customLayout = equalized
        onChange?()
        realign(raiseWindows: false)
        return true
    }

    private func applyPaneLayout(_ layout: PaneLayout, reflow: GridReflowResult<UUID>) {
        customLayout = layout
        cells = reflow.cells
        activeCell = reflow.activeCell
        assignments = reflow.assignments
        normalizePaneSwitchState()
        clearPresentation()
        onChange?()
        presentVisibleWindows()
    }

    func cellIndex(for id: UUID) -> Int? { cells.firstIndex { $0 == id } }

    func activateCell(_ index: Int) {
        guard cells.indices.contains(index), index != activeCell else { return }
        let previousSelection = selectedID
        activeCell = index
        recordSelectionChange(from: previousSelection)
        if !pinnedCells.contains(index) { lastUnpinnedCell = index }
        onChange?()
    }

    func activateAdjacentPane(_ direction: Int) -> UUID? {
        guard direction == -1 || direction == 1 else { return nil }
        let occupiedCells = cells.indices.filter { cells[$0] != nil }
        guard occupiedCells.count > 1 else { return nil }
        let current = occupiedCells.firstIndex(of: activeCell) ?? (direction > 0 ? -1 : 0)
        let next = (current + direction + occupiedCells.count) % occupiedCells.count
        let cell = occupiedCells[next]
        activateCell(cell)
        return cells[cell]
    }

    private func recordSelectionChange(from previousID: UUID?) {
        guard let previousID, previousID != selectedID, tabIDs.contains(previousID) else { return }
        previousSelectedID = previousID
    }

    func isPanePinned(_ index: Int) -> Bool { pinnedCells.contains(index) }

    func setPanePinned(_ pinned: Bool, at index: Int) {
        guard cells.count > 1, cells.indices.contains(index), pinnedCells.contains(index) != pinned else { return }
        if pinned {
            pinnedCells.insert(index)
            if lastUnpinnedCell == index {
                lastUnpinnedCell = cells.indices.first(where: { !pinnedCells.contains($0) }) ?? index
            }
        } else {
            pinnedCells.remove(index)
            lastUnpinnedCell = index
        }
        onChange?()
    }

    func setPinnedCells(_ indices: [Int]) {
        pinnedCells = Set(indices.filter { cells.indices.contains($0) })
        normalizePaneSwitchState()
        onChange?()
    }

    private func normalizePaneSwitchState() {
        pinnedCells = Set(pinnedCells.filter { cells.indices.contains($0) })
        if cells.count <= 1 {
            pinnedCells.removeAll()
            lastUnpinnedCell = 0
        } else if let target = tabSwitchCell {
            lastUnpinnedCell = target
        } else {
            lastUnpinnedCell = min(max(lastUnpinnedCell, 0), cells.count - 1)
        }
    }

    // MARK: Combined tabs

    /// The tab bar entries: tabs, with each combined tab's windows replaced by the combined tab's ID.
    var tabEntries: [UUID] {
        guard !paneGroups.isEmpty else { return tabIDs }
        var entries: [UUID] = []
        var seen: Set<UUID> = []
        for id in tabIDs {
            if let group = groupID(containing: id) {
                if seen.insert(group).inserted { entries.append(group) }
            } else {
                entries.append(id)
            }
        }
        return entries
    }

    func isPaneGroup(_ id: UUID) -> Bool { paneGroups[id] != nil }

    /// The combined tab whose panes show a tab.
    func groupID(containing id: UUID) -> UUID? {
        if let activeGroupID, cells.contains(id) { return activeGroupID }
        return paneGroups.first { $0.key != activeGroupID && $0.value.cells.contains(id) }?.key
    }

    /// A combined tab's tabs in pane order.
    func groupMembers(_ group: UUID) -> [UUID] {
        guard let state = paneGroups[group] else { return [] }
        return (group == activeGroupID ? cells : state.cells).compactMap { $0 }
    }

    /// The pane state a combined tab shows.
    func paneState(ofGroup group: UUID) -> PaneState? {
        group == activeGroupID ? livePaneState : paneGroups[group]
    }

    var canCombineVisiblePanes: Bool {
        activeGroupID == nil && cells.count > 1 && cells.filter { $0 != nil }.count > 1
    }

    /// Turns the shown panes into one combined tab that keeps their layout and tabs.
    /// The normal panes go back to one pane, showing the tab after the combined tab.
    @discardableResult
    func combineVisiblePanes() -> UUID? {
        guard canCombineVisiblePanes else { return nil }
        let members = cells.compactMap { $0 }
        var next = 0
        if let first = tabIDs.firstIndex(where: members.contains) {
            var order = tabIDs.filter { !members.contains($0) }
            order.insert(contentsOf: members, at: first)
            tabIDs = order
            next = first + members.count
        }
        let others = looseTabIDs.filter { !members.contains($0) }
        let shown = tabIDs[next...].first(where: others.contains) ?? tabIDs[..<next].last(where: others.contains)
        let group = UUID()
        paneGroups[group] = livePaneState
        baseState = PaneState(
            gridSize: .single, customLayout: nil, cells: [shown], activeCell: 0, pinnedCells: [],
            lastUnpinnedCell: 0, assignments: Dictionary(uniqueKeysWithValues: others.map { ($0, 0) }))
        activeGroupID = group
        onChange?()
        return group
    }

    /// Turns a combined tab back into separate tabs. Ungrouping the shown one brings back the normal panes, whose empty
    /// panes take its windows.
    func ungroup(_ group: UUID, activate: Bool = false) {
        guard paneGroups[group] != nil else { return }
        guard activeGroupID == group else {
            paneGroups[group] = nil
            onChange?()
            return
        }
        let previousSelection = selectedID
        switchPaneState(to: nil)
        paneGroups[group] = nil
        let loose = looseTabIDs
        for index in cells.indices where cells[index] == nil && !pinnedCells.contains(index) {
            cells[index] = loose.first { !cells.contains($0) }
            if let id = cells[index] { assignments[id] = index }
        }
        recordSelectionChange(from: previousSelection)
        onChange?()
        if activate, let id = selectedID, managedByID[id] != nil { focus(id) }
        presentVisibleWindows()
        if activate, selectedID.map(isStartPage) == true { onFocusStartPage?() }
    }

    /// The normal panes, even while a combined tab is shown.
    var basePaneState: PaneState { baseState ?? livePaneState }

    /// Each combined tab's pane state, with the live state for the shown one.
    var paneGroupStates: [(id: UUID, state: PaneState)] {
        tabEntries.compactMap { entry in paneState(ofGroup: entry).map { (entry, $0) } }
    }

    /// Recreates saved combined tabs (shown as inactive) from pane states whose cells hold this session's tab IDs.
    func restorePaneGroups(_ states: [PaneState]) {
        guard activeGroupID == nil else { return }
        let known = Set(tabIDs)
        var restored = false
        for var state in states {
            guard state.customLayout?.isValid ?? state.gridSize.isValid,
                  state.cells.count == state.customLayout?.paneCount ?? state.gridSize.cellCount
            else { continue }
            let grouped = groupedIDs
            state.cells = state.cells.map { $0.flatMap { known.contains($0) && !grouped.contains($0) ? $0 : nil } }
            let members = state.cells.compactMap { $0 }
            guard !members.isEmpty, Set(members).count == members.count else { continue }
            state.activeCell = state.cells.indices.contains(state.activeCell) ? state.activeCell : 0
            state.pinnedCells = Set(state.pinnedCells.filter { state.cells.indices.contains($0) })
            state.assignments = state.assignments.filter { known.contains($0.key) }
            for (index, id) in state.cells.enumerated() {
                if let id { state.assignments[id] = index }
            }
            paneGroups[UUID()] = state
            restored = true
        }
        guard restored else { return }
        applyPaneState(excludingGroupedTabs(from: livePaneState))
        clearPresentation()
        onChange?()
        presentVisibleWindows()
    }

    /// The tab index where a tab bar entry starts; the end for an index past the last entry.
    func tabIndex(forEntryAt index: Int) -> Int {
        let entries = tabEntries
        guard entries.indices.contains(index) else { return tabIDs.count }
        let entry = entries[index]
        let members = paneGroups[entry] == nil ? [entry] : groupMembers(entry)
        return tabIDs.firstIndex(where: members.contains) ?? tabIDs.count
    }

    private var groupedIDs: Set<UUID> {
        var ids: Set<UUID> = []
        for (group, state) in paneGroups {
            ids.formUnion((group == activeGroupID ? cells : state.cells).compactMap { $0 })
        }
        return ids
    }

    /// Tabs outside combined tabs.
    private var looseTabIDs: [UUID] {
        let grouped = groupedIDs
        return tabIDs.filter { !grouped.contains($0) }
    }

    /// The tabs that may fill empty panes: a combined tab only shows its own tabs.
    private var paneFillIDs: [UUID] { activeGroupID == nil ? looseTabIDs : [] }

    private var livePaneState: PaneState {
        PaneState(
            gridSize: gridSize, customLayout: customLayout, cells: cells, activeCell: activeCell,
            pinnedCells: pinnedCells, lastUnpinnedCell: lastUnpinnedCell, assignments: assignments)
    }

    private func applyPaneState(_ state: PaneState) {
        gridSize = state.gridSize
        customLayout = state.customLayout
        cells = state.cells
        activeCell = cells.indices.contains(state.activeCell) ? state.activeCell : 0
        pinnedCells = state.pinnedCells
        lastUnpinnedCell = state.lastUnpinnedCell
        normalizePaneSwitchState()
        let fallback = tabSwitchCell ?? 0
        var next: [UUID: Int] = [:]
        for id in tabIDs {
            if let index = cellIndex(for: id) {
                next[id] = index
            } else if let stored = state.assignments[id], cells.indices.contains(stored) {
                next[id] = stored
            } else if let current = assignments[id], cells.indices.contains(current) {
                next[id] = current
            } else {
                next[id] = fallback
            }
        }
        assignments = next
    }

    /// Keeps the windows of combined tabs out of normal panes; other tabs take the panes they leave.
    private func excludingGroupedTabs(from state: PaneState) -> PaneState {
        let grouped = groupedIDs
        var state = state
        for index in state.cells.indices where state.cells[index].map(grouped.contains) == true {
            state.cells[index] = tabIDs.first { !grouped.contains($0) && !state.cells.contains($0) }
        }
        return state
    }

    /// Shows a combined tab's panes, or the normal panes for nil, remembering the panes shown until now.
    /// Callers report the change and present the windows.
    private func switchPaneState(to group: UUID?) {
        guard group != activeGroupID, group.map({ paneGroups[$0] != nil }) ?? true else { return }
        let live = livePaneState
        if let activeGroupID {
            paneGroups[activeGroupID] = live
        } else {
            baseState = live
        }
        activeGroupID = group
        if let group, let state = paneGroups[group] {
            applyPaneState(state)
        } else {
            applyPaneState(excludingGroupedTabs(from: baseState ?? live))
            baseState = nil
        }
        clearPresentation()
    }

    /// The tab that replaces a removed one in an unsplit workspace: the next normal tab, none in a combined tab.
    private func replacementTab(near index: Int) -> UUID? {
        guard activeGroupID == nil else { return nil }
        let loose = Set(looseTabIDs)
        let split = min(index, tabIDs.count)
        return tabIDs[split...].first(where: loose.contains) ?? tabIDs[..<split].last(where: loose.contains)
    }

    func focusVisibleWindow(_ id: UUID) {
        if let index = cellIndex(for: id) { activateCell(index) }
    }

    func observeFocusedWindow(_ element: AXUIElement) {
        guard let window = windows.first(where: { CFEqual($0.candidate.element, element) }) else { return }
        // A running app can briefly focus its old window before the requested new one appears.
        guard !pendingWindowLaunches.values.contains(where: {
            $0.pid == window.candidate.application.processIdentifier && cells.contains($0.page)
        }) else { return }
        let previousSelection = selectedID
        let id = window.id
        guard groupID(containing: id) == activeGroupID else {
            // The window belongs to other panes; show them, as clicking its tab would.
            select(id)
            return
        }
        let previousAssignment = assignments[id]
        var changed = false
        var targetCell: Int?
        if let cell = cellIndex(for: id) {
            targetCell = cell
            if activeCell != cell {
                activeCell = cell
                changed = true
            }
            if !pinnedCells.contains(cell), lastUnpinnedCell != cell {
                lastUnpinnedCell = cell
                changed = true
            }
        } else {
            let cell: Int?
            if isSplit {
                cell = tabSwitchCell
            } else {
                cell = cells.indices.first
            }
            guard let cell else { return }
            targetCell = cell
            cells[cell] = id
            assignments[id] = cell
            activeCell = cell
            if !pinnedCells.contains(cell) { lastUnpinnedCell = cell }
            changed = true
        }
        guard changed else { return }
        recordSelectionChange(from: previousSelection)
        var errors: [Error] = []
        if previousAssignment != targetCell, !access.isFullScreen(window.candidate.element),
           let target = targetCell.flatMap({ currentTargets()[$0] })
        {
            do {
                try align(window, to: target)
                alignedFrames[id] = try access.frame(window.candidate.element)
            } catch {
                errors.append(error)
            }
        }
        presentedFrames = Dictionary(
            uniqueKeysWithValues: visibleWindows.compactMap { window in
                guard !access.isFullScreen(window.candidate.element) else { return nil }
                return alignedFrames[window.id].map { (window.id, $0) }
            })
        onPresentedFrame?(selectedID.flatMap { presentedFrames[$0] })
        onPresentedFrames?(presentedFrames)
        onChange?()
        report(errors)
    }

    func contains(_ candidate: WindowCandidate) -> Bool {
        managedByID.values.contains { $0.candidate.isSameWindow(as: candidate) }
    }

    func isStartPage(_ id: UUID) -> Bool { managedByID[id] == nil && tabIDs.contains(id) }

    func reserveLaunch(of bundleID: String) -> UUID {
        let token = UUID()
        pendingLaunchBundleIDs[token] = bundleID
        return token
    }

    func releaseLaunch(_ token: UUID) {
        pendingLaunchBundleIDs.removeValue(forKey: token)
    }

    /// Whether a start page is waiting for a new window of the app.
    func isAwaitingWindow(pid: pid_t, bundleID: String?) -> Bool {
        pendingWindowLaunches.values.contains { $0.pid == pid }
            || bundleID.map { pendingLaunchBundleIDs.values.contains($0) } == true
    }

    func launchWindows(at url: URL, from page: UUID) async throws -> [WindowCandidate] {
        try Task.checkCancellation()
        guard isStartPage(page), cells.contains(page) else { throw CancellationError() }
        let bundleID = Bundle(url: url)?.bundleIdentifier
        let reservation = bundleID.map(reserveLaunch(of:))
        defer { reservation.map(releaseLaunch) }
        // Launch Services can resolve another path to the same live instance. Don't reopen it and focus its old tab.
        if let app = access.runningApplication(url) {
            return try await launchCandidates(for: app, from: page, alreadyRunning: true)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        return try await launchCandidates(for: app, from: page, alreadyRunning: false)
    }

    /// Chooses an item of the app's Dock menu as the Dock would, and returns the new windows it opened for the start
    /// page. The Dock's own commands, such as Hide or Quit, don't wait for windows unless they launch the app.
    func chooseDockMenuItem(_ path: DockMenuPath, in items: [DockMenuItem], of url: URL,
                            from page: UUID) async throws -> [WindowCandidate] {
        try Task.checkCancellation()
        guard isStartPage(page), cells.contains(page) else { throw CancellationError() }
        let choose = access.chooseDockMenuItem
        let press = { try await Task.detached { try choose(path, url) }.value }
        if let app = access.runningApplication(url) {
            guard !items.isDockCommand(path) else {
                try await press()
                return []
            }
            return try await launchCandidates(for: app, from: page, alreadyRunning: true, request: press)
        }
        let reservation = Bundle(url: url)?.bundleIdentifier.map(reserveLaunch(of:))
        defer { reservation.map(releaseLaunch) }
        try await press()
        for _ in 0 ..< 20 {
            try await Task.sleep(nanoseconds: 250_000_000)
            guard isStartPage(page), cells.contains(page) else { throw CancellationError() }
            if let app = access.runningApplication(url) {
                return try await launchCandidates(for: app, from: page, alreadyRunning: false)
            }
        }
        return []
    }

    /// Waits for the app's new windows. For a running app, `request` asks it for one, its New Window command by default.
    func launchCandidates(for app: NSRunningApplication, from page: UUID, alreadyRunning: Bool,
                          request: (() async throws -> Void)? = nil) async throws -> [WindowCandidate] {
        try Task.checkCancellation()
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw WindowAccessError(operation: L("新規ウィンドウの作成"), code: .actionUnsupported)
        }
        guard isStartPage(page), cells.contains(page) else { throw CancellationError() }
        let token = UUID()
        pendingWindowLaunches[token] = (page, app.processIdentifier)
        defer { pendingWindowLaunches.removeValue(forKey: token) }

        var priorElements: [AXUIElement] = []
        var priorNumbers: Set<CGWindowID> = []
        let number = access.windowID
        if alreadyRunning {
            let elements = access.windowElements
            (priorElements, priorNumbers) = try await Task.detached {
                guard let old = elements(app) else {
                    throw WindowAccessError(operation: L("ウィンドウ一覧の取得"), code: .cannotComplete)
                }
                return (old, Set(old.compactMap(number)))
            }.value
            try Task.checkCancellation()
            if let request { try await request() } else { try await access.requestNewWindow(app) }
        }
        let list = access.applicationWindows
        var previous: [WindowCandidate] = []
        var stable = 0
        for _ in 0 ..< 40 {
            try Task.checkCancellation()
            guard isStartPage(page), cells.contains(page) else { throw CancellationError() }
            guard !app.isTerminated else { return [] }
            let fresh = await Task.detached { [priorElements, priorNumbers] in
                (list(app) ?? []).filter { candidate in
                    !priorElements.contains { CFEqual($0, candidate.element) }
                        && (priorNumbers.isEmpty || number(candidate.element).map(priorNumbers.contains) != true)
                }
            }.value
            let windows = fresh.filter { !contains($0) && !isClaimedElsewhere($0) }
            if !windows.isEmpty, windows.count == previous.count,
               windows.allSatisfy({ window in previous.contains { $0.isSameWindow(as: window) } }) {
                stable += 1
                if stable >= 3 { return windows }
            } else {
                stable = 0
            }
            previous = windows
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return previous
    }

    func newTab(id: UUID = UUID()) {
        switchPaneState(to: nil)
        tabIDs.append(id)
        let cell = tabSwitchCell ?? activeCell
        let displaced = cells[cell]
        cells[cell] = id
        assignments[id] = cell
        activeCell = cell
        replacePresentation(of: displaced, with: id)
        select(id, activate: true)
    }

    private struct UnavailableWindow: LocalizedError {
        let label: String
        var errorDescription: String? { L("追加できなくなったウィンドウ: %@", label) }
    }

    @discardableResult
    func fillStartPage(_ id: UUID, with candidates: [WindowCandidate]) -> Bool {
        guard isStartPage(id), let index = tabIDs.firstIndex(of: id), let cell = cellIndex(for: id) else {
            onMessage?(.attention(L("このタブまたはウィンドウは利用できなくなりました。")))
            return false
        }
        var added = 0
        var errors: [Error] = []
        for candidate in candidates {
            guard !contains(candidate), !isClaimedElsewhere(candidate) else {
                errors.append(UnavailableWindow(label: candidate.label))
                continue
            }
            do {
                let window = try register(candidate, id: added == 0 ? id : UUID())
                if added > 0 {
                    tabIDs.insert(window.id, at: index + added)
                    assignments[window.id] = cell
                }
                added += 1
            } catch {
                errors.append(error)
            }
        }
        if added > 0 { select(id, activate: true) }
        report(errors)
        return added > 0
    }

    func add(_ candidate: WindowCandidate, originalFrame: CGRect? = nil, at insertionIndex: Int? = nil) {
        if let insertionIndex, !(0 ... tabIDs.count).contains(insertionIndex) {
            onMessage?(.attention(L("タブを移動できませんでした。移動先と対象ウィンドウを確認してください。")))
            return
        }
        add([candidate], originalFrame: originalFrame, at: insertionIndex)
    }

    func add(_ candidates: [WindowCandidate]) {
        add(candidates, originalFrame: nil)
    }

    private func register(_ candidate: WindowCandidate, id: UUID,
                          originalFrame: CGRect? = nil) throws -> ManagedWindow {
        for attribute in [kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute] {
            try access.requireWritable(candidate.element, attribute)
        }
        let window = ManagedWindow(
            id: id, candidate: candidate, originalFrame: try originalFrame ?? access.frame(candidate.element),
            originallyMinimized: try access.isMinimized(candidate.element))
        managedByID[id] = window
        onAddedApplication?(candidate.application)
        onAddedWindow?(candidate)
        return window
    }

    /// Adds a new window as a tab without selecting it, raising windows or bringing the workspace forward.
    /// It only fills a pane when one is empty; otherwise it waits behind the pane's shown tab.
    /// Throws when the window can't be managed, so the caller can decide how often to report it.
    @discardableResult
    func addInBackground(_ candidate: WindowCandidate) throws -> UUID? {
        guard !contains(candidate), !isClaimedElsewhere(candidate) else { return nil }
        let window = try register(candidate, id: UUID())
        tabIDs.append(window.id)
        let preferred = tabSwitchCell ?? activeCell
        if activeGroupID != nil {
            // A combined tab only shows its own windows. The new tab waits for the normal panes instead.
            if var base = baseState,
               let empty = base.cells.indices.first(where: { base.cells[$0] == nil && !base.pinnedCells.contains($0) })
            {
                base.cells[empty] = window.id
                base.assignments[window.id] = empty
                baseState = base
            }
        } else {
            let empty = cells.indices.contains(preferred) && cells[preferred] == nil
                ? preferred : cells.indices.first { cells[$0] == nil && !pinnedCells.contains($0) }
            if let empty {
                cells[empty] = window.id
                assignments[window.id] = empty
                onChange?()
                synchronize(bringToFront: false, raiseWindows: false, showShortcutHint: false)
                return window.id
            }
        }
        assignments[window.id] = preferred
        onChange?()
        if !access.isFullScreen(candidate.element), let target = currentTargets()[preferred] {
            do {
                try align(window, to: target)
                alignedFrames[window.id] = try access.frame(candidate.element)
            } catch {
                report(error)
            }
        }
        return window.id
    }

    private func add(_ candidates: [WindowCandidate], originalFrame: CGRect?, at insertionIndex: Int? = nil) {
        let leavesGroup = activeGroupID != nil && candidates.contains { !contains($0) }
        if leavesGroup { switchPaneState(to: nil) }
        var added: [ManagedWindow] = []
        var errors: [Error] = []
        for candidate in candidates where !contains(candidate) {
            do {
                let window = try register(candidate, id: UUID(), originalFrame: originalFrame)
                tabIDs.insert(window.id, at: insertionIndex ?? tabIDs.count)
                added.append(window)
                assignments[window.id] = activeCell
            } catch {
                errors.append(error)
            }
        }
        for window in added.dropLast() {
            do {
                _ = try access.minimize(window.candidate.element, false)
            } catch {
                errors.append(error)
            }
        }
        var emptyCells = cells.indices.filter { cells[$0] == nil }
        if let position = emptyCells.firstIndex(of: activeCell) {
            emptyCells.remove(at: position)
            emptyCells.insert(activeCell, at: 0)
        }
        for (window, empty) in zip(added, emptyCells) {
            cells[empty] = window.id
            assignments[window.id] = empty
        }
        if let last = added.last {
            select(last.id)
        } else if leavesGroup {
            onChange?()
            presentVisibleWindows()
        }
        report(errors)
    }

    /// Selects a tab, or a combined tab by its entry ID. A tab shown by other panes brings those panes back.
    func select(_ id: UUID, activate: Bool = false) {
        if paneGroups[id] != nil {
            selectGroup(id, activate: activate)
            return
        }
        guard tabIDs.contains(id) else { return }
        let previousSelection = selectedID
        let group = groupID(containing: id)
        let switching = group != activeGroupID
        if switching { switchPaneState(to: group) }
        var displaced: UUID?
        if let index = cellIndex(for: id) {
            activeCell = index
            if !pinnedCells.contains(index) { lastUnpinnedCell = index }
        } else {
            guard let cell = tabSwitchCell else {
                onChange?()
                if switching { presentVisibleWindows() }
                return
            }
            displaced = cells[cell]
            cells[cell] = id
            assignments[id] = cell
            activeCell = cell
            lastUnpinnedCell = cell
        }
        recordSelectionChange(from: previousSelection)
        if !switching { replacePresentation(of: displaced, with: id) }
        onChange?()
        if activate, managedByID[id] != nil { focus(id) }
        presentVisibleWindows()
        if activate, isStartPage(id) { onFocusStartPage?() }
    }

    private func selectGroup(_ group: UUID, activate: Bool) {
        let previousSelection = selectedID
        switchPaneState(to: group)
        recordSelectionChange(from: previousSelection)
        onChange?()
        if activate, let id = selectedID, managedByID[id] != nil { focus(id) }
        presentVisibleWindows()
        if activate, selectedID.map(isStartPage) == true { onFocusStartPage?() }
    }

    private func select(_ id: UUID, inCell cell: Int, activate: Bool) {
        guard tabIDs.contains(id), cells.indices.contains(cell),
              !pinnedCells.contains(cell), cellIndex(for: id) == nil || cellIndex(for: id) == cell
        else { return }
        let previousSelection = selectedID
        let displaced = cells[cell]
        cells[cell] = id
        assignments[id] = cell
        activeCell = cell
        lastUnpinnedCell = cell
        recordSelectionChange(from: previousSelection)
        replacePresentation(of: displaced, with: id)
        onChange?()
        if activate, managedByID[id] != nil { focus(id) }
        presentVisibleWindows()
        if activate, isStartPage(id) { onFocusStartPage?() }
    }

    /// Focuses a window; if its AX element went stale, re-resolves it once and retries.
    private func focus(_ id: UUID) {
        guard let window = managedByID[id] else { return }
        do {
            try access.focus(window.candidate.element, window.candidate.application)
        } catch let error as WindowAccessError where error.code == .invalidUIElement {
            guard let fresh = reresolve(window) else {
                report(error)
                return
            }
            managedByID[id]?.candidate = fresh
            onChange?()
            do {
                try access.focus(fresh.element, fresh.application)
            } catch {
                report(error)
            }
        } catch {
            report(error)
        }
    }

    func moveWindow(_ id: UUID, toCell destination: Int) {
        guard tabIDs.contains(id), cells.indices.contains(destination),
              [nil, activeGroupID].contains(groupID(containing: id))
        else { return }
        if let source = cellIndex(for: id) {
            guard source != destination else { return }
            cells.swapAt(source, destination)
            assignments = assignments.mapValues { cell in
                cell == source ? destination : cell == destination ? source : cell
            }
        } else {
            cells[destination] = id
        }
        assignments[id] = destination
        activeCell = destination
        if !pinnedCells.contains(destination) { lastUnpinnedCell = destination }
        clearPresentation()
        onChange?()
        presentVisibleWindows()
    }

    func reorderWindows(_ orderedIDs: [UUID]) {
        guard orderedIDs.count == tabIDs.count, Set(orderedIDs) == Set(tabIDs), orderedIDs != tabIDs
        else { return }
        tabIDs = orderedIDs
        onChange?()
    }

    /// Reorders the tab bar entries; each combined tab keeps its windows together.
    func reorderTabEntries(_ orderedEntries: [UUID]) {
        let entries = tabEntries
        guard orderedEntries.count == entries.count, Set(orderedEntries) == Set(entries) else { return }
        let normalized = orderedEntries.filter(isTabPinned) + orderedEntries.filter { !isTabPinned($0) }
        reorderWindows(normalized.flatMap { entry in
            paneGroups[entry] == nil ? [entry] : tabIDs.filter(groupMembers(entry).contains)
        })
    }

    func sortTabEntries(by key: (UUID) -> String) {
        let current = tabEntries
        let keyed = current.enumerated().map { index, id in (index: index, id: id, key: key(id)) }
        let ordered = keyed.sorted {
            let result = $0.key.localizedStandardCompare($1.key)
            return result == .orderedSame ? $0.index < $1.index : result == .orderedAscending
        }.map(\.id)
        if ordered != current { reorderTabEntries(ordered) }
    }

    @discardableResult
    func transferWindow(_ id: UUID, to destination: WindowSession, at insertionIndex: Int? = nil, cell: Int? = nil)
        -> Bool
    {
        let insertion = insertionIndex ?? destination.tabIDs.count
        // Without a pane, the tab joins the destination's normal panes rather than a combined tab.
        let destinationState = cell == nil ? destination.baseState ?? destination.livePaneState
            : destination.livePaneState
        let targetCell = cell ?? destinationState.activeCell
        guard self !== destination, let index = tabIDs.firstIndex(of: id),
              managedByID[id].map({ !destination.contains($0.candidate) }) ?? true,
              (0 ... destination.tabIDs.count).contains(insertion),
              destinationState.cells.indices.contains(targetCell)
        else {
            onMessage?(.attention(L("タブを移動できませんでした。移動先と対象ウィンドウを確認してください。")))
            return false
        }
        if pinnedTabIDs.remove(id) != nil { destination.pinnedTabIDs.insert(id) }
        if cell == nil { destination.switchPaneState(to: nil) }
        tabIDs.remove(at: index)
        destination.tabIDs.insert(id, at: insertion)
        destination.managedByID[id] = managedByID.removeValue(forKey: id)
        destination.minimumSizes[id] = minimumSizes.removeValue(forKey: id)
        if constraintWarningIDs.remove(id) != nil { destination.constraintWarningIDs.insert(id) }
        cancelConstraintRecovery(for: id)
        requestedFrames.removeValue(forKey: id)
        suspendedWindowIDs.remove(id)
        assignments.removeValue(forKey: id)
        pendingClosedIDs.remove(id)
        if !isSplit, cells[0] == id {
            cells[0] = replacementTab(near: index)
        }
        reconcilePanes()
        destination.cells[targetCell] = id
        destination.assignments[id] = targetCell
        destination.activeCell = targetCell
        if !destination.pinnedCells.contains(targetCell) {
            destination.lastUnpinnedCell = targetCell
        }
        destination.clearPresentation()
        if !pinnedTabIDs.isEmpty { reorderTabEntries(tabEntries) }
        if !destination.pinnedTabIDs.isEmpty { destination.reorderTabEntries(destination.tabEntries) }
        // Both ownership lists are updated before observers run; never restore the transferred window here.
        onChange?()
        destination.onChange?()
        presentVisibleWindows()
        destination.presentVisibleWindows()
        return true
    }

    /// Moves every window tab of `source` behind this session's tabs without changing what is shown here,
    /// except that empty panes take the first moved windows. Start pages stay behind. Returns how many windows moved.
    @discardableResult
    func absorbWindows(from source: WindowSession) -> Int {
        guard source !== self else { return 0 }
        let ids = source.tabIDs.filter { id in
            source.managedByID[id].map { !contains($0.candidate) } ?? false
        }
        guard !ids.isEmpty else { return 0 }
        var movedPinnedTabs = false
        switchPaneState(to: nil)
        for id in ids {
            if source.pinnedTabIDs.remove(id) != nil {
                pinnedTabIDs.insert(id)
                movedPinnedTabs = true
            }
            source.tabIDs.removeAll { $0 == id }
            tabIDs.append(id)
            managedByID[id] = source.managedByID.removeValue(forKey: id)
            minimumSizes[id] = source.minimumSizes.removeValue(forKey: id)
            if source.constraintWarningIDs.remove(id) != nil { constraintWarningIDs.insert(id) }
            source.cancelConstraintRecovery(for: id)
            source.requestedFrames.removeValue(forKey: id)
            source.suspendedWindowIDs.remove(id)
            source.assignments.removeValue(forKey: id)
            source.pendingClosedIDs.remove(id)
            let preferred = tabSwitchCell ?? activeCell
            let empty = cells.indices.contains(preferred) && cells[preferred] == nil
                ? preferred : cells.indices.first { cells[$0] == nil && !pinnedCells.contains($0) }
            if let empty { cells[empty] = id }
            assignments[id] = empty ?? preferred
        }
        source.reconcilePanes()
        clearPresentation()
        if movedPinnedTabs {
            source.reorderTabEntries(source.tabEntries)
            reorderTabEntries(tabEntries)
        }
        // Both ownership lists are updated before observers run; never restore a moved window here.
        source.onChange?()
        onChange?()
        presentVisibleWindows()
        return ids.count
    }

    private func presentVisibleWindows() {
        var errors: [Error] = []
        for window in visibleWindows {
            do {
                _ = try access.minimize(window.candidate.element, false)
            } catch {
                errors.append(error)
            }
        }
        synchronize(bringToFront: true)
        report(errors)
    }

    func cycle(_ offset: Int) {
        guard !paneGroups.isEmpty else {
            guard let cell = tabSwitchCell else { return }
            let candidates = tabIDs.filter { id in
                guard let index = cellIndex(for: id) else { return true }
                return index == cell
            }
            guard candidates.count > 1 else { return }
            let index = candidates.firstIndex { cellIndex(for: $0) == cell } ?? (offset > 0 ? -1 : 0)
            let next = ((index + offset) % candidates.count + candidates.count) % candidates.count
            select(candidates[next], inCell: cell, activate: true)
            return
        }
        let switchCell = tabSwitchCell
        let candidates = tabEntries.filter { entry in
            guard paneGroups[entry] == nil, activeGroupID == nil else { return true }
            guard let switchCell else { return false }
            return cellIndex(for: entry).map { $0 == switchCell } ?? true
        }
        guard candidates.count > 1 else { return }
        let current = activeGroupID ?? switchCell.flatMap { cells[$0] }
        let index = current.flatMap(candidates.firstIndex(of:)) ?? (offset > 0 ? -1 : 0)
        let next = ((index + offset) % candidates.count + candidates.count) % candidates.count
        select(candidates[next], activate: true)
    }

    func selectPreviousUsedTab() {
        guard canSelectPreviousUsedTab, let previousSelectedID else {
            self.previousSelectedID = nil
            return
        }
        select(previousSelectedID, activate: true)
    }

    func sync(showShortcutHint: Bool = true) {
        synchronize(bringToFront: false, showShortcutHint: showShortcutHint)
    }

    func sync(excluding id: UUID, showShortcutHint: Bool = true) {
        synchronize(bringToFront: false, raiseWindows: false, showShortcutHint: showShortcutHint, excluding: id)
    }

    /// Re-applies target frames and re-presents even if nothing appears to have changed.
    func realign(raiseWindows: Bool = true) {
        requestedFrames.removeAll()
        synchronize(bringToFront: false, raiseWindows: raiseWindows)
    }

    func alignedFrame(for id: UUID) -> CGRect? { alignedFrames[id] }

    /// Makes the next refit compare a shown window with its pane, e.g. one left out of syncing while it was resized.
    func expectPaneFrame(for id: UUID) {
        guard cells.contains(id), let target = currentTargets()[assignments[id] ?? 0] else { return }
        alignedFrames[id] = target
        requestedFrames.removeValue(forKey: id)
    }

    /// Puts windows that were moved, resized, maximized or minimized outside WindowDock back into their panes.
    func refitDisplacedWindows() {
        var displaced = false
        var errors: [Error] = []
        for window in windows where !suspendedWindowIDs.contains(window.id) {
            guard !access.isFullScreen(window.candidate.element) else {
                requestedFrames.removeValue(forKey: window.id)
                alignedFrames.removeValue(forKey: window.id)
                withdrawPresentation(of: window.id)
                continue
            }
            do {
                if try access.isMinimized(window.candidate.element) {
                    _ = try access.minimize(window.candidate.element, false)
                    requestedFrames.removeValue(forKey: window.id)
                    displaced = true
                }
                if let aligned = alignedFrames[window.id],
                   WindowGeometry.fits(try access.frame(window.candidate.element), requested: aligned, tolerance: 1)
                { continue }
                requestedFrames.removeValue(forKey: window.id)
                displaced = true
            } catch {
                errors.append(error)
            }
        }
        if displaced {
            synchronize(bringToFront: false, raiseWindows: false, showShortcutHint: false)
        }
        report(errors)
    }

    var hasFullScreenWindow: Bool {
        windows.contains { access.isFullScreen($0.candidate.element) }
    }

    /// Takes windows out of native full screen, where they can't be fitted into their panes.
    /// Returns whether any window was in full screen; leaving it animates, so fit the windows once it is done.
    func leaveFullScreen() -> Bool {
        var fullScreen = false
        var errors: [Error] = []
        for window in windows where access.isFullScreen(window.candidate.element) {
            fullScreen = true
            do {
                try access.setFullScreen(window.candidate.element, false)
            } catch {
                errors.append(error)
            }
        }
        report(errors)
        return fullScreen
    }

    func resume() {
        var errors: [Error] = []
        for window in windows where suspendedWindowIDs.contains(window.id) || cells.contains(window.id) {
            do {
                _ = try access.minimize(window.candidate.element, false)
                suspendedWindowIDs.remove(window.id)
                requestedFrames.removeValue(forKey: window.id)
            } catch {
                errors.append(error)
            }
        }
        synchronize(bringToFront: true)
        report(errors)
    }

    func raiseSelected(activate: Bool = false) {
        let order = presentationOrder.filter { !access.isFullScreen($0.candidate.element) }
        let selectingStartPage = selectedID.map(isStartPage) == true
        guard !activate || selectingStartPage else {
            // Front-window-only activation brings one window per call above other apps, so every visible
            // window takes its turn, ending with the selected one.
            for window in order { focus(window.id) }
            return
        }
        var errors: [Error] = []
        for window in order {
            do {
                try access.raise(window.candidate.element)
            } catch {
                errors.append(error)
            }
        }
        report(errors)
        if activate, selectingStartPage { onFocusStartPage?() }
    }

    private var presentationOrder: [ManagedWindow] {
        visibleWindows.filter { $0.id != selectedID } + visibleWindows.filter { $0.id == selectedID }
    }

    private func minimums(for assignments: [UUID: Int]) -> [Int: CGSize] {
        windows.reduce(into: [Int: CGSize]()) { result, window in
            guard let size = minimumSizes[window.id] else { return }
            let cell = assignments[window.id] ?? 0
            let previous = result[cell] ?? .zero
            result[cell] = CGSize(width: max(previous.width, size.width), height: max(previous.height, size.height))
        }
    }

    private func constraintAppNames(for ids: Set<UUID>) -> String? {
        var seen: Set<String> = []
        let names = windows.compactMap { window -> String? in
            guard ids.contains(window.id) else { return nil }
            let app = window.candidate.application
            guard let name = app.localizedName ?? app.bundleIdentifier ?? app.executableURL?.lastPathComponent,
                  !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
        return names.isEmpty ? nil : ListFormatter.localizedString(byJoining: names)
    }

    private func synchronize(
        bringToFront: Bool, raiseWindows: Bool = true, showShortcutHint: Bool = true, excluding: UUID? = nil) {
        guard !windows.isEmpty else { return }
        // A resize event (e.g. the zoom animation) can arrive while syncing; rerun afterwards so the final frame isn't lost.
        guard !isSynchronizing else {
            resyncRequested = true
            resyncExcluding = excluding
            return
        }
        isSynchronizing = true
        defer {
            isSynchronizing = false
            if resyncRequested {
                resyncRequested = false
                let excluding = resyncExcluding
                resyncExcluding = nil
                DispatchQueue.main.async { [weak self] in
                    self?.synchronize(bringToFront: false, excluding: excluding)
                }
            }
        }
        var retryingWindows: Set<UUID> = []
        var rejectedWindows: Set<UUID>?
        while true {
            let minima = minimums(for: assignments)
            if fitMinimumSizes?(minima) == false, isSplit {
                let blockers = paneLayout.minimumSizeBlockers(
                    in: currentTargets().values.reduce(.null) { $0.union($1) },
                    paneMinimums: minima, windowMinimums: minimumSizes, assignments: assignments,
                    sharedTracks: customLayout == nil ? (gridSize.columns, gridSize.rows) : nil)
                rejectedWindows = blockers.isEmpty ? retryingWindows : blockers
                collapseAfterConstraintFailure()
                continue
            }
            let targets = currentTargets()
            guard windows.allSatisfy({ targets[assignments[$0.id] ?? 0] != nil }) else {
                clearPresentation()
                onMessage?(.attention(L("分割表示の領域を取得できませんでした。")))
                return
            }
            let changed = windows.contains {
                $0.id != excluding && requestedFrames[$0.id] != targets[assignments[$0.id] ?? 0]
            }
            guard bringToFront || changed || !retryingWindows.isEmpty || rejectedWindows != nil else { return }
            var errors: [Error] = []
            var actualFrames: [UUID: CGRect] = [:]
            var mismatches: Set<UUID> = []
            let visibleIDs = Set(visibleWindows.map(\.id))
            let order = windows.filter { $0.id != excluding && !visibleIDs.contains($0.id) }
                + presentationOrder.filter { $0.id != excluding }
            for window in order {
                // Native full-screen windows live in another Space and cannot be fitted until they leave it.
                guard !access.isFullScreen(window.candidate.element) else {
                    requestedFrames.removeValue(forKey: window.id)
                    alignedFrames.removeValue(forKey: window.id)
                    continue
                }
                guard let requested = targets[assignments[window.id] ?? 0] else { continue }
                do {
                    try align(window, to: requested)
                    var actual = try access.frame(window.candidate.element)
                    // Apps animate resizes (e.g. un-maximizing); wait for them to settle before treating the size as a minimum.
                    // Expect a known minimum size so constrained windows don't stall every step of a workspace drag.
                    let expected =
                        minimumSizes[window.id].map {
                            CGRect(
                                origin: requested.origin,
                                size: CGSize(
                                    width: max(requested.width, $0.width), height: max(requested.height, $0.height)))
                        } ?? requested
                    var attempts = 0
                    while !fits(actual, requested: requested),
                          !fits(actual, requested: expected), attempts < 6
                    {
                        attempts += 1
                        Thread.sleep(forTimeInterval: 0.05)
                        actual = try access.frame(window.candidate.element)
                    }
                    actualFrames[window.id] = actual
                    if !fits(actual, requested: requested) {
                        mismatches.insert(window.id)
                        cancelConstraintRecovery(for: window.id)
                        var minimum = minimumSizes[window.id] ?? .zero
                        if actual.width > requested.width + Self.frameRoundingTolerance.width {
                            minimum.width = max(minimum.width, actual.width)
                        }
                        if actual.height > requested.height + Self.frameRoundingTolerance.height {
                            minimum.height = max(minimum.height, actual.height)
                        }
                        minimumSizes[window.id] = minimum
                        requestedFrames.removeValue(forKey: window.id)
                    }
                } catch {
                    cancelConstraintRecovery(for: window.id)
                    requestedFrames.removeValue(forKey: window.id)
                    errors.append(error)
                }
            }
            if let excluding, let leader = managedByID[excluding] {
                do {
                    actualFrames[excluding] = try access.frame(leader.candidate.element)
                } catch {
                    errors.append(error)
                }
            }
            alignedFrames.merge(actualFrames) { $1 }
            if isSplit, !mismatches.isEmpty {
                report(errors)
                if retryingWindows.isEmpty {
                    retryingWindows = mismatches
                } else {
                    rejectedWindows = mismatches
                    collapseAfterConstraintFailure()
                }
                continue
            }
            var frames: [UUID: CGRect] = [:]
            for window in presentationOrder {
                guard let actual = actualFrames[window.id] else { continue }
                if raiseWindows {
                    do {
                        try access.raise(window.candidate.element)
                    } catch {
                        errors.append(error)
                        continue
                    }
                }
                frames[window.id] = actual
            }
            presentedFrames = frames
            onPresentedFrame?(selectedID.flatMap { frames[$0] })
            onPresentedFrames?(frames)
            constraintWarningIDs.formUnion(mismatches)
            for id in actualFrames.keys where constraintWarningIDs.contains(id) {
                scheduleConstraintRecovery(for: id, fitted: !mismatches.contains(id))
            }
            if let rejectedWindows {
                let apps = constraintAppNames(for: rejectedWindows) ?? L("対象アプリ")
                onMessage?(.attention(L("%@のウィンドウがペインに収まらないため、分割を解除して1×1表示に戻しました。", apps)))
            } else if let selectedID, constraintWarningIDs.contains(selectedID) {
                let app = constraintAppNames(for: [selectedID]) ?? L("対象アプリ")
                onMessage?(.attention(L("%@のウィンドウがペインの大きさや位置に合わず、完全には収まりません。", app)))
            } else if showShortcutHint, errors.isEmpty, !frames.isEmpty {
                onMessage?(.information(L("⌃ Tab / ⌃ ⇧ Tab でタブを切替")))
            }
            report(errors)
            return
        }
    }

    private func currentTargets() -> [Int: CGRect] {
        if let targetFrames { return targetFrames() }
        var frames: [Int: CGRect] = [:]
        frames[0] = targetFrame?()
        if isSplit { frames[1] = secondaryTargetFrame?() }
        return frames
    }

    private func collapseAfterConstraintFailure() {
        configureGrid(.single)
        requestedFrames.removeAll()
        clearPresentation()
        onChange?()
    }

    private func align(_ window: ManagedWindow, to frame: CGRect) throws {
        let actual = try access.frame(window.candidate.element)
        if actual == frame {
            requestedFrames[window.id] = frame
            return
        }
        // A busy app can keep showing its previous frame, or the new size at its previous position, for a while. It can
        // also apply a request whose Accessibility call timed out, so record the request before making it.
        recordFrameRequest(actual, for: window.id)
        recordFrameRequest(frame, for: window.id)
        if actual.size != frame.size {
            try access.setFrame(window.candidate.element, frame)
        } else {
            try access.setPosition(window.candidate.element, frame.origin)
        }
        requestedFrames[window.id] = frame
    }

    private func recordFrameRequest(_ frame: CGRect, for id: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        recentFrameRequests = recentFrameRequests.compactMapValues { requests in
            let recent = requests.filter { now - $0.time < Self.lateFrameRequestInterval }
            return recent.isEmpty ? nil : recent
        }
        recentFrameRequests[id, default: []].append((frame, now))
    }

    /// Whether a window shows a frame it had or WindowDock requested a moment ago, which a busy app reported late, rather
    /// than a move or resize by the user. Position and size are compared separately, as they can be set separately.
    func isLateFrameRequest(_ frame: CGRect, for id: UUID) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let requests = (recentFrameRequests[id] ?? []).filter { now - $0.time < Self.lateFrameRequestInterval }
        return requests.contains {
            abs(frame.minX - $0.frame.minX) <= Self.framePositionTolerance
                && abs(frame.minY - $0.frame.minY) <= Self.framePositionTolerance
        } && requests.contains {
            abs(frame.width - $0.frame.width) <= Self.frameRoundingTolerance.width
                && abs(frame.height - $0.frame.height) <= Self.frameRoundingTolerance.height
        }
    }

    private func fits(_ actual: CGRect, requested: CGRect) -> Bool {
        abs(actual.minX - requested.minX) <= Self.framePositionTolerance
            && abs(actual.minY - requested.minY) <= Self.framePositionTolerance
            && abs(actual.width - requested.width) <= Self.frameRoundingTolerance.width
            && abs(actual.height - requested.height) <= Self.frameRoundingTolerance.height
    }

    private func cancelConstraintRecovery(for id: UUID) {
        constraintRecoveryTimers.removeValue(forKey: id)?.timer.invalidate()
    }

    private func scheduleConstraintRecovery(for id: UUID, fitted: Bool) {
        if constraintRecoveryTimers[id]?.fitted == fitted { return }
        cancelConstraintRecovery(for: id)
        let timer = Timer(timeInterval: Self.constraintRecoveryDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.confirmConstraintRecovery(for: id, wasFitted: fitted)
            }
        }
        constraintRecoveryTimers[id] = (timer, fitted)
        RunLoop.main.add(timer, forMode: .common)
    }

    private func confirmConstraintRecovery(for id: UUID, wasFitted: Bool) {
        constraintRecoveryTimers.removeValue(forKey: id)
        guard constraintWarningIDs.contains(id),
              let window = windows.first(where: { $0.id == id }),
              let target = currentTargets()[assignments[id] ?? 0]
        else { return }
        do {
            guard fits(try access.frame(window.candidate.element), requested: target) else {
                requestedFrames.removeValue(forKey: id)
                scheduleConstraintRecovery(for: id, fitted: false)
                return
            }
            guard wasFitted else {
                scheduleConstraintRecovery(for: id, fitted: true)
                return
            }
            constraintWarningIDs.remove(id)
            if selectedID == id {
                let app = constraintAppNames(for: [id]) ?? L("対象アプリ")
                onConstraintWarningCleared?(
                    L("%@のウィンドウがペインの大きさや位置に合わず、完全には収まりません。", app))
            }
        } catch {
            requestedFrames.removeValue(forKey: id)
            report(error)
        }
    }

    private func clearPresentation() {
        if let selectedID { requestedFrames.removeValue(forKey: selectedID) }
        presentedFrames = [:]
        onPresentedFrame?(nil)
        onPresentedFrames?([:])
    }

    /// Swaps what a pane shows while the other panes keep showing through, so they don't flash the workspace background.
    private func replacePresentation(of displaced: UUID?, with id: UUID) {
        requestedFrames.removeValue(forKey: id)
        if let displaced, displaced != id { withdrawPresentation(of: displaced) }
    }

    /// Stops showing a window through the workspace before it leaves its pane, while the other panes stay shown.
    private func withdrawPresentation(of id: UUID) {
        guard presentedFrames.removeValue(forKey: id) != nil else { return }
        onPresentedFrame?(selectedID.flatMap { presentedFrames[$0] })
        onPresentedFrames?(presentedFrames)
    }

    func suspend() {
        var errors: [Error] = []
        for window in windows {
            do {
                if try access.minimize(window.candidate.element, true) {
                    suspendedWindowIDs.insert(window.id)
                }
            } catch {
                errors.append(error)
            }
        }
        clearPresentation()
        report(errors)
    }

    @discardableResult
    func remove(_ id: UUID) -> Bool {
        remove(id, closeWindow: closesWindowsOnRelease)
    }

    @discardableResult
    func remove(_ id: UUID, closeWindow: Bool) -> Bool {
        if paneGroups[id] != nil {
            return groupMembers(id).reduce(true) { remove($1, closeWindow: closeWindow) && $0 }
        }
        guard let index = tabIDs.firstIndex(of: id) else { return true }
        if let window = managedByID[id], closeWindow {
            let number = access.windowID(window.candidate.element) ?? kCGNullWindowID
            do {
                try access.close(window.candidate.element)
            } catch {
                // A timeout can mean the press was delivered, e.g. while an app opens a modal save dialog.
                if (error as? WindowAccessError)?.code == .cannotComplete { managedByID[id]?.closingWindowID = number }
                report(error)
                return false
            }
            managedByID[id]?.closingWindowID = number
            // A successful AX press isn't proof of closure: the owner may ask to save or veto closing.
            guard window.candidate.application.isTerminated || access.probe(window.candidate.element)
                .error == .invalidUIElement
            else { return true }
        } else if let window = managedByID[id] {
            // Stop showing the window through its pane before moving it back to its original frame.
            withdrawPresentation(of: id)
            do {
                try window.restore(using: access)
            } catch {
                report(error)
                synchronize(bringToFront: true)
                return false
            }
        }
        managedByID.removeValue(forKey: id)
        tabIDs.remove(at: index)
        pinnedTabIDs.remove(id)
        if previousSelectedID == id { previousSelectedID = nil }
        if !isSplit, cells[0] == id {
            cells[0] = replacementTab(near: index)
        }
        requestedFrames.removeValue(forKey: id)
        suspendedWindowIDs.remove(id)
        assignments.removeValue(forKey: id)
        minimumSizes.removeValue(forKey: id)
        constraintWarningIDs.remove(id)
        cancelConstraintRecovery(for: id)
        reconcilePanes()
        onChange?()
        presentVisibleWindows()
        return true
    }

    private var pendingClosedIDs: Set<UUID> = []

    /// Whether another workspace manages a window; such a window must never be taken over.
    var isClaimedElsewhere: (WindowCandidate) -> Bool = { _ in false }

    private func reresolve(_ window: ManagedWindow) -> WindowCandidate? {
        let stale = window.candidate
        guard let live = access.applicationWindows(stale.application) else { return nil }
        if let number = window.closingWindowID {
            guard number != kCGNullWindowID else { return nil }
            return live.first {
                access.windowID($0.element) == number && !contains($0) && !isClaimedElsewhere($0)
            }
        }
        return WindowAccess.reresolve(stale, among: live) { candidate in
            contains(candidate) || isClaimedElsewhere(candidate)
        }
    }

    func pruneClosedWindows() {
        var closedIDs: Set<UUID> = []
        var listedByPID: [pid_t: [AXUIElement]] = [:]
        var titleChanged = false
        for window in windows {
            if window.candidate.application.isTerminated {
                closedIDs.insert(window.id)
                continue
            }
            let probe = access.probe(window.candidate.element)
            // Some apps keep the AX element alive after removing the window from their window list.
            if let number = window.closingWindowID, [.success, .noValue, .attributeUnsupported].contains(probe.error) {
                let app = window.candidate.application
                if listedByPID[app.processIdentifier] == nil {
                    listedByPID[app.processIdentifier] = access.windowElements(app)
                }
                if let listed = listedByPID[app.processIdentifier],
                   !listed.contains(where: { CFEqual($0, window.candidate.element) }),
                   number == kCGNullWindowID || !listed.contains(where: { access.windowID($0) == number })
                {
                    closedIDs.insert(window.id)
                }
            }
            if let title = probe.title, window.candidate.title != title {
                managedByID[window.id]?.candidate.title = title
                titleChanged = true
            }
            // A busy app still owns its window; only a stale element is looked up again.
            if probe.error == .invalidUIElement {
                if let fresh = reresolve(window) {
                    titleChanged = titleChanged || window.candidate.title != fresh.title
                    managedByID[window.id]?.candidate = fresh
                    WindowAccess.logger.notice("prune re-resolved \(fresh.label, privacy: .public)")
                } else {
                    closedIDs.insert(window.id)
                }
            }
        }
        // Require two consecutive misses so a transient AX failure doesn't drop tabs.
        let confirmed = closedIDs.intersection(pendingClosedIDs)
        pendingClosedIDs = closedIDs.subtracting(confirmed)
        guard !confirmed.isEmpty else {
            if titleChanged { onChange?() }
            return
        }
        WindowAccess.logger.notice("prune removing \(confirmed.count) windows")
        let ids = confirmed
        for id in ids { managedByID.removeValue(forKey: id) }
        tabIDs.removeAll { ids.contains($0) }
        pinnedTabIDs.subtract(ids)
        requestedFrames = requestedFrames.filter { !ids.contains($0.key) }
        suspendedWindowIDs.subtract(ids)
        assignments = assignments.filter { !ids.contains($0.key) }
        minimumSizes = minimumSizes.filter { !ids.contains($0.key) }
        constraintWarningIDs.subtract(ids)
        for id in ids { cancelConstraintRecovery(for: id) }
        reconcilePanes()
        onChange?()
        presentVisibleWindows()
    }

    private func reconcilePanes() {
        let ids = Set(tabIDs)
        func scrub(_ state: inout PaneState) {
            state.cells = state.cells.map { $0.flatMap { ids.contains($0) ? $0 : nil } }
            state.assignments = state.assignments.filter { ids.contains($0.key) }
        }
        for (group, var state) in paneGroups where group != activeGroupID {
            scrub(&state)
            paneGroups[group] = state.cells.contains { $0 != nil } ? state : nil
        }
        if var base = baseState {
            let vacated = base.cells.indices.filter { base.cells[$0].map(ids.contains) == false }
            scrub(&base)
            let loose = looseTabIDs
            for index in vacated {
                base.cells[index] = loose.first { !base.cells.contains($0) }
                if let id = base.cells[index] { base.assignments[id] = index }
            }
            baseState = base
        }
        var vacated: [Int] = []
        for index in cells.indices {
            if let id = cells[index], !ids.contains(id) {
                cells[index] = nil
                vacated.append(index)
            }
        }
        if let activeGroupID, !cells.contains(where: { $0 != nil }) {
            // The combined tab lost its last tab; show the normal panes again.
            paneGroups[activeGroupID] = nil
            self.activeGroupID = nil
            applyPaneState(excludingGroupedTabs(from: baseState ?? livePaneState))
            baseState = nil
            vacated = []
        }
        if activeGroupID == nil {
            let loose = looseTabIDs
            for index in vacated {
                cells[index] = loose.first { !cells.contains($0) }
            }
        }
        for index in cells.indices {
            if let id = cells[index] { assignments[id] = index }
        }
        if activeGroupID == nil, looseTabIDs.count <= 1, customLayout == nil { configureGrid(.single) }
        clearPresentation()
    }

    func restoreAll() -> [String] {
        var failures: [String] = []
        for window in windows {
            do {
                try window.restore(using: access)
            } catch {
                WindowAccess.logger.error("\(error.localizedDescription, privacy: .public)")
                failures.append("\(window.candidate.label): \(error.localizedDescription)")
            }
        }
        return failures
    }

    private func report(_ error: Error) {
        report([error])
    }

    private func report(_ errors: [Error]) {
        var shown: [String] = []
        for error in errors {
            // A stale element means the window closed or was recreated; pruning drops or re-resolves it, so don't alarm.
            if (error as? WindowAccessError)?.code == .invalidUIElement {
                WindowAccess.logger.debug("\(error.localizedDescription, privacy: .public)")
            } else {
                WindowAccess.logger.error("\(error.localizedDescription, privacy: .public)")
                shown.append(error.localizedDescription)
            }
        }
        guard !shown.isEmpty else { return }
        onMessage?(.attention(shown.joined(separator: " / ")))
    }
}
