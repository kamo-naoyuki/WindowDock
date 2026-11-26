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

@MainActor
final class WindowSession {
    private static let frameRoundingTolerance = CGSize(width: 12, height: 20)
    private static let framePositionTolerance: CGFloat = 1
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
    var tabSwitchCell: Int? {
        guard !cells.isEmpty else { return nil }
        if cells.indices.contains(lastUnpinnedCell), !pinnedCells.contains(lastUnpinnedCell) {
            return lastUnpinnedCell
        }
        return cells.indices.first { !pinnedCells.contains($0) }
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
        normalizePaneSwitchState()
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
            assignments: assignments)
        cells = result.cells
        activeCell = result.activeCell
        assignments = result.assignments
        gridSize = size
        customLayout = nil
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
            windowIDs: tabIDs, assignments: assignments)
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
                  windowIDs: tabIDs, assignments: assignments)
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
    }

    func updatePaneProportions(_ layout: PaneLayout) {
        guard customLayout != nil, layout.isValid, layout.paneCount == cells.count else {
            onMessage?(.attention(L("ペインの配置を変更できませんでした。")))
            return
        }
        customLayout = layout
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
        activeCell = index
        if !pinnedCells.contains(index) { lastUnpinnedCell = index }
        onChange?()
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

    func focusVisibleWindow(_ id: UUID) {
        if let index = cellIndex(for: id) { activateCell(index) }
    }

    func observeFocusedWindow(_ element: AXUIElement) {
        guard let window = windows.first(where: { CFEqual($0.candidate.element, element) }) else { return }
        // A running app can briefly focus its old window before the requested new one appears.
        guard !pendingWindowLaunches.values.contains(where: {
            $0.pid == window.candidate.application.processIdentifier && cells.contains($0.page)
        }) else { return }
        let id = window.id
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
        let instances = (bundleID.map(NSRunningApplication.runningApplications(withBundleIdentifier:))
            ?? NSWorkspace.shared.runningApplications).filter { !$0.isTerminated }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let matchingURL = instances.first { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == canonical }
        // Launch Services can resolve another path to the same live instance. Don't reopen it and focus its old tab.
        if let app = matchingURL ?? (bundleID == nil ? nil : instances.first) {
            return try await launchCandidates(for: app, from: page, alreadyRunning: true)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        return try await launchCandidates(for: app, from: page, alreadyRunning: false)
    }

    func launchCandidates(for app: NSRunningApplication, from page: UUID,
                          alreadyRunning: Bool) async throws -> [WindowCandidate] {
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
            try await access.requestNewWindow(app)
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
        let empty = cells.indices.contains(preferred) && cells[preferred] == nil
            ? preferred : cells.indices.first { cells[$0] == nil && !pinnedCells.contains($0) }
        if let empty {
            cells[empty] = window.id
            assignments[window.id] = empty
            onChange?()
            synchronize(bringToFront: false, raiseWindows: false, showShortcutHint: false)
            return window.id
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
        if let last = added.last { select(last.id) }
        report(errors)
    }

    func select(_ id: UUID, activate: Bool = false) {
        guard tabIDs.contains(id) else { return }
        var displaced: UUID?
        if let index = cellIndex(for: id) {
            activeCell = index
            if !pinnedCells.contains(index) { lastUnpinnedCell = index }
        } else {
            guard let cell = tabSwitchCell else {
                onChange?()
                return
            }
            displaced = cells[cell]
            cells[cell] = id
            assignments[id] = cell
            activeCell = cell
            lastUnpinnedCell = cell
        }
        replacePresentation(of: displaced, with: id)
        onChange?()
        if activate, managedByID[id] != nil { focus(id) }
        presentVisibleWindows()
        if activate, isStartPage(id) { onFocusStartPage?() }
    }

    private func select(_ id: UUID, inCell cell: Int, activate: Bool) {
        guard tabIDs.contains(id), cells.indices.contains(cell),
              !pinnedCells.contains(cell), cellIndex(for: id) == nil || cellIndex(for: id) == cell
        else { return }
        let displaced = cells[cell]
        cells[cell] = id
        assignments[id] = cell
        activeCell = cell
        lastUnpinnedCell = cell
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
        guard tabIDs.contains(id), cells.indices.contains(destination) else { return }
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

    @discardableResult
    func transferWindow(_ id: UUID, to destination: WindowSession, at insertionIndex: Int? = nil, cell: Int? = nil)
        -> Bool
    {
        let insertion = insertionIndex ?? destination.tabIDs.count
        let targetCell = cell ?? destination.activeCell
        guard self !== destination, let index = tabIDs.firstIndex(of: id),
              managedByID[id].map({ !destination.contains($0.candidate) }) ?? true,
              (0 ... destination.tabIDs.count).contains(insertion),
              destination.cells.indices.contains(targetCell)
        else {
            onMessage?(.attention(L("タブを移動できませんでした。移動先と対象ウィンドウを確認してください。")))
            return false
        }
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
            cells[0] = tabIDs.isEmpty ? nil : tabIDs[min(index, tabIDs.count - 1)]
        }
        reconcilePanes()
        destination.cells[targetCell] = id
        destination.assignments[id] = targetCell
        destination.activeCell = targetCell
        if !destination.pinnedCells.contains(targetCell) {
            destination.lastUnpinnedCell = targetCell
        }
        destination.clearPresentation()
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
        for id in ids {
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
        guard let cell = tabSwitchCell else { return }
        let candidates = tabIDs.filter { id in
            guard let index = cellIndex(for: id) else { return true }
            return index == cell
        }
        guard candidates.count > 1 else { return }
        let index = candidates.firstIndex { cellIndex(for: $0) == cell } ?? (offset > 0 ? -1 : 0)
        let next = ((index + offset) % candidates.count + candidates.count) % candidates.count
        select(candidates[next], inCell: cell, activate: true)
    }

    func sync() {
        synchronize(bringToFront: false)
    }

    func sync(excluding id: UUID) {
        synchronize(bringToFront: false, raiseWindows: false, excluding: id)
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
            } else if showShortcutHint, !frames.isEmpty {
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
        if actual.size != frame.size {
            try access.setFrame(window.candidate.element, frame)
        } else {
            try access.setPosition(window.candidate.element, frame.origin)
        }
        requestedFrames[window.id] = frame
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
        if !isSplit, cells[0] == id {
            cells[0] = tabIDs.isEmpty ? nil : tabIDs[min(index, tabIDs.count - 1)]
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
        for index in cells.indices {
            if let id = cells[index], !ids.contains(id) {
                cells[index] = nil
                cells[index] = tabIDs.first(where: { !cells.contains($0) })
            }
            if let id = cells[index] { assignments[id] = index }
        }
        if tabIDs.count <= 1, customLayout == nil { configureGrid(.single) }
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
        guard !errors.isEmpty else { return }
        for error in errors {
            WindowAccess.logger.error("\(error.localizedDescription, privacy: .public)")
        }
        onMessage?(.attention(errors.map(\.localizedDescription).joined(separator: " / ")))
    }
}
