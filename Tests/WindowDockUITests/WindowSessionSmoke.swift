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

    /// Child process for `runFrontWindowOnlyActivationChecks`: an inactive app with three windows.
    static func runActivationHelper(_ application: NSApplication, resizable: Bool = false) {
        // Regular apps activate themselves at launch; becoming regular afterwards keeps this one in the background.
        application.setActivationPolicy(.accessory)
        DispatchQueue.main.async { application.setActivationPolicy(.regular) }
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
        guard let application = NSRunningApplication(processIdentifier: helper.pid),
              let element = WindowAccess.windowElements(application)?.first(where: {
                  WindowAccess.windowID(of: $0) == CGWindowID(helper.windows[0])
              })
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

    static func runChecks() -> [String] {
        var failures: [String] = []
        failures += runNestedPaneChecks()
        failures += runPanePinChecks()
        failures += runTabSelectionFeedbackChecks()
        failures += runNestedPaneUIChecks()
        failures += runNestedPaneLimitChecks()
        failures += runNestedPaneMinimumChecks()
        failures += runManyTabMoveChecks()
        failures += runRemovalApertureChecks()
        failures += runCloseOnReleaseChecks()
        failures += runDisplacedWindowChecks()
        failures += runWindowEventRefitChecks()
        failures += runWindowEventReturnPolicyChecks()
        failures += runReresolveChecks()
        failures += runTabTransferRevealChecks()
        failures += runOutsideTabDropChecks()
        failures += runConstraintNoticeChecks()
        failures += runTransferChecks()
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
