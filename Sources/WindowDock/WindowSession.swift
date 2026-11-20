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
    private(set) var gridSize = WorkspaceGridSize.single
    private(set) var cells: [UUID?] = [nil]
    private(set) var activeCell = 0
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
    private var isSynchronizing = false
    private var resyncRequested = false

    init(access: WindowAccessClient = WindowAccessClient()) {
        self.access = access
    }

    var selectedID: UUID? { cells[activeCell] }
    var primaryID: UUID? { cells.first ?? nil }
    var secondaryID: UUID? { cells.count > 1 ? cells[1] : nil }
    var splitLayout: WorkspaceSplitLayout { gridSize.columns == 1 ? .stacked : .sideBySide }
    var selected: ManagedWindow? { windows.first { $0.id == selectedID } }
    var isSplit: Bool { gridSize.cellCount > 1 }
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
        guard size != gridSize else { return }
        configureGrid(size)
        clearPresentation()
        onChange?()
        presentVisibleWindows()
    }

    private func configureGrid(_ size: WorkspaceGridSize) {
        let result = GridReflow.reflow(
            oldColumns: gridSize.columns,
            oldCells: cells,
            activeCell: activeCell,
            newColumns: size.columns,
            newRows: size.rows,
            windowIDs: windows.map(\.id),
            assignments: assignments)
        cells = result.cells
        activeCell = result.activeCell
        assignments = result.assignments
        gridSize = size
    }

    func cellIndex(for id: UUID) -> Int? { cells.firstIndex { $0 == id } }

    func activateCell(_ index: Int) {
        guard cells.indices.contains(index), index != activeCell else { return }
        activeCell = index
        onChange?()
    }

    func focusVisibleWindow(_ id: UUID) {
        if let index = cellIndex(for: id) { activateCell(index) }
    }

    func contains(_ candidate: WindowCandidate) -> Bool {
        windows.contains { $0.candidate.isSameWindow(as: candidate) }
    }

    func add(_ candidate: WindowCandidate, originalFrame: CGRect? = nil) {
        add([candidate], originalFrame: originalFrame)
    }

    func add(_ candidates: [WindowCandidate]) {
        add(candidates, originalFrame: nil)
    }

    private func add(_ candidates: [WindowCandidate], originalFrame: CGRect?) {
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
        defer {
            if activate { focus(id) }
        }
        if let index = cellIndex(for: id) {
            activeCell = index
        } else {
            cells[activeCell] = id
            assignments[id] = activeCell
        }
        clearPresentation()
        presentVisibleWindows()
        onChange?()
    }

    /// Focuses a window; if its AX element went stale, re-resolves it once and retries.
    private func focus(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        do {
            try access.focus(windows[index].candidate.element, windows[index].candidate.application)
        } catch {
            WindowAccess.logger.error("\(error.localizedDescription, privacy: .public)")
            guard let fresh = WindowAccess.reresolve(windows[index].candidate, excluding: windows.map(\.candidate)) else { return }
            windows[index].candidate = fresh
            do {
                try access.focus(fresh.element, fresh.application)
            } catch {
                WindowAccess.logger.error("\(error.localizedDescription, privacy: .public)")
            }
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
        clearPresentation()
        onChange?()
        presentVisibleWindows()
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
        guard !windows.isEmpty else { return }
        let index = windows.firstIndex { $0.id == selectedID } ?? (offset > 0 ? -1 : 0)
        let next = ((index + offset) % windows.count + windows.count) % windows.count
        select(windows[next].id, activate: true)
    }

    func sync() {
        synchronize(bringToFront: false)
    }

    /// Re-applies target frames and re-presents even if nothing appears to have changed.
    func realign() {
        requestedFrames.removeAll()
        synchronize(bringToFront: false)
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

    func raiseSelected() {
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
            let minima = windows.reduce(into: [Int: CGSize]()) { result, window in
                guard let size = minimumSizes[window.id] else { return }
                let cell = assignments[window.id] ?? 0
                let previous = result[cell] ?? .zero
                result[cell] = CGSize(width: max(previous.width, size.width), height: max(previous.height, size.height))
            }
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
                    var attempts = 0
                    while !WindowGeometry.fits(actual, requested: requested, tolerance: 1), attempts < 6 {
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
            onPresentedFrame?(selectedID.flatMap { frames[$0] })
            onPresentedFrames?(frames)
            if rejectedGrid {
                onMessage?(.attention(L("対象アプリの最小サイズ・位置制約により分割が収まらないため、1×1表示に戻しました。枠を広げるか分割数を減らしてください。")))
            } else if !mismatches.isEmpty {
                onMessage?(.attention(L("対象アプリのサイズ・位置の制約により、枠内に完全には収まりません。枠を広げてください。")))
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
        onPresentedFrame?(nil)
        onPresentedFrames?([:])
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
        do {
            try windows[index].restore(using: access)
        } catch {
            report(error)
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
        reconcilePanes()
        onChange?()
        presentVisibleWindows()
        return true
    }

    private var pendingClosedIDs: Set<UUID> = []

    func pruneClosedWindows() {
        var invalidIDs: Set<UUID> = []
        var closed = windows.filter { window in
            if window.candidate.application.isTerminated { return true }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(window.candidate.element, kAXRoleAttribute as CFString, &value)
            let failed = ![.success, .noValue, .attributeUnsupported].contains(error)
            if error == .invalidUIElement { invalidIDs.insert(window.id) }
            return failed
        }
        for window in closed {
            guard let index = windows.firstIndex(where: { $0.id == window.id }),
                  !window.candidate.application.isTerminated,
                  let fresh = WindowAccess.reresolve(window.candidate, excluding: windows.map(\.candidate)) else { continue }
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
        guard !confirmed.isEmpty else { return }
        WindowAccess.logger.notice("prune removing \(confirmed.count) windows")
        let ids = confirmed
        windows.removeAll { ids.contains($0.id) }
        requestedFrames = requestedFrames.filter { !ids.contains($0.key) }
        suspendedWindowIDs.subtract(ids)
        assignments = assignments.filter { !ids.contains($0.key) }
        minimumSizes = minimumSizes.filter { !ids.contains($0.key) }
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
        if windows.count <= 1 { configureGrid(.single) }
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
