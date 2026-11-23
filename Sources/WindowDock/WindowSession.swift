import AppKit
import WindowDockCore

struct ManagedWindow {
    let id = UUID()
    var candidate: WindowCandidate
    let originalFrame: CGRect
    let originallyMinimized: Bool

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

@MainActor
final class WindowSession {
    private(set) var windows: [ManagedWindow] = []
    // The last regular-grid preset; customLayout takes precedence when present.
    private(set) var gridSize = WorkspaceGridSize.single
    private(set) var customLayout: PaneLayout?
    private(set) var cells: [UUID?] = [nil]
    private(set) var activeCell = 0
    private(set) var pinnedCells: Set<Int> = []
    private var lastUnpinnedCell = 0
    var onChange: (() -> Void)?
    var onMessage: ((WorkspaceNotice) -> Void)?
    var onPresentedFrame: ((CGRect?) -> Void)?
    var onPresentedFrames: (([UUID: CGRect]) -> Void)?
    var targetFrame: (() -> CGRect?)?
    var secondaryTargetFrame: (() -> CGRect?)?
    var targetFrames: (() -> [Int: CGRect])?
    var fitMinimumSizes: (([Int: CGSize]) -> Bool)?
    private let access: WindowAccessClient
    private var requestedFrames: [UUID: CGRect] = [:]
    private var suspendedWindowIDs: Set<UUID> = []
    private var assignments: [UUID: Int] = [:]
    private var minimumSizes: [UUID: CGSize] = [:]
    private var constraintWarningIDs: Set<UUID> = []
    /// The frames last passed to `onPresentedFrames`, which the workspace shows through.
    private var presentedFrames: [UUID: CGRect] = [:]
    /// The frames windows had once they were last aligned, to notice when they are moved, resized or maximized outside WindowDock.
    private var alignedFrames: [UUID: CGRect] = [:]
    private var isSynchronizing = false
    private var resyncRequested = false

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
        customLayout ?? .grid(
            columnWeights: Array(repeating: 1, count: gridSize.columns),
            rowWeights: Array(repeating: 1, count: gridSize.rows)
        )
    }
    var visibleWindows: [ManagedWindow] {
        windows.filter { cells.contains($0.id) }
    }

    func setSplit(_ enabled: Bool, layout: WorkspaceSplitLayout = .sideBySide) {
        setGrid(enabled
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
            windowIDs: windows.map(\.id),
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
            windowIDs: windows.map(\.id), assignments: assignments
        )
        pinnedCells = Set(pinnedCells.filter { $0 < layout.paneCount })
        applyPaneLayout(layout, reflow: result)
    }

    func canSplitPane(at index: Int, axis: PaneLayout.Axis, currentLayout: PaneLayout? = nil) -> Bool {
        plannedPaneSplit(at: index, axis: axis, currentLayout: currentLayout) != nil
    }

    private func plannedPaneSplit(
        at index: Int, axis: PaneLayout.Axis, currentLayout: PaneLayout?
    ) -> (layout: PaneLayout, reflow: GridReflowResult<UUID>)? {
        let layout = currentLayout ?? paneLayout
        guard layout.isValid, layout.paneCount == cells.count,
              let split = layout.splittingPane(at: index, axis: axis),
              let result = PaneReflow.split(cells: cells, activeCell: activeCell, at: index,
                                            windowIDs: windows.map(\.id), assignments: assignments) else { return nil }
        if !minimumSizes.isEmpty {
            let bounds = currentTargets().values.reduce(CGRect.null) { $0.union($1) }
            guard !bounds.isNull,
                  let minimum = split.minimumSize(minimums(for: result.assignments), dividerThickness: PaneLayout.dividerThickness),
                  minimum.width <= bounds.width, minimum.height <= bounds.height else { return nil }
        }
        return (split, result)
    }

    func splitPane(at index: Int, axis: PaneLayout.Axis, currentLayout: PaneLayout? = nil) {
        guard let plan = plannedPaneSplit(at: index, axis: axis, currentLayout: currentLayout) else {
            onMessage?(.attention(L("ペインの配置を変更できませんでした。")))
            return
        }
        pinnedCells = Set(pinnedCells.map { $0 > index ? $0 + 1 : $0 })
        if lastUnpinnedCell > index { lastUnpinnedCell += 1 }
        applyPaneLayout(plan.layout, reflow: plan.reflow)
    }

    func closePane(at index: Int, currentLayout: PaneLayout? = nil) {
        let layout = currentLayout ?? paneLayout
        guard layout.isValid, layout.paneCount == cells.count,
              let removal = layout.removingPane(at: index),
              let result = PaneReflow.close(cells: cells, activeCell: activeCell, at: index,
                                            destination: removal.destination, assignments: assignments) else {
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

    func contains(_ candidate: WindowCandidate) -> Bool {
        windows.contains { $0.candidate.isSameWindow(as: candidate) }
    }

    func add(_ candidate: WindowCandidate, originalFrame: CGRect? = nil, at insertionIndex: Int? = nil) {
        if let insertionIndex, !(0...windows.count).contains(insertionIndex) {
            onMessage?(.attention(L("タブを移動できませんでした。移動先と対象ウィンドウを確認してください。")))
            return
        }
        add([candidate], originalFrame: originalFrame, at: insertionIndex)
    }

    func add(_ candidates: [WindowCandidate]) {
        add(candidates, originalFrame: nil)
    }

    private func add(_ candidates: [WindowCandidate], originalFrame: CGRect?, at insertionIndex: Int? = nil) {
        var added: [ManagedWindow] = []
        var errors: [Error] = []
        for candidate in candidates where !contains(candidate) {
            do {
                for attribute in [kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute] {
                    try access.requireWritable(candidate.element, attribute)
                }
                let window = ManagedWindow(
                    candidate: candidate,
                    originalFrame: try originalFrame ?? access.frame(candidate.element),
                    originallyMinimized: try access.isMinimized(candidate.element)
                )
                windows.append(window)
                added.append(window)
                assignments[window.id] = activeCell
            } catch {
                errors.append(error)
            }
        }
        if let insertionIndex, let window = added.first {
            windows.removeAll { $0.id == window.id }
            windows.insert(window, at: insertionIndex)
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
        guard windows.contains(where: { $0.id == id }) else { return }
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
        if activate { focus(id) }
        presentVisibleWindows()
        onChange?()
    }

    private func select(_ id: UUID, inCell cell: Int, activate: Bool) {
        guard windows.contains(where: { $0.id == id }), cells.indices.contains(cell),
              !pinnedCells.contains(cell), cellIndex(for: id) == nil || cellIndex(for: id) == cell else { return }
        let displaced = cells[cell]
        cells[cell] = id
        assignments[id] = cell
        activeCell = cell
        lastUnpinnedCell = cell
        replacePresentation(of: displaced, with: id)
        if activate { focus(id) }
        presentVisibleWindows()
        onChange?()
    }

    /// Focuses a window; if its AX element went stale, re-resolves it once and retries.
    private func focus(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        do {
            try access.focus(windows[index].candidate.element, windows[index].candidate.application)
        } catch let error as WindowAccessError where error.code == .invalidUIElement {
            guard let fresh = reresolve(windows[index].candidate) else {
                report(error)
                return
            }
            windows[index].candidate = fresh
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
        guard windows.contains(where: { $0.id == id }), cells.indices.contains(destination) else { return }
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
        let currentIDs = Set(windows.map(\.id))
        guard orderedIDs.count == windows.count,
              Set(orderedIDs).count == windows.count,
              Set(orderedIDs) == currentIDs else { return }
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let reordered = orderedIDs.compactMap { windowsByID[$0] }
        guard reordered.map(\.id) != windows.map(\.id) else { return }
        windows = reordered
        onChange?()
    }

    @discardableResult
    func transferWindow(_ id: UUID, to destination: WindowSession, at insertionIndex: Int? = nil, cell: Int? = nil) -> Bool {
        let insertion = insertionIndex ?? destination.windows.count
        let targetCell = cell ?? destination.activeCell
        guard self !== destination, let index = windows.firstIndex(where: { $0.id == id }),
              !destination.contains(windows[index].candidate),
              (0...destination.windows.count).contains(insertion),
              destination.cells.indices.contains(targetCell) else {
            onMessage?(.attention(L("タブを移動できませんでした。移動先と対象ウィンドウを確認してください。")))
            return false
        }
        let window = windows.remove(at: index)
        destination.windows.insert(window, at: insertion)
        destination.minimumSizes[id] = minimumSizes.removeValue(forKey: id)
        if constraintWarningIDs.remove(id) != nil { destination.constraintWarningIDs.insert(id) }
        requestedFrames.removeValue(forKey: id)
        suspendedWindowIDs.remove(id)
        assignments.removeValue(forKey: id)
        pendingClosedIDs.remove(id)
        if !isSplit, cells[0] == id {
            cells[0] = windows.isEmpty ? nil : windows[min(index, windows.count - 1)].id
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
        let candidates = windows.filter { window in
            guard let index = cellIndex(for: window.id) else { return true }
            return index == cell
        }
        guard candidates.count > 1 else { return }
        let index = candidates.firstIndex { cellIndex(for: $0.id) == cell } ?? (offset > 0 ? -1 : 0)
        let next = ((index + offset) % candidates.count + candidates.count) % candidates.count
        select(candidates[next].id, inCell: cell, activate: true)
    }

    func sync() {
        synchronize(bringToFront: false)
    }

    /// Re-applies target frames and re-presents even if nothing appears to have changed.
    func realign() {
        requestedFrames.removeAll()
        synchronize(bringToFront: false)
    }

    /// Puts windows that were moved, resized or maximized outside WindowDock back into their panes.
    func refitDisplacedWindows() {
        var displaced = false
        for window in windows {
            guard let aligned = alignedFrames[window.id],
                  let actual = try? access.frame(window.candidate.element),
                  !WindowGeometry.fits(actual, requested: aligned, tolerance: 1) else { continue }
            requestedFrames.removeValue(forKey: window.id)
            displaced = true
        }
        if displaced { synchronize(bringToFront: false) }
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
        guard !activate else {
            // Front-window-only activation brings one window per call above other apps, so every visible
            // window takes its turn, ending with the selected one.
            for window in presentationOrder { focus(window.id) }
            return
        }
        var errors: [Error] = []
        for window in presentationOrder {
            do {
                try access.raise(window.candidate.element)
            } catch {
                errors.append(error)
            }
        }
        report(errors)
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

    private func synchronize(bringToFront: Bool) {
        guard !windows.isEmpty else { return }
        // A resize event (e.g. the zoom animation) can arrive while syncing; rerun afterwards so the final frame isn't lost.
        guard !isSynchronizing else {
            resyncRequested = true
            return
        }
        isSynchronizing = true
        defer {
            isSynchronizing = false
            if resyncRequested {
                resyncRequested = false
                DispatchQueue.main.async { [weak self] in self?.synchronize(bringToFront: false) }
            }
        }
        var correction = 0
        var rejectedGrid = false
        while true {
            let minima = minimums(for: assignments)
            if fitMinimumSizes?(minima) == false, isSplit {
                collapseAfterConstraintFailure()
                rejectedGrid = true
                correction = 0
                continue
            }
            let targets = currentTargets()
            guard windows.allSatisfy({ targets[assignments[$0.id] ?? 0] != nil }) else {
                clearPresentation()
                onMessage?(.attention(L("分割表示の領域を取得できませんでした。")))
                return
            }
            let changed = windows.contains { requestedFrames[$0.id] != targets[assignments[$0.id] ?? 0] }
            guard bringToFront || changed || correction > 0 || rejectedGrid else { return }
            var errors: [Error] = []
            var actualFrames: [UUID: CGRect] = [:]
            var mismatches: Set<UUID> = []
            let visibleIDs = Set(visibleWindows.map(\.id))
            let order = windows.filter { !visibleIDs.contains($0.id) } + presentationOrder
            for window in order {
                guard let requested = targets[assignments[window.id] ?? 0] else { continue }
                do {
                    try align(window, to: requested)
                    var actual = try access.frame(window.candidate.element)
                    // Apps animate resizes (e.g. un-maximizing); wait for them to settle before treating the size as a minimum.
                    // Expect a known minimum size so constrained windows don't stall every step of a workspace drag.
                    let expected = minimumSizes[window.id].map {
                        CGRect(origin: requested.origin, size: CGSize(
                            width: max(requested.width, $0.width), height: max(requested.height, $0.height)
                        ))
                    } ?? requested
                    var attempts = 0
                    while !WindowGeometry.fits(actual, requested: requested, tolerance: 1),
                          !WindowGeometry.fits(actual, requested: expected, tolerance: 1), attempts < 6 {
                        attempts += 1
                        Thread.sleep(forTimeInterval: 0.05)
                        actual = try access.frame(window.candidate.element)
                    }
                    actualFrames[window.id] = actual
                    if !requested.insetBy(dx: -1, dy: -1).contains(actual) {
                        mismatches.insert(window.id)
                        var minimum = minimumSizes[window.id] ?? .zero
                        if actual.width > requested.width + 1 { minimum.width = max(minimum.width, actual.width) }
                        if actual.height > requested.height + 1 { minimum.height = max(minimum.height, actual.height) }
                        minimumSizes[window.id] = minimum
                        requestedFrames.removeValue(forKey: window.id)
                    }
                } catch {
                    requestedFrames.removeValue(forKey: window.id)
                    errors.append(error)
                }
            }
            alignedFrames.merge(actualFrames) { $1 }
            if isSplit, !mismatches.isEmpty {
                report(errors)
                if correction == 0 {
                    correction += 1
                } else {
                    collapseAfterConstraintFailure()
                    rejectedGrid = true
                    correction = 0
                }
                continue
            }
            var frames: [UUID: CGRect] = [:]
            for window in presentationOrder {
                guard let actual = actualFrames[window.id] else { continue }
                do {
                    try access.raise(window.candidate.element)
                    frames[window.id] = actual
                } catch {
                    errors.append(error)
                }
            }
            presentedFrames = frames
            onPresentedFrame?(selectedID.flatMap { frames[$0] })
            onPresentedFrames?(frames)
            constraintWarningIDs.formUnion(mismatches)
            if rejectedGrid {
                onMessage?(.attention(L("対象アプリの最小サイズ・位置制約により分割が収まらないため、1×1表示に戻しました。")))
            } else if selectedID.map({ constraintWarningIDs.contains($0) }) == true {
                onMessage?(.attention(L("対象アプリのサイズ・位置の制約により、枠内に完全には収まりません。")))
            } else if !frames.isEmpty {
                onMessage?(.information(L("⌃ Tab / ⌃ ⇧ Tab で切替 · タブの × で元に戻す")))
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
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return true }
        // Restoring moves the window out of its pane; until the pane is closed, it would show what is behind the workspace.
        withdrawPresentation(of: id)
        do {
            try windows[index].restore(using: access)
        } catch {
            report(error)
            synchronize(bringToFront: true)
            return false
        }
        windows.remove(at: index)
        if !isSplit, cells[0] == id {
            cells[0] = windows.isEmpty ? nil : windows[min(index, windows.count - 1)].id
        }
        requestedFrames.removeValue(forKey: id)
        suspendedWindowIDs.remove(id)
        assignments.removeValue(forKey: id)
        minimumSizes.removeValue(forKey: id)
        constraintWarningIDs.remove(id)
        reconcilePanes()
        onChange?()
        presentVisibleWindows()
        return true
    }

    private var pendingClosedIDs: Set<UUID> = []

    /// Whether another workspace manages a window; such a window must never be taken over.
    var isClaimedElsewhere: (WindowCandidate) -> Bool = { _ in false }

    private func reresolve(_ stale: WindowCandidate) -> WindowCandidate? {
        guard let live = access.applicationWindows(stale.application) else { return nil }
        return WindowAccess.reresolve(stale, among: live) { candidate in
            contains(candidate) || isClaimedElsewhere(candidate)
        }
    }

    func pruneClosedWindows() {
        var invalidIDs: Set<UUID> = []
        var closed: [ManagedWindow] = []
        var titleChanged = false
        for index in windows.indices {
            let window = windows[index]
            if window.candidate.application.isTerminated {
                closed.append(window)
                continue
            }
            let probe = access.probe(window.candidate.element)
            if let title = probe.title, windows[index].candidate.title != title {
                windows[index].candidate.title = title
                titleChanged = true
            }
            if probe.error == .invalidUIElement { invalidIDs.insert(window.id) }
            if ![.success, .noValue, .attributeUnsupported].contains(probe.error) {
                closed.append(window)
            }
        }
        // A busy app (e.g. a timed-out Electron window) still owns its element; only a stale element is looked up again.
        for window in closed where invalidIDs.contains(window.id) {
            guard let index = windows.firstIndex(where: { $0.id == window.id }),
                  !window.candidate.application.isTerminated,
                  let fresh = reresolve(window.candidate) else { continue }
            titleChanged = titleChanged || windows[index].candidate.title != fresh.title
            windows[index].candidate = fresh
            WindowAccess.logger.notice("prune re-resolved \(fresh.label, privacy: .public)")
            closed.removeAll { $0.id == window.id }
        }
        let closedIDs = Set(closed.map(\.id)).filter { id in
            invalidIDs.contains(id) || windows.first { $0.id == id }?.candidate.application.isTerminated == true
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
        windows.removeAll { ids.contains($0.id) }
        requestedFrames = requestedFrames.filter { !ids.contains($0.key) }
        suspendedWindowIDs.subtract(ids)
        assignments = assignments.filter { !ids.contains($0.key) }
        minimumSizes = minimumSizes.filter { !ids.contains($0.key) }
        constraintWarningIDs.subtract(ids)
        reconcilePanes()
        onChange?()
        presentVisibleWindows()
    }

    private func reconcilePanes() {
        let ids = Set(windows.map(\.id))
        for index in cells.indices {
            if let id = cells[index], !ids.contains(id) {
                cells[index] = nil
                cells[index] = windows.first(where: { !cells.contains($0.id) })?.id
            }
            if let id = cells[index] { assignments[id] = index }
        }
        if windows.count <= 1, customLayout == nil { configureGrid(.single) }
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
