import AppKit
import WindowDockCore

@MainActor
enum WindowSessionSmoke {
    private enum Operation: Equatable {
        case resize(Int)
        case move(Int)
        case minimize(Int, Bool)
        case raise(Int)
    }

    private struct InjectedFailure: LocalizedError {
        var errorDescription: String? { "Injected window operation failure" }
    }

    private final class WindowState {
        let element: AXUIElement
        let originalFrame: CGRect
        let originallyMinimized: Bool
        var frame: CGRect
        var minimized: Bool
        var minimumSize = CGSize.zero
        var sizeIncrement = CGSize.zero
        /// In native full screen, the window ignores frame changes.
        var fullScreen = false

        init(index: Int) {
            // These handles only identify simulated windows; the client intercepts every operation.
            element = AXUIElementCreateApplication(pid_t(900_000 + index))
            originalFrame = CGRect(x: 40 + index * 20, y: 80, width: 500, height: 400)
            originallyMinimized = index == 2
            frame = originalFrame
            minimized = originallyMinimized
        }
    }

    private final class Model {
        let windows: [WindowState]
        var target = CGRect(x: 200, y: 160, width: 900, height: 600)
        var operations: [Operation] = []
        var onMove: (() -> Void)?
        /// Called before a window's frame is set, with its index and the new frame.
        var onSetFrame: ((Int, CGRect) -> Void)?
        var failedMoves: Set<Int> = []
        var failedMinimizations: Set<Int> = []
        var failedRegistrations: Set<Int> = []
        var failedFocuses: Set<Int> = []
        var closeRequests: [Int] = []
        var onClose: ((Int) throws -> Void)?
        var focusedWindows: [Int] = []
        /// Windows asked to leave full screen, by index.
        var fullScreenExits: [Int] = []
        var probeErrors: [Int: AXError] = [:]
        var titles: [Int: String] = [:]
        /// The windows that their app lists, by index.
        var listedWindows: [Int] = []
        var changeCount = 0
        var notices: [WorkspaceNotice] = []
        var presentedFrames: [CGRect?] = []
        var paneFrames: [UUID: CGRect] = [:]
        var rightTarget = CGRect(x: 650, y: 160, width: 450, height: 600)
        var gridTargets: [Int: CGRect]?

        init(windowCount: Int = 4) {
            windows = (0 ..< windowCount).map(WindowState.init)
        }

        func index(of element: AXUIElement) throws -> Int {
            guard let index = windows.firstIndex(where: { CFEqual($0.element, element) }) else {
                throw InjectedFailure()
            }
            return index
        }
    }

    private static func access(for model: Model) -> WindowAccessClient {
        var access = WindowAccessClient()
        access.requireWritable = { element, _ in
            let index = try model.index(of: element)
            if model.failedRegistrations.contains(index) { throw InjectedFailure() }
        }
        access.frame = { element in model.windows[try model.index(of: element)].frame }
        access.isMinimized = { element in model.windows[try model.index(of: element)].minimized }
        access.setFrame = { element, frame in
            let index = try model.index(of: element)
            model.onSetFrame?(index, frame)
            model.operations.append(.resize(index))
            guard !model.windows[index].fullScreen else { return }
            model.windows[index].frame = frame
            model.windows[index].frame.size.width = max(frame.width, model.windows[index].minimumSize.width)
            model.windows[index].frame.size.height = max(frame.height, model.windows[index].minimumSize.height)
            let increment = model.windows[index].sizeIncrement
            if increment.width > 0 {
                model.windows[index].frame.size.width =
                    ceil(model.windows[index].frame.width / increment.width) * increment.width
            }
            if increment.height > 0 {
                model.windows[index].frame.size.height =
                    ceil(model.windows[index].frame.height / increment.height) * increment.height
            }
        }
        access.setPosition = { element, position in
            let index = try model.index(of: element)
            model.onMove?()
            if model.failedMoves.contains(index) { throw InjectedFailure() }
            model.operations.append(.move(index))
            guard !model.windows[index].fullScreen else { return }
            model.windows[index].frame.origin = position
        }
        access.isFullScreen = { element in
            (try? model.index(of: element)).map { model.windows[$0].fullScreen } ?? false
        }
        // Leaving full screen animates; a check ends it by clearing `fullScreen`.
        access.setFullScreen = { element, fullScreen in
            let index = try model.index(of: element)
            if !fullScreen { model.fullScreenExits.append(index) }
        }
        access.minimize = { element, minimized in
            let index = try model.index(of: element)
            if model.failedMinimizations.contains(index) { throw InjectedFailure() }
            guard model.windows[index].minimized != minimized else { return false }
            model.operations.append(.minimize(index, minimized))
            model.windows[index].minimized = minimized
            return true
        }
        access.raise = { element in model.operations.append(.raise(try model.index(of: element))) }
        access.close = { element in
            let index = try model.index(of: element)
            model.closeRequests.append(index)
            try model.onClose?(index)
        }
        access.windowID = { element in (try? model.index(of: element)).map { CGWindowID($0 + 1) } }
        access.windowElements = { _ in model.listedWindows.map { model.windows[$0].element } }
        access.focus = { element, _ in
            let index = try model.index(of: element)
            if model.failedFocuses.contains(index) { throw InjectedFailure() }
            model.focusedWindows.append(index)
        }
        access.probe = { element in
            guard let index = try? model.index(of: element) else {
                return WindowProbeResult(error: .invalidUIElement, title: nil)
            }
            let error = model.probeErrors[index] ?? .success
            let title =
                [.success, .noValue, .attributeUnsupported].contains(error)
                    ? model.titles[index] ?? "Test \(index)"
                    : nil
            return WindowProbeResult(error: error, title: title)
        }
        access.applicationWindows = { _ in
            model.listedWindows.map {
                WindowCandidate(element: model.windows[$0].element, application: .current, title: "Live \($0)")
            }
        }
        return access
    }

    private static func fixture(
        registering indexes: [Int] = [0, 1, 2], windowCount: Int = 4,
        sharedModel: Model? = nil) -> (WindowSession, Model) {
        let model = sharedModel ?? Model(windowCount: windowCount)
        let session = WindowSession(access: access(for: model))
        session.targetFrame = { model.target }
        session.secondaryTargetFrame = { model.rightTarget }
        session.targetFrames = { model.gridTargets ?? [0: model.target, 1: model.rightTarget] }
        session.onMessage = { model.notices.append($0) }
        session.onConstraintWarningCleared = { text in
            if model.notices.last?.text == text { model.notices.append(.information("Recovered")) }
        }
        session.onPresentedFrame = { model.presentedFrames.append($0) }
        session.onPresentedFrames = { model.paneFrames = $0 }
        session.onChange = { model.changeCount += 1 }
        for index in indexes {
            session.add(
                WindowCandidate(
                    element: model.windows[index].element,
                    application: .current,
                    title: "Test \(index)"))
        }
        model.operations.removeAll()
        model.changeCount = 0
        return (session, model)
    }

    static func runNestedPaneChecks() -> [String] {
        var failures: [String] = []
        let (session, model) = fixture(registering: [0, 1, 2, 3])
        session.targetFrames = { [weak session] in
            guard let frames = session?.paneLayout.geometry(in: model.target)?.panes else { return [:] }
            return Dictionary(uniqueKeysWithValues: frames.enumerated().map { ($0.offset, $0.element) })
        }
        let ids = session.windows.map(\.id)
        session.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        session.moveWindow(ids[0], toCell: 0)
        session.moveWindow(ids[1], toCell: 1)
        let leftFrame = model.windows[0].frame
        session.splitPane(at: 1, axis: .vertical)
        if session.cells != [ids[0], ids[1], ids[2]] || session.selectedID != ids[1] || session.windows.map(\.id) != ids
            || model.windows[0].frame != leftFrame
        {
            failures.append("splitting the right pane changed the left pane, selection, or registered tabs")
        }
        session.closePane(at: 1)
        if session.cells != [ids[0], ids[2]] || session.selectedID != ids[2] || session.windows.map(\.id) != ids
            || model.windows[1].frame == model.windows[1].originalFrame
        {
            failures.append("closing a nested pane released its tab or failed to retain the sibling and other panes")
        }
        session.splitPane(at: 0, axis: .vertical)
        if session.cells != [ids[0], ids[1], ids[2]] || session.activeCell != 2 {
            failures.append("splitting before the active pane did not reindex it or reuse a hidden tab")
        }
        let (destination, _) = fixture(registering: [], sharedModel: model)
        destination.splitPane(at: 0, axis: .vertical)
        if !session.transferWindow(ids[3], to: destination, cell: 1) || destination.cells != [nil, ids[3]]
            || destination.customLayout == nil || session.cells != [ids[0], ids[1], ids[2]]
        {
            failures.append("transferring a hidden tab to a nested pane changed the other visible panes")
        }
        session.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        if session.customLayout != nil || session.cells.count != 2 || session.selectedID != ids[2]
            || session.windows.map(\.id) != [ids[0], ids[1], ids[2]]
        {
            failures.append("returning to the same grid preset lost the selected tab or kept the custom tree")
        }
        let (empty, _) = fixture(registering: [], sharedModel: model)
        empty.splitPane(at: 0, axis: .horizontal)
        empty.splitPane(at: 1, axis: .vertical)
        empty.targetFrames = { [weak empty] in
            guard let frames = empty?.paneLayout.geometry(in: model.target)?.panes else { return [:] }
            return Dictionary(uniqueKeysWithValues: frames.enumerated().map { ($0.offset, $0.element) })
        }
        empty.add(WindowCandidate(element: model.windows[0].element, application: .current, title: "Empty panes"))
        guard let added = empty.selectedID else { return failures + ["adding a window to a nested layout failed"] }
        if empty.cells.count != 3 || !empty.remove(added) || empty.cells != [nil, nil, nil] || empty.customLayout == nil
        {
            failures.append("adding or releasing the only window collapsed intentionally empty nested panes")
        }
        let before = session.cells
        model.notices.removeAll()
        session.splitPane(at: 99, axis: .horizontal)
        if session.cells != before || model.notices.last?.needsAttention != true {
            failures.append("an invalid pane split mutated the session or failed without a notice")
        }
        return failures
    }

    static func runPanePinChecks() -> [String] {
        var failures: [String] = []
        let (session, _) = fixture(registering: Array(0 ..< 5), windowCount: 5)
        session.setGrid(WorkspaceGridSize(columns: 3, rows: 1))
        func nextTab(in cell: Int) -> UUID? {
            let candidates = session.windows.filter { window in
                guard let index = session.cellIndex(for: window.id) else { return true }
                return index == cell
            }
            guard candidates.count > 1 else { return nil }
            let current = candidates.firstIndex { session.cellIndex(for: $0.id) == cell } ?? -1
            return candidates[(current + 1) % candidates.count].id
        }
        let pinnedWindow = session.cells[0]
        let otherWindow = session.cells[1]
        let firstCycleTarget = nextTab(in: 2)
        session.activateCell(2)
        session.setPanePinned(true, at: 0)
        session.activateCell(0)
        session.cycle(1)
        if session.cells[0] != pinnedWindow || session.cells[1] != otherWindow || session.cells[2] != firstCycleTarget
            || session.activeCell != 2 || session.tabSwitchCell != 2
        {
            failures.append("cycling from a pinned pane did not replace the last unpinned pane")
        }

        let secondCycleTarget = nextTab(in: 1)
        session.setPanePinned(true, at: 2)
        session.cycle(1)
        if session.cells[0] != pinnedWindow || session.cells[1] != secondCycleTarget || session.pinnedCells != [0, 2] {
            failures.append("cycling with three panes changed a pinned pane or failed to choose an unpinned target")
        }
        session.setPanePinned(true, at: 1)
        let allPinned = session.cells
        session.cycle(1)
        if session.cells != allPinned || session.tabSwitchCell != nil {
            failures.append("cycling changed a pane when every pane was pinned")
        }

        let (flash, _) = fixture(registering: [0, 1, 2])
        flash.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        flash.setPanePinned(true, at: 0)
        guard let flashPinned = flash.cells[0],
              let hiddenTab = flash.windows.first(where: { flash.cellIndex(for: $0.id) == nil })
        else {
            return failures + ["the pinned-pane flash fixture had no hidden tab"]
        }
        var emissions: [[UUID: CGRect]] = []
        let previousHandler = flash.onPresentedFrames
        flash.onPresentedFrames = { frames in
            emissions.append(frames)
            previousHandler?(frames)
        }
        flash.select(hiddenTab.id)
        if emissions.contains(where: { $0[flashPinned] == nil }) {
            failures.append("selecting a tab briefly stopped showing the pinned pane")
        }

        let (reflow, _) = fixture(registering: [0, 1])
        reflow.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        reflow.setPanePinned(true, at: 1)
        reflow.splitPane(at: 0, axis: .vertical)
        if reflow.pinnedCells != [2] {
            failures.append("splitting before a pinned pane did not remap its index")
        }
        reflow.closePane(at: 0)
        if reflow.pinnedCells != [1] {
            failures.append("closing a pane before a pinned pane did not remap its index")
        }
        return failures
    }

    /// A combined tab keeps its own panes: selecting it shows them, any other tab brings back the normal panes, which
    /// change independently, and ungrouping keeps what is shown.
    static func runPaneGroupChecks() -> [String] {
        var failures: [String] = []
        let (session, model) = fixture(registering: [0, 1, 2, 3])
        let ids = session.windows.map(\.id)
        let halves = WorkspaceGridSize(columns: 2, rows: 1)
        let single = WorkspaceGridSize(columns: 1, rows: 1)
        session.setGrid(halves)
        session.moveWindow(ids[0], toCell: 0)
        session.moveWindow(ids[1], toCell: 1)
        guard session.cells == [ids[0], ids[1]], let group = session.combineVisiblePanes() else {
            return ["the combined tab fixture could not combine two shown panes"]
        }
        let groupFrames = [model.windows[0].frame, model.windows[1].frame]
        if session.tabEntries != [group, ids[2], ids[3]] || session.groupMembers(group) != [ids[0], ids[1]]
            || session.activeGroupID != group || session.cells != [ids[0], ids[1]] || session.canCombineVisiblePanes
        {
            failures.append("combining the shown panes did not make one tab that shows them")
        }
        if session.basePaneState.gridSize != single || session.basePaneState.customLayout != nil
            || session.basePaneState.cells != [ids[2]] || !session.basePaneState.pinnedCells.isEmpty
        {
            failures.append("combining did not return the normal panes to one pane showing the next tab")
        }
        session.select(ids[3])
        if session.activeGroupID != nil || session.gridSize != single || session.cells != [ids[3]] {
            failures.append("selecting another tab after combining did not show it in one pane")
        }
        session.setGrid(halves)
        session.select(group)
        session.moveWindow(ids[3], toCell: 1)
        if session.groupMembers(group) != [ids[0], ids[3]] || session.tabEntries != [group, ids[1], ids[2]] {
            failures.append("moving a tab into a combined tab's pane did not swap it into the combined tab")
        }
        session.select(ids[2])
        if Set(session.cells.compactMap { $0 }) != [ids[1], ids[2]] {
            failures.append("the normal panes still showed a window that moved into the combined tab")
        }
        session.select(group)
        session.moveWindow(ids[1], toCell: 1)
        session.select(ids[2])
        if session.activeGroupID != nil || session.gridSize != halves || session.selectedID != ids[2]
            || Set(session.cells.compactMap { $0 }) != [ids[2], ids[3]]
        {
            failures.append("selecting another tab did not return to the normal panes")
        }
        session.setGrid(single)
        session.select(group)
        if session.activeGroupID != group || session.gridSize != halves || session.cells != [ids[0], ids[1]]
            || [model.windows[0].frame, model.windows[1].frame] != groupFrames
        {
            failures.append("selecting the combined tab did not bring back its panes and window frames")
        }
        session.select(ids[3])
        if session.activeGroupID != nil || session.gridSize != single || session.cells != [ids[3]] {
            failures.append("changing the normal panes changed the combined tab, or returning to them lost the change")
        }
        session.cycle(1)
        let cycledToGroup = session.activeGroupID == group && session.cells == [ids[0], ids[1]]
        session.cycle(1)
        if !cycledToGroup || session.activeGroupID != nil || session.cells != [ids[2]] {
            failures.append("Control+Tab did not step through the combined tab like any other tab")
        }

        session.select(group)
        model.operations.removeAll()
        session.ungroup(group)
        if session.activeGroupID != nil || session.isPaneGroup(group) || session.tabEntries != ids
            || session.cells != [ids[0], ids[1]] || session.gridSize != halves || !model.operations.isEmpty
        {
            failures.append("ungrouping the shown combined tab changed what was shown or kept the combined tab")
        }
        session.select(ids[2])
        if session.gridSize != halves || !session.cells.contains(ids[2]) {
            failures.append("ungrouping did not keep its panes as the normal panes")
        }

        session.moveWindow(ids[0], toCell: 0)
        session.moveWindow(ids[1], toCell: 1)
        guard let regrouped = session.combineVisiblePanes() else {
            return failures + ["the combined tab fixture could not combine the panes again"]
        }
        session.select(ids[3])
        if !session.remove(ids[1], closeWindow: false) || session.groupMembers(regrouped) != [ids[0]]
            || session.tabEntries != [regrouped, ids[2], ids[3]] || model.windows[1].frame != model.windows[1]
            .originalFrame
        {
            failures.append("releasing a combined tab's hidden window did not leave the rest of the combined tab")
        }
        if !session.remove(regrouped, closeWindow: false) || session.isPaneGroup(regrouped)
            || session.windows.map(\.id) != [ids[2], ids[3]] || model.windows[0].frame != model.windows[0].originalFrame
        {
            failures.append("releasing a combined tab did not release all of its windows")
        }

        let (restored, _) = fixture(registering: [0, 1, 2, 3])
        let restoredIDs = restored.windows.map(\.id)
        restored.restorePaneGroups([
            PaneState(
                gridSize: halves, customLayout: nil, cells: [restoredIDs[1], restoredIDs[0]], activeCell: 1,
                pinnedCells: [], lastUnpinnedCell: 1, assignments: [:]),
            // Windows already in a combined tab cannot join another one.
            PaneState(
                gridSize: halves, customLayout: nil, cells: [restoredIDs[0], nil], activeCell: 0,
                pinnedCells: [], lastUnpinnedCell: 0, assignments: [:]),
        ])
        guard let restoredGroup = restored.tabEntries.first(where: restored.isPaneGroup) else {
            return failures + ["restoring a combined tab did not create it"]
        }
        if restored.activeGroupID != nil || restored.tabEntries.count != 3
            || restored.groupMembers(restoredGroup) != [restoredIDs[1], restoredIDs[0]]
            || restored.cells.contains(restoredIDs[0]) || restored.cells.contains(restoredIDs[1])
        {
            failures.append("restoring a combined tab showed its windows in the normal panes or duplicated a window")
        }
        restored.select(restoredGroup)
        if restored.cells != [restoredIDs[1], restoredIDs[0]] || restored.selectedID != restoredIDs[0] {
            failures.append("a restored combined tab did not show its saved panes")
        }
        return failures
    }

    /// The combine button, the combined tab's title and context menu, and saving and restoring combined tabs.
    static func runPaneGroupUIChecks() -> [String] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return ["combined tab fixture needs the Dock for an application with a bundle identifier"]
        }
        var failures: [String] = []
        let model = Model(windowCount: 4)
        let restoredModel = Model(windowCount: 4)
        let controller = WorkspaceController(name: "Combined tabs", access: access(for: model))
        let restored = WorkspaceController(name: "Restored combined tabs", access: access(for: restoredModel))
        defer {
            for controller in [controller, restored] {
                controller.quitting = true
                controller.window.orderOut(nil)
            }
        }
        guard let chrome = controller.window.contentView as? WorkspaceChromeView else {
            return ["combined tab fixture could not find its chrome"]
        }
        let window = controller.window
        window.setFrame(NSRect(x: 120, y: 140, width: 900, height: 600), display: false)
        func candidates(_ model: Model) -> [WindowCandidate] {
            model.windows.indices.map {
                WindowCandidate(element: model.windows[$0].element, application: dock, title: "Pane \($0)")
            }
        }
        func tabButtons() -> [NSButton] {
            chrome.layoutSubtreeIfNeeded()
            return chrome.tabs.arrangedSubviews.compactMap {
                ($0 as? WorkspaceTabGroup)?.arrangedSubviews.first as? NSButton
            }.sorted { $0.tag < $1.tag }
        }
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func combineItem() -> NSMenuItem? {
            let menu = controller.activePaneMenu()
            menu.update()
            return menu.item(withTitle: L("表示中のペインを1つのタブにまとめる"))
        }
        controller.session.add(candidates(model))
        chrome.layoutSubtreeIfNeeded()
        if chrome.combineButton.isEnabled || combineItem()?.isEnabled != false {
            failures.append("combining was available with a single pane")
        }
        let halves = WorkspaceGridSize(columns: 2, rows: 1)
        let single = WorkspaceGridSize(columns: 1, rows: 1)
        let ids = controller.session.windows.map(\.id)
        controller.session.setGrid(halves)
        controller.session.moveWindow(ids[0], toCell: 0)
        controller.session.moveWindow(ids[1], toCell: 1)
        guard chrome.combineButton.isEnabled, combineItem()?.isEnabled == true,
              let action = chrome.combineButton.action,
              NSApp.sendAction(action, to: chrome.combineButton.target, from: chrome.combineButton),
              let group = controller.session.activeGroupID
        else { return failures + ["the combine button could not combine two shown panes"] }
        if tabButtons().map(\.title) != ["Pane 0|Pane 1", "Pane 2", "Pane 3"] {
            failures.append("the combined tab was not one tab titled after its windows: \(tabButtons().map(\.title))")
        }
        if tabButtons().first?.image != nil
            || (tabButtons().first?.cell as? WorkspaceTabButtonCell)?.combinedWindows
            .map({ $0.icon != nil }) != [true, true]
        {
            failures.append("the combined tab had its own icon instead of one icon per window")
        }
        chrome.showsTabIconsOnly = true
        if let iconTab = tabButtons().first,
           iconTab.image?.isTemplate != false || !iconTab.title.isEmpty || iconTab
           .accessibilityLabel() != "Pane 0|Pane 1"
           || (iconTab.cell as? WorkspaceTabButtonCell)?.combinedWindows.isEmpty != true
        {
            failures.append("an icon-only combined tab did not show its windows' icons under its windows' names")
        }
        chrome.showsTabIconsOnly = false
        if !chrome.combineButton.isEnabled || !chrome.combineButtonUngroups
            || chrome.combineButton.accessibilityLabel() != L("タブのまとめを解除") || combineItem()?.isEnabled != false
        {
            failures.append("the combine button did not turn into ungrouping while a combined tab was shown")
        }

        // Save while the combined tab is shown, with different normal panes.
        controller.session.select(ids[2])
        controller.session.setGrid(single)
        controller.session.select(group)
        do {
            let saved = try JSONDecoder().decode(
                SavedWorkspace.self, from: JSONEncoder().encode(controller.savedWorkspace()))
            if saved.windows.map(\.title) != ["Pane 0", "Pane 1", "Pane 2", "Pane 3"]
                || saved.columns != 1 || saved.rows != 1
                || saved.paneGroups != [
                    SavedPaneGroup(columns: 2, rows: 1, cells: [0, 1], activeCell: 1, pinnedPanes: []),
                ]
            {
                failures.append("saving did not keep the normal panes and the combined tab apart: \(saved)")
            }
            let available = candidates(restoredModel)
            restored.restoreLayout(saved)
            let matches = SavedLayout.matches(saved.windows, among: available) { element in
                restoredModel.windows[try restoredModel.index(of: element)].frame
            }
            restored.session.add(available)
            restored.restorePaneGroups(saved, windows: available, matches: matches)
            let restoredIDs = restored.session.windows.map(\.id)
            let restoredGroup = restored.session.tabEntries.first(where: restored.session.isPaneGroup)
            if restored.session.tabEntries.count != 3 || restored.session.gridSize != single
                || restoredGroup.map(restored.session.groupMembers) != [restoredIDs[0], restoredIDs[1]]
            {
                failures.append("restoring did not recreate the combined tab next to the normal panes")
            }
        } catch {
            failures.append("combined tab persistence failed: \(error)")
        }

        chrome.onReorderTabs?([1, 0, 2])
        if controller.session.tabEntries != [ids[2], group, ids[3]]
            || controller.session.windows.map(\.id) != [ids[2], ids[0], ids[1], ids[3]]
        {
            failures.append("reordering the tab bar split up the combined tab's windows")
        }

        guard let groupTab = tabButtons().first(where: { $0.title.contains(CombinedTabTitle.separator) }) else {
            return failures + ["the combined tab disappeared"]
        }
        let menu = groupTab.menu(for: event(.rightMouseDown))
        menu?.update()
        guard let ungroup = menu?.item(withTitle: L("タブのまとめを解除")), ungroup.isEnabled,
              menu?.item(withTitle: L("ペイン")) == nil
        else { return failures + ["the combined tab's context menu had no ungroup item, or had pane items"] }
        guard let ungroupAction = ungroup.action, NSApp.sendAction(ungroupAction, to: ungroup.target, from: ungroup)
        else { return failures + ["the combined tab's ungroup item could not be chosen"] }
        if controller.session.isPaneGroup(group) || controller.session.cells != [ids[0], ids[1]]
            || tabButtons().count != 4 || combineItem()?.isEnabled != true
        {
            failures.append("ungrouping from the context menu did not return to separate tabs showing the same panes")
        }

        // A narrow combined tab shortens each window's name rather than cutting off the later ones.
        let longName = "window-driven-workspace.md — window_switcher — a document with a long name"
        model.titles = [0: longName, 1: "ssh ks000", 2: "Pane 2", 3: "Pane 3"]
        controller.session.pruneClosedWindows()
        guard let combineAction = chrome.combineButton.action,
              NSApp.sendAction(combineAction, to: chrome.combineButton.target, from: chrome.combineButton),
              let longGroup = controller.session.activeGroupID,
              let longTab = tabButtons().first(where: { $0.title.contains(CombinedTabTitle.separator) }),
              let longCell = longTab.cell as? WorkspaceTabButtonCell,
              let bitmap = longTab.bitmapImageRepForCachingDisplay(in: longTab.bounds)
        else { return failures + ["the combine button could not combine windows with long names"] }
        longTab.cacheDisplay(in: longTab.bounds, to: bitmap)
        let drawnTitle = longCell.drawnTitle ?? NSAttributedString()
        var drawnIcons = 0
        drawnTitle.enumerateAttribute(.attachment, in: NSRange(location: 0, length: drawnTitle.length)) { value, _, _ in
            if (value as? NSTextAttachment)?.image != nil { drawnIcons += 1 }
        }
        let drawn = drawnTitle.string.replacingOccurrences(of: "\u{FFFC}", with: "")
        let drawnNames = drawn.components(separatedBy: CombinedTabTitle.separator)
        if longTab.title != longName + "|ssh ks000" || drawnNames.count != 2 || !drawnNames[0].hasPrefix("win")
            || !drawnNames[0].hasSuffix("…") || !drawnNames[1].hasPrefix("ssh") || drawnIcons != 2
        {
            failures.append(
                "a narrow combined tab did not show every window's icon and part of its name: \(drawn), "
                    + "\(drawnIcons) icons, width \(longTab.bounds.width)")
        }
        NSApp.sendAction(combineAction, to: chrome.combineButton.target, from: chrome.combineButton)
        if controller.session.isPaneGroup(longGroup) || controller.session.cells != [ids[0], ids[1]]
            || chrome.combineButtonUngroups || !chrome.combineButton.isEnabled
            || chrome.combineButton.accessibilityLabel() != L("表示中のペインを1つのタブにまとめる")
        {
            failures.append("the combine button did not ungroup the shown combined tab")
        }
        return failures
    }

    static func runTabSelectionFeedbackChecks() -> [String] {
        var failures: [String] = []
        for autoHide in [false, true] {
            let model = Model(windowCount: 3)
            var client = access(for: model)
            var observe: ((String) -> Void)?
            let focus = client.focus
            client.focus = { element, application in
                observe?("focus")
                try focus(element, application)
            }
            let minimize = client.minimize
            client.minimize = { element, minimized in
                observe?("presentation")
                return try minimize(element, minimized)
            }
            let controller = WorkspaceController(name: "Selection feedback", access: client)
            defer {
                observe = nil
                controller.quitting = true
                controller.setAutoHideTabs(false)
                controller.window.orderOut(nil)
            }
            guard let chrome = controller.window.contentView as? WorkspaceChromeView else {
                return failures + ["selection feedback fixture could not find its chrome"]
            }
            controller.session.add(model.windows.map {
                WindowCandidate(element: $0.element, application: .current, title: "Selection probe")
            })
            controller.session.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
            controller.session.setPanePinned(true, at: 0)
            controller.setAutoHideTabs(autoHide)
            chrome.setAutoHiddenToolbarVisible(true)
            controller.window.orderFrontRegardless()
            chrome.layoutSubtreeIfNeeded()
            guard let original = controller.session.cells[1],
                  let hidden = controller.session.windows
                  .first(where: { controller.session.cellIndex(for: $0.id) == nil })
            else { return failures + ["selection feedback fixture had no hidden tab"] }
            let ids = controller.session.windows.map(\.id)
            func tab(for id: UUID) -> WorkspaceTabGroup? {
                chrome.tabs.arrangedSubviews.compactMap { $0 as? WorkspaceTabGroup }.first {
                    ($0.arrangedSubviews.first as? NSButton)?.tag == ids.firstIndex(of: id)
                }
            }
            var expected = hidden.id
            var operation = "click"
            var observed: Set<String> = []
            observe = { phase in
                guard observed.insert(phase).inserted else { return }
                let highlighted = chrome.tabs.arrangedSubviews.filter { $0.layer?.borderWidth == 2 }
                if highlighted.count != 1 || highlighted.first !== tab(for: expected) {
                    failures.append("\(operation), auto-hide \(autoHide): tab highlight was late at AX \(phase)")
                }
                if chrome.tabs.window?.viewsNeedDisplay != false {
                    failures.append("\(operation), auto-hide \(autoHide): tab drawing was pending at AX \(phase)")
                }
            }
            guard let button = tab(for: hidden.id)?.arrangedSubviews.first as? NSButton,
                  let action = button.action, NSApp.sendAction(action, to: button.target, from: button)
            else { return failures + ["selection feedback fixture could not click the hidden tab"] }
            if observed != ["focus", "presentation"] {
                failures.append("tab click did not exercise focus and presentation")
            }
            expected = original
            operation = "cycle"
            observed = []
            controller.session.cycle(1)
            if observed != ["focus", "presentation"] {
                failures.append("tab cycle did not exercise focus and presentation")
            }
        }
        return failures
    }

    /// Speakers follow the windows playing audio, through tab re-renders and during a tab drag. A browser window plays
    /// only while one of its tabs may play; other windows play with their application.
    static func runAudioIndicatorChecks() -> [String] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return ["audio indicator fixture needs the Dock as a second application"]
        }
        final class Observation {
            let onChange: @MainActor @Sendable () -> Void
            init(_ onChange: @escaping @MainActor @Sendable () -> Void) { self.onChange = onChange }
        }
        var failures: [String] = []
        let model = Model(windowCount: 3)
        var playing: Set<pid_t> = []
        var browserTabs: [Int: BrowserWindowTabs] = [:]
        var observations: [pid_t: Observation] = [:]
        weak var observedSelf: Observation?
        let tabSource = BrowserTabSource(
            read: { windows, completion in
                completion(windows.map { window in
                    (try? model.index(of: window)).flatMap { browserTabs[$0] } ?? .noTabStrip
                })
            },
            observe: { pid, onChange in
                let observation = Observation(onChange)
                observations[pid] = observation
                return observation
            },
            forget: { _ in })
        let audio = AudioPlaybackMonitor(hold: 0, playingApplications: { playing }, browserTabs: tabSource)
        let controller = WorkspaceController(name: "Audio indicator", access: access(for: model), audio: audio)
        defer {
            controller.quitting = true
            controller.window.orderOut(nil)
        }
        guard let chrome = controller.window.contentView as? WorkspaceChromeView else {
            return ["audio indicator fixture could not find its chrome"]
        }
        controller.session.add([
            WindowCandidate(element: model.windows[0].element, application: .current, title: "Playing tab probe"),
            WindowCandidate(element: model.windows[1].element, application: .current, title: "Silent tab probe"),
            WindowCandidate(element: model.windows[2].element, application: dock, title: "Other app probe"),
        ])
        chrome.layoutSubtreeIfNeeded()
        let buttons = chrome.tabs.arrangedSubviews.compactMap {
            ($0 as? WorkspaceTabGroup)?.arrangedSubviews.first as? WorkspaceTabButton
        }
        guard buttons.count == 3 else { return ["audio indicator fixture expected 3 tabs, found \(buttons.count)"] }
        let described = L("音声を再生中")
        func states() -> [Bool] {
            buttons.map { $0.audioIndicator?.isHidden == false && $0.toolTip?.contains(described) == true }
        }
        func expect(_ expected: [Bool], _ step: String, wait: Bool = true) {
            let deadline = Date().addingTimeInterval(wait ? 2 : 0)
            while states() != expected, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            let speakers = buttons.map { $0.audioIndicator?.isHidden == false }
            let toolTips = buttons.map { $0.toolTip?.contains(described) == true }
            if speakers != expected || toolTips != expected {
                failures.append("\(step): speakers \(speakers), tooltips \(toolTips), expected \(expected)")
            }
        }
        expect([false, false, false], "before playback")
        browserTabs = [0: .tabs([.silent, .playing]), 1: .tabs([.silent])]
        playing = [getpid()]
        audio.refresh()
        expect([false, false, false], "before the tabs were read", wait: false)
        expect([true, false, false], "while one browser window plays")
        browserTabs = [0: .tabs([.muted]), 1: .tabs([.otherAlert])]
        observedSelf = observations[getpid()]
        observations[getpid()]?.onChange()
        expect([false, true, false], "after the browser renamed its tabs")
        controller.session.select(controller.session.windows[1].id)
        expect([false, true, false], "after selecting another tab")
        guard let dragged = buttons[2].superview as? WorkspaceTabGroup else {
            return failures + ["audio indicator fixture lost its third tab"]
        }
        chrome.beginTabDrag(source: buttons[2], token: "audio-indicator-probe")
        playing = [dock.processIdentifier]
        audio.refresh()
        expect([false, false, true], "during a tab drag, for an app without tabs")
        if !dragged.isFloating || chrome.tabs.arrangedSubviews.contains(dragged) {
            failures.append("a playback change ended the tab drag")
        }
        chrome.endTabDrag()
        observations = [:]
        if observedSelf != nil { failures.append("tabs were still observed after their application went quiet") }
        playing = []
        audio.refresh()
        expect([false, false, false], "after playback")
        return failures
    }

    static func runNestedPaneUIChecks() -> [String] {
        var failures: [String] = []
        let model = Model(windowCount: 3)
        let controller = WorkspaceController(name: "Nested panes", access: access(for: model))
        let restored = WorkspaceController(name: "Restored panes")
        defer {
            for controller in [controller, restored] {
                controller.quitting = true
                controller.setAutoHideTabs(false)
                controller.window.orderOut(nil)
            }
        }
        guard let chrome = controller.window.contentView as? WorkspaceChromeView,
              let restoredChrome = restored.window.contentView as? WorkspaceChromeView
        else {
            return ["nested pane fixture could not find its chrome"]
        }
        let window = controller.window
        window.setFrame(NSRect(x: 120, y: 140, width: 900, height: 600), display: false)
        restored.window.setFrame(window.frame, display: false)
        controller.session.add(
            model.windows.map {
                WindowCandidate(element: $0.element, application: .current, title: "Nested probe")
            })
        let singlePaneMenu = controller.activePaneMenu()
        singlePaneMenu.update()
        if singlePaneMenu.item(withTitle: L("ペインを固定"))?.isEnabled != false {
            failures.append("a single pane's pin action became enabled after menu validation")
        }
        controller.session.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        chrome.layoutSubtreeIfNeeded()
        let left = chrome.gridAreas[0].frame
        func event(_ type: NSEvent.EventType, _ location: NSPoint = .zero) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func perform(_ title: String, in menu: NSMenu?) {
            guard let item = menu?.item(withTitle: L(title)), let action = item.action,
                  NSApp.sendAction(action, to: item.target, from: item)
            else {
                failures.append("nested pane menu could not perform \(title)")
                return
            }
            chrome.layoutSubtreeIfNeeded()
        }
        let rightTab = chrome.tabs.arrangedSubviews.compactMap {
            ($0 as? WorkspaceTabGroup)?.arrangedSubviews.first as? NSButton
        }.first { $0.tag == 0 }
        let menu = rightTab?.menu(for: event(.rightMouseDown))
        perform("上下に分割", in: menu?.item(withTitle: L("ペイン"))?.submenu)
        guard chrome.gridAreas.count == 3 else { return failures + ["tab pane menu did not create a nested split"] }
        let pinMenu = chrome.gridAreas[0].menu(for: event(.rightMouseDown))
        pinMenu?.update()
        if pinMenu?.item(withTitle: L("ペインを固定"))?.isEnabled != true {
            failures.append("splitting a pane did not enable its pin action")
        }
        perform("ペインを固定", in: pinMenu)
        let pinnedID = controller.session.cells[0]
        let pinnedTag = controller.session.windows.firstIndex { $0.id == pinnedID }
        let pinnedTab = chrome.tabs.arrangedSubviews.compactMap { $0 as? WorkspaceTabGroup }.first {
            ($0.arrangedSubviews.first as? NSButton)?.tag == pinnedTag
        }
        if !controller.session.isPanePinned(0)
            || pinnedTab?.subviews.compactMap({ $0 as? NSImageView }).first?.isHidden != false
        {
            failures.append("pinning a pane did not update its pin marker")
        }
        perform("ペインを固定", in: chrome.gridAreas[0].menu(for: event(.rightMouseDown)))
        if controller.session.isPanePinned(0) {
            failures.append("the pane context menu did not unpin a pinned pane")
        }
        if chrome.gridAreas[0].frame != left || chrome.columnSelector.title != L("カスタム")
            || chrome.rowSelector.title != L("カスタム")
        {
            failures.append("a tab's split changed another pane or did not show Custom in the preset controls")
        }
        let upperRight = chrome.gridAreas[1].frame
        let start = chrome.stage.convert(NSPoint(x: upperRight.midX, y: upperRight.minY - 4), to: nil)
        let end = NSPoint(x: start.x, y: start.y - 40)
        NSApp.postEvent(event(.leftMouseDragged, end), atStart: false)
        NSApp.postEvent(event(.leftMouseUp, end), atStart: false)
        chrome.stage.mouseDown(with: event(.leftMouseDown, start))
        if chrome.gridAreas[0].frame != left || abs(chrome.gridAreas[1].frame.height - upperRight.height - 40) > 0.5
            || controller.session.customLayout != chrome.stage.customLayout
        {
            failures.append("dragging a nested divider changed another pane or did not update the saved proportions")
        }
        controller.session.activateCell(2)
        perform("上下に分割", in: controller.activePaneMenu())
        guard chrome.gridAreas.count == 4, controller.session.cells[3] == nil else {
            return failures + ["splitting without a hidden tab did not create an empty pane"]
        }
        perform("ペインを閉じる", in: chrome.gridAreas[3].menu(for: event(.rightMouseDown)))
        if chrome.gridAreas.count != 3 || controller.session.windows.count != 3 {
            failures.append("an empty pane's context menu released windows or closed the wrong pane")
        }
        controller.setAutoHideTabs(true)
        chrome.layoutSubtreeIfNeeded()
        let snapshot = SavedWorkspace(
            name: controller.name, windows: [], columns: 2, rows: 1,
            autoHideTabs: true, paneLayout: controller.session.customLayout,
            pinnedPanes: [1])
        do {
            let decoded = try JSONDecoder().decode(SavedWorkspace.self, from: JSONEncoder().encode(snapshot))
            restored.restoreLayout(decoded)
            restoredChrome.layoutSubtreeIfNeeded()
            if restored.session.customLayout != snapshot.paneLayout || !restored.autoHideTabs
                || restored.session.pinnedCells != [1]
                || restoredChrome.gridAreas.map(\.frame) != chrome.gridAreas.map(\.frame)
            {
                failures.append(
                    "saving and restoring a nested layout lost its shape, ratios, pin, or auto-hide setting")
            }
            let legacy = try JSONDecoder().decode(
                SavedWorkspace.self, from: Data(#"{"name":"Legacy","windows":[],"columns":2,"rows":2}"#.utf8))
            restored.restoreLayout(legacy)
            if restored.session.customLayout != nil || restoredChrome.gridAreas.count != 4 || restored.autoHideTabs {
                failures.append("a legacy columns/rows save did not restore as a regular grid")
            }
        } catch {
            failures.append("nested layout persistence failed: \(error)")
        }
        controller.setAutoHideTabs(false)
        chrome.columnSelector.selectItem(at: 1)
        if let action = chrome.columnSelector.action {
            _ = NSApp.sendAction(action, to: chrome.columnSelector.target, from: chrome.columnSelector)
        }
        if controller.session.customLayout != nil || chrome.gridAreas.count != 2 {
            failures.append("choosing a preset after a nested split did not restore the regular grid")
        }
        controller.session.setPanePinned(true, at: 0)
        controller.session.setGrid(.single)
        let collapsedMenu = controller.activePaneMenu()
        collapsedMenu.update()
        let collapsedPin = collapsedMenu.item(withTitle: L("ペインを固定"))
        if collapsedPin?.isEnabled != false || collapsedPin?.state != .off {
            failures.append("returning to one pane did not disable and clear its pin action")
        }
        return failures
    }

    static func runNestedPaneLimitChecks() -> [String] {
        var failures: [String] = []
        let model = Model(windowCount: 16)
        let controller = WorkspaceController(name: "Nested limits", access: access(for: model))
        defer {
            controller.quitting = true
            controller.window.orderOut(nil)
        }
        guard let chrome = controller.window.contentView as? WorkspaceChromeView else {
            return ["nested limits fixture could not find its chrome"]
        }
        controller.session.onMessage = { model.notices.append($0) }
        controller.session.add(
            model.windows.map {
                WindowCandidate(element: $0.element, application: .current, title: "Nested limit probe")
            })
        let ids = controller.session.windows.map(\.id)
        let selected = controller.session.selectedID
        let rightClick = NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: controller.window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1)!
        func menu(for pane: Int) -> NSMenu? {
            guard let id = controller.session.cells[pane], let tag = ids.firstIndex(of: id),
                  let tab = chrome.tabs.arrangedSubviews.compactMap({
                      ($0 as? WorkspaceTabGroup)?.arrangedSubviews.first as? NSButton
                  }).first(where: { $0.tag == tag })
            else { return nil }
            let menu = tab.menu(for: rightClick)?.item(withTitle: L("ペイン"))?.submenu
            menu?.update()
            return menu
        }
        for title in ["左右に分割", "左右に分割", "上下に分割", "上下に分割"] {
            let count = controller.session.cells.count
            for index in (0 ..< count).reversed() {
                guard let item = menu(for: index)?.item(withTitle: L(title)), item.isEnabled,
                      let action = item.action, NSApp.sendAction(action, to: item.target, from: item)
                else {
                    return failures + ["nested split menu stopped before reaching 4 by 4"]
                }
            }
            if controller.session.cells.count != count * 2 {
                return failures + ["repeated pane splitting stopped at \(controller.session.cells.count) panes"]
            }
            if controller.session.cells.count == 4 {
                let horizontal = menu(for: 0)?.item(withTitle: L("左右に分割"))
                let vertical = menu(for: 0)?.item(withTitle: L("上下に分割"))
                if horizontal?.isEnabled != false || vertical?.isEnabled != true {
                    failures.append("reaching four columns did not disable only horizontal splitting")
                }
            }
        }
        chrome.layoutSubtreeIfNeeded()
        let expectedWidth = (chrome.stage.bounds.width - 3 * chrome.stage.dividerThickness) / 4
        let expectedHeight = (chrome.stage.bounds.height - 3 * chrome.stage.dividerThickness) / 4
        for area in chrome.gridAreas {
            if abs(area.frame.width - expectedWidth) > 0.5 || abs(area.frame.height - expectedHeight) > 0.5 {
                failures.append("repeated menu splits did not reach the regular 4 by 4 pane size")
                break
            }
        }
        if controller.session.windows.map(\.id) != ids || Set(controller.session.cells.compactMap { $0 }) != Set(ids)
            || controller.session.selectedID != selected
        {
            failures.append("deep nesting lost a tab, pane assignment, or the selected window")
        }
        let smallest = menu(for: 15)
        if smallest?.item(withTitle: L("左右に分割"))?.isEnabled != false
            || smallest?.item(withTitle: L("上下に分割"))?.isEnabled != false
            || smallest?.item(withTitle: L("ペインを閉じる"))?.isEnabled != true
        {
            failures.append("the smallest pane did not disable splitting while keeping Close Pane enabled")
        }
        let before = controller.session.customLayout
        controller.session.splitPane(at: 0, axis: .horizontal)
        if controller.session.customLayout != before || model.notices.last?.needsAttention != true {
            failures.append("bypassing the disabled menu exceeded the nesting limit without a notice")
        }
        return failures
    }

    static func runNestedPaneMinimumChecks() -> [String] {
        var failures: [String] = []
        let model = Model(windowCount: 2)
        model.windows.forEach { $0.minimumSize.width = 600 }
        let controller = WorkspaceController(name: "Pane minimum limits", access: access(for: model))
        defer {
            controller.quitting = true
            controller.window.orderOut(nil)
        }
        controller.window.setFrame(NSRect(x: 120, y: 140, width: 900, height: 600), display: false)
        controller.session.onMessage = { model.notices.append($0) }
        controller.session.add(
            model.windows.map {
                WindowCandidate(element: $0.element, application: .current, title: "Minimum size probe")
            })
        // The first attempted fit learns app minimum sizes, which are not exposed by every app through AX.
        controller.session.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        guard controller.session.cells.count == 1 else {
            return ["minimum-size fixture did not learn the apps' width constraints"]
        }
        guard let appName = NSRunningApplication.current.localizedName, !appName.isEmpty else {
            return ["minimum-size fixture has no application name"]
        }
        let warning = model.notices.last?.text ?? ""
        if !warning.contains("1×1") || warning.components(separatedBy: appName).count != 2 {
            failures.append("the 1×1 fallback did not name the constraining app exactly once")
        }
        let menu = controller.activePaneMenu()
        menu.update()
        let horizontal = menu.items.first { $0.title.contains(L("左右に分割")) }
        if horizontal?.isEnabled != false || horizontal?.title.contains(appName) != true
            || menu.item(withTitle: L("上下に分割"))?.isEnabled != true
        {
            failures.append("known width minimums did not identify the app on just the blocked split direction")
        }
        let cells = controller.session.cells
        model.operations.removeAll()
        model.notices.removeAll()
        controller.session.splitPane(at: 0, axis: .horizontal)
        if controller.session.cells != cells || !model.operations.isEmpty || model.notices.last?.needsAttention != true
            || model.notices.last?.text.contains(appName) != true
        {
            failures.append("a blocked minimum-size split changed windows or failed without a notice")
        }
        controller.window.setFrame(NSRect(x: 120, y: 140, width: 1400, height: 600), display: false)
        let expandedMenu = controller.activePaneMenu()
        expandedMenu.update()
        guard let item = expandedMenu.item(withTitle: L("左右に分割")), item.isEnabled,
              let action = item.action, NSApp.sendAction(action, to: item.target, from: item)
        else {
            return failures + ["enlarging the workspace did not re-enable a split that now fits"]
        }
        if controller.session.cells.count != 2 {
            failures.append("a re-enabled split failed to fit the windows at their known minimum sizes")
        }

        // A window can also reject just its requested position, without contributing any minimum size.
        let (positionSession, positionModel) = fixture(registering: [0, 1])
        positionSession.targetFrames = {
            [0: positionModel.target, 1: positionModel.target.offsetBy(dx: positionModel.target.width + 8, dy: 0)]
        }
        positionModel.windows[0].fullScreen = true // Simulates a window that ignores position changes.
        positionSession.setSplit(true)
        let positionWarning = positionModel.notices.last?.text ?? ""
        if positionSession.isSplit || !positionWarning.contains(appName) || !positionWarning.contains("1×1") {
            failures.append("a rejected window position lost the app's name after returning to 1×1")
        }

        let (terminalSession, terminalModel) = fixture(registering: [0], windowCount: 1)
        terminalModel.windows[0].sizeIncrement = CGSize(width: 8, height: 16)
        terminalSession.splitPane(at: 0, axis: .horizontal)
        if !terminalSession.isSplit || terminalSession.customLayout?.paneCount != 2 {
            failures.append("small text-grid size rounding was mistaken for a minimum that blocks splitting")
        }
        return failures
    }

    static func runTransferChecks() -> [String] {
        var failures: [String] = []
        let (source, model) = fixture()
        let (destination, _) = fixture(registering: [3], sharedModel: model)
        let transferred = source.windows[2]
        let target = CGRect(x: 1200, y: 120, width: 800, height: 600)
        destination.targetFrames = { [0: target] }
        var observedDuplicate = false
        source.onChange = {
            if source.contains(transferred.candidate) && destination.contains(transferred.candidate) {
                observedDuplicate = true
            }
        }
        if !source.transferWindow(transferred.id, to: destination, at: 0) || source.contains(transferred.candidate)
            || destination.windows.first?.id != transferred.id || destination.selectedID != transferred.id
            || observedDuplicate
        {
            failures.append(
                "cross-workspace transfer lost identity, insertion position, selection, or unique ownership")
        }
        if model.windows[2].frame != target || model.windows[2].minimized
            || destination.windows.first?.originalFrame != transferred.originalFrame
            || destination.windows.first?.originallyMinimized != transferred.originallyMinimized
        {
            failures.append("transfer did not align the window or preserve its original restoration state")
        }
        let originalSourceIDs = source.windows.map(\.id)
        let originalDestinationIDs = destination.windows.map(\.id)
        if source.transferWindow(source.windows[0].id, to: destination, at: -1)
            || source.windows.map(\.id) != originalSourceIDs || destination.windows.map(\.id) != originalDestinationIDs
        {
            failures.append("invalid transfer modified window ownership")
        }
        if !destination.remove(transferred.id) || model.windows[2].frame != transferred.originalFrame
            || model.windows[2].minimized != transferred.originallyMinimized
        {
            failures.append("releasing a transferred tab did not restore its pre-registration state")
        }
        source.setSplit(true)
        destination.setSplit(true)
        destination.targetFrames = { [0: target, 1: target.offsetBy(dx: 800, dy: 0)] }
        let splitID = source.windows[0].id
        if !source.transferWindow(splitID, to: destination, cell: 1) || source.cells.contains(splitID)
            || destination.cells[1] != splitID || destination.activeCell != 1 || source.windows.count != 1
        {
            failures.append("pane transfer failed to reconcile the source or select the destination pane")
        }
        let (empty, _) = fixture(registering: [], sharedModel: model)
        let lastID = source.windows[0].id
        if !source.transferWindow(lastID, to: empty) || !source.windows.isEmpty || source.cells != [nil]
            || empty.selectedID != lastID
        {
            failures.append("detaching the last tab did not leave an empty source and a selected destination")
        }
        return failures
    }

    static func runWorkspaceMergeChecks() -> [String] {
        var failures: [String] = []
        let (source, model) = fixture()
        let startPage = UUID()
        source.newTab(id: startPage)
        let (destination, _) = fixture(registering: [3], sharedModel: model)
        let targets: [Int: CGRect] = [
            0: CGRect(x: 1200, y: 120, width: 400, height: 600), 1: CGRect(x: 1600, y: 120, width: 400, height: 600),
        ]
        destination.setSplit(true)
        destination.targetFrames = { targets }
        let kept = destination.windows[0].id
        let moved = source.windows
        var observedDuplicate = false
        for session in [source, destination] {
            session.onChange = {
                if moved.contains(where: { source.contains($0.candidate) && destination.contains($0.candidate) }) {
                    observedDuplicate = true
                }
            }
        }
        if destination.absorbWindows(from: source) != 3 || observedDuplicate || !source.windows.isEmpty
            || source.tabIDs != [startPage] || destination.tabIDs != [kept] + moved.map(\.id)
        {
            failures.append("merging workspaces lost windows, kept start pages, or briefly shared ownership")
        }
        if destination.cells != [kept, moved[0].id] || destination.selectedID != kept {
            failures
                .append("merging changed the shown window instead of only filling the empty pane: \(destination.cells)")
        }
        if model.windows[0].frame != targets[1] || model.windows[1].frame != targets[0]
            || model.windows[2].frame != targets[0]
        {
            failures.append("merged windows were not aligned to the destination's panes")
        }
        if destination.windows.dropFirst().map(\.originalFrame) != moved.map(\.originalFrame)
            || destination.absorbWindows(from: source) != 0
            || !destination.remove(moved[2].id) || model.windows[2].frame != moved[2].originalFrame
        {
            failures.append("merged windows lost their original frames or a repeated merge moved windows again")
        }

        let first = WorkspaceController(name: "Merge 1")
        let second = WorkspaceController(name: "Merge 2")
        defer {
            first.quitting = true
            second.quitting = true
            first.window.orderOut(nil)
            second.window.orderOut(nil)
        }
        first.autoGroupBundleIDs = ["com.example.a", "com.example.b"]
        second.autoGroupBundleIDs = ["com.example.b", "com.example.c"]
        first.absorbWorkspaces([first, second])
        if first.autoGroupBundleIDs != ["com.example.a", "com.example.b", "com.example.c"] {
            failures
                .append(
                    "merging workspaces did not combine their automatically added apps: \(first.autoGroupBundleIDs)")
        }
        return failures
    }

    static func runRegisteredWindowDragChecks() -> [String] {
        var failures: [String] = []
        let (source, model) = fixture(registering: [0])
        let (other, _) = fixture(registering: [1], sharedModel: model)
        let registered = source.windows.map(\.candidate) + other.windows.map(\.candidate)
        let candidate = source.windows[0].candidate
        let pid = candidate.application.processIdentifier
        let windowNumbers: [CGWindowID] = [80, 84, 81]
        var lookups = 0
        let windowID: (AXUIElement) -> CGWindowID? = { element in
            lookups += 1
            return (try? model.index(of: element)).map { windowNumbers[$0] }
        }
        // A moving window's AX frame lags behind the WindowServer, so frame matching cannot identify it.
        var resolutions = 0
        let laggingFrame: (WindowServerWindow) throws -> WindowCandidate = { _ in
            resolutions += 1
            throw InjectedFailure()
        }
        var registration = WorkspaceWindowDragRegistration()
        for offset in [CGFloat(0), 100, 200] {
            let moved = WindowServerWindow(id: 80, processID: pid, frame: model.target.offsetBy(dx: offset, dy: 0))
            if !registration.isRegistered(moved, among: registered, windowID: windowID, resolve: laggingFrame) {
                failures.append("a registered window was offered for ordinary dragging into a workspace")
            }
        }
        if !registration.isRegistered(
            WindowServerWindow(id: 84, processID: pid, frame: model.target),
            among: registered, windowID: windowID, resolve: laggingFrame)
        {
            failures.append("a window registered in another workspace was not suppressed")
        }
        for offset in [CGFloat(0), 100, 200] {
            let sibling = WindowServerWindow(id: 90, processID: pid, frame: model.target.offsetBy(dx: offset, dy: 40))
            if registration.isRegistered(sibling, among: registered, windowID: windowID, resolve: laggingFrame) {
                failures.append(
                    "an unregistered window was not droppable while another window of its app was registered")
                break
            }
        }
        if resolutions != 0 {
            failures.append("drag identification fell back to frame matching although window numbers were available")
        }
        if lookups != registered.count {
            failures.append("registered window numbers were looked up again during one drag: \(lookups)")
        }
        let sibling = WindowCandidate(
            element: model.windows[2].element, application: .current, title: "Newly registered")
        if !registration.isRegistered(
            WindowServerWindow(id: 81, processID: pid, frame: model.target),
            among: registered + [sibling], windowID: windowID, resolve: laggingFrame)
        {
            failures.append("drag identification did not notice newly registered ownership")
        }
        let unrelated = WindowServerWindow(id: 82, processID: pid + 1, frame: model.target)
        if registration.isRegistered(unrelated, among: registered, windowID: windowID, resolve: laggingFrame) {
            failures.append("an app with no registered windows was suppressed")
        }
        registration.reset()
        lookups = 0
        _ = registration.isRegistered(
            WindowServerWindow(id: 90, processID: pid, frame: model.target),
            among: registered, windowID: windowID, resolve: laggingFrame)
        if lookups != registered.count {
            failures.append("resetting the drag did not discard cached window numbers")
        }

        // Without window numbers, frames identify the window once it can be matched.
        let unavailable: (AXUIElement) -> CGWindowID? = { _ in nil }
        registration.reset()
        resolutions = 0
        let resolve: (WindowServerWindow) throws -> WindowCandidate = { _ in
            resolutions += 1
            return candidate
        }
        for offset in [CGFloat(0), 100, 200] {
            let moved = WindowServerWindow(id: 80, processID: pid, frame: model.target.offsetBy(dx: offset, dy: 0))
            if !registration.isRegistered(moved, among: registered, windowID: unavailable, resolve: resolve) {
                failures.append("frame fallback did not suppress a registered window")
            }
        }
        if resolutions != 1 {
            failures.append("frame fallback repeated AX resolution while moving: \(resolutions)")
        }
        registration.reset()
        resolutions = 0
        for offset in [CGFloat(0), 100, 200] {
            let moved = WindowServerWindow(id: 90, processID: pid, frame: model.target.offsetBy(dx: offset, dy: 40))
            if registration.isRegistered(moved, among: registered, windowID: unavailable, resolve: laggingFrame) {
                failures.append("a window whose moving frame could not be matched was not droppable")
            }
        }
        if resolutions != 1 {
            failures.append("an unmatched moving frame was resolved again on every sample: \(resolutions)")
        }
        return failures
    }

    /// Drags an unregistered window of an app whose other window is already in a workspace onto the tab bar.
    static func runExternalWindowDropChecks() -> [String] {
        let model = Model(windowCount: 2)
        let controller = WorkspaceController(name: "Window drop", access: access(for: model))
        let window = controller.window
        defer {
            controller.hideWindowDropTarget()
            controller.quitting = true
            window.orderOut(nil)
        }
        guard let chrome = window.contentView as? WorkspaceChromeView,
              let screen = NSScreen.screens.first
        else { return ["window drop fixture could not find its content or screen"] }
        window.setFrame(NSRect(x: 200, y: 160, width: 900, height: 600), display: true)
        controller.session.add(
            WindowCandidate(element: model.windows[0].element, application: .current, title: "Registered"))
        // Drop targets are hit-tested like clicks; keep other apps' windows from covering the fixture.
        window.level = .floating
        window.orderFrontRegardless()
        chrome.layoutSubtreeIfNeeded()
        let pid = ProcessInfo.processInfo.processIdentifier
        let registeredNumber: CGWindowID = 9_000_001
        let draggedNumber: CGWindowID = 9_000_002
        let workspace = WindowServerWindow(
            id: CGWindowID(window.windowNumber), processID: pid,
            frame: WindowGeometry.accessibilityRect(from: window.frame, primaryScreenTop: screen.frame.maxY))
        let drop = window.convertPoint(
            toScreen: chrome.addButton.convert(
                NSPoint(x: chrome.addButton.bounds.midX, y: chrome.addButton.bounds.midY), to: nil))
        guard controller.acceptsWindowDrop(at: drop) else {
            return ["window drop fixture's tab bar did not accept drops"]
        }
        let axDrop = CGPoint(x: drop.x, y: screen.frame.maxY - drop.y)
        // Let the WindowServer apply the ordering before hit-testing it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        // The dragged window starts outside the workspace and is grabbed 40 points into its titlebar.
        let start = CGRect(x: workspace.frame.maxX + 60, y: workspace.frame.minY + 40, width: 500, height: 400)
        let grab = CGPoint(x: start.minX + 40, y: start.minY + 10)
        let moved = start.offsetBy(dx: axDrop.x - grab.x, dy: axDrop.y - grab.y)

        // Tools such as Accessibility Inspector cover the screen with a transparent, click-through overlay window.
        let overlay = NSWindow(
            contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.ignoresMouseEvents = true
        overlay.level = .screenSaver
        defer { overlay.orderOut(nil) }
        let overlayWindow = WindowServerWindow(
            id: 9_000_003, processID: pid, frame: workspace.frame, layer: Int(CGWindowLevelForKey(.screenSaverWindow)))

        func run(
            dragging number: CGWindowID, windowID: @escaping (AXUIElement) -> CGWindowID?,
            releaseOutside: Bool = false, coveredByOverlay: Bool = false) -> (
            shownBeforeHover: Bool, shown: Bool, finished: Bool) {
            let coordinator = WorkspaceWindowDrop { [controller] }
            var pointer = WorkspaceWindowDrop.Pointer(location: .zero, buttonDown: false)
            var frame = start
            var finished: [WorkspaceController] = []
            var finishedIndex: Int?
            coordinator.pointer = { pointer }
            coordinator.windows = {
                [WindowServerWindow(id: number, processID: pid, frame: frame)]
                    + (coveredByOverlay ? [overlayWindow] : []) + [workspace]
            }
            // The harness owns both fake windows, so only the workspace must not count as its own app.
            coordinator.ownPID = -1
            coordinator.isRegularApplication = { _ in true }
            coordinator.windowID = windowID
            coordinator.resolve = { _ in throw InjectedFailure() }
            coordinator.finish = { target, _, _, index in
                finished.append(target)
                finishedIndex = index
            }
            func sample(_ point: CGPoint, down: Bool) {
                pointer = .init(location: NSPoint(x: point.x, y: screen.frame.maxY - point.y), buttonDown: down)
                coordinator.poll()
            }
            sample(grab, down: false)
            sample(grab, down: true)
            frame = start.offsetBy(dx: 30, dy: 0)
            sample(CGPoint(x: grab.x + 30, y: grab.y), down: true)
            let shownBeforeHover = chrome.windowDropPanel?.isVisible == true && chrome.windowDropPreview == nil
            if releaseOutside {
                sample(CGPoint(x: grab.x + 30, y: grab.y), down: false)
                return (shownBeforeHover, chrome.windowDropPanel?.isVisible == true, !finished.isEmpty)
            }
            frame = moved
            sample(axDrop, down: true)
            let shown = chrome.windowDropPanel?.isVisible == true || chrome.windowDropPreview != nil
            sample(axDrop, down: false)
            return (shownBeforeHover, shown, finished.count == 1 && finished.first === controller && finishedIndex == 1)
        }

        var failures: [String] = []
        let numbers: (AXUIElement) -> CGWindowID? = { element in
            CFEqual(element, model.windows[0].element) ? registeredNumber : nil
        }
        let sibling = run(dragging: draggedNumber, windowID: numbers)
        if sibling.shownBeforeHover {
            failures.append("a dragged window showed the tab bar before reaching the workspace")
        }
        if !sibling.shown {
            failures.append(
                "dragging an unregistered window over the tab bar showed no drop target when another window of its app was registered")
        }
        if !sibling.finished {
            failures.append(
                "releasing an unregistered window on the tab bar did not add it when another window of its app was registered")
        }
        let outside = run(dragging: draggedNumber, windowID: numbers, releaseOutside: true)
        if outside.shownBeforeHover || outside.shown || outside.finished {
            failures.append("a drag released outside the workspace did not dismiss its tab bar")
        }
        if chrome.windowDropPanel?.isVisible == true || chrome.windowDropPreview != nil {
            failures.append("the drop target stayed visible after release")
        }
        let fallback = run(dragging: draggedNumber, windowID: { _ in nil })
        if !fallback.shown || !fallback.finished {
            failures.append("a window whose moving frame could not be matched was not added: \(fallback)")
        }
        let registered = run(dragging: registeredNumber, windowID: numbers)
        if registered.shownBeforeHover || registered.shown || registered.finished {
            failures.append("dragging an already registered window offered it for addition: \(registered)")
        }
        overlay.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(window.windowNumber))
            as? [[String: Any]] ?? []).contains { $0[kCGWindowNumber as String] as? Int == overlay.windowNumber }
        if !onScreen { failures.append("the click-through overlay fixture was not above the workspace") }
        let covered = run(dragging: draggedNumber, windowID: numbers, coveredByOverlay: true)
        overlay.orderOut(nil)
        if !covered.shown || !covered.finished {
            failures.append("a click-through overlay above the workspace blocked dropping a window: \(covered)")
        }
        return failures
    }

    static func runKeyboardFocusChecks() -> [String] {
        var failures: [String] = []
        let (session, model) = fixture()
        let applications = [AXUIElementCreateApplication(800_001), AXUIElementCreateApplication(800_002)]
        var steps: [String] = []
        let setAttribute: (AXUIElement, String, CFTypeRef) throws -> Void = { element, attribute, _ in
            if attribute == kAXFrontmostAttribute {
                steps.append("all-windows \(applications.firstIndex { CFEqual($0, element) } ?? -1)")
            }
        }
        do {
            for index in [0, 1, 2, 0] {
                steps = []
                try WindowAccess.focus(
                    model.windows[index].element, applicationElement: applications[index == 2 ? 1 : 0],
                    setAttribute: setAttribute,
                    raiseWindow: { steps.append("raise \(try model.index(of: $0))") },
                    activateFrontWindowOnly: {
                        steps.append("front-only")
                        return true
                    })
                // Activating the whole app would bring its unregistered windows above other apps too.
                if steps != ["raise \(index)", "front-only", "raise \(index)"] {
                    failures.append("tab focus did not bring only window \(index) forward: \(steps)")
                }
            }
            steps = []
            try WindowAccess.focus(
                model.windows[2].element, applicationElement: applications[1], setAttribute: setAttribute,
                raiseWindow: { steps.append("raise \(try model.index(of: $0))") },
                activateFrontWindowOnly: {
                    steps.append("front-only")
                    return false
                })
            if steps != ["raise 2", "front-only", "all-windows 1", "raise 2"] {
                failures.append("unavailable front-window-only activation did not fall back to AXFrontmost: \(steps)")
            }
            steps = []
            do {
                try WindowAccess.focus(
                    model.windows[2].element, applicationElement: applications[1],
                    setAttribute: { _, attribute, _ in
                        if attribute == kAXFrontmostAttribute { throw InjectedFailure() }
                    },
                    raiseWindow: { steps.append("raise \(try model.index(of: $0))") },
                    activateFrontWindowOnly: { false })
                failures.append("application activation failure did not propagate")
            } catch is InjectedFailure {
            }
            if steps != ["raise 2"] { failures.append("failed application activation still raised after activation") }
        } catch {
            failures.append("keyboard focus operation failed: \(error.localizedDescription)")
        }
        session.cycle(1)
        session.cycle(1)
        session.cycle(-1)
        if model.focusedWindows != [0, 1, 0] {
            failures.append("forward and reverse keyboard cycling did not focus the selected tab")
        }
        model.failedFocuses.insert(1)
        session.cycle(1)
        if model.notices.last?.needsAttention != true {
            failures.append("keyboard focus failure was not reported to the user")
        }
        return failures
    }

    static func runWindowInsertionChecks() -> [String] {
        var failures: [String] = []
        for insertion in [0, 1, 3] {
            let (session, model) = fixture()
            let originals = session.windows.map(\.id)
            let candidate = WindowCandidate(element: model.windows[3].element, application: .current, title: "Inserted")
            session.add(candidate, originalFrame: model.windows[3].originalFrame, at: insertion)
            guard let inserted = session.windows.first(where: { $0.candidate.isSameWindow(as: candidate) }) else {
                failures.append("window addition at an insertion line failed")
                continue
            }
            var expected = originals
            expected.insert(inserted.id, at: insertion)
            if session.windows.map(\.id) != expected || session.selectedID != inserted.id {
                failures.append("a new window was not inserted and selected at the indicated position")
            }
            if !session.remove(inserted.id) || model.windows[3].frame != model.windows[3].originalFrame {
                failures.append("inserting a window changed its original restoration geometry")
            }
        }
        let (session, model) = fixture()
        let originals = session.windows.map(\.id)
        session.add(WindowCandidate(element: model.windows[3].element, application: .current, title: "Invalid"), at: -1)
        if session.windows.map(\.id) != originals || model.notices.last?.needsAttention != true {
            failures.append("an invalid insertion position changed the session or failed silently")
        }
        return failures
    }

    static func runTitlebarFocusChecks() -> [String] {
        let model = Model(windowCount: 2)
        let controller = WorkspaceController(name: "Titlebar focus", access: access(for: model))
        let window = controller.window
        defer {
            controller.quitting = true
            window.orderOut(nil)
        }
        guard let chrome = window.contentView as? WorkspaceChromeView,
              let screen = NSScreen.screens.first
        else { return ["titlebar focus fixture could not find its content or screen"] }
        func settle(_ seconds: TimeInterval = 0.5, until condition: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline {
                if let event = NSApp.nextEvent(
                    matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
                {
                    NSApp.sendEvent(event)
                }
            }
        }
        window.setFrame(NSRect(x: 160, y: 180, width: 900, height: 600), display: true)
        controller.session.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        controller.session.add(
            model.windows.map {
                WindowCandidate(element: $0.element, application: .current, title: "Focus probe")
            })
        controller.bringToFront()
        settle()
        guard NSApp.isActive, window.isKeyWindow else {
            return ["titlebar focus fixture did not become active and key"]
        }
        guard
            let dragSpace = chrome.subviews.flatMap(\.subviews).compactMap({ $0 as? NSStackView })
            .flatMap(\.arrangedSubviews).first(where: { $0.toolTip == L("ドラッグして移動 / ダブルクリックで最大化") })
        else { return ["titlebar focus fixture could not find the toolbar drag area"] }
        var failures: [String] = []
        if !model.focusedWindows.isEmpty {
            failures.append("making the workspace key stole focus before any titlebar gesture")
        }
        func gesture(at point: NSPoint, delta: NSSize) -> Bool {
            guard
                let down = NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
            else { return false }
            let start = window.convertPoint(toScreen: point)
            let types: [CGEventType] = delta == .zero ? [.leftMouseUp] : [.leftMouseDragged, .leftMouseUp]
            let events = types.compactMap { type -> NSEvent? in
                guard
                    let event = CGEvent(
                        mouseEventSource: nil, mouseType: type,
                        mouseCursorPosition: CGPoint(
                            x: start.x + delta.width, y: screen.frame.maxY - start.y - delta.height),
                        mouseButton: .left)
                else { return nil }
                return NSEvent(cgEvent: event)
            }
            guard events.count == types.count else { return false }
            // Queue only in this app, without moving the system pointer or clicking another app.
            for event in events { NSApp.postEvent(event, atStart: false) }
            window.sendEvent(down)
            return true
        }
        let barPoint = dragSpace.convert(NSPoint(x: dragSpace.bounds.midX, y: dragSpace.bounds.midY), to: nil)
        let gestures: [(String, NSPoint, NSSize)] = [
            ("titlebar click", barPoint, .zero),
            ("titlebar click while already key", barPoint, .zero),
            ("titlebar drag", barPoint, NSSize(width: 20, height: 10)),
            ("resize grip", NSPoint(x: chrome.bounds.maxX - 12, y: 12), NSSize(width: 20, height: -10)),
        ]
        for (label, point, delta) in gestures {
            model.focusedWindows.removeAll()
            guard gesture(at: point, delta: delta) else {
                failures.append("\(label): could not create mouse events")
                continue
            }
            if !model.focusedWindows.isEmpty {
                failures.append("\(label): handed off focus before mouse tracking returned")
            }
            settle()
            // Each visible pane's window comes above other apps, and the selected one keeps focus.
            if model.focusedWindows != [0, 1] {
                failures.append(
                    "\(label): selected pane was not focused on release; another activation click is needed: "
                        + "\(model.focusedWindows) (active \(NSApp.isActive), key \(window.isKeyWindow), "
                        + "frontmost \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"))")
            }
        }

        // A pending handoff must not steal focus from a window opened before it runs.
        model.focusedWindows.removeAll()
        if !gesture(at: barPoint, delta: .zero) { failures.append("could not create interrupted titlebar click") }
        let other = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        other.makeKeyAndOrderFront(nil)
        settle()
        window.makeKeyAndOrderFront(nil)
        settle()
        if !model.focusedWindows.isEmpty {
            failures.append("a stale titlebar handoff stole focus after another window became key")
        }

        // Clicks on an inactive workspace. The click is handled before WindowDock's activation arrives.
        let helper: ActivationHelperProcess
        switch ActivationHelperProcess.launch() {
        case .success(let launched): helper = launched
        case .failure(let failure): return failures + [failure.message]
        }
        defer { helper.terminate() }
        settle(0.5)
        // NSApp.deactivate() does not give up activation, so another app takes it.
        func deactivate() -> Bool {
            if NSApp.isActive {
                _ = WindowAccess.activateFrontWindowOnly(helper.pid)
                settle(2) { !NSApp.isActive }
            }
            return !NSApp.isActive
        }
        if deactivate() {
            model.focusedWindows.removeAll()
            if !gesture(at: barPoint, delta: .zero) { failures.append("could not create inactive titlebar click") }
            settle(0.3)
            if !model.focusedWindows.isEmpty {
                failures.append("inactive titlebar click handed off focus before WindowDock was active")
            }
            // Stands in for the click, which lets WindowDock activate itself.
            helper.send("yield \(ProcessInfo.processInfo.processIdentifier)")
            settle(0.3)
            controller.bringToFront()
            settle(2) { NSApp.isActive && window.isKeyWindow && !model.focusedWindows.isEmpty }
            settle(0.2)
            if model.focusedWindows != [0, 1] {
                failures.append(
                    "titlebar click on an inactive workspace left only the frame in front once WindowDock became active; another click is needed: \(model.focusedWindows)")
            }
        } else {
            failures.append("titlebar focus fixture could not deactivate WindowDock")
        }
        let paneArea = chrome.gridAreas[0]
        let panePoint = paneArea.convert(NSPoint(x: paneArea.bounds.midX, y: paneArea.bounds.midY), to: nil)
        let tabButtons = chrome.tabs.arrangedSubviews.compactMap {
            ($0 as? WorkspaceTabGroup)?.arrangedSubviews.compactMap { $0 as? WorkspaceTabButton }.first
        }
        if let tab = tabButtons.first(where: { $0.tag == 0 }) {
            let tabPoint = tab.convert(NSPoint(x: tab.bounds.midX, y: tab.bounds.midY), to: nil)
            for (label, point) in [("pane", panePoint), ("tab", tabPoint)] {
                controller.session.select(controller.session.windows[1].id)
                guard deactivate() else {
                    failures.append("titlebar focus fixture could not deactivate WindowDock before a \(label) click")
                    continue
                }
                model.focusedWindows.removeAll()
                if !gesture(at: point, delta: .zero) { failures.append("could not create inactive \(label) click") }
                settle(1) { !model.focusedWindows.isEmpty }
                // A pane does not track the mouse; deliver its queued mouse-up before the next click.
                settle(0.3)
                if model.focusedWindows != [0] {
                    failures.append(
                        "the first click on a \(label) of an inactive workspace did not focus its window: \(model.focusedWindows)")
                }
            }
        } else {
            failures.append("titlebar focus fixture could not find its first tab")
        }
        return failures
    }

    static func runConstraintNoticeChecks() -> [String] {
        var failures: [String] = []
        let (session, model) = fixture()
        let ids = session.windows.map(\.id)
        model.windows[0].minimumSize.width = model.target.width + 100
        model.target.size.width -= 10
        session.sync()
        if model.notices.last?.needsAttention == true {
            failures.append("hidden constrained window showed a size warning")
        }
        session.select(ids[0])
        if model.notices.last?.needsAttention != true {
            failures.append("selected constrained window did not show a size warning")
        }
        let constrainedStart = Date()
        for _ in 0 ..< 3 {
            model.target.origin.x += 1
            session.sync()
        }
        if Date().timeIntervalSince(constrainedStart) > 0.2 {
            failures.append("a window at its known minimum size stalled every workspace sync")
        }
        model.windows[0].minimumSize = .zero
        for _ in 0 ..< 3 {
            model.target.origin.x += 1
            session.sync()
            if model.notices.last?.needsAttention != true {
                failures.append("repeated synchronization cleared the selected tab's warning")
                break
            }
        }
        session.select(ids[2])
        if model.notices.last?.needsAttention == true {
            failures.append("switching to an unconstrained tab did not clear the warning")
        }
        session.select(ids[0])
        if model.notices.last?.needsAttention != true {
            failures.append("returning to the constrained tab did not restore its warning")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(3.2))
        if model.notices.last?.needsAttention == true {
            failures.append("a window that stayed fitted did not clear its warning")
        }

        model.windows[0].minimumSize.width = model.target.width + 100
        model.target.size.width -= 1
        session.sync()
        model.windows[0].minimumSize = .zero
        model.target.origin.x += 1
        session.sync()
        RunLoop.current.run(until: Date().addingTimeInterval(1.6))
        model.windows[0].minimumSize.width = model.target.width + 100
        model.target.size.width -= 1
        session.sync()
        model.windows[0].minimumSize = .zero
        model.target.origin.x += 1
        session.sync()
        RunLoop.current.run(until: Date().addingTimeInterval(1.6))
        if model.notices.last?.needsAttention != true {
            failures.append("a renewed mismatch did not restart the warning recovery delay")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.6))
        if model.notices.last?.needsAttention == true {
            failures.append("a warning did not clear after the restarted recovery delay")
        }

        model.windows[0].minimumSize.width = model.target.width + 100
        model.target.size.width -= 1
        session.sync()
        model.windows[0].minimumSize = .zero
        model.target.origin.x += 1
        session.sync()
        model.windows[0].frame.origin.x += 50
        RunLoop.current.run(until: Date().addingTimeInterval(3.2))
        if model.notices.last?.needsAttention != true {
            failures.append("a warning cleared without checking the current window frame")
        }
        session.sync()
        RunLoop.current.run(until: Date().addingTimeInterval(3.2))
        if model.notices.last?.needsAttention == true {
            failures.append("a warning did not clear after the displaced window was refitted")
        }
        model.windows[0].minimumSize.width = model.target.width + 100
        model.target.size.width -= 1
        session.sync()
        model.windows[0].minimumSize = .zero
        model.target.origin.x += 1
        session.sync()
        model.notices.append(.attention("Another problem"))
        RunLoop.current.run(until: Date().addingTimeInterval(3.2))
        if model.notices.last?.text != "Another problem" {
            failures.append("clearing a fit warning replaced an unrelated notice")
        }

        let (settlingSession, settlingModel) = fixture(registering: [0], windowCount: 1)
        settlingModel.windows[0].minimumSize.width = settlingModel.target.width + 100
        settlingModel.target.size.width -= 1
        settlingSession.sync()
        settlingModel.windows[0].frame = settlingModel.target
        RunLoop.current.run(until: Date().addingTimeInterval(3.2))
        if settlingModel.notices.last?.needsAttention != true {
            failures.append("a window that settled without a sync cleared its warning too soon")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(3.2))
        if settlingModel.notices.last?.needsAttention == true {
            failures.append("a window that settled without a sync kept its warning")
        }
        return failures
    }

    static func runEnhancedUIFrameChecks() -> [String] {
        let helper: ActivationHelperProcess
        switch ActivationHelperProcess.launch(resizable: true) {
        case .success(let launched): helper = launched
        case .failure(let failure): return [failure.message]
        }
        defer { helper.terminate() }

        let application = AXUIElementCreateApplication(helper.pid)
        AXUIElementSetMessagingTimeout(application, 0.3)
        let attribute = "AXEnhancedUserInterface"
        let wasEnhanced = (try? WindowAccess.value(application, attribute) as? Bool) ?? false
        defer {
            _ = AXUIElementSetAttributeValue(
                application, attribute as CFString, wasEnhanced ? kCFBooleanTrue : kCFBooleanFalse)
        }
        _ = AXUIElementSetAttributeValue(application, attribute as CFString, kCFBooleanTrue)
        guard (try? WindowAccess.value(application, attribute) as? Bool) == true else {
            return ["could not enable Enhanced UI on the helper application"]
        }

        guard let process = NSRunningApplication(processIdentifier: helper.pid),
              let windows = WindowAccess.windowElements(process),
              let window = windows.first(where: { WindowAccess.windowID(of: $0) == CGWindowID(helper.windows[0]) }),
              let before = try? WindowAccess.frame(window)
        else {
            return ["could not find the Enhanced UI helper window"]
        }
        let target = CGRect(
            x: before.minX, y: before.minY + 24, width: before.width, height: before.height - 24)
        do {
            try WindowAccess.setFrame(window, target)
        } catch {
            return ["could not resize the Enhanced UI helper window: \(error.localizedDescription)"]
        }

        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        guard let actual = try? WindowAccess.frame(window),
              WindowGeometry.fits(actual, requested: target, tolerance: 1)
        else {
            return [
                "Enhanced UI frame change did not reach its target "
                    + "(actual: \(String(describing: try? WindowAccess.frame(window))), target: \(target))"
            ]
        }
        guard (try? WindowAccess.value(application, attribute) as? Bool) == true else {
            return ["Enhanced UI was not restored after changing the helper window frame"]
        }
        return []
    }

    static func runManyTabMoveChecks() -> [String] {
        var failures: [String] = []
        let (session, model) = fixture(registering: Array(0 ..< 20), windowCount: 20)
        var clearedDuringMove = false
        session.onPresentedFrames = { model.paneFrames = $0 }
        let selectedID = session.selectedID!
        model.paneFrames = [selectedID: model.target]
        model.target.origin.x += 80
        session.targetFrames = { [0: model.target] }
        model.onMove = {
            if model.paneFrames.isEmpty { clearedDuringMove = true }
        }
        session.sync()
        if clearedDuringMove || model.paneFrames[selectedID] != model.target {
            failures.append("many-tab move blanked the entire pane or did not restore the selected window")
        }
        return failures
    }

    @MainActor private final class NewWindowTarget: NSObject {
        @objc func newWindow(_ sender: Any?) {
            let window = NSWindow(contentRect: NSRect(x: 240, y: 220, width: 360, height: 240),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "New helper window"
            window.orderFront(nil)
        }
    }

    static func runNewWindowLaunchCheck() async -> [String] {
        let helper: ActivationHelperProcess
        switch ActivationHelperProcess.launch(resizable: true) {
        case .success(let launched): helper = launched
        case .failure(let failure): return [failure.message]
        }
        defer { helper.terminate() }
        guard let app = NSRunningApplication(processIdentifier: helper.pid),
              let existing = WindowAccess.applicationWindows(app), existing.count == 3
        else { return ["couldn't list the helper's three existing windows"] }
        var client = WindowAccessClient()
        var onRequest: @MainActor () -> Void = {}
        client.requestNewWindow = { app in
            await onRequest()
            try await WindowAccess.requestNewWindow(app)
        }
        let session = WindowSession(access: client)
        let old = existing[0].element
        guard let oldFrame = try? WindowAccess.frame(old) else { return ["could not read the helper frame"] }
        session.targetFrame = { oldFrame }
        session.add(existing[0])
        guard let oldTab = session.selectedID else { return ["could not register the helper's old window"] }
        session.newTab()
        guard let page = session.selectedID else { return ["no start page"] }
        onRequest = { [weak session] in session?.observeFocusedWindow(old) }
        do {
            let windows = try await session.launchCandidates(for: app, from: page, alreadyRunning: true)
            guard windows.count == 1, windows[0].title == "New helper window",
                  let number = WindowAccess.windowID(of: windows[0].element), !helper.windows.contains(Int(number)),
                  WindowAccess.applicationWindows(app)?.count == existing.count + 1, session.selectedID == page
            else { return ["launch returned \(windows.count) candidates instead of creating one new window"] }
            session.observeFocusedWindow(old)
            guard session.selectedID == oldTab else { return ["old window focus still suppressed after launch"] }
            return []
        } catch { return ["new window in running app: \(error.localizedDescription)"] }
    }

    /// Child process for `runFrontWindowOnlyActivationChecks`: an inactive app with three windows.
    static func runActivationHelper(_ application: NSApplication, resizable: Bool = false) {
        // Regular apps activate themselves at launch; becoming regular afterwards keeps this one in the background.
        application.setActivationPolicy(.accessory)
        DispatchQueue.main.async { application.setActivationPolicy(.regular) }
        let target = NewWindowTarget()
        let menu = NSMenu()
        menu.addItem(withTitle: "Smoke", action: nil, keyEquivalent: "").submenu = NSMenu(title: "Smoke")
        let file = NSMenu(title: "File")
        menu.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file
        let create = file.addItem(
            withTitle: "New Window",
            action: #selector(NewWindowTarget.newWindow(_:)),
            keyEquivalent: "n")
        create.target = target
        application.mainMenu = menu
        let windows = (0 ..< 3).map { index in
            let window = NSWindow(
                contentRect: NSRect(x: 300 + index * 40, y: 300 + index * 40, width: 300, height: 200),
                styleMask: resizable ? [.titled, .resizable, .miniaturizable] : [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            if resizable { window.collectionBehavior.insert(.fullScreenPrimary) }
            window.orderFrontRegardless()
            return window
        }
        print(
            ([ProcessInfo.processInfo.processIdentifier] + windows.map { Int32($0.windowNumber) })
                .map(String.init).joined(separator: " "))
        fflush(stdout)
        DispatchQueue.global().async {
            defer { withExtendedLifetime(target) {} }
            while let line = readLine() {
                if line.hasPrefix("raise "), let index = Int(line.dropFirst(6)) {
                    DispatchQueue.main.async { windows[index].orderFrontRegardless() }
                } else if line.hasPrefix("zoom "), let index = Int(line.dropFirst(5)) {
                    DispatchQueue.main.async { windows[index].zoom(nil) }
                } else if line.hasPrefix("minimize "), let index = Int(line.dropFirst(9)) {
                    DispatchQueue.main.async { windows[index].miniaturize(nil) }
                } else if line.hasPrefix("fullscreen "), let index = Int(line.dropFirst(11)) {
                    DispatchQueue.main.async { windows[index].toggleFullScreen(nil) }
                } else if line.hasPrefix("yield "), let pid = pid_t(line.dropFirst(6)) {
                    // Stands in for the Dock, which lets the app whose Dock menu item was chosen activate itself.
                    DispatchQueue.main.async {
                        if #available(macOS 14, *), let target = NSRunningApplication(processIdentifier: pid) {
                            application.yieldActivation(to: target)
                        }
                    }
                } else if line.hasPrefix("activate "), let pid = pid_t(line.dropFirst(9)) {
                    // Like the Dock, activates the app with all of its windows.
                    DispatchQueue.main.async {
                        if #available(macOS 14, *), let target = NSRunningApplication(processIdentifier: pid) {
                            _ = target.activate(from: .current, options: [.activateAllWindows])
                        }
                    }
                }
            }
            exit(0)
        }
    }

    /// A running `runActivationHelper` process, which can take activation away from the harness.
    final class ActivationHelperProcess {
        let pid: pid_t
        let windows: [Int]
        private let process: Process
        private let input: Pipe

        /// Fails with a description when the helper cannot be launched.
        static func launch(resizable: Bool = false) -> Result<ActivationHelperProcess, SmokeFailure> {
            guard let executable = Bundle.main.executableURL else {
                return .failure(.init("activation helper could not find its executable"))
            }
            let process = Process()
            let output = Pipe()
            let input = Pipe()
            process.executableURL = executable
            process.arguments = [resizable ? "--resizable-helper" : "--activation-helper"]
            process.standardOutput = output
            process.standardInput = input
            do { try process.run() } catch {
                return .failure(.init("activation helper failed to launch: \(error.localizedDescription)"))
            }
            let fields = (String(data: output.fileHandleForReading.availableData, encoding: .utf8) ?? "")
                .split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            guard fields.count == 4 else {
                process.terminate()
                process.waitUntilExit()
                return .failure(.init("activation helper did not report its windows"))
            }
            return .success(
                ActivationHelperProcess(
                    process: process, input: input, pid: pid_t(fields[0]), windows: Array(fields[1...])))
        }

        private init(process: Process, input: Pipe, pid: pid_t, windows: [Int]) {
            self.process = process
            self.input = input
            self.pid = pid
            self.windows = windows
        }

        func send(_ command: String) { input.fileHandleForWriting.write(Data("\(command)\n".utf8)) }

        func terminate() {
            process.terminate()
            process.waitUntilExit()
        }
    }

    struct SmokeFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Uses real windows of another process and changes the active application, so it runs in its own
    /// harness process (`--activation-only`) that is not the active app when it launches the helper.
    static func runFrontWindowOnlyActivationChecks() -> [String] {
        let helper: ActivationHelperProcess
        switch ActivationHelperProcess.launch() {
        case .success(let launched): helper = launched
        case .failure(let failure): return [failure.message]
        }
        defer { helper.terminate() }
        let helperPID = helper.pid
        let helperWindows = helper.windows
        func wait(_ seconds: TimeInterval, until condition: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }
        func stackIndex(_ number: Int) -> Int {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            return list.firstIndex { $0[kCGWindowNumber as String] as? Int == number } ?? Int.max
        }
        wait(0.5)
        let otherApplication = NSWindow(
            contentRect: NSRect(x: 250, y: 250, width: 500, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        otherApplication.isReleasedWhenClosed = false
        otherApplication.orderFrontRegardless()
        defer { otherApplication.close() }
        let other = otherApplication.windowNumber
        wait(0.3)
        // The registered window is raised within its inactive app before the app is activated.
        helper.send("raise 2")
        wait(2) { stackIndex(helperWindows[2]) < stackIndex(other) }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == helperPID
            || helperWindows[..<2].contains(where: { stackIndex($0) < stackIndex(other) })
        {
            return [
                "activation fixture did not start with unregistered windows behind another app "
                    + "(helper frontmost: \(NSWorkspace.shared.frontmostApplication?.processIdentifier == helperPID), "
                    + "stack: \(helperWindows.map(stackIndex)) vs \(stackIndex(other)))"
            ]
        }
        guard WindowAccess.activateFrontWindowOnly(helperPID) else {
            return ["front-window-only app activation is unavailable, so tab focus would raise every app window"]
        }
        wait(2) { NSWorkspace.shared.frontmostApplication?.processIdentifier == helperPID }
        wait(0.4)
        var failures: [String] = []
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != helperPID {
            failures.append("front-window-only activation did not make the window's app frontmost")
        }
        if stackIndex(helperWindows[2]) > stackIndex(other) {
            failures.append("front-window-only activation did not keep the registered window in front")
        }
        if helperWindows[..<2].contains(where: { stackIndex($0) < stackIndex(other) }) {
            failures.append("activating a tab's app brought its unregistered windows above other apps")
        }
        return failures
    }

    /// A tab whose window stops answering must not take over another workspace's window of the same app,
    /// which would leave both workspaces managing it and make it impossible to move.
    static func runReresolveChecks() -> [String] {
        var failures: [String] = []
        let (renamed, renameModel) = fixture(registering: [0], windowCount: 1)
        renameModel.titles[0] = "Updated title"
        renamed.pruneClosedWindows()
        if renamed.windows[0].candidate.title != "Updated title" || renameModel.changeCount != 1 {
            failures.append("a changed window title was not reflected in the session")
        }
        renamed.pruneClosedWindows()
        if renameModel.changeCount != 1 {
            failures.append("an unchanged window title triggered another session update")
        }
        renameModel.titles[0] = ""
        renamed.pruneClosedWindows()
        if !renamed.windows[0].candidate.title.isEmpty || renameModel.changeCount != 2 {
            failures.append("a removed window title was not reflected in the session")
        }

        let model = Model(windowCount: 3)
        let (first, _) = fixture(registering: [0], sharedModel: model)
        let (second, _) = fixture(registering: [1], sharedModel: model)
        first.isClaimedElsewhere = { second.contains($0) }
        second.isClaimedElsewhere = { first.contains($0) }
        func manages(_ session: WindowSession, _ index: Int) -> Bool {
            session.windows.contains { CFEqual($0.candidate.element, model.windows[index].element) }
        }

        // A busy app (e.g. VS Code timing out) still owns the window.
        model.listedWindows = [1, 2]
        model.probeErrors = [0: .cannotComplete]
        first.pruneClosedWindows()
        first.pruneClosedWindows()
        if !manages(first, 0) || first.windows.count != 1 {
            failures.append("a tab whose window was busy was re-bound or dropped")
        }

        // The window closed while the app's only other window belongs to another workspace.
        model.listedWindows = [1]
        model.probeErrors = [0: .invalidUIElement]
        first.pruneClosedWindows()
        if manages(first, 1) {
            failures.append("a tab whose window closed took over another workspace's window")
        }
        first.pruneClosedWindows()
        if !first.windows.isEmpty {
            failures.append("a tab whose window closed was not removed")
        }
        if !second.transferWindow(second.windows[0].id, to: first) || !manages(first, 1) || !second.windows.isEmpty {
            failures.append("a window could not be moved to a workspace whose closed tab had the same app")
        }

        // A stale element of a window that still exists is found again among unclaimed windows.
        let (third, _) = fixture(registering: [0], sharedModel: model)
        third.isClaimedElsewhere = { first.contains($0) }
        model.listedWindows = [1, 2]
        third.pruneClosedWindows()
        if !manages(third, 2) || third.windows.count != 1 {
            failures.append("a tab with a stale element was not re-resolved to its app's unclaimed window")
        }
        return failures
    }

    static func runOutsideTabDropChecks() -> [String] {
        var failures: [String] = []
        let suite = "WindowDockOutsideDropSmoke-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return ["could not create isolated settings"] }
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TabOutsideDropSettings(defaults: defaults)
        if settings.action != .release { failures.append("outside drop did not default to release") }
        let menu = settings.menu()
        if menu.items.count != 3 || menu.items.map(\.state) != [.on, .off, .off] {
            failures.append("outside drop settings menu did not show three options with release selected")
        }
        for (index, action) in TabOutsideDropAction.allCases.enumerated() where menu.items.indices.contains(index) {
            let item = menu.items[index]
            if let selector = item.action { NSApp.sendAction(selector, to: item.target, from: item) }
            if TabOutsideDropSettings(defaults: defaults).action != action
                || settings.menu().items[index].state != .on
            {
                failures.append("outside drop setting did not persist or show selection: \(action)")
            }
        }

        let model = Model(windowCount: 1)
        let source = WorkspaceController(name: "Outside source", access: access(for: model))
        var created: [WorkspaceController] = []
        defer {
            for controller in [source] + created {
                controller.hideTabTransferTargets()
                controller.quitting = true
                controller.window.orderOut(nil)
            }
        }
        guard let chrome = source.window.contentView as? WorkspaceChromeView else {
            return failures + ["outside drop fixture has no chrome"]
        }
        source.window.orderFrontRegardless()
        let candidate = WindowCandidate(element: model.windows[0].element, application: .current, title: "Outside")
        source.session.add(candidate)
        let originalID = source.session.windows[0].id
        let transfer = WorkspaceTabTransfer { [source] + created }
        var action: TabOutsideDropAction = .nothing
        var releases = 0
        var transfers = 0
        var creationPoint: NSPoint?
        var duplicateOnCreate = false
        var discards = 0
        transfer.outsideDropAction = { action }
        transfer.onRelease = { _ in releases += 1 }
        transfer.onTransfer = { _, _ in transfers += 1 }
        transfer.createWorkspace = { point in
            creationPoint = point
            let controller = WorkspaceController(name: "Created", access: access(for: model))
            created.append(controller)
            transfer.attach(controller)
            controller.window.orderFrontRegardless()
            if duplicateOnCreate { controller.session.add(candidate) }
            return controller
        }
        transfer.discardWorkspace = { controller in
            discards += 1
            controller.window.orderOut(nil)
        }
        transfer.attach(source)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let outside = NSPoint(x: source.window.frame.maxX + 500, y: source.window.frame.maxY + 500)
        func drag(to point: NSPoint? = nil, cancelled: Bool = false) {
            chrome.layoutSubtreeIfNeeded()
            guard let button = (chrome.tabs.arrangedSubviews.first as? WorkspaceTabGroup)?.arrangedSubviews.first
                as? WorkspaceTabButton else {
                failures.append("outside drop fixture could not find a tab")
                return
            }
            let token = UUID().uuidString
            board.clearContents()
            board.setString(token, forType: workspaceTabDragType)
            button.onDragBegin?(button, token, NSPoint(x: 10, y: 10), NSImage(size: NSSize(width: 100, height: 28)))
            button.onDragMove?(board, point ?? outside)
            button.onDragEnd?(board, point ?? outside, cancelled)
        }
        drag()
        if source.session.windows.map(\.id) != [originalID] || !created.isEmpty || releases != 0 {
            failures.append("do-nothing outside drop changed the workspace")
        }
        action = .newWorkspace
        drag(cancelled: true)
        if source.session.windows.map(\.id) != [originalID] || !created.isEmpty {
            failures.append("cancelled outside drop created a workspace or moved the tab")
        }
        drag()
        if created.count != 1 || creationPoint != outside || transfers != 1 || !source.session.windows.isEmpty
            || created.first?.session.windows.first?.id != originalID
            || created.first?.session.windows.first?.originalFrame != model.windows[0].originalFrame
        {
            failures.append("outside drop did not transfer the tab to a new workspace with its original state")
        }
        if let destination = created.first {
            _ = destination.session.transferWindow(originalID, to: source.session)
            destination.window.orderOut(nil)
        }
        duplicateOnCreate = true
        drag()
        if discards != 1 || transfers != 1 || source.session.windows.map(\.id) != [originalID] {
            failures.append("a failed new-workspace transfer did not retain the source tab and discard the workspace")
        }
        action = .release
        drag()
        if !source.session.windows.isEmpty || releases != 1 || model.windows[0].frame != model.windows[0].originalFrame
            || !model.closeRequests.isEmpty
        {
            failures.append("outside release did not restore and release the window")
        }
        source.session.add(candidate)
        source.session.closesWindowsOnRelease = true
        model.onClose = { _ in throw InjectedFailure() }
        let closeID = source.session.windows[0].id
        drag()
        if model.closeRequests != [0] || source.session.windows.map(\.id) != [closeID] || releases != 1 {
            failures.append("outside release ignored the close setting or removed a tab whose close failed")
        }
        source.session.closesWindowsOnRelease = false
        duplicateOnCreate = false
        let panePoint = NSPoint(x: source.window.frame.midX, y: source.window.frame.midY)
        action = .nothing
        drag(to: panePoint)
        if source.session.windows.map(\.id) != [closeID] || created.count != 2 {
            failures.append("do-nothing over the only pane changed the workspace")
        }
        action = .newWorkspace
        drag(to: panePoint, cancelled: true)
        if source.session.windows.map(\.id) != [closeID] || created.count != 2 {
            failures.append("cancelling over the only pane changed the workspace")
        }
        drag(to: panePoint)
        if created.count != 3 || creationPoint != panePoint || transfers != 2
            || !source.session.windows.isEmpty || created.last?.session.windows.first?.id != closeID
        {
            failures.append("dropping a tab over the only pane did not create a workspace")
        }
        if let destination = created.last, destination.session.windows.contains(where: { $0.id == closeID }) {
            _ = destination.session.transferWindow(closeID, to: source.session)
            destination.window.orderOut(nil)
        }
        source.window.orderFrontRegardless()
        source.session.setSplit(true)
        chrome.layoutSubtreeIfNeeded()
        if chrome.gridAreas.count == 2 {
            let pane = chrome.gridAreas[1]
            let splitPoint = source.window.convertPoint(
                toScreen: pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil))
            action = .release
            drag(to: splitPoint)
            if source.session.cells[1] != closeID || releases != 1 {
                failures.append("dropping in a split pane did not move the tab within the workspace")
            }
        } else {
            failures.append("could not create split pane fixture")
        }
        source.session.setSplit(false)
        drag(to: panePoint)
        if !source.session.windows.isEmpty || releases != 2 {
            failures.append("dropping over the only pane did not release the tab")
        }
        return failures
    }

    static func runTabTransferRevealChecks() -> [String] {
        let model = Model(windowCount: 3)
        let source = WorkspaceController(name: "Reveal source", access: access(for: model))
        let destination = WorkspaceController(name: "Reveal destination", access: access(for: model))
        defer {
            for controller in [source, destination] {
                controller.hideTabTransferTargets()
                controller.quitting = true
                controller.window.orderOut(nil)
            }
        }
        guard let visible = NSScreen.main?.visibleFrame,
              let chrome = source.window.contentView as? WorkspaceChromeView,
              let destinationChrome = destination.window.contentView as? WorkspaceChromeView
        else {
            return ["tab reveal fixture could not find its screen or content"]
        }
        source.window.setFrame(
            NSRect(x: visible.minX + 40, y: visible.minY + 40, width: 700, height: 500), display: true)
        destination.window.setFrame(source.window.frame.offsetBy(dx: 400, dy: 100), display: true)
        source.session.add(WindowCandidate(element: model.windows[0].element, application: .current, title: "Moved"))
        source.session.add(WindowCandidate(element: model.windows[1].element, application: .current, title: "Stays"))
        destination.session.add(
            WindowCandidate(element: model.windows[2].element, application: .current, title: "Destination"))
        destination.window.orderFrontRegardless()
        source.window.orderFrontRegardless()
        chrome.layoutSubtreeIfNeeded()
        destinationChrome.layoutSubtreeIfNeeded()
        let sourceFrame = source.window.frame
        let destinationFrame = destination.window.frame
        let sourceOnly = NSPoint(x: sourceFrame.minX + 60, y: sourceFrame.minY + 60)
        let destinationOnly = NSPoint(x: destinationFrame.maxX - 60, y: destinationFrame.midY)
        let overlap = NSPoint(x: destinationFrame.minX + 60, y: destinationFrame.minY + 60)
        guard !destinationFrame.contains(sourceOnly), !sourceFrame.contains(destinationOnly),
              sourceFrame.contains(overlap), destinationFrame.contains(overlap), !source.tabRowContains(overlap)
        else {
            return ["tab reveal fixture could not place overlapping workspaces: \(sourceFrame) \(destinationFrame)"]
        }

        let transfer = WorkspaceTabTransfer { [source, destination] }
        var transfers: [(WorkspaceController, WorkspaceController)] = []
        transfer.onTransfer = { transfers.append(($0, $1)) }
        transfer.attach(source)
        transfer.attach(destination)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var button: WorkspaceTabButton?
        func begin() {
            chrome.layoutSubtreeIfNeeded()
            button =
                (chrome.tabs.arrangedSubviews.first as? WorkspaceTabGroup)?.arrangedSubviews.first
                    as? WorkspaceTabButton
            let token = UUID().uuidString
            board.clearContents()
            board.setString(token, forType: workspaceTabDragType)
            button?.onDragBegin?(button!, token, NSPoint(x: 10, y: 10), NSImage(size: NSSize(width: 100, height: 28)))
        }
        func move(_ point: NSPoint) { button?.onDragMove?(board, point) }
        func end(_ point: NSPoint, cancelled: Bool) { button?.onDragEnd?(board, point, cancelled) }
        func inFront(_ front: WorkspaceController, of back: WorkspaceController) -> Bool {
            let order = NSApp.orderedWindows
            guard let first = order.firstIndex(where: { $0 === front.window }),
                  let second = order.firstIndex(where: { $0 === back.window })
            else { return false }
            return first < second
        }
        func modelIndex(of id: UUID?, in session: WindowSession) -> Int? {
            guard let window = session.windows.first(where: { $0.id == id }) else { return nil }
            return model.windows.firstIndex { CFEqual($0.element, window.candidate.element) }
        }
        let sourceSelected = modelIndex(of: source.session.selectedID, in: source.session)
        var failures: [String] = []

        begin()
        guard button != nil, transfer.isActive else { return ["tab reveal fixture could not start a tab drag"] }
        move(overlap)
        if !model.focusedWindows.isEmpty || !inFront(source, of: destination)
            || destinationChrome.windowDropPanel?.isVisible == true
        {
            failures.append(
                "a workspace hidden behind the tab's own workspace took the tab where they overlap: "
                    + "focused \(model.focusedWindows), source front \(inFront(source, of: destination)), "
                    + "marker \(destinationChrome.windowDropPanel?.isVisible == true)")
        }
        move(destinationOnly)
        if !inFront(destination, of: source) || model.focusedWindows != [2]
            || destinationChrome.windowDropPanel?.isVisible != true
        {
            failures.append(
                "a tab dragged over a workspace behind did not bring it and its windows forward: "
                    + "front \(inFront(destination, of: source)), focused \(model.focusedWindows)")
        }
        move(overlap)
        if !inFront(destination, of: source) || model.focusedWindows != [2]
            || destinationChrome.windowDropPanel?.isVisible != true
        {
            failures.append(
                "the workspace brought forward lost the overlap to the one behind it: \(model.focusedWindows)")
        }
        move(sourceOnly)
        if !inFront(source, of: destination) || model.focusedWindows.count < 2
            || model.focusedWindows.last != sourceSelected
        {
            failures.append("moving the tab back did not bring its own workspace forward: \(model.focusedWindows)")
        }
        move(destinationOnly)
        model.focusedWindows.removeAll()
        end(destinationOnly, cancelled: true)
        if transfer.isActive || !inFront(source, of: destination) || model.focusedWindows.last != sourceSelected
            || !transfers.isEmpty || source.session.windows.count != 2
            || destinationChrome.windowDropPanel?.isVisible == true
        {
            failures.append("a cancelled tab drag left the workspace it passed over in front: \(model.focusedWindows)")
        }

        model.focusedWindows.removeAll()
        begin()
        move(destinationOnly)
        end(destinationOnly, cancelled: false)
        if transfer.isActive || transfers.count != 1 || transfers.first?.0 !== source
            || transfers.first?.1 !== destination
            || modelIndex(of: destination.session.selectedID, in: destination.session) != 0
            || source.session.windows.count != 1
        {
            failures.append("dropping a tab on another workspace did not move it there")
        }
        if !inFront(destination, of: source) || model.focusedWindows.last != 0 {
            failures.append(
                "the workspace that received a tab was not left in front with the moved window: \(model.focusedWindows)")
        }

        // Both workspaces have a pane at the overlap; moving the pointer there must not raise the source's overlay.
        source.session.setSplit(true)
        destination.session.setSplit(true)
        begin()
        move(sourceOnly)
        move(destinationOnly)
        move(overlap)
        func highlighted(in chrome: WorkspaceChromeView) -> [NSView] {
            chrome.gridAreas.filter { $0.subviews.contains { $0 is WorkspaceTabDropOverlay && !$0.isHidden } }
        }
        let expected = destinationChrome.gridAreas.filter {
            destination.window.convertToScreen($0.convert($0.bounds, to: nil)).contains(overlap)
        }
        if !highlighted(in: chrome).isEmpty || expected.count != 1 || highlighted(in: destinationChrome) != expected {
            failures.append("overlapping split workspaces did not highlight just the frontmost drop pane")
        }
        end(overlap, cancelled: true)
        if !highlighted(in: destinationChrome).isEmpty || !highlighted(in: chrome).isEmpty {
            failures.append("cancelling a tab transfer left a pane highlighted")
        }
        return failures
    }

    /// A drop does not activate WindowDock, which would bring every workspace forward; it only makes the destination
    /// key. Whether or not WindowDock was active at the drop, the destination must be the workspace that comes back
    /// when WindowDock is activated again, e.g. with Cmd+Tab. Changes the active application, so it runs in the
    /// `--activation-only` harness.
    static func runTabTransferKeyChecks() -> [String] {
        let model = Model(windowCount: 4)
        let source = WorkspaceController(name: "Key source", access: access(for: model))
        let destination = WorkspaceController(name: "Key destination", access: access(for: model))
        defer {
            for controller in [source, destination] {
                controller.hideTabTransferTargets()
                controller.quitting = true
                controller.window.orderOut(nil)
            }
        }
        func settle(_ seconds: TimeInterval = 0.5, until condition: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline {
                if let event = NSApp.nextEvent(
                    matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
                {
                    NSApp.sendEvent(event)
                }
            }
        }
        guard let visible = NSScreen.main?.visibleFrame,
              let chrome = source.window.contentView as? WorkspaceChromeView
        else {
            return ["tab drop key fixture could not find its screen or content"]
        }
        source.window.setFrame(
            NSRect(x: visible.minX + 40, y: visible.minY + 40, width: 500, height: 400), display: true)
        destination.window.setFrame(source.window.frame.offsetBy(dx: 560, dy: 0), display: true)
        source.session.add(
            (0 ..< 3).map {
                WindowCandidate(element: model.windows[$0].element, application: .current, title: "Moved \($0)")
            })
        destination.session.add(
            WindowCandidate(element: model.windows[3].element, application: .current, title: "Destination"))
        let dropPoint = NSPoint(x: destination.window.frame.midX, y: destination.window.frame.midY)
        let transfer = WorkspaceTabTransfer { [source, destination] }
        transfer.attach(source)
        transfer.attach(destination)
        let activation = WorkspaceActivation { [source, destination] }
        activation.latestClick = { nil }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let helper: ActivationHelperProcess
        switch ActivationHelperProcess.launch() {
        case .success(let launched): helper = launched
        case .failure(let failure): return [failure.message]
        }
        defer { helper.terminate() }
        settle(0.5)
        let pid = ProcessInfo.processInfo.processIdentifier
        // NSApp.deactivate() does not give up activation, so the helper takes it.
        func setActive(_ active: Bool) -> Bool {
            if active, !NSApp.isActive {
                helper.send("yield \(pid)")
                settle(0.3)
                NSApp.activate(ignoringOtherApps: true)
                settle(2) { NSApp.isActive }
            } else if !active, NSApp.isActive {
                _ = WindowAccess.activateFrontWindowOnly(helper.pid)
                settle(2) { !NSApp.isActive }
            }
            return NSApp.isActive == active
        }
        func inFront(_ front: WorkspaceController, of back: WorkspaceController) -> Bool {
            let order = NSApp.orderedWindows
            guard let first = order.firstIndex(where: { $0 === front.window }),
                  let second = order.firstIndex(where: { $0 === back.window })
            else { return false }
            return first < second
        }

        var failures: [String] = []
        for activeAtDrop in [true, false] {
            let state = activeAtDrop ? "active" : "inactive"
            guard setActive(true) else {
                failures.append("tab drop key fixture could not activate WindowDock")
                continue
            }
            destination.window.orderFrontRegardless()
            source.window.makeKeyAndOrderFront(nil)
            settle(2) { source.window.isKeyWindow }
            guard source.window.isKeyWindow, setActive(activeAtDrop) else {
                failures.append("tab drop key fixture could not make the source key while WindowDock was \(state)")
                continue
            }
            settle(0.3)
            chrome.layoutSubtreeIfNeeded()
            guard
                let button = (chrome.tabs.arrangedSubviews.first as? WorkspaceTabGroup)?
                .arrangedSubviews.first as? WorkspaceTabButton
            else {
                failures.append("tab drop key fixture could not find a tab to drag")
                continue
            }
            let count = source.session.windows.count
            let token = UUID().uuidString
            board.clearContents()
            board.setString(token, forType: workspaceTabDragType)
            button.onDragBegin?(button, token, NSPoint(x: 10, y: 10), NSImage(size: NSSize(width: 100, height: 28)))
            button.onDragMove?(board, dropPoint)
            button.onDragEnd?(board, dropPoint, false)
            guard source.session.windows.count == count - 1 else {
                failures.append("tab drop key fixture could not drop a tab while WindowDock was \(state)")
                continue
            }
            let operations = model.operations.count
            settle()
            if model.operations.dropFirst(operations).contains(where: { if case .raise = $0 { true } else { false } }) {
                failures.append(
                    "a tab dropped while WindowDock was \(state) raised the workspace again after its windows "
                        + "were handed focus, which can order the frame above them")
            }
            guard setActive(false), setActive(true) else {
                failures.append("tab drop key fixture could not switch WindowDock away and back")
                continue
            }
            activation.applicationDidBecomeActive()
            settle()
            if activation.activeController !== destination || !inFront(destination, of: source) {
                failures.append(
                    "after a tab was dropped while WindowDock was \(state), activating WindowDock again "
                        + "brought back the workspace the tab came from")
            }
        }
        return failures
    }

    /// Releasing a tab moves its window back to where it was. Its pane must stop showing through the workspace first,
    /// or what is behind the workspace shows there until the tab is gone; the other panes stay shown.
    private static func runRemovalApertureChecks() -> [String] {
        var failures: [String] = []
        func shownWhileRestoring(_ index: Int, in session: WindowSession, _ model: Model) -> (Bool, Set<UUID>?) {
            guard
                let id = session.windows.first(where: {
                    CFEqual($0.candidate.element, model.windows[index].element)
                })?.id
            else { return (false, nil) }
            var shown: Set<UUID>?
            model.onSetFrame = { moved, frame in
                if moved == index, frame == model.windows[index].originalFrame { shown = Set(model.paneFrames.keys) }
            }
            defer { model.onSetFrame = nil }
            return (session.remove(id), shown)
        }

        let (single, singleModel) = fixture(registering: [0])
        guard singleModel.paneFrames.count == 1 else { return ["removal aperture fixture did not show its tab"] }
        let (removedLast, shownForLast) = shownWhileRestoring(0, in: single, singleModel)
        if !removedLast || shownForLast != [] || !singleModel.paneFrames.isEmpty {
            failures.append(
                "removing the last tab moved its window away while the workspace still showed through to it: "
                    + "\(shownForLast.map { "\($0.count) panes" } ?? "not restored")")
        }

        let (split, splitModel) = fixture(registering: [0, 1, 3])
        split.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        guard let left = split.cells[0], let right = split.cells[1], splitModel.paneFrames.count == 2,
              let leftIndex = splitModel.windows.firstIndex(where: { window in
                  split.windows.contains { $0.id == left && CFEqual($0.candidate.element, window.element) }
              })
        else { return failures + ["removal aperture fixture could not show two panes"] }
        let (removedPane, shownForPane) = shownWhileRestoring(leftIndex, in: split, splitModel)
        if !removedPane || shownForPane != [right] {
            failures.append(
                "removing a split pane's tab did not stop showing only that pane before moving its window: "
                    +
                    "\(shownForPane.map { $0.contains(left) ? "still shown" : "\($0.count) panes shown" } ?? "not restored")")
        }

        let (failing, failingModel) = fixture(registering: [0])
        failingModel.failedMinimizations.insert(0)
        let (removedFailing, _) = shownWhileRestoring(0, in: failing, failingModel)
        if removedFailing || failing.windows.count != 1
            || failing.selectedID.map({ failingModel.paneFrames[$0] }) != .some(failingModel.target)
        {
            failures.append("a tab whose window could not be restored was not shown in its pane again")
        }
        return failures
    }

    static func runEmptyWorkspaceDeletionChecks() -> [String] {
        var failures: [String] = []
        var controllers: [WorkspaceController] = []
        defer {
            for controller in controllers {
                controller.quitting = true
                controller.window.orderOut(nil)
                SavedLayout.remove(named: controller.name)
            }
        }
        func makeController(_ name: String, model: Model) -> WorkspaceController {
            let controller = WorkspaceController(name: "\(name)-\(UUID())", access: access(for: model))
            controller.returnsDisplacedWindows = false
            controllers.append(controller)
            return controller
        }
        func candidate(_ model: Model, _ index: Int = 0) -> WindowCandidate {
            WindowCandidate(element: model.windows[index].element, application: .current, title: "Empty probe \(index)")
        }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }

        let model = Model(windowCount: 2)
        let controller = makeController("Empty policy", model: model)
        var deletions = 0
        controller.onAutoDelete = { _ in deletions += 1 }
        controller.session.add(candidate(model))
        controller.removeSelected()
        SavedLayout.upsert([SavedWorkspace(name: controller.name, windows: [])])
        settle()
        if deletions != 0 || !SavedLayout.load().contains(where: { $0.name == controller.name }) {
            failures.append("empty-workspace deletion was enabled by default")
        }

        controller.deletesWhenEmpty = true
        controller.session.add(candidate(model))
        settle()
        if deletions != 0 { failures.append("a refilled workspace was deleted by a queued empty-state check") }
        controller.session.add(candidate(model, 1))
        controller.removeSelected()
        settle()
        if deletions != 0 { failures.append("a workspace was deleted while it still had a tab") }
        controller.removeSelected()
        if deletions != 0 { failures.append("empty-workspace deletion ran before tab removal completed") }
        controller.deletesWhenEmpty = false
        settle()
        if deletions != 0 { failures.append("disabling auto-delete did not cancel its queued deletion") }
        controller.deletesWhenEmpty = true
        settle()
        if deletions != 1 || !controller.session.windows.isEmpty
            || SavedLayout.load().contains(where: { $0.name == controller.name })
        {
            failures.append("an emptied workspace was not deleted when the option was enabled")
        }
        let previousDeletions = deletions
        controller.session.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        settle()
        if deletions != previousDeletions { failures.append("an empty workspace requested deletion more than once") }

        let transferModel = Model(windowCount: 1)
        let source = makeController("Empty transfer source", model: transferModel)
        let destination = makeController("Empty transfer destination", model: transferModel)
        source.deletesWhenEmpty = true
        destination.deletesWhenEmpty = true
        source.window.orderFrontRegardless()
        destination.window.orderFrontRegardless()
        var transferFinished = false
        var sourceDeleted = false
        source.onAutoDelete = { _ in
            if !transferFinished { failures.append("the source was deleted before tab transfer finished") }
            sourceDeleted = true
        }
        destination
            .onAutoDelete = { _ in failures.append("a fresh empty workspace or the transfer destination was deleted") }
        destination.session.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        settle()
        source.session.add(candidate(transferModel))
        let transferred = source.session.windows[0]
        guard source.session.transferWindow(transferred.id, to: destination.session) else {
            return failures + ["empty-workspace fixture could not transfer its last tab"]
        }
        SavedLayout.upsert([
            SavedWorkspace(name: source.name, windows: []),
            SavedWorkspace(name: destination.name, windows: [
                SavedWindow(bundleID: "test.empty-workspace", title: "Transferred", frame: transferred.originalFrame)
            ]),
        ])
        transferFinished = true
        settle()
        if !sourceDeleted || source.window.isVisible || !destination.window.isVisible
            || destination.session.windows.first?.id != transferred.id
            || destination.session.windows.first?.originalFrame != transferred.originalFrame
            || !transferModel.closeRequests.isEmpty
            || SavedLayout.load().contains(where: { $0.name == source.name })
            || !SavedLayout.load().contains(where: { $0.name == destination.name && $0.windows.count == 1 })
        {
            failures.append("last-tab transfer did not delete only the source and preserve the transferred window")
        }

        let closingModel = Model(windowCount: 1)
        let closing = makeController("Empty after close", model: closingModel)
        closing.deletesWhenEmpty = true
        var closedDeletions = 0
        closing.onAutoDelete = { _ in closedDeletions += 1 }
        closing.session.add(candidate(closingModel))
        let id = closing.session.windows[0].id
        closingModel.failedMinimizations.insert(0)
        closing.session.remove(id, closeWindow: false)
        settle()
        if closedDeletions != 0 || closing.session.windows.isEmpty {
            failures.append("a failed release deleted the workspace or its last tab")
        }
        closingModel.failedMinimizations.removeAll()
        closingModel.listedWindows = [0]
        closing.session.remove(id, closeWindow: true)
        settle()
        if closedDeletions != 0 || closing.session.windows.isEmpty {
            failures.append("a close awaiting a save decision deleted the workspace")
        }
        closingModel.probeErrors[0] = .invalidUIElement
        closingModel.listedWindows = []
        closing.session.pruneClosedWindows()
        settle()
        if closedDeletions != 0 { failures.append("a single missing-window sample deleted the workspace") }
        closing.session.pruneClosedWindows()
        settle()
        if closedDeletions != 1 { failures.append("a workspace whose last window closed was not deleted") }

        destination.session.remove(transferred.id, closeWindow: false)
        destination.quitting = true
        settle()
        return failures
    }

    /// A registered app's new windows join their workspace in the background; windows that already existed,
    /// were released, belong elsewhere, are awaited by a launcher, or appeared while the workspace was paused don't.
    static func runAutoGroupChecks() -> [String] {
        var failures: [String] = []
        let bundleID = "test.autogroup"
        let model = Model(windowCount: 14)
        var client = access(for: model)
        client.isTrusted = { true }
        client.allWindowIDs = { _ in [] }
        var creationHandlers: [(AXUIElement) -> Void] = []
        client.observeWindowCreation = { _, handler in
            creationHandlers.append(handler)
            return NSObject()
        }
        var controllers: [WorkspaceController] = []
        let coordinator = AutoGroupCoordinator(access: client, controllers: { controllers })
        coordinator.runningApplications = { [.current] }
        coordinator.bundleIdentifier = { _ in bundleID }
        coordinator.readsWindowsInBackground = false
        var closed: [SavedWorkspace] = []
        var closedUpdates: [(name: String, ids: [String])] = []
        coordinator.closedWorkspaces = { closed }
        coordinator.updateClosedWorkspace = { closedUpdates.append(($0, $1)) }
        var saves = 0
        coordinator.save = { _ in saves += 1 }
        var confirmations: [AutoGroupConfirmation] = []
        var answer: Bool? = false
        coordinator.confirm = {
            confirmations.append($0)
            return answer
        }
        defer {
            coordinator.stop()
            for controller in controllers {
                controller.quitting = true
                controller.window.orderOut(nil)
            }
        }
        func makeController(_ name: String) -> WorkspaceController {
            let controller = WorkspaceController(name: "\(name) \(UUID())", access: client)
            controller.returnsDisplacedWindows = false
            controller.autoGrouping = coordinator
            controller.window.setFrame(NSRect(x: 160, y: 160, width: 900, height: 600), display: false)
            controllers.append(controller)
            return controller
        }
        func candidate(_ index: Int) -> WindowCandidate {
            WindowCandidate(element: model.windows[index].element, application: .current, title: "Auto \(index)")
        }
        func pump(_ seconds: TimeInterval = 1.2, until condition: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }
        func reportCreation(_ index: Int) {
            for handler in creationHandlers { handler(model.windows[index].element) }
        }
        func open(_ index: Int) {
            model.listedWindows.append(index)
            reportCreation(index)
        }
        func id(of index: Int, in controller: WorkspaceController) -> UUID? {
            controller.session.windows.first { CFEqual($0.candidate.element, model.windows[index].element) }?.id
        }
        func event(in window: NSWindow) -> NSEvent {
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func tabMenu(_ controller: WorkspaceController, _ tab: Int) -> NSMenu? {
            guard let chrome = controller.window.contentView as? WorkspaceChromeView else { return nil }
            chrome.layoutSubtreeIfNeeded()
            let menu = chrome.tabs.arrangedSubviews.compactMap {
                ($0 as? WorkspaceTabGroup)?.arrangedSubviews.first as? NSButton
            }.first { $0.tag == tab }?.menu(for: event(in: controller.window))
            menu?.update()
            return menu
        }
        let toggleTitle = L("「%@」の新しいウィンドウを自動でこのワークスペースに追加", NSRunningApplication.current.localizedName ?? L("対象アプリ"))
        func shows(_ text: String, in controller: WorkspaceController) -> Bool {
            func search(_ view: NSView) -> Bool {
                (view as? NSTextField)?.stringValue == text || view.subviews.contains(where: search)
            }
            return controller.window.contentView.map(search) ?? false
        }

        let first = makeController("Auto group")
        first.session.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        first.session.add(candidate(1))
        model.listedWindows = [0, 1]
        coordinator.register([bundleID], in: first)
        if confirmations.count != 1 || confirmations.first?.existingWindowCount != 1
            || confirmations.first?.moves.isEmpty != true
        {
            failures.append("registering did not offer the app's one unmanaged open window: \(confirmations)")
        }
        if first.autoGroupBundleIDs != [bundleID] || saves == 0 || creationHandlers.isEmpty {
            failures.append("registering did not save the rule and watch the app's new windows")
        }
        if first.session.windows.count != 1 {
            failures.append("declining to add open windows still added them")
        }

        reportCreation(0)
        pump()
        if first.session.windows.count != 1 { failures.append("a window open before registration was collected") }

        let selected = first.session.selectedID
        model.operations.removeAll()
        model.focusedWindows.removeAll()
        open(3)
        pump(2) { id(of: 3, in: first) != nil }
        if let added = id(of: 3, in: first) {
            if first.session.cells != [selected, added] {
                failures.append("a collected window did not fill the empty pane: \(first.session.cells)")
            }
            if first.session.selectedID != selected || model.operations.contains(.raise(3))
                || !model.focusedWindows.isEmpty
            {
                failures.append("a collected window was selected, raised or focused")
            }
            first.session.remove(added, closeWindow: false)
            pump(0.1)
            reportCreation(3)
            pump()
            if id(of: 3, in: first) != nil { failures.append("a released window was collected again") }
        } else {
            failures.append("a registered app's new window was not collected")
        }

        let other = makeController("Auto group other")
        other.session.add(candidate(4))
        open(4)
        pump()
        if id(of: 4, in: first) != nil || id(of: 4, in: other) == nil {
            failures.append("a window managed by another workspace was collected")
        }

        let reservation = first.session.reserveLaunch(of: bundleID)
        open(5)
        pump()
        if id(of: 5, in: first) != nil { failures.append("a window awaited by a new-tab launcher was collected") }
        first.session.releaseLaunch(reservation)

        model.windows[6].fullScreen = true
        open(2)
        open(6)
        pump()
        if id(of: 2, in: first) != nil || id(of: 6, in: first) != nil {
            failures.append("a new minimized or full-screen window was collected")
        }

        first.collectRestoration(SavedWorkspace(name: first.name, windows: []), excluding: []) { _ in }
        if !first.isRestoring || first.acceptsAutomaticWindows {
            failures.append("a restore prompt did not pause automatic grouping")
        }
        if let menu = tabMenu(first, 0) {
            if menu.item(withTitle: toggleTitle)?.isEnabled != false
                || menu.item(withTitle: L("別のアプリを選ぶ…"))?.isEnabled != false
            {
                failures.append("automatic grouping could be changed during a restore prompt")
            }
        } else {
            failures.append("auto-group fixture could not open a tab menu")
        }
        open(7)
        pump()
        if id(of: 7, in: first) != nil { failures.append("a window opened during a restore prompt was collected") }
        if let prompt = first.session.tabIDs.first(where: first.session.isStartPage) {
            first.session.remove(prompt, closeWindow: false)
        }
        pump(0.1)
        reportCreation(7)
        pump()
        if first.isRestoring || id(of: 7, in: first) != nil {
            failures.append("a window opened while paused was collected after resuming")
        }
        open(8)
        pump(2) { id(of: 8, in: first) != nil }
        if id(of: 8, in: first) == nil { failures.append("automatic grouping did not resume after a restore prompt") }

        let tabCount = first.session.windows.count
        let toggle = tabMenu(first, 0)?.item(withTitle: toggleTitle)
        if toggle?.state != .on || toggle?.isEnabled != true {
            failures.append("the tab menu did not show its app as collected")
        }
        if let toggle, let action = toggle.action { NSApp.sendAction(action, to: toggle.target, from: toggle) }
        if !first.autoGroupBundleIDs.isEmpty || first.session.windows.count != tabCount {
            failures.append("turning off collection from the tab menu did not keep the tabs and remove only the rule")
        }
        let off = tabMenu(first, 0)?.item(withTitle: toggleTitle)
        if off?.state != .off { failures.append("the tab menu still showed an unregistered app as collected") }
        confirmations.removeAll()
        answer = false
        if let off, let action = off.action { NSApp.sendAction(action, to: off.target, from: off) }
        if first.autoGroupBundleIDs != [bundleID] || confirmations.count != 1 {
            failures.append("turning on collection from the tab menu did not register the app")
        }
        first.session.newTab()
        if let blank = first.session.tabIDs.lastIndex(where: first.session.isStartPage) {
            let menu = tabMenu(first, blank)
            if menu?.item(withTitle: L("新しいウィンドウを自動で追加するアプリを選ぶ…"))?.isEnabled != true
                || menu?.items.contains(where: { $0.title.hasPrefix("「") }) == true
            {
                failures.append("a blank tab's menu did not offer only choosing apps to collect")
            }
            first.session.remove(first.session.tabIDs[blank], closeWindow: false)
        }

        model.listedWindows = [0, 1, 3, 8]
        let second = makeController("Auto group second")
        confirmations.removeAll()
        answer = true
        coordinator.register([bundleID], in: second)
        if confirmations.count != 1 || confirmations.first?.moves.map { $0.from } != [first.name]
            || confirmations.first?.existingWindowCount != 2
        {
            failures.append("moving an app to another workspace was not confirmed with its source and windows")
        }
        if !first.autoGroupBundleIDs.isEmpty || second.autoGroupBundleIDs != [bundleID]
            || id(of: 0, in: second) == nil || id(of: 3, in: second) == nil
        {
            failures.append("moving an app did not move its rule or add its open windows")
        }

        model.listedWindows.append(10)
        coordinator.applicationLaunched(.current)
        pump(2) { id(of: 10, in: second) != nil }
        if id(of: 10, in: second) == nil || id(of: 10, in: first) != nil {
            failures.append("a window that appeared while its app launched was not collected by the new owner")
        }

        let closedName = "Auto group closed \(UUID())"
        closed = [SavedWorkspace(name: closedName, windows: [], autoGroupBundleIDs: ["test.closed"])]
        confirmations.removeAll()
        coordinator.register(["test.closed"], in: second)
        if confirmations.first?.moves.map { $0.from } != [closedName] || closedUpdates.last?.name != closedName
            || closedUpdates.last?.ids != [] || !second.autoGroupBundleIDs.contains("test.closed")
            {
                failures.append("moving an app from a closed workspace did not update the saved workspace")
            }
        closed = [SavedWorkspace(name: closedName, windows: [], autoGroupBundleIDs: ["test.cancel"])]
        let updates = closedUpdates.count
        answer = nil
        coordinator.register(["test.cancel"], in: second)
        if second.autoGroupBundleIDs.contains("test.cancel") || closedUpdates.count != updates {
            failures.append("cancelling a move still changed the rules")
        }
        closed = []

        let failure = InjectedFailure().localizedDescription
        model.failedRegistrations = [11, 12]
        open(11)
        pump()
        if !shows(failure, in: second) { failures.append("a window that could not be collected was not reported") }
        second.showNotice(.information("Auto group probe"))
        open(12)
        pump()
        if shows(failure, in: second) { failures.append("a repeated collection failure was reported again") }

        coordinator.unregister(bundleID, from: second)
        let secondTabs = second.session.windows.count
        open(13)
        pump()
        if second.autoGroupBundleIDs != ["test.closed"] || second.session.windows.count != secondTabs
            || id(of: 13, in: first) != nil
        {
            failures.append("unregistering did not stop collection while keeping the tabs")
        }

        // The editor lists this workspace's apps checked, and saving changes several apps at once.
        let edited = makeController("Auto group edit")
        edited.autoGroupBundleIDs = ["test.edit.keep", "test.edit.drop"]
        let textEdit = "com.apple.TextEdit"
        second.autoGroupBundleIDs.append(textEdit)
        coordinator.recentApplications = { [textEdit: Date()] }
        let choices = coordinator.applicationChoices(for: edited)
        if choices.map(\.bundleID) != ["test.edit.keep", "test.edit.drop", textEdit]
            || choices.map(\.selected) != [true, true, false] || choices.last?.registeredIn != second.name
        {
            failures.append("the app editor did not list registered apps checked before other apps: \(choices)")
        }
        let list = AutoGroupApplicationList(choices: choices)
        list.checkbox(for: "test.edit.drop")?.state = .off
        list.checkbox(for: textEdit)?.state = .on
        list.add(["test.edit.new", "test.edit.keep"])
        if list.selectedBundleIDs != ["test.edit.keep", textEdit, "test.edit.new"] || list.frame.width < 300
            || list.frame.height > 340
        {
            failures.append("the app editor did not track checked and added apps: \(list.selectedBundleIDs)")
        }
        confirmations.removeAll()
        answer = nil
        if coordinator.setApplications(list.selectedBundleIDs, for: edited)
            || edited.autoGroupBundleIDs != ["test.edit.keep", "test.edit.drop"]
            || !second.autoGroupBundleIDs.contains(textEdit)
        {
            failures.append("cancelling the app editor's move still changed the rules")
        }
        answer = false
        if !coordinator.setApplications(list.selectedBundleIDs, for: edited)
            || Set(edited.autoGroupBundleIDs) != ["test.edit.keep", textEdit, "test.edit.new"]
            || second.autoGroupBundleIDs.contains(textEdit) || confirmations.count != 2
        {
            failures
                .append(
                    "saving the app editor did not add, move and remove apps together: \(edited.autoGroupBundleIDs)")
        }
        let dropped = edited.autoGroupBundleIDs.filter { $0 != "test.edit.keep" }
        if !coordinator.setApplications(["test.edit.keep"], for: edited) || edited
            .autoGroupBundleIDs != ["test.edit.keep"]
            || !shows(L("%@の自動追加を止めました。追加済みのタブは残ります。", AutoGroupApplication.names(dropped)), in: edited)
            || coordinator.setApplications(["test.edit.keep"], for: edited)
        {
            failures.append("unchecking several apps did not stop them together or reported an unchanged list")
        }
        let workspaceMenu = (edited.window.contentView as? WorkspaceChromeView)?.workspaceMenu?()
        workspaceMenu?.update()
        if workspaceMenu?.items.first(where: { $0.title == L("新しいウィンドウを自動で追加するアプリ…") })?.isEnabled != true {
            failures.append("the workspace menu did not offer editing the apps whose new windows are added")
        }

        let empty = makeController("Auto group empty")
        var autoDeleted = false
        empty.onAutoDelete = { _ in autoDeleted = true }
        empty.deletesWhenEmpty = true
        empty.autoGroupBundleIDs = ["test.keep"]
        empty.session.add(candidate(9))
        if let added = id(of: 9, in: empty) { empty.session.remove(added, closeWindow: false) }
        pump(0.2)
        if autoDeleted { failures.append("an empty workspace that collects apps was deleted") }
        empty.autoGroupBundleIDs = []
        pump(0.2)
        if !autoDeleted { failures.append("an empty workspace was not deleted after its last rule was removed") }

        let legacy = Data(#"[{"name":"Legacy","windows":[]}]"#.utf8)
        let saved = SavedWorkspace(name: "Rules", windows: [], autoGroupBundleIDs: ["a", "b"])
        if (try? JSONDecoder().decode([SavedWorkspace].self, from: legacy))?.first.map({ $0.autoGroupBundleIDs == nil })
            != true
            || (try? JSONDecoder().decode(SavedWorkspace.self, from: JSONEncoder().encode(saved)))?
            .autoGroupBundleIDs != ["a", "b"]
        {
            failures.append("saved workspaces did not keep or tolerate missing automatic-grouping rules")
        }
        return failures
    }

    static func runDisplacedWindowChecks() -> [String] {
        let (session, model) = fixture(registering: [0, 1, 3])
        session.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        func modelIndex(_ id: UUID?) -> Int? {
            guard let window = session.windows.first(where: { $0.id == id }) else { return nil }
            return model.windows.firstIndex { CFEqual($0.element, window.candidate.element) }
        }
        guard let left = modelIndex(session.cells[0]), let right = modelIndex(session.cells[1]),
              let hidden = [0, 1, 3].first(where: { $0 != left && $0 != right }),
              model.windows[left].frame == model.target, model.windows[right].frame == model.rightTarget
        else { return ["displaced window fixture could not show two panes"] }
        let fitted = model.windows.map(\.frame)
        var failures: [String] = []

        model.operations.removeAll()
        session.refitDisplacedWindows()
        if !model.operations.isEmpty {
            failures.append("refitting moved or raised windows although none had left its pane: \(model.operations)")
        }

        model.windows[left].frame = CGRect(x: 0, y: 25, width: 1440, height: 875)
        model.windows[hidden].frame.origin.x += 300
        model.operations.removeAll()
        model.notices.removeAll()
        session.refitDisplacedWindows()
        if model.windows[left].frame != fitted[left]
            || session.cells[0].flatMap({ model.paneFrames[$0] }) != fitted[left]
        {
            failures.append(
                "a window maximized outside WindowDock was not fitted back into its pane: \(model.windows[left].frame)")
        }
        if model.windows[hidden].frame != fitted[hidden] {
            failures.append(
                "a background tab's window moved outside WindowDock was not fitted back: \(model.windows[hidden].frame)")
        }
        if model.operations.contains(where: { operation in
            if case .raise = operation { return true }
            return false
        }) {
            failures.append("refitting a displaced window raised managed windows over the external app")
        }
        if !model.notices.isEmpty {
            failures.append("refitting a displaced window showed the tab-switch hint without a WindowDock request")
        }
        if model.operations.contains(.resize(right)) || model.operations.contains(.move(right)) {
            failures.append("refitting moved a window that had stayed in its pane")
        }

        model.windows[left].minimized = true
        model.windows[hidden].minimized = true
        model.operations.removeAll()
        session.refitDisplacedWindows()
        if model.windows[left].minimized || model.windows[hidden].minimized {
            failures.append("refitting did not restore minimized windows, including a background tab")
        }
        if model.operations.contains(where: {
            if case .raise = $0 { return true }
            return false
        }) {
            failures.append("restoring minimized windows raised other managed windows")
        }

        model.windows[left].minimized = true
        model.failedMinimizations.insert(left)
        session.refitDisplacedWindows()
        if model.notices.last?.needsAttention != true {
            failures.append("a failed automatic unminimize did not report an error")
        }

        let (constrained, constrainedModel) = fixture(registering: [0])
        constrainedModel.windows[0].minimumSize.width = constrainedModel.target.width + 80
        constrainedModel.windows[0].frame.size.width = constrainedModel.windows[0].minimumSize.width
        constrained.realign()
        constrainedModel.operations.removeAll()
        constrained.refitDisplacedWindows()
        if !constrainedModel.operations.isEmpty {
            failures.append("refitting retried a known size constraint even though the window had not moved")
        }
        return failures
    }

    static func runManagedWindowFollowChecks() -> [String] {
        let model = Model(windowCount: 2)
        let controller = WorkspaceController(name: "Window follow \(UUID())", access: access(for: model))
        controller.managedWindowMoveAction = .follow
        defer {
            controller.quitting = true
            controller.window.orderOut(nil)
        }
        let candidates = model.windows.map {
            WindowCandidate(element: $0.element, application: .current, title: "Follow")
        }
        controller.session.add(candidates)
        controller.session.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        controller.window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        model.operations.removeAll()
        // Resizes and zooms are applied once the frames settle after the release.
        func settleAfterRelease(until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(1.5)
            while !condition(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }

        let processID = ProcessInfo.processInfo.processIdentifier
        let initialWindow = WindowServerWindow(id: 1, processID: processID, frame: model.windows[0].frame)
        guard model.windows.count == 2, controller.session.windows.count == 2,
              controller.beginManagedWindowDrag(windowServerWindow: initialWindow)
        else { return ["managed-window follow fixture could not capture its leader"] }
        let leaderStart = model.windows[0].frame
        let peerStart = model.windows[1].frame
        let workspaceStart = controller.window.frame
        let selected = controller.session.selectedID
        let cells = controller.session.cells
        var failures: [String] = []
        model.windows[0].frame.origin.x += 60
        model.windows[0].frame.origin.y += 30
        let firstSample = WindowServerWindow(id: 1, processID: processID, frame: model.windows[0].frame)
        controller.updateManagedWindowDrag(using: [firstSample], mouseButtonDown: true)
        let firstWorkspaceDelta = CGPoint(
            x: controller.window.frame.minX - workspaceStart.minX,
            y: controller.window.frame.minY - workspaceStart.minY)
        let firstPeerDelta = CGPoint(
            x: model.windows[1].frame.minX - peerStart.minX,
            y: model.windows[1].frame.minY - peerStart.minY)
        if abs(firstWorkspaceDelta.x - 60) > 1 || abs(firstWorkspaceDelta.y + 30) > 1 {
            failures.append("the workspace did not follow while the leader was still moving: \(firstWorkspaceDelta)")
        }
        if abs(firstPeerDelta.x - 60) > 1 || abs(firstPeerDelta.y - 30) > 1 {
            failures.append("the other pane did not follow during the drag: \(firstPeerDelta)")
        }

        model.windows[0].frame.origin.x += 30
        model.windows[0].frame.origin.y += 15
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let lastSample = WindowServerWindow(id: 1, processID: processID, frame: model.windows[0].frame)
        controller.updateManagedWindowDrag(using: [lastSample], mouseButtonDown: true)
        let lastWorkspaceDelta = CGPoint(
            x: controller.window.frame.minX - workspaceStart.minX,
            y: controller.window.frame.minY - workspaceStart.minY)
        if abs(lastWorkspaceDelta.x - 90) > 1 || abs(lastWorkspaceDelta.y + 45) > 1 {
            failures.append("a later drag sample did not update the live workspace offset: \(lastWorkspaceDelta)")
        }
        controller.finishManagedWindowDrag()

        let leaderDelta = CGPoint(
            x: model.windows[0].frame.minX - leaderStart.minX,
            y: model.windows[0].frame.minY - leaderStart.minY)
        let peerDelta = CGPoint(
            x: model.windows[1].frame.minX - peerStart.minX,
            y: model.windows[1].frame.minY - peerStart.minY)
        let workspaceDelta = CGPoint(
            x: controller.window.frame.minX - workspaceStart.minX,
            y: controller.window.frame.minY - workspaceStart.minY)
        if abs(leaderDelta.x - 90) > 1 || abs(leaderDelta.y - 45) > 1 {
            failures.append("following changed the leader window's drag: \(leaderDelta)")
        }
        if abs(peerDelta.x - 90) > 1 || abs(peerDelta.y - 45) > 1 {
            failures.append("the other pane did not follow the leader: \(peerDelta)")
        }
        if abs(workspaceDelta.x - 90) > 1 || abs(workspaceDelta.y + 45) > 1 {
            failures.append("the workspace did not follow the leader in screen coordinates: \(workspaceDelta)")
        }
        if controller.session.selectedID != selected || controller.session.cells != cells {
            failures.append("following changed the selected tab or pane assignments")
        }
        if model.operations.contains(where: {
            if case .raise = $0 { return true }
            return false
        }) {
            failures.append("following raised managed windows over the foreground app")
        }

        let stableWorkspace = controller.window.frame
        let fittedLeaderSize = model.windows[0].frame.size
        let resizeStart = WindowServerWindow(id: 1, processID: processID, frame: model.windows[0].frame)
        guard controller.beginManagedWindowDrag(windowServerWindow: resizeStart) else {
            return failures + ["managed-window resize fixture could not capture its leader"]
        }
        model.windows[0].frame.origin.x -= 25
        model.windows[0].frame.size.width += 50
        let resizeSample = WindowServerWindow(id: 1, processID: processID, frame: model.windows[0].frame)
        controller.updateManagedWindowDrag(using: [resizeSample], mouseButtonDown: true)
        if controller.window.frame != stableWorkspace {
            failures.append("resizing a managed window moved its workspace")
        }
        controller.finishManagedWindowDrag()
        settleAfterRelease { model.windows[0].frame.size == fittedLeaderSize }
        if model.windows[0].frame.size != fittedLeaderSize {
            failures.append("a resized managed window was not returned to its pane")
        }

        let leaderID = controller.session.windows[0].id
        let originalPaneWidth = controller.session.alignedFrame(for: leaderID)?.width ?? 0
        let dividerStart = WindowServerWindow(id: 1, processID: processID, frame: model.windows[0].frame)
        guard controller.beginManagedWindowDrag(windowServerWindow: dividerStart) else {
            return failures + ["managed-window divider fixture could not capture its leader"]
        }
        model.windows[0].frame.size.width += 80
        controller.finishManagedWindowDrag()
        settleAfterRelease { (controller.session.alignedFrame(for: leaderID)?.width ?? 0) > originalPaneWidth + 20 }
        let resizedPaneWidth = controller.session.alignedFrame(for: leaderID)?.width ?? 0
        if resizedPaneWidth <= originalPaneWidth + 20 || controller.session.customLayout != nil {
            failures.append(
                "resizing an inner grid edge did not update its regular-grid track: "
                    + "\(originalPaneWidth) -> \(resizedPaneWidth), custom \(controller.session.customLayout != nil)")
        }

        controller.session.setGrid(WorkspaceGridSize(columns: 1, rows: 2))
        controller.session.realign(raiseWindows: false)
        let verticalPaneHeight = controller.session.alignedFrame(for: leaderID)?.height ?? 0
        guard let verticalPaneIndex = controller.session.cells.firstIndex(of: leaderID) else {
            return failures + ["managed-window vertical-divider fixture could not find its pane"]
        }
        let verticalEdge: WorkspaceResizeEdges = verticalPaneIndex == 0 ? .bottom : .top
        let verticalDividerStart = WindowServerWindow(id: 1, processID: processID, frame: model.windows[0].frame)
        guard controller.beginManagedWindowDrag(windowServerWindow: verticalDividerStart) else {
            return failures + ["managed-window vertical-divider fixture could not capture its leader"]
        }
        if verticalEdge == .bottom {
            model.windows[0].frame.size.height += 60
        } else {
            model.windows[0].frame.origin.y -= 60
            model.windows[0].frame.size.height += 60
        }
        controller.finishManagedWindowDrag()
        settleAfterRelease {
            (controller.session.alignedFrame(for: leaderID)?.height ?? 0) > verticalPaneHeight + 20
        }
        let resizedVerticalPaneHeight = controller.session.alignedFrame(for: leaderID)?.height ?? 0
        if resizedVerticalPaneHeight <= verticalPaneHeight + 20 {
            failures.append("resizing an inner vertical edge did not update its regular-grid track")
        }

        controller.session.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        controller.session.realign(raiseWindows: false)
        controller.session.setCustomLayout(PaneLayout.grid(columnWeights: [1, 1], rowWeights: [1]))
        controller.session.realign(raiseWindows: false)
        let customPaneWidth = controller.session.alignedFrame(for: leaderID)?.width ?? 0
        guard let customPaneIndex = controller.session.cells.firstIndex(of: leaderID) else {
            return failures + ["managed-window custom-divider fixture could not find its pane"]
        }
        let customDividerStart = WindowServerWindow(id: 1, processID: processID, frame: model.windows[0].frame)
        guard controller.beginManagedWindowDrag(windowServerWindow: customDividerStart) else {
            return failures + ["managed-window custom-divider fixture could not capture its leader"]
        }
        if customPaneIndex == 0 {
            model.windows[0].frame.size.width += 60
        } else {
            model.windows[0].frame.origin.x += 60
            model.windows[0].frame.size.width -= 60
        }
        controller.finishManagedWindowDrag()
        settleAfterRelease {
            abs((controller.session.alignedFrame(for: leaderID)?.width ?? 0) - customPaneWidth) > 20
        }
        let resizedCustomPaneWidth = controller.session.alignedFrame(for: leaderID)?.width ?? 0
        if controller.session.customLayout == nil
            || (customPaneIndex == 0 && resizedCustomPaneWidth <= customPaneWidth + 20)
            || (customPaneIndex != 0 && resizedCustomPaneWidth >= customPaneWidth - 20)
        {
            failures.append("resizing an inner custom-layout edge did not update its adjacent divider")
        }

        let alignedFrames = controller.session.cells.compactMap { id in
            id.flatMap { controller.session.alignedFrame(for: $0) }
        }
        guard let leaderPane = controller.session.alignedFrame(for: leaderID),
              let contentMinX = alignedFrames.map(\.minX).min(),
              let contentMaxX = alignedFrames.map(\.maxX).max()
        else { return failures + ["managed-window workspace-edge fixture could not read pane frames"] }
        let outerEdge: WorkspaceResizeEdges
        if abs(leaderPane.minX - contentMinX) <= 1 {
            outerEdge = .left
        } else if abs(leaderPane.maxX - contentMaxX) <= 1 {
            outerEdge = .right
        } else {
            return failures + ["managed-window workspace-edge fixture did not find an outer pane edge"]
        }
        let workspaceBeforeOuterResize = controller.window.frame
        let outerResizeStart = WindowServerWindow(id: 1, processID: processID, frame: model.windows[0].frame)
        guard controller.beginManagedWindowDrag(windowServerWindow: outerResizeStart) else {
            return failures + ["managed-window workspace-edge fixture could not capture its leader"]
        }
        if outerEdge == .left {
            model.windows[0].frame.origin.x -= 50
        }
        model.windows[0].frame.size.width += 50
        controller.finishManagedWindowDrag()
        settleAfterRelease { controller.window.frame.width > workspaceBeforeOuterResize.width + 40 }
        let expectedWorkspaceFrame = outerEdge == .left
            ? CGRect(
                x: workspaceBeforeOuterResize.minX - 50,
                y: workspaceBeforeOuterResize.minY,
                width: workspaceBeforeOuterResize.width + 50,
                height: workspaceBeforeOuterResize.height)
            : CGRect(
                x: workspaceBeforeOuterResize.minX,
                y: workspaceBeforeOuterResize.minY,
                width: workspaceBeforeOuterResize.width + 50,
                height: workspaceBeforeOuterResize.height)
        if !WindowGeometry.fits(controller.window.frame, requested: expectedWorkspaceFrame, tolerance: 1)
        {
            failures.append(
                "resizing an outer managed-window edge did not resize the workspace: "
                    + "\(workspaceBeforeOuterResize) -> \(controller.window.frame)")
        }

        guard let screen = controller.window.screen, let primaryScreen = NSScreen.screens.first else {
            return failures + ["managed-window maximize fixture could not find its screen"]
        }
        let maximizeStart = WindowServerWindow(id: 1, processID: processID, frame: model.windows[0].frame)
        guard controller.beginManagedWindowDrag(windowServerWindow: maximizeStart) else {
            return failures + ["managed-window maximize fixture could not capture its leader"]
        }
        model.windows[0].frame = WindowGeometry.accessibilityRect(
            from: screen.visibleFrame, primaryScreenTop: primaryScreen.frame.maxY)
        controller.finishManagedWindowDrag()
        settleAfterRelease { WindowGeometry.fits(controller.window.frame, requested: screen.visibleFrame, tolerance: 1)
        }
        if !WindowGeometry.fits(controller.window.frame, requested: screen.visibleFrame, tolerance: 1) {
            failures.append("maximizing an aligned managed window did not maximize its workspace")
        }
        return failures
    }

    /// Resizing and maximizing can finish after the release, and the press can reach a window other than the one
    /// being resized, e.g. a background tab behind the pane when the resize area lies outside the window.
    static func runManagedWindowSettledFollowChecks() -> [String] {
        let model = Model(windowCount: 3)
        let controller = WorkspaceController(name: "Settled follow \(UUID())", access: access(for: model))
        controller.managedWindowMoveAction = .follow
        defer {
            controller.quitting = true
            controller.window.orderOut(nil)
        }
        controller.session.add(model.windows.map {
            WindowCandidate(element: $0.element, application: .current, title: "Settled follow")
        })
        controller.session.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        controller.window.setFrame(NSRect(x: 160, y: 160, width: 900, height: 600), display: true)
        controller.window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        func settle(until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(1.5)
            while !condition(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }
        func modelIndex(_ id: UUID) -> Int? {
            controller.session.managedByID[id].flatMap { try? model.index(of: $0.candidate.element) }
        }
        let visible = controller.session.cells.compactMap { $0 }
        guard visible.count == 2, let resizedID = visible.first, let resized = modelIndex(resizedID),
              let hiddenID = controller.session.windows.map(\.id).first(where: { !visible.contains($0) }),
              let hidden = modelIndex(hiddenID),
              let pane = controller.session.alignedFrame(for: resizedID),
              let other = controller.session.alignedFrame(for: visible[1])
        else { return ["settled-follow fixture did not show two panes and a background tab"] }
        let processID = ProcessInfo.processInfo.processIdentifier
        var failures: [String] = []

        let workspaceBeforeResize = controller.window.frame
        let pressedBackgroundTab = WindowServerWindow(
            id: CGWindowID(hidden + 1), processID: processID, frame: model.windows[hidden].frame)
        _ = controller.beginManagedWindowDrag(windowServerWindow: pressedBackgroundTab)
        let resizesLeft = pane.minX < other.minX
        if resizesLeft { model.windows[resized].frame.origin.x -= 50 }
        model.windows[resized].frame.size.width += 50
        controller.windowsChangedOutsideWorkspace(model.windows[resized].element)
        controller.finishManagedWindowDrag()
        settle { controller.window.frame.width > workspaceBeforeResize.width + 40 }
        let expectedResize = NSRect(
            x: workspaceBeforeResize.minX - (resizesLeft ? 50 : 0), y: workspaceBeforeResize.minY,
            width: workspaceBeforeResize.width + 50, height: workspaceBeforeResize.height)
        if !WindowGeometry.fits(controller.window.frame, requested: expectedResize, tolerance: 1) {
            failures.append(
                "resizing an outer edge while the press reached a background tab did not resize the workspace: "
                    + "\(workspaceBeforeResize) -> \(controller.window.frame)")
        }

        guard let screen = controller.window.screen, let primaryScreen = NSScreen.screens.first else {
            return failures + ["settled-follow fixture could not find its screen"]
        }
        let maximized = WindowGeometry.accessibilityRect(
            from: screen.visibleFrame, primaryScreenTop: primaryScreen.frame.maxY)
        settle { false }
        let zoomStart = WindowServerWindow(
            id: CGWindowID(resized + 1), processID: processID, frame: model.windows[resized].frame)
        guard controller.beginManagedWindowDrag(windowServerWindow: zoomStart) else {
            return failures + ["settled-follow fixture could not capture the window to maximize"]
        }
        controller.finishManagedWindowDrag()
        model.windows[resized].frame = maximized
        controller.windowsChangedOutsideWorkspace(model.windows[resized].element)
        settle { WindowGeometry.fits(controller.window.frame, requested: screen.visibleFrame, tolerance: 1) }
        if !WindowGeometry.fits(controller.window.frame, requested: screen.visibleFrame, tolerance: 1) {
            failures.append("a maximize that finished after the release did not maximize the workspace")
        }

        settle { false }
        model.windows[resized].frame = maximized
        controller.windowsChangedOutsideWorkspace(model.windows[resized].element)
        settle { model.windows[resized].frame != maximized }
        if let fitted = controller.session.alignedFrame(for: resizedID),
           model.windows[resized].frame == maximized || model.windows[resized].frame != fitted
        {
            failures.append(
                "maximizing a window in a maximized workspace left it out of its pane: \(model.windows[resized].frame)")
        }
        return failures
    }

    /// Resizing a window's edge changes the workspace or its divider while the mouse is still down.
    static func runManagedWindowLiveResizeChecks() -> [String] {
        let model = Model(windowCount: 2)
        let controller = WorkspaceController(name: "Live resize \(UUID())", access: access(for: model))
        controller.managedWindowMoveAction = .follow
        defer {
            controller.quitting = true
            controller.window.orderOut(nil)
        }
        controller.session.add(model.windows.map {
            WindowCandidate(element: $0.element, application: .current, title: "Live resize")
        })
        controller.session.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        controller.window.setFrame(NSRect(x: 160, y: 160, width: 900, height: 600), display: true)
        controller.window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        func pump(_ seconds: TimeInterval = 0.05, until condition: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }
        func modelIndex(_ id: UUID) -> Int? {
            controller.session.managedByID[id].flatMap { try? model.index(of: $0.candidate.element) }
        }
        let visible = controller.session.cells.compactMap { $0 }.sorted {
            (controller.session.alignedFrame(for: $0)?.minX ?? 0) <
                (controller.session.alignedFrame(for: $1)?.minX ?? 0)
        }
        guard visible.count == 2, let leader = modelIndex(visible[0]), let peer = modelIndex(visible[1]) else {
            return ["live-resize fixture did not show two panes"]
        }
        let leaderID = visible[0]
        let processID = ProcessInfo.processInfo.processIdentifier
        func sample() -> WindowServerWindow {
            WindowServerWindow(id: CGWindowID(leader + 1), processID: processID, frame: model.windows[leader].frame)
        }
        func fits(_ index: Int, _ expected: CGRect) -> Bool {
            WindowGeometry.fits(model.windows[index].frame, requested: expected, tolerance: 1)
        }
        func leaderFitsPane(_ expected: CGRect) -> Bool {
            fits(leader, expected) && controller.session.alignedFrame(for: leaderID).map {
                WindowGeometry.fits($0, requested: expected, tolerance: 1)
            } == true
        }
        var failures: [String] = []

        let workspaceStart = controller.window.frame
        let leaderStart = model.windows[leader].frame
        let peerStart = model.windows[peer].frame
        guard controller.beginManagedWindowDrag(windowServerWindow: sample()) else {
            return ["live-resize fixture could not capture its leader"]
        }
        model.windows[leader].frame.origin.x -= 50
        model.windows[leader].frame.size.width += 50
        let firstOuterFrame = model.windows[leader].frame
        controller.updateManagedWindowDrag(using: [sample()], mouseButtonDown: true)
        let firstOuterWorkspace = NSRect(
            x: workspaceStart.minX - 50, y: workspaceStart.minY,
            width: workspaceStart.width + 50, height: workspaceStart.height)
        if !WindowGeometry.fits(controller.window.frame, requested: firstOuterWorkspace, tolerance: 1) {
            failures.append(
                "the workspace did not follow an outer-edge resize while the mouse was down: "
                    + "\(workspaceStart) -> \(controller.window.frame)")
        }
        if model.windows[leader].frame != firstOuterFrame {
            failures.append("following a live resize moved the window being resized: \(model.windows[leader].frame)")
        }
        if !fits(peer, peerStart) {
            failures.append(
                "an outer-edge resize changed the other pane instead of only the resized one: "
                    + "\(peerStart) -> \(model.windows[peer].frame)")
        }
        pump()
        model.windows[leader].frame.origin.x -= 30
        model.windows[leader].frame.size.width += 30
        controller.updateManagedWindowDrag(using: [sample()], mouseButtonDown: true)
        let lastOuterWorkspace = NSRect(
            x: workspaceStart.minX - 80, y: workspaceStart.minY,
            width: workspaceStart.width + 80, height: workspaceStart.height)
        if !WindowGeometry.fits(controller.window.frame, requested: lastOuterWorkspace, tolerance: 1) {
            failures.append(
                "a later resize sample did not set the workspace from the drag's start: \(controller.window.frame)")
        }
        controller.finishManagedWindowDrag()
        let outerLeader = CGRect(
            x: leaderStart.minX - 80, y: leaderStart.minY, width: leaderStart.width + 80, height: leaderStart.height)
        pump(0.6)
        if !WindowGeometry.fits(controller.window.frame, requested: lastOuterWorkspace, tolerance: 1)
            || !leaderFitsPane(outerLeader) || !fits(peer, peerStart)
        {
            failures.append(
                "a live outer-edge resize did not end with each window in its pane: "
                    + "\(controller.window.frame), \(model.windows[leader].frame), \(model.windows[peer].frame)")
        }

        guard controller.beginManagedWindowDrag(windowServerWindow: sample()) else {
            return failures + ["live-resize fixture could not capture its leader for the divider"]
        }
        model.windows[leader].frame.size.width += 60
        let dividerFrame = model.windows[leader].frame
        controller.updateManagedWindowDrag(using: [sample()], mouseButtonDown: true)
        let dividerPeer = CGRect(
            x: peerStart.minX + 60, y: peerStart.minY, width: peerStart.width - 60, height: peerStart.height)
        if !fits(peer, dividerPeer) {
            failures.append(
                "the neighbouring pane did not follow an inner-edge resize while the mouse was down: "
                    + "\(peerStart) -> \(model.windows[peer].frame)")
        }
        pump()
        if model.windows[leader].frame != dividerFrame {
            failures.append("moving a divider live moved the window being resized: \(model.windows[leader].frame)")
        }
        controller.finishManagedWindowDrag()
        pump(0.6)
        if !leaderFitsPane(dividerFrame) || !fits(peer, dividerPeer) {
            failures.append(
                "a live inner-edge resize did not end with both windows in their panes: "
                    + "\(model.windows[leader].frame), \(model.windows[peer].frame)")
        }

        let workspaceBeforeSmallResize = controller.window.frame
        guard controller.beginManagedWindowDrag(windowServerWindow: sample()) else {
            return failures + ["live-resize fixture could not capture its leader for a small resize"]
        }
        model.windows[leader].frame.origin.x -= 8
        model.windows[leader].frame.size.width += 8
        controller.updateManagedWindowDrag(using: [sample()], mouseButtonDown: true)
        if controller.window.frame != workspaceBeforeSmallResize {
            failures.append("a small left-edge resize moved the workspace while the mouse was down")
        }
        controller.finishManagedWindowDrag()
        pump(0.6)
        if controller.window.frame != workspaceBeforeSmallResize || !leaderFitsPane(dividerFrame) {
            failures.append(
                "a small left-edge resize was not put back into its pane: "
                    + "\(controller.window.frame), \(model.windows[leader].frame)")
        }

        // A press just outside the window's edge reaches the workspace, so no window was captured at the press.
        let workspaceBeforeAdoption = controller.window.frame
        model.windows[leader].frame.origin.x -= 40
        model.windows[leader].frame.size.width += 40
        let adoptedLeader = model.windows[leader].frame
        controller.windowsChangedOutsideWorkspace(model.windows[leader].element, mouseButtonDown: true)
        let adoptedWorkspace = NSRect(
            x: workspaceBeforeAdoption.minX - 40, y: workspaceBeforeAdoption.minY,
            width: workspaceBeforeAdoption.width + 40, height: workspaceBeforeAdoption.height)
        if !controller.isTrackingManagedWindowDrag
            || !WindowGeometry.fits(controller.window.frame, requested: adoptedWorkspace, tolerance: 1)
        {
            failures.append(
                "a resize the press did not reach was not followed while the mouse was down: "
                    + "\(workspaceBeforeAdoption) -> \(controller.window.frame)")
        }
        controller.finishManagedWindowDrag()
        pump(0.6)
        if !WindowGeometry.fits(controller.window.frame, requested: adoptedWorkspace, tolerance: 1)
            || !leaderFitsPane(adoptedLeader) || !fits(peer, dividerPeer)
        {
            failures.append(
                "a resize the press did not reach did not end with each window in its pane: "
                    + "\(controller.window.frame), \(model.windows[leader].frame), \(model.windows[peer].frame)")
        }
        return failures
    }

    /// Minimizing a shown window minimizes its workspace, and restoring it brings the workspace back.
    /// The workspace lags behind a dragged window drawn in front of it, so the window's pane must stay opaque while it
    /// is dragged; otherwise the windows behind the workspace show through where the pane lags.
    static func runManagedWindowDragConcealmentChecks() -> [String] {
        let model = Model(windowCount: 2)
        let controller = WorkspaceController(name: "Drag concealment \(UUID())", access: access(for: model))
        controller.managedWindowMoveAction = .follow
        defer {
            controller.quitting = true
            controller.window.orderOut(nil)
        }
        controller.session.add(model.windows.map {
            WindowCandidate(element: $0.element, application: .current, title: "Drag concealment")
        })
        controller.session.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        controller.window.setFrame(NSRect(x: 160, y: 160, width: 900, height: 600), display: true)
        controller.window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let workspace = controller.window.contentView as? WorkspaceBackgroundView,
              workspace.gridContentAreas.count == 2,
              let leaderID = controller.session.cells[0],
              let leader = controller.session.managedByID[leaderID].flatMap({
                  try? model.index(of: $0.candidate.element)
              })
        else { return ["drag-concealment fixture did not show two panes"] }
        func reveals(_ cell: Int) -> Bool {
            let area = workspace.gridContentAreas[cell]
            let pane = workspace.convert(area.bounds, from: area)
            return workspace.visibleContentRects.contains { $0.intersects(pane) }
        }
        guard reveals(0), reveals(1) else {
            return ["drag-concealment fixture did not show its windows through the workspace"]
        }
        let processID = ProcessInfo.processInfo.processIdentifier
        func leaderSample() -> WindowServerWindow {
            WindowServerWindow(id: CGWindowID(leader + 1), processID: processID, frame: model.windows[leader].frame)
        }
        func workspaceSample() -> WindowServerWindow {
            WindowServerWindow(
                id: CGWindowID(controller.window.windowNumber), processID: processID, frame: controller.window.frame)
        }
        guard controller.beginManagedWindowDrag(windowServerWindow: leaderSample()) else {
            return ["drag-concealment fixture could not capture its leader"]
        }
        var failures: [String] = []
        model.windows[leader].frame.origin.x += 60
        // The WindowServer lists windows front to back.
        controller.updateManagedWindowDrag(using: [leaderSample(), workspaceSample()], mouseButtonDown: true)
        if reveals(0) {
            failures.append("the dragged window's pane let the windows behind the workspace show through")
        }
        if !reveals(1) {
            failures.append("hiding the dragged window's pane also hid the other pane's window")
        }

        // E.g. a Command-drag moves a window without bringing it in front of the workspace.
        model.windows[leader].frame.origin.x += 30
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        controller.updateManagedWindowDrag(using: [workspaceSample(), leaderSample()], mouseButtonDown: true)
        if !reveals(0) {
            failures.append("a dragged window behind the workspace was hidden by its pane")
        }

        controller.updateManagedWindowDrag(using: [leaderSample(), workspaceSample()], mouseButtonDown: true)
        controller.finishManagedWindowDrag()
        if !reveals(0) || !reveals(1) {
            failures.append("the dragged window's pane stayed opaque after the drag")
        }
        return failures
    }

    static func runManagedWindowMinimizeFollowChecks() -> [String] {
        let model = Model(windowCount: 2)
        let controller = WorkspaceController(name: "Minimize follow \(UUID())", access: access(for: model))
        controller.managedWindowMoveAction = .follow
        defer {
            controller.quitting = true
            controller.window.orderOut(nil)
        }
        controller.session.add(model.windows.map {
            WindowCandidate(element: $0.element, application: .current, title: "Minimize follow")
        })
        controller.session.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        controller.window.setFrame(NSRect(x: 160, y: 160, width: 900, height: 600), display: true)
        controller.window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        func pump(_ seconds: TimeInterval, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }
        let visible = controller.session.cells.compactMap { $0 }
        guard visible.count == 2,
              let shown = controller.session.managedByID[visible[0]].flatMap({
                  try? model.index(of: $0.candidate.element)
              })
        else { return ["minimize-follow fixture did not show two panes"] }
        let other = 1 - shown
        var failures: [String] = []

        model.windows[shown].minimized = true
        controller.windowsChangedOutsideWorkspace(model.windows[shown].element)
        pump(3) { controller.window.isMiniaturized && model.windows[other].minimized }
        if !controller.window.isMiniaturized || !controller.suspended {
            failures.append("minimizing a shown window did not minimize its workspace")
        }
        if !model.windows[other].minimized {
            failures.append("minimizing a shown window left the workspace's other window on screen")
        }
        if !model.windows[shown].minimized {
            failures.append("minimizing a shown window put it back into its pane")
        }

        model.windows[shown].minimized = false
        controller.windowRestoredOutsideWorkspace(model.windows[shown].element)
        pump(3) { !controller.window.isMiniaturized && !controller.suspended && !model.windows[other].minimized }
        if controller.window.isMiniaturized || controller.suspended {
            failures.append("restoring a minimized window did not restore its workspace")
        }
        if model.windows[other].minimized {
            failures.append("restoring a minimized window left the workspace's other window minimized")
        }
        return failures
    }

    /// Activation refits normal windows; full-screen windows only return when enabled.
    static func runActivationRefitChecks() -> [String] {
        let model = Model(windowCount: 2)
        let controller = WorkspaceController(name: "Activation refit", access: access(for: model))
        let window = controller.window
        defer {
            controller.quitting = true
            window.orderOut(nil)
        }
        func settle(_ seconds: TimeInterval = 0.5, until condition: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline {
                if let event = NSApp.nextEvent(
                    matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
                {
                    NSApp.sendEvent(event)
                }
            }
        }
        window.setFrame(NSRect(x: 160, y: 180, width: 900, height: 600), display: true)
        controller.session.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        controller.session.add(
            model.windows.map {
                WindowCandidate(element: $0.element, application: .current, title: "Refit probe")
            })
        controller.bringToFront()
        settle()
        guard NSApp.isActive, window.isKeyWindow else {
            return ["activation refit fixture did not become active and key"]
        }
        let fitted = model.windows.map(\.frame)
        let grid = controller.session.gridSize
        let activation = WorkspaceActivation(controllers: { [controller] })
        activation.latestClick = { nil }
        func raised(_ index: Int? = nil) -> Bool {
            model.operations.contains { operation in
                if case .raise(let raised) = operation { return index.map { $0 == raised } ?? true }
                return false
            }
        }
        var failures: [String] = []

        model.windows[0].frame = CGRect(x: 0, y: 25, width: 1440, height: 875)
        model.operations.removeAll()
        activation.applicationDidBecomeActive()
        settle { raised(0) }
        if model.windows[0].frame != fitted[0] {
            failures.append(
                "a window maximized while another app was active stayed maximized when WindowDock became active: \(model.windows[0].frame)")
        }
        if model.operations.contains(.resize(1)) || model.operations.contains(.move(1)) {
            failures.append("activation moved a window that had stayed in its pane")
        }

        model.windows[1].fullScreen = true
        model.windows[1].frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        model.windows[0].frame = fitted[0].offsetBy(dx: 30, dy: 20)
        model.operations.removeAll()
        activation.applicationDidBecomeActive()
        settle(0.5)
        if !model.fullScreenExits.isEmpty || raised(1)
            || model.operations.contains(.resize(1)) || model.operations.contains(.move(1))
            || controller.session.gridSize != grid
        {
            failures.append("activation changed a full-screen window or its pane layout without opting in")
        }
        if model.windows[0].frame != fitted[0] {
            failures.append("preserving full screen prevented another pane's maximized window from returning")
        }
        model.focusedWindows.removeAll()
        controller.scheduleSelectedWindowRaise(activate: true)
        settle(0.4)
        if model.focusedWindows.contains(1) {
            failures.append("activating the workspace focused a full-screen window in another Space without opting in")
        }
        model.fullScreenExits.removeAll()
        model.operations.removeAll()
        controller.returnsFullScreenWindows = true
        activation.applicationDidBecomeActive()
        settle(0.4)
        if model.fullScreenExits != [1] {
            failures.append("activation did not take a full-screen window out of full screen: \(model.fullScreenExits)")
        }
        if raised() {
            // Raising a full-screen window switches to its Space instead of showing it in its pane.
            failures.append("activation raised windows before the full-screen window had left full screen")
        }
        model.windows[1].fullScreen = false
        model.windows[1].frame = fitted[1].offsetBy(dx: 0, dy: 40)
        settle(2) { raised(1) }
        if model.windows[1].frame != fitted[1] || controller.session.gridSize != grid {
            failures.append(
                "a window that left full screen was not fitted back into its pane: "
                    +
                    "\(model.windows[1].frame), grid \(controller.session.gridSize.columns)×\(controller.session.gridSize.rows)")
        }
        if !raised(1) {
            failures.append("the workspace's windows were not raised once the window had left full screen")
        }
        return failures
    }

    /// A real window zoomed or minimized by its app, without a mouse drag, returns to its pane on its own.
    static func runWindowEventRefitChecks() -> [String] {
        let helper: ActivationHelperProcess
        switch ActivationHelperProcess.launch(resizable: true) {
        case .success(let launched): helper = launched
        case .failure(let failure): return [failure.message]
        }
        defer { helper.terminate() }
        // A just-launched helper can take a moment to answer accessibility requests, e.g. while the system is busy.
        func helperWindow() -> AXUIElement? {
            guard let application = NSRunningApplication(processIdentifier: helper.pid) else { return nil }
            return WindowAccess.windowElements(application)?.first {
                WindowAccess.windowID(of: $0) == CGWindowID(helper.windows[0])
            }
        }
        var helperElement = helperWindow()
        let lookupDeadline = Date().addingTimeInterval(3)
        while helperElement == nil, Date() < lookupDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            helperElement = helperWindow()
        }
        guard let element = helperElement, let application = NSRunningApplication(processIdentifier: helper.pid)
        else { return ["could not find the window-event helper window"] }
        let controller = WorkspaceController(name: "Window events")
        let window = controller.window
        defer {
            controller.quitting = true
            window.orderOut(nil)
        }
        func settle(_ seconds: TimeInterval, until condition: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline {
                if let event = NSApp.nextEvent(
                    matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
                {
                    NSApp.sendEvent(event)
                }
            }
        }
        window.setFrame(NSRect(x: 160, y: 180, width: 900, height: 600), display: true)
        window.orderFrontRegardless()
        controller.session.add(WindowCandidate(element: element, application: application, title: "Event probe"))
        settle(1)
        guard let fitted = try? WindowAccess.frame(element), fitted.width > 600 else {
            return ["window-event fixture did not fit the helper window into its pane"]
        }
        func inPane() -> Bool {
            guard (try? WindowAccess.isMinimized(element)) == false, let frame = try? WindowAccess.frame(element)
            else { return false }
            return WindowGeometry.fits(frame, requested: fitted, tolerance: 1)
        }
        var failures: [String] = []

        helper.send("zoom 0")
        var zoomed = false
        settle(3) {
            if !inPane() { zoomed = true }
            return zoomed && inPane()
        }
        if !zoomed {
            failures.append("the helper window did not zoom")
        } else if !inPane() {
            failures.append(
                "a window zoomed by its app stayed maximized instead of returning to its pane: "
                    + "\(String(describing: try? WindowAccess.frame(element)))")
        }

        helper.send("minimize 0")
        var minimized = false
        settle(4) {
            if (try? WindowAccess.isMinimized(element)) == true { minimized = true }
            return minimized && inPane()
        }
        if !minimized {
            failures.append("the helper window did not minimize")
        } else if !inPane() {
            failures.append(
                "a window minimized by its app stayed out of its pane (minimized: "
                    + "\(String(describing: try? WindowAccess.isMinimized(element))))")
        }

        settle(0.5)
        helper.send("fullscreen 0")
        var fullScreen = false
        settle(3) {
            if WindowAccess.isFullScreen(element) { fullScreen = true }
            return false
        }
        if !fullScreen {
            failures.append("the helper window did not enter full screen")
        } else if !WindowAccess.isFullScreen(element) {
            failures.append("a real full-screen window returned to its pane without opting in")
        }
        controller.returnsFullScreenWindows = true
        controller.windowsChangedOutsideWorkspace()
        settle(10) { !WindowAccess.isFullScreen(element) && inPane() }
        if WindowAccess.isFullScreen(element) || !inPane() {
            failures.append(
                "a window made full screen by its app did not return to its pane (full screen: "
                    +
                    "\(WindowAccess.isFullScreen(element)), frame: \(String(describing: try? WindowAccess.frame(element))))")
        }

        // AXFullScreen clears before AppKit finishes the transition and accepts another window action.
        settle(1)
        controller.returnsDisplacedWindows = false
        helper.send("minimize 0")
        var minimizedWhileDisabled = false
        settle(1.5) {
            if (try? WindowAccess.isMinimized(element)) == true { minimizedWhileDisabled = true }
            return false
        }
        if !minimizedWhileDisabled {
            failures.append("the helper window did not minimize for the disabled-setting check")
        } else if (try? WindowAccess.isMinimized(element)) != true {
            failures.append("automatic return unminimized a window while the setting was disabled")
        }
        do {
            _ = try WindowAccess.minimize(element, false)
            try WindowAccess.setFrame(element, fitted.offsetBy(dx: 30, dy: 20))
        } catch {
            return failures + ["could not move the helper window: \(error.localizedDescription)"]
        }
        settle(0.6)
        if inPane() {
            failures.append("automatic return moved a window while the setting was disabled")
        }
        controller.returnsDisplacedWindows = true
        controller.windowsChangedOutsideWorkspace()
        settle(2, until: inPane)

        controller.applicationDidHide()
        settle(1)
        if (try? WindowAccess.isMinimized(element)) != true {
            failures.append("automatic return undid the workspace's own minimization")
        }
        controller.applicationDidUnhide()
        settle(2, until: inPane)
        if !inPane() { failures.append("a suspended workspace did not restore its managed window on resume") }

        guard let managed = controller.session.windows.first else {
            return failures + ["the window-event fixture lost its registered window"]
        }
        controller.windowsChangedOutsideWorkspace()
        controller.session.remove(managed.id, closeWindow: false)
        settle(0.8)
        if let frame = try? WindowAccess.frame(element),
           !WindowGeometry.fits(frame, requested: managed.originalFrame, tolerance: 1) {
            failures.append("a queued automatic return moved a released window back into its old pane")
        }
        return failures
    }

    static func runWindowEventReturnPolicyChecks() -> [String] {
        let model = Model(windowCount: 1)
        let controller = WorkspaceController(name: "Automatic return policy", access: access(for: model))
        defer {
            controller.quitting = true
            controller.window.orderOut(nil)
        }
        controller.session.add(
            WindowCandidate(element: model.windows[0].element, application: .current, title: "Return policy"))
        let fitted = model.windows[0].frame
        func settle(_ seconds: TimeInterval = 0.4) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }
        var failures: [String] = []
        model.windows[0].fullScreen = true
        model.windows[0].frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        model.operations.removeAll()
        controller.windowsChangedOutsideWorkspace()
        settle()
        if !model.fullScreenExits.isEmpty || !model.operations.isEmpty {
            failures.append("automatic return changed a full-screen window without opting in")
        }
        model.fullScreenExits.removeAll()
        controller.returnsFullScreenWindows = true
        controller.windowsChangedOutsideWorkspace()
        settle()
        if model.fullScreenExits.isEmpty {
            failures.append("automatic return did not request leaving full screen")
        }
        controller.returnsDisplacedWindows = false
        model.windows[0].fullScreen = false
        model.windows[0].frame = fitted.offsetBy(dx: 80, dy: 40)
        model.operations.removeAll()
        settle()
        if !model.operations.isEmpty {
            failures.append("a pending full-screen return changed the window after the setting was disabled")
        }
        controller.returnsDisplacedWindows = true
        model.windows[0].fullScreen = true
        controller.windowsChangedOutsideWorkspace()
        settle()
        let exitRequests = model.fullScreenExits.count
        controller.returnsFullScreenWindows = false
        model.operations.removeAll()
        settle(1.3)
        if model.fullScreenExits.count != exitRequests || !model.operations.isEmpty {
            failures.append("disabling full-screen return did not cancel its pending retries")
        }
        model.windows[0].fullScreen = false
        model.onMove = { controller.windowsChangedOutsideWorkspace() }
        model.onSetFrame = { _, _ in controller.windowsChangedOutsideWorkspace() }
        for _ in 0 ..< 5 {
            model.windows[0].frame = fitted.offsetBy(dx: 80, dy: 40)
            controller.windowsChangedOutsideWorkspace()
            settle()
            if model.windows[0].frame != fitted {
                failures.append("repeated window moves stopped returning to the pane")
                break
            }
        }
        model.operations.removeAll()
        settle(0.8)
        if !model.operations.isEmpty {
            failures.append("notifications from automatic return repeatedly moved or raised an aligned window")
        }
        model.onMove = nil
        model.onSetFrame = nil
        return failures
    }

    private static func runCloseOnReleaseChecks() -> [String] {
        var failures: [String] = []
        let (session, model) = fixture()
        let ids = session.windows.map(\.id)
        model.listedWindows = [0, 1, 2, 3]
        model.onClose = { index in
            if index == 0 { model.probeErrors[0] = .invalidUIElement }
            if index == 2 { throw InjectedFailure() }
        }
        session.remove(ids[1], closeWindow: true)
        if session.closesWindowsOnRelease { failures.append("a one-off close enabled the default close setting") }
        session.pruneClosedWindows()
        session.pruneClosedWindows()
        if session.windows.map(\.id) != ids || model.closeRequests != [1] {
            failures.append("a window awaiting a save decision was detached or asked to close again")
        }
        session.closesWindowsOnRelease = true
        if session.remove(ids[2]) || session.windows.map(\.id) != ids || model.notices.last?.needsAttention != true {
            failures.append("a rejected close did not report an error and keep the tab")
        }
        session.remove(ids[0])
        if session.windows.map(\.id) != [ids[1], ids[2]] || model.windows[0].frame == model.windows[0].originalFrame {
            failures.append("an immediately closed tab was not removed without restoring its frame")
        }
        // The app keeps an AX element alive after closing its window and has another, unmanaged window.
        model.listedWindows = [2, 3]
        session.pruneClosedWindows()
        session.pruneClosedWindows()
        if session.windows.map(\.id) != [ids[2]] {
            failures.append("the closed window's tab was kept or another window was removed")
        }
        let (other, _) = fixture(registering: [], sharedModel: model)
        session.transferWindow(ids[2], to: other)
        other.closesWindowsOnRelease = true
        if !other.restoreAll().isEmpty { failures.append("workspace restoration failed with close mode enabled") }
        other.remove(ids[2], closeWindow: false)
        if !other.closesWindowsOnRelease { failures.append("a one-off release disabled the default close setting") }
        if !other.windows.isEmpty || model.closeRequests != [1, 2, 0] || model.windows[2].frame != model.windows[2]
            .originalFrame {
            failures.append("transferring, restoring, or explicitly releasing a tab sent a close request")
        }
        return failures
    }

    static func runExternalFocusChecks() -> [String] {
        var failures: [String] = []
        let (single, singleModel) = fixture()
        let singleIDs = single.windows.map(\.id)
        singleModel.operations.removeAll()
        single.observeFocusedWindow(singleModel.windows[1].element)
        if single.selectedID != singleIDs[1] || singleModel.operations.isEmpty == false
            || !singleModel.focusedWindows.isEmpty || Set(singleModel.paneFrames.keys) != [singleIDs[1]]
        {
            failures.append("external focus did not select a single-pane tab without activating other windows")
        }

        let (split, splitModel) = fixture()
        let splitIDs = split.windows.map(\.id)
        split.setSplit(true)
        split.setPanePinned(true, at: 0)
        splitModel.operations.removeAll()
        split.observeFocusedWindow(splitModel.windows[1].element)
        if split.primaryID != splitIDs[2] || split.secondaryID != splitIDs[1] || split.selectedID != splitIDs[1]
            || split.tabSwitchCell != 1 || splitModel.operations.contains(.raise(1))
            || splitModel.operations.contains(.raise(2)) || splitModel.operations.contains(.raise(0))
            || splitModel.windows[1].frame != splitModel.rightTarget
        {
            failures.append("external focus did not move only the focused tab into the unpinned pane")
        }
        split.observeFocusedWindow(splitModel.windows[2].element)
        if split.selectedID != splitIDs[2] || split.tabSwitchCell != 1 {
            failures.append("external focus in a pinned pane changed the unpinned-pane switch target")
        }
        split.setPanePinned(true, at: 1)
        let beforeAllPinnedFocus = split.cells
        split.observeFocusedWindow(splitModel.windows[0].element)
        if split.cells != beforeAllPinnedFocus || !splitModel.focusedWindows.isEmpty
            || splitModel.operations.contains(.raise(1)) || splitModel.operations.contains(.raise(2))
            || splitModel.operations.contains(.raise(0))
        {
            failures.append("external focus replaced a pane when every pane was pinned or activated managed windows")
        }
        return failures
    }

    static func runNewTabChecks() -> [String] {
        var failures: [String] = []
        let (session, model) = fixture(registering: [0, 1])
        let original = session.tabIDs
        session.setSplit(true)
        let pinned = session.cells[0]
        session.setPanePinned(true, at: 0)
        session.newTab()
        guard let blank = session.selectedID, session.isStartPage(blank),
              session.tabIDs == original + [blank], session.cells == [pinned, blank],
              model.paneFrames[blank] == nil else { return ["new tab didn't preserve the pinned pane"] }
        session.newTab()
        guard let other = session.selectedID, other != blank else { return ["+ reused the existing blank tab"] }
        session.cycle(-1)
        guard session.selectedID == blank else { return ["couldn't cycle between start pages"] }
        session.reorderWindows([other, blank] + original)
        let candidate = WindowCandidate(element: model.windows[2].element, application: .current, title: "Chosen")
        var added = 0
        session.onAddedApplication = { _ in added += 1 }
        model.failedRegistrations.insert(2)
        _ = session.fillStartPage(blank, with: [candidate])
        session.isClaimedElsewhere = { _ in true }
        model.failedRegistrations.removeAll()
        _ = session.fillStartPage(blank, with: [candidate])
        if !session.isStartPage(blank) || added != 0 { failures.append("failed/claimed window consumed start page") }
        session.isClaimedElsewhere = { _ in false }
        let extra = WindowCandidate(element: model.windows[3].element, application: .current, title: "Another")
        _ = session.fillStartPage(blank, with: [session.windows[0].candidate, candidate, extra])
        guard let extraID = session.windows.first(where: { $0.candidate.isSameWindow(as: extra) })?.id else {
            return failures + ["multi-select didn't register the other window"]
        }
        if added != 2 || session.tabIDs != [other, blank, extraID] + original || session.selectedID != blank
            || session.selected?.candidate.title != "Chosen" || session.cells != [pinned, blank] {
            failures.append("choosing a window didn't replace just the originating tab in place")
        }
        session.remove(other, closeWindow: true)
        if !model.closeRequests.isEmpty || session.tabIDs.contains(other) { failures.append("closing blank used AX") }
        let controller = WorkspaceController(name: "New tab smoke", access: access(for: model))
        defer { controller.finishClosing() }
        controller.session.onFocusStartPage = {}
        guard let chrome = controller.window.contentView as? WorkspaceChromeView
        else { return failures + ["no chrome"] }
        controller.window.orderBack(nil)
        chrome.addButton.performClick(nil)
        if controller.window.attachedSheet != nil || chrome.tabs.arrangedSubviews.count != 1
            || chrome.gridAreas[0].subviews.isEmpty {
            failures.append("+ did not create an inline page")
        }
        func checkVisiblePage(_ stage: String) {
            chrome.layoutSubtreeIfNeeded()
            controller.window.displayIfNeeded()
            let pane = chrome.gridAreas[0]
            guard let page = pane.subviews.first, page.visibleRect.width > 200, page.visibleRect.height > 150,
                  page.frame == pane.bounds else {
                failures
                    .append(
                        "\(stage): start page not filling visible pane (grid \(chrome.stage.bounds), pane \(pane.frame), page \(String(describing: pane.subviews.first?.frame)))")
                return
            }
            // Look for the first heading, not the tab label, border or permission-dependent window previews.
            let header = NSRect(x: 16, y: pane.bounds.maxY - 50, width: 174, height: 40)
            guard let rep = pane.bitmapImageRepForCachingDisplay(in: header) else {
                failures.append("\(stage): couldn't render the new-tab heading")
                return
            }
            pane.cacheDisplay(in: header, to: rep)
            var darkest: CGFloat = 1, lightest: CGFloat = 0
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceGray),
                          color.alphaComponent > 0.9 else { continue }
                    darkest = min(darkest, color.whiteComponent)
                    lightest = max(lightest, color.whiteComponent)
                }
            }
            if lightest - darkest < 0.25 { failures.append("\(stage): new-tab heading rendered blank") }
        }
        checkVisiblePage("new tab")
        controller.window.setContentSize(NSSize(width: 780, height: 510))
        checkVisiblePage("resized tab")
        controller.session.splitPane(at: 0, axis: .horizontal)
        checkVisiblePage("split pane")
        controller.removeSelected()
        if !chrome.gridAreas[0].subviews.isEmpty { failures.append("closing tab left page mounted") }
        return failures
    }

    static func runChecks() -> [String] {
        var failures: [String] = []
        failures += runNewTabChecks()
        failures += runNestedPaneChecks()
        failures += runPanePinChecks()
        failures += runPaneGroupChecks()
        failures += runPaneGroupUIChecks()
        failures += runTabSelectionFeedbackChecks()
        failures += runNestedPaneUIChecks()
        failures += runNestedPaneLimitChecks()
        failures += runNestedPaneMinimumChecks()
        failures += runManyTabMoveChecks()
        failures += runRemovalApertureChecks()
        failures += runCloseOnReleaseChecks()
        failures += runDisplacedWindowChecks()
        failures += runEmptyWorkspaceDeletionChecks()
        failures += runAutoGroupChecks()
        failures += runWindowEventRefitChecks()
        failures += runWindowEventReturnPolicyChecks()
        failures += runReresolveChecks()
        failures += runTabTransferRevealChecks()
        failures += runOutsideTabDropChecks()
        failures += runConstraintNoticeChecks()
        failures += runTransferChecks()
        failures += runWorkspaceMergeChecks()
        failures += runRegisteredWindowDragChecks()
        failures += runExternalWindowDropChecks()
        failures += runExternalFocusChecks()
        failures += runKeyboardFocusChecks()
        failures += runWindowInsertionChecks()
        let (orderingSession, orderingModel) = fixture()
        let originalOrder = orderingSession.windows.map(\.id)
        let originalCells = orderingSession.cells
        orderingSession.reorderWindows([originalOrder[2], originalOrder[1], originalOrder[0]])
        if orderingSession.windows.map(\.id) != [originalOrder[2], originalOrder[1], originalOrder[0]]
            || orderingSession.cells != originalCells || orderingModel.changeCount != 1
            || !orderingModel.operations.isEmpty
        {
            failures.append("reordering tabs changed pane assignments or window state")
        }
        orderingSession.reorderWindows([originalOrder[0], originalOrder[0], originalOrder[2]])
        if orderingSession.windows.map(\.id) != [originalOrder[2], originalOrder[1], originalOrder[0]]
            || orderingModel.changeCount != 1
        {
            failures.append("invalid tab order changed the session")
        }

        let (session, model) = fixture()
        guard session.windows.count == 3 else { return ["stacked fixture could not register windows"] }
        let ids = session.windows.map(\.id)

        for _ in 0 ..< 10 {
            for id in ids { session.select(id) }
        }

        let expectedRaises = (0 ..< 10).flatMap { _ in (0 ..< 3).map(Operation.raise) }
        if model.operations != expectedRaises {
            failures.append("stacked switching minimized/restored, moved or resized an already aligned window")
        }
        if model.windows.prefix(3).contains(where: { $0.minimized || $0.frame != model.target }) {
            failures.append("stacked tabs are not all visible at the same frame")
        }
        model.operations.removeAll()
        model.target.origin.x += 70
        session.sync()
        if model.operations != [.move(0), .move(1), .move(2), .raise(2)]
            || model.windows.prefix(3).contains(where: { $0.frame != model.target })
        {
            failures.append("moving the workspace did not move the entire stack without resizing")
        }
        model.operations.removeAll()
        model.target.size.width -= 100
        session.sync()
        if model.operations != [.resize(0), .resize(1), .resize(2), .raise(2)]
            || model.windows.prefix(3).contains(where: { $0.frame != model.target })
        {
            failures.append("resizing the workspace left background tabs behind or above the selected tab")
        }
        model.operations.removeAll()
        session.sync()
        if !model.operations.isEmpty { failures.append("unchanged workspace repeated frame writes") }

        model.windows[0].frame = model.windows[0].originalFrame
        session.select(ids[0])
        if model.windows[0].frame != model.target || model.operations != [.resize(0), .raise(0)] {
            failures.append("selecting a manually displaced tab did not realign it")
        }
        model.operations.removeAll()
        model.windows[1].minimized = true
        session.suspend()
        session.suspend()
        if model.windows.prefix(3).contains(where: { !$0.minimized })
            || model.operations != [.minimize(0, true), .minimize(2, true)]
        {
            failures.append("workspace suspension did not minimize all tabs exactly once")
        }
        model.target.origin.y += 40
        session.resume()
        if model.windows[0].minimized || model.windows[2].minimized || !model.windows[1].minimized
            || model.windows[0].frame != model.target || model.windows[2].frame != model.target
            || model.operations.last != .raise(0)
        {
            failures.append("resume did not restore the stack while preserving a manually minimized inactive tab")
        }
        if !session.remove(ids[0]) || session.selectedID != ids[1]
            || model.windows[0].frame != model.windows[0].originalFrame || model.windows[0].minimized
        {
            failures.append("removing the selected tab did not restore it and present the next tab")
        }
        if !session.restoreAll().isEmpty
            || model.windows.prefix(3).contains(where: {
                $0.frame != $0.originalFrame || $0.minimized != $0.originallyMinimized
            })
        {
            failures.append("stacked tabs did not restore their original frames and minimized states")
        }
        if model.windows[3].frame != model.windows[3].originalFrame
            || model.windows[3].minimized != model.windows[3].originallyMinimized
        {
            failures.append("unregistered sibling window was modified")
        }
        return failures + checkPartialFailures() + checkBatchAddition() + checkSplitSelection(layout: .sideBySide)
            + checkSplitSelection(layout: .stacked) + checkGrid() + checkGridConstraints() + checkInput()
    }

    private static func gridTargets(_ size: WorkspaceGridSize) -> [Int: CGRect] {
        let width = (1600 - CGFloat(size.columns - 1) * 32) / CGFloat(size.columns)
        let height = (1000 - CGFloat(size.rows - 1) * 32) / CGFloat(size.rows)
        return Dictionary(
            uniqueKeysWithValues: (0 ..< size.cellCount).map { index in
                (
                    index,
                    CGRect(
                        x: 200 + CGFloat(index % size.columns) * (width + 32),
                        y: 160 + CGFloat(index / size.columns) * (height + 32),
                        width: width, height: height))
            })
    }

    private static func configureGridFixture(_ session: WindowSession, _ model: Model) {
        session.onChange = { [weak session] in
            model.changeCount += 1
            if let session { model.gridTargets = gridTargets(session.gridSize) }
        }
        model.gridTargets = gridTargets(session.gridSize)
    }

    private static func checkGrid() -> [String] {
        var failures: [String] = []
        let (session, model) = fixture(registering: Array(0 ..< 17), windowCount: 18)
        let ids = session.windows.map(\.id)
        configureGridFixture(session, model)
        session.setGrid(WorkspaceGridSize(columns: 4, rows: 4))
        if session.gridSize.cellCount != 16 || session.visibleWindows.count != 16
            || Set(session.cells.compactMap { $0 }).count != 16 || model.paneFrames.count != 16
        {
            failures.append("4x4 grid did not display sixteen distinct windows")
        }
        let visibleFrames = Array(model.paneFrames.values)
        for index in visibleFrames.indices {
            for other in visibleFrames.indices where other > index {
                if visibleFrames[index].intersects(visibleFrames[other]) {
                    failures.append("4x4 grid published overlapping actual window frames")
                }
            }
        }
        let oldCells = session.cells
        model.operations.removeAll()
        session.activateCell(15)
        if session.activeCell != 15 || !model.operations.isEmpty {
            failures.append("activating a grid cell changed external windows")
        }
        guard let hidden = ids.first(where: { !oldCells.contains($0) }) else {
            return failures + ["4x4 fixture has no hidden window"]
        }
        if let source = session.cells[0], let destination = session.cells[15] {
            session.moveWindow(source, toCell: 15)
            if session.cells[15] != source || session.cells[0] != destination
                || Array(session.cells[1 ..< 15]) != Array(oldCells[1 ..< 15]) || session.selectedID != source
                || model.paneFrames[source] != model.gridTargets?[15]
                || model.paneFrames[destination] != model.gridTargets?[0]
            {
                failures.append("pane exchange did not swap only the two displayed windows and their actual frames")
            }
        }
        let swapped = session.cells
        session.select(hidden)
        if session.cells[15] != hidden || Array(session.cells.prefix(15)) != Array(swapped.prefix(15)) {
            failures.append("selecting a hidden tab changed a cell other than the active one")
        }
        session.setGrid(WorkspaceGridSize(columns: 3, rows: 4))
        if session.gridSize.columns != 3 || session.gridSize.rows != 4 || session.selectedID != hidden
            || Set(session.cells.compactMap { $0 }).count != 12
        {
            failures.append("shrinking only the column count lost the active window or duplicated cells")
        }
        session.setGrid(.single)
        if session.selectedID != hidden || model.paneFrames.count != 1
            || model.windows.prefix(17).contains(where: { $0.frame != gridTargets(.single)[0] })
        {
            failures.append("collapsing a grid did not reunite hidden stacks behind the active tab")
        }
        session.setGrid(WorkspaceGridSize(columns: 5, rows: 1))
        if session.gridSize != .single || model.notices.last?.needsAttention != true {
            failures.append("invalid grid dimensions were accepted or rejected silently")
        }
        if !session.restoreAll().isEmpty
            || model.windows.contains(where: {
                $0.frame != $0.originalFrame || $0.minimized != $0.originallyMinimized
            })
        {
            failures.append("sixteen-cell lifecycle changed original states or an unregistered sibling")
        }

        let (emptySession, emptyModel) = fixture(registering: [], windowCount: 4)
        configureGridFixture(emptySession, emptyModel)
        emptySession.setGrid(WorkspaceGridSize(columns: 2, rows: 2))
        emptySession.activateCell(3)
        emptySession.add(
            Array(emptyModel.windows.prefix(3)).map {
                WindowCandidate(element: $0.element, application: .current, title: "Fill empty cells")
            })
        if emptySession.visibleWindows.count != 3 || Set(emptySession.cells.compactMap { $0 }).count != 3
            || emptySession.cells[3] != emptySession.windows.first?.id
        {
            failures.append("batch addition did not fill distinct empty grid cells starting at the active cell")
        }
        guard let emptyCell = emptySession.cells.firstIndex(where: { $0 == nil }) else {
            return failures + ["batch fixture has no remaining empty cell"]
        }
        let movedID = emptySession.windows.last!.id
        let previous = emptySession.cellIndex(for: movedID)!
        emptySession.moveWindow(movedID, toCell: emptyCell)
        if emptySession.cells[emptyCell] != movedID || emptySession.cells[previous] != nil
            || emptySession.visibleWindows.count != 3
        {
            failures.append("moving a displayed tab into an empty cell duplicated it or lost another pane")
        }
        emptySession.activateCell(previous)
        emptySession.cycle(1)
        if emptySession.selectedID != emptySession.windows.first?.id || emptySession.activeCell != 3 {
            failures.append("keyboard cycling from an empty cell did not select the first registered tab")
        }
        return failures
    }

    private static func checkGridConstraints() -> [String] {
        var failures: [String] = []
        let (session, model) = fixture(registering: [0, 1, 2, 3])
        configureGridFixture(session, model)
        model.windows[3].minimumSize.width = 900
        var learned: [Int: CGSize] = [:]
        session.fitMinimumSizes = { [weak session] sizes in
            learned = sizes
            guard let session else { return false }
            guard session.gridSize.columns == 2, session.gridSize.rows == 2 else { return true }
            if (sizes[0]?.width ?? 0) > 784 {
                model.gridTargets = [
                    0: CGRect(x: 200, y: 160, width: 900, height: 484),
                    1: CGRect(x: 1132, y: 160, width: 668, height: 484),
                    2: CGRect(x: 200, y: 676, width: 900, height: 484),
                    3: CGRect(x: 1132, y: 676, width: 668, height: 484),
                ]
            }
            return true
        }
        session.setGrid(WorkspaceGridSize(columns: 2, rows: 2))
        if session.gridSize.cellCount != 4 || learned[0] != CGSize(width: 900, height: 0) || model.paneFrames.count != 4
            || model.windows[3].frame != model.gridTargets?[0]
        {
            failures.append("actual minimum width was not learned and fitted without inventing a minimum height")
        }
        let frames = Array(model.paneFrames.values)
        for index in frames.indices {
            if frames.indices.contains(where: { $0 != index && frames[index].intersects(frames[$0]) }) {
                failures.append("minimum-size correction left overlapping windows")
                break
            }
        }
        let (blocked, blockedModel) = fixture()
        configureGridFixture(blocked, blockedModel)
        blockedModel.windows[1].minimumSize.width = 1500
        blocked.fitMinimumSizes = { sizes in sizes.values.allSatisfy { $0.width <= 1000 } }
        blocked.setGrid(WorkspaceGridSize(columns: 2, rows: 2))
        if blocked.gridSize != .single || blockedModel.paneFrames.count != 1
            || blockedModel.notices.last?.needsAttention != true
            || blockedModel.notices.last?.text.contains("1×1") != true
        {
            failures.append("infeasible minimum sizes did not reject the overlapping grid explicitly")
        }
        return failures
    }

    private static func checkInput() -> [String] {
        var failures: [String] = []
        func key(_ flags: NSEvent.ModifierFlags = .control, code: UInt16 = 48) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: "\t",
                charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: code)!
        }
        var context = WorkspaceShortcutContext()
        if context.direction(for: key(), ownPID: 1, frontPID: 2, visiblePIDs: [2], enabled: false) != nil {
            failures.append("disabled Control Tab switching still intercepted the shortcut")
        }
        if context.direction(for: key(), ownPID: 1, frontPID: 2, visiblePIDs: [2]) != 1 {
            failures.append("Control Tab was not accepted from a visible external window")
        }
        for _ in 0 ..< 30 {
            if context.direction(for: key(), ownPID: 1, frontPID: 2, visiblePIDs: [3]) != 1 {
                failures.append("continuous Control Tab stopped after AXRaise left keyboard focus in the previous app")
                break
            }
        }
        if context.direction(for: key([.control, .shift, .capsLock]), ownPID: 1, frontPID: 2, visiblePIDs: [3]) != -1 {
            failures.append("reverse switching or Caps Lock support regressed")
        }
        context.reset()
        if context.direction(for: key(), ownPID: 1, frontPID: 2, visiblePIDs: [3]) != nil {
            failures.append("a mouse click did not end the retained shortcut focus context")
        }
        _ = context.direction(for: key(), ownPID: 1, frontPID: 2, visiblePIDs: [2])
        context.applicationDidActivate(9)
        if context.direction(for: key(), ownPID: 1, frontPID: 2, visiblePIDs: [3]) != nil
            || context.direction(for: key([.control, .command]), ownPID: 1, frontPID: 1, visiblePIDs: []) != nil
        {
            failures.append("shortcut context survived an unrelated app activation or accepted a different shortcut")
        }
        _ = context.direction(for: key(), ownPID: 1, frontPID: 2, visiblePIDs: [2])
        _ = context.direction(for: key(.command, code: 50), ownPID: 1, frontPID: 2, visiblePIDs: [3])
        if context.direction(for: key(), ownPID: 1, frontPID: 2, visiblePIDs: [3]) != nil {
            failures.append("switching windows within the same application retained a stale shortcut context")
        }
        context.reset()
        let workspaceKey = key([.control, .option])
        if WorkspaceShortcutContext.workspaceDirection(for: workspaceKey, ownPID: 1, frontPID: 2, managedPIDs: [2]) != 1
            || WorkspaceShortcutContext.workspaceDirection(
                for: key([.control, .option, .shift, .capsLock]), ownPID: 1, frontPID: 1, managedPIDs: []) != -1
        {
            failures.append("Control Option Tab did not switch workspaces from WindowDock or a workspace window")
        }
        if WorkspaceShortcutContext.workspaceDirection(for: workspaceKey, ownPID: 1, frontPID: 9, managedPIDs: [2])
            != nil
            || WorkspaceShortcutContext.workspaceDirection(for: key(), ownPID: 1, frontPID: 2, managedPIDs: [2]) != nil
            || context.direction(for: workspaceKey, ownPID: 1, frontPID: 2, visiblePIDs: [2]) != nil
        {
            failures.append("workspace and tab switching shortcuts overlapped or fired from an unrelated app")
        }

        let (session, model) = fixture(registering: [])
        let candidate = WindowCandidate(element: model.windows[0].element, application: .current, title: "Dragged")
        let original = model.windows[0].originalFrame
        model.windows[0].frame.origin.x += 120
        session.add(candidate, originalFrame: original)
        session.add(candidate, originalFrame: original)
        if session.windows.count != 1 || !session.remove(session.windows[0].id) || model.windows[0].frame != original {
            failures.append("drag registration duplicated a tab or restored the post-drag rather than pre-drag frame")
        }
        return failures
    }

    static func runShortcutChecks() -> [String] { checkInput() }

    private static func checkSplitSelection(layout: WorkspaceSplitLayout) -> [String] {
        var failures: [String] = []
        let (session, model) = fixture()
        let ids = session.windows.map(\.id)
        let full = model.target
        func configure(_ model: Model, for layout: WorkspaceSplitLayout) {
            model.target = full
            if layout == .sideBySide {
                model.target.size.width = 444
                model.rightTarget = CGRect(x: full.minX + 450, y: full.minY, width: 450, height: full.height)
            } else {
                model.target.size.height = 294
                model.rightTarget = CGRect(x: full.minX, y: full.minY + 300, width: full.width, height: 300)
            }
        }
        configure(model, for: layout)
        session.setSplit(true, layout: layout)
        if session.primaryID != ids[2] || session.secondaryID != ids[0] || model.windows[2].frame != model.target
            || model.windows[0].frame != model.rightTarget || Set(model.paneFrames.keys) != Set([ids[2], ids[0]])
        {
            failures.append("split did not display two distinct windows in their pane frames")
        }
        model.operations.removeAll()
        session.focusVisibleWindow(ids[0])
        if session.selectedID != ids[0] || session.primaryID != ids[2] || !model.operations.isEmpty {
            failures.append("focusing the right pane moved windows or changed pane assignments")
        }
        session.select(ids[1])
        if session.primaryID != ids[2] || session.secondaryID != ids[1] || model.windows[1].frame != model.rightTarget
            || model.windows[2].frame != model.target
        {
            failures.append("selecting a hidden tab did not replace only the active right pane")
        }
        let other: WorkspaceSplitLayout = layout == .sideBySide ? .stacked : .sideBySide
        configure(model, for: other)
        session.setSplit(true, layout: other)
        if session.primaryID != ids[2] || session.secondaryID != ids[1] || session.selectedID != ids[1]
            || session.splitLayout != other || model.windows[2].frame != model.target
            || model.windows[1].frame != model.rightTarget
        {
            failures.append("changing split orientation lost the displayed windows or the active pane")
        }
        configure(model, for: layout)
        session.setSplit(true, layout: layout)
        model.operations.removeAll()
        session.select(ids[2])
        if model.operations != [.raise(1), .raise(2)] || session.secondaryID != ids[1] {
            failures.append("selecting a displayed tab resized it or swapped the visible panes")
        }
        session.cycle(1)
        if session.primaryID != ids[0] || session.secondaryID != ids[1] || model.windows[0].frame != model.target
            || model.windows[1].frame != model.rightTarget
        {
            failures.append("tab cycling did not replace the active left pane independently")
        }
        model.target.origin.y += 40
        model.rightTarget.origin.y += 40
        session.sync()
        if model.windows[0].frame != model.target || model.windows[1].frame != model.rightTarget
            || model.windows[2].frame != model.target
        {
            failures.append("workspace movement did not preserve both pane stacks")
        }
        model.failedMoves.insert(1)
        model.target.origin.x += 20
        model.rightTarget.origin.x += 20
        session.sync()
        if Set(model.paneFrames.keys) != Set([ids[0]]) || model.notices.last?.needsAttention != true {
            failures.append("one failed pane movement did not mask only that pane and report its error")
        }
        model.failedMoves.remove(1)
        session.sync()
        if Set(model.paneFrames.keys) != Set([ids[0], ids[1]]) {
            failures.append("failed split pane did not recover independently")
        }
        session.suspend()
        session.resume()
        if model.windows.prefix(3).contains(where: { $0.minimized }) || model.windows[0].frame != model.target
            || model.windows[1].frame != model.rightTarget
        {
            failures.append("split suspension/resume lost a visible pane or its geometry")
        }
        model.target = full
        session.focusVisibleWindow(ids[1])
        session.setSplit(false)
        if session.primaryID != ids[1] || session.isSplit
            || model.windows.prefix(3).contains(where: { $0.frame != full })
            || Set(model.paneFrames.keys) != Set([ids[1]])
        {
            failures.append("disabling split did not expand the active pane and reunite the stack")
        }
        configure(model, for: layout)
        session.setSplit(true, layout: layout)
        if !session.remove(ids[1]) || session.primaryID != ids[2] || session.secondaryID != ids[0] {
            failures.append("removing a visible pane did not fill it from a hidden tab")
        }
        model.target = full
        if !session.remove(ids[2]) || session.isSplit || session.primaryID != ids[0] || model.windows[0].frame != full {
            failures.append("removing down to one tab did not automatically collapse split")
        }
        if !session.remove(ids[0]) || session.primaryID != nil || session.selectedID != nil || !model.paneFrames.isEmpty
        {
            failures.append("removing the final split tab left a stale pane or aperture")
        }
        let (rightSession, rightModel) = fixture()
        let rightIDs = rightSession.windows.map(\.id)
        configure(rightModel, for: layout)
        rightSession.setSplit(true, layout: layout)
        if !rightSession.remove(rightIDs[0]) || rightSession.primaryID != rightIDs[2]
            || rightSession.secondaryID != rightIDs[1] || rightSession.selectedID != rightIDs[2]
        {
            failures.append("removing the inactive right pane changed the active left pane")
        }
        rightSession.focusVisibleWindow(rightIDs[1])
        let addedCandidate = WindowCandidate(
            element: rightModel.windows[3].element, application: .current, title: "New right tab")
        rightSession.add(addedCandidate)
        if rightSession.primaryID != rightIDs[2]
            || rightSession.selected?.candidate.isSameWindow(as: addedCandidate) != true
            || rightSession.secondaryID != rightSession.selectedID
            || rightModel.windows[3].frame != rightModel.rightTarget || rightModel.windows[2].frame != rightModel.target
        {
            failures.append("adding a tab to the active right pane displaced the left pane")
        }
        return failures.map { "\(layout): \($0)" }
    }

    private static func checkBatchAddition() -> [String] {
        var failures: [String] = []
        let (session, model) = fixture(registering: [])
        let candidates = model.windows.map {
            WindowCandidate(element: $0.element, application: .current, title: "Batch")
        }
        session.add([candidates[0], candidates[2], candidates[0], candidates[1]])
        if session.windows.count != 3 || session.selected?.candidate.isSameWindow(as: candidates[1]) != true
            || model.changeCount != 1
            || model.operations.filter({
                if case .raise = $0 { return true }
                return false
            }) != [.raise(1)] || model.windows.prefix(3).contains(where: { $0.minimized || $0.frame != model.target })
        {
            failures.append("batch addition did not register unique windows and present only the final tab")
        }
        if !session.restoreAll().isEmpty
            || model.windows.prefix(3).contains(where: {
                $0.frame != $0.originalFrame || $0.minimized != $0.originallyMinimized
            })
        {
            failures.append("batch addition did not preserve original window states")
        }

        let (partial, partialModel) = fixture(registering: [])
        partialModel.failedRegistrations.insert(1)
        let partialCandidates = partialModel.windows.map {
            WindowCandidate(element: $0.element, application: .current, title: "Partial batch")
        }
        partial.add(Array(partialCandidates.prefix(3)))
        if partial.windows.count != 2 || partialModel.changeCount != 1
            || partial.selected?.candidate.isSameWindow(as: partialCandidates[2]) != true
            || partialModel.notices.last?.needsAttention != true
            || partialModel.windows[1].frame != partialModel.windows[1].originalFrame
        {
            failures.append("partial batch failure blocked valid windows, modified a rejected window or lost its error")
        }
        return failures
    }

    private static func checkPartialFailures() -> [String] {
        var failures: [String] = []
        let (session, model) = fixture()
        model.failedMoves.insert(1)
        model.target.origin.x += 50
        session.sync()
        if model.windows[0].frame != model.target || model.windows[2].frame != model.target
            || model.notices.last?.needsAttention != true
            || model.notices.last?.text.contains("Injected window operation failure") != true
        {
            failures.append("one failed background move blocked the other tabs or failed silently")
        }
        model.failedMoves.remove(1)
        session.sync()
        if model.windows[1].frame != model.target || model.operations.last != .raise(2) {
            failures.append("failed background alignment was not retried beneath the selected window")
        }
        model.failedMoves.insert(2)
        model.target.origin.y += 30
        session.sync()
        if model.presentedFrames.last != .some(nil) || model.notices.last?.needsAttention != true {
            failures.append("failed selected-window movement left a stale transparent aperture")
        }
        model.failedMoves.remove(2)
        session.sync()
        if model.presentedFrames.last != .some(model.target) {
            failures.append("selected-window alignment did not recover after an error")
        }
        model.failedMinimizations.insert(0)
        session.suspend()
        if !model.windows[1].minimized || !model.windows[2].minimized || model.notices.last?.needsAttention != true {
            failures.append("one failed minimization blocked suspension of the remaining stack")
        }
        model.failedMinimizations.remove(0)
        session.resume()
        if model.windows.prefix(3).contains(where: { $0.minimized }) {
            failures.append("partial suspension could not be resumed")
        }
        return failures
    }
}
