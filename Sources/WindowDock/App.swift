import AppKit
import Sparkle
import WindowDockCore

@main
enum WindowDockApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var sessionInactive = false
    private static var isScreenUnavailable: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return (info["CGSSessionScreenIsLocked"] as? Bool) == true || (info["kCGSessionOnConsoleKey"] as? Bool) == false
    }
    private var pruneResumeDate = Date.distantPast

    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var controllers: [WorkspaceController] = []
    private var workspaceCounter = 0
    private var skipLayoutSave = false
    private var workspaceMenu: NSMenu!
    private var timer: Timer?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var quitting = false
    private var monitorTrust: Bool?
    private var shortcutContext = WorkspaceShortcutContext()
    private var windowDragTracker = WorkspaceWindowDragTracker()
    private var windowDragRegistration = WorkspaceWindowDragRegistration()
    private var dragTimer: Timer?
    private var lastWindowSnapshot: TimeInterval = 0
    private var dragSamplingFailed = false
    private var activeTabDrag: (controller: WorkspaceController, id: UUID, token: String, button: NSButton)?
    private lazy var activation = WorkspaceActivation { [weak self] in self?.controllers ?? [] }

    private var activeController: WorkspaceController? { activation.activeController }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp]) { [weak self] event in
            if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
                self?.shortcutContext.reset()
                self?.cancelWindowDrag()
                return event
            }
            if event.type == .leftMouseUp {
                self?.controllers.forEach { $0.scheduleSelectedWindowRaiseIfPending() }
                return event
            }
            if self?.handleShortcut(event) == true { return nil }
            return event
        }
        refreshGlobalMonitor()
        startWindowDragMonitoring()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sessionInactive = true
            }
        }
        center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sessionInactive = false
                self?.pruneResumeDate = Date().addingTimeInterval(5)
                // Global event monitors can stop delivering events across a session switch.
                self?.refreshGlobalMonitor(force: true)
            }
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sessionInactive = true
            }
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sessionInactive = false
                self?.pruneResumeDate = Date().addingTimeInterval(5)
                // Global event monitors can stop delivering events across a session switch.
                self?.refreshGlobalMonitor(force: true)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshGlobalMonitor()
                // While the login window / another user is in front, AX queries fail; don't mistake that for closed windows.
                guard let self, self.activeTabDrag == nil, !self.sessionInactive,
                      !Self.isScreenUnavailable, Date() >= self.pruneResumeDate else { return }
                self.controllers.forEach { $0.session.pruneClosedWindows() }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        let saved = chooseWorkspacesToRestore(SavedLayout.load().filter { !$0.windows.isEmpty })
        let first = addWorkspace(name: saved.first?.name)
        if !saved.isEmpty { restore(saved[...], in: first) }
    }

    /// Lets the user pick which saved workspaces to bring back; a single workspace needs no question.
    private func chooseWorkspacesToRestore(_ workspaces: [SavedWorkspace]) -> [SavedWorkspace] {
        guard workspaces.count > 1 else { return workspaces }
        let checks = workspaces.map { workspace -> NSButton in
            let check = NSButton(
                checkboxWithTitle: "\(workspace.name) — " + L("%d個のウィンドウ", workspace.windows.count),
                target: nil, action: nil
            )
            check.state = .on
            return check
        }
        let list = NSStackView(views: checks)
        list.orientation = .vertical
        list.alignment = .leading
        list.frame = NSRect(origin: .zero, size: list.fittingSize)
        let alert = NSAlert()
        alert.messageText = L("前回のワークスペースを復元")
        alert.informativeText = L("復元するワークスペースを選んでください。")
        alert.accessoryView = list
        alert.addButton(withTitle: L("復元"))
        alert.addButton(withTitle: L("復元しない"))
        guard alert.runModal() == .alertFirstButtonReturn else { return [] }
        return zip(workspaces, checks).filter { $0.1.state == .on }.map { $0.0 }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let active = activeController
        for controller in controllers {
            let item = NSMenuItem(title: controller.name, action: #selector(showWorkspace(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = controller
            item.state = controller === active ? .on : .off
            menu.addItem(item)
        }
        appendClosedWorkspaces(to: menu)
        menu.addItem(.separator())
        let new = NSMenuItem(title: L("新規ワークスペース"), action: #selector(newWorkspace), keyEquivalent: "")
        new.target = self
        menu.addItem(new)
        return menu
    }

    /// Asks for every workspace's windows first and adds them all afterwards, so that activating one workspace's
    /// windows never covers the dialog of the next workspace.
    private func restore(_ workspaces: ArraySlice<SavedWorkspace>, in controller: WorkspaceController,
                         chosen: [(WorkspaceController, [WindowCandidate], WorkspaceGridSize?)] = []) {
        guard let workspace = workspaces.first else { return }
        var chosen = chosen
        var picked: [WindowCandidate] = []
        controller.presentPicker(
            restoring: workspace.windows,
            excluding: chosen.flatMap { $0.1 },
            collect: { picked = $0 }
        ) { [weak self] in
            guard let self else { return }
            chosen.append((controller, picked, workspace.gridSize))
            if let next = workspaces.dropFirst().first {
                self.restore(workspaces.dropFirst(), in: self.addWorkspace(name: next.name), chosen: chosen)
                return
            }
            for (controller, candidates, grid) in chosen.reversed() {
                if let grid { controller.session.setGrid(grid) }
                if !candidates.isEmpty { controller.session.add(candidates) }
            }
            chosen.first?.0.bringToFront()
            chosen.first?.0.scheduleSelectedWindowRaise()
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let updateItem = NSMenuItem(title: L("アップデートを確認…"), action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = updater
        appMenu.addItem(updateItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("WindowDock を終了"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let workspaceItem = NSMenuItem()
        workspaceMenu = NSMenu(title: L("ワークスペース"))
        workspaceMenu.delegate = self
        workspaceItem.submenu = workspaceMenu
        menu.addItem(workspaceItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L("ウィンドウ"))
        windowMenu.addItem(withTitle: L("ウィンドウを追加…"), action: #selector(showPicker), keyEquivalent: "o")
        windowMenu.addItem(withTitle: L("選択中のタブを解除"), action: #selector(removeSelected), keyEquivalent: "w")
        let nextTab = windowMenu.addItem(withTitle: L("次のタブ"), action: #selector(selectNextTab), keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = [.control]
        let previousTab = windowMenu.addItem(withTitle: L("前のタブ"), action: #selector(selectPreviousTab), keyEquivalent: "\t")
        previousTab.keyEquivalentModifierMask = [.control, .shift]
        windowMenu.addItem(withTitle: L("最小化"), action: #selector(minimizeWorkspace), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("最大化 / 復元"), action: #selector(maximizeWorkspace), keyEquivalent: "")
        windowMenu.addItem(withTitle: L("列数を1 / 2に切替"), action: #selector(toggleSplit), keyEquivalent: "")
        windowMenu.addItem(withTitle: L("行数を1 / 2に切替"), action: #selector(toggleStackedSplit), keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
    }

    /// Rebuilt each time it opens: fixed commands, then every workspace with its registered windows.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === workspaceMenu else { return }
        menu.removeAllItems()
        menu.addItem(withTitle: L("新規ワークスペース"), action: #selector(newWorkspace), keyEquivalent: "n")
        menu.addItem(withTitle: L("ワークスペース名を変更…"), action: #selector(renameWorkspace), keyEquivalent: "")
        let close = menu.addItem(withTitle: L("ワークスペースを閉じる"), action: #selector(closeWorkspace), keyEquivalent: "w")
        close.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: L("ワークスペースを削除…"), action: #selector(deleteWorkspace), keyEquivalent: "")
        menu.addItem(.separator())
        let active = activeController
        for controller in controllers {
            let item = NSMenuItem(
                title: "\(controller.name) — " + L("%d個のウィンドウ", controller.session.windows.count),
                action: #selector(showWorkspace(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = controller
            item.state = controller === active ? .on : .off
            menu.addItem(item)
            for managed in controller.session.windows {
                let windowItem = NSMenuItem(title: managed.candidate.label, action: #selector(showWorkspaceWindow(_:)), keyEquivalent: "")
                windowItem.target = self
                windowItem.indentationLevel = 1
                windowItem.representedObject = WorkspaceWindowRef(controller: controller, id: managed.id)
                windowItem.state = controller.session.selectedID == managed.id ? .mixed : .off
                menu.addItem(windowItem)
            }
        }
        appendClosedWorkspaces(to: menu)
    }

    /// Saved workspaces that are not open right now; each can be reopened or deleted.
    private func appendClosedWorkspaces(to menu: NSMenu) {
        let open = Set(controllers.map(\.name))
        let closed = SavedLayout.load().filter { !open.contains($0.name) }
        guard !closed.isEmpty else { return }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("閉じているワークスペース"), action: nil, keyEquivalent: "").isEnabled = false
        for workspace in closed {
            let item = NSMenuItem(
                title: "\(workspace.name) — " + L("%d個のウィンドウ", workspace.windows.count),
                action: nil, keyEquivalent: ""
            )
            let submenu = NSMenu()
            let reopen = NSMenuItem(title: L("開く"), action: #selector(reopenSavedWorkspace(_:)), keyEquivalent: "")
            let delete = NSMenuItem(title: L("ワークスペースを削除…"), action: #selector(deleteSavedWorkspace(_:)), keyEquivalent: "")
            for entry in [reopen, delete] {
                entry.target = self
                entry.representedObject = workspace.name
                submenu.addItem(entry)
            }
            item.submenu = submenu
            menu.addItem(item)
        }
    }

    @objc private func reopenSavedWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let workspace = SavedLayout.load().first(where: { $0.name == name }) else { return }
        let controller = addWorkspace(name: workspace.name)
        if let grid = workspace.gridSize { controller.session.setGrid(grid) }
        controller.presentPicker(restoring: workspace.windows, completion: nil)
    }

    @objc private func deleteSavedWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = L("ワークスペース「%@」を削除しますか？", name)
        alert.informativeText = L("閉じるだけでは前回の構成に残ります。削除すると次回の復元候補からも外れます。")
        alert.addButton(withTitle: L("削除"))
        alert.addButton(withTitle: L("キャンセル"))
        if alert.runModal() == .alertFirstButtonReturn { SavedLayout.remove(named: name) }
    }

    private final class WorkspaceWindowRef: NSObject {
        let controller: WorkspaceController
        let id: UUID
        init(controller: WorkspaceController, id: UUID) {
            self.controller = controller
            self.id = id
        }
    }

    @objc private func showWorkspace(_ sender: NSMenuItem) {
        guard let controller = sender.representedObject as? WorkspaceController else { return }
        activation.show(controller)
    }

    @objc private func showWorkspaceWindow(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? WorkspaceWindowRef else { return }
        ref.controller.session.select(ref.id)
        activation.show(ref.controller)
    }

    // MARK: Workspaces

    @objc private func newWorkspace() { addWorkspace() }

    @discardableResult
    private func addWorkspace(name: String? = nil) -> WorkspaceController {
        let controller = WorkspaceController(name: name ?? nextWorkspaceName())
        controller.onClose = { [weak self] in self?.close($0) }
        controller.onSessionChange = { [weak self] controller in
            guard let self, !self.quitting else { return }
            let workspace = self.savedWorkspace(controller)
            if !workspace.windows.isEmpty { SavedLayout.upsert([workspace]) }
        }
        controller.onRename = { [weak self] in self?.rename($0) }
        controller.onDelete = { [weak self] in self?.delete($0) }
        controller.onSuspend = { [weak self] in
            self?.shortcutContext.reset()
            self?.cancelWindowDrag()
            self?.clearTabDrag()
        }
        controller.isRegisteredElsewhere = { [weak self, weak controller] candidate in
            guard let self else { return false }
            return self.controllers.contains { $0 !== controller && $0.session.contains(candidate) }
        }
        controller.onTabDragBegin = { [weak self, weak controller] id, token, button in
            guard let self, let controller else { return }
            self.clearTabDrag()
            self.cancelWindowDrag()
            self.activeTabDrag = (controller, id, token, button)
        }
        controller.onTabDragMove = { [weak self] token, board, button, point in
            guard let self, let drag = self.activeTabDrag, drag.token == token, drag.button === button else { return }
            let destination = self.tabDragDestination(at: point, from: drag.controller)
            let target = destination === drag.controller ? nil : destination
            for controller in self.controllers where controller !== target {
                controller.hideTabTransferTargets()
            }
            target?.previewTabTransfer(pasteboard: board, source: button, at: point)
        }
        controller.acceptsExternalTab = { [weak self, weak controller] token, button in
            guard let self, let drag = self.activeTabDrag, let controller else { return false }
            return drag.controller !== controller && drag.token == token && drag.button === button
        }
        controller.onExternalTabDrop = { [weak self, weak controller] token, button, index, cell in
            guard let self, let controller, let drag = self.activeTabDrag,
                  drag.token == token, drag.button === button, drag.controller !== controller else { return false }
            return self.transferDraggedTab(to: controller, index: index, cell: cell)
        }
        controller.onTabDragEnd = { [weak self] token, board, point, cancelled in
            guard let self, let drag = self.activeTabDrag, drag.token == token else { return }
            if !cancelled, drag.controller.acceptsWindowDrag,
               let destination = self.tabDragDestination(at: point, from: drag.controller) {
                _ = destination.completeTabDrop(pasteboard: board, source: drag.button, at: point)
            }
            self.clearTabDrag()
        }
        if let origin = activeController?.window.frame.origin {
            controller.window.setFrameOrigin(NSPoint(x: origin.x + 30, y: origin.y - 30))
        }
        controllers.append(controller)
        controller.bringToFront()
        return controller
    }

    private func tabDragDestination(at point: NSPoint, from source: WorkspaceController) -> WorkspaceController? {
        let candidates = NSApp.orderedWindows.compactMap { window in
            controllers.first { $0 !== source && $0.window === window && $0.acceptsWindowDrag }
        }
        switch WorkspaceTabDragRoute.resolve(
            at: point, sourceFrame: source.window.frame, sourceTabRowContains: source.tabRowContains(point),
            destinationFrames: candidates.map { $0.window.frame }
        ) {
        case .none: return nil
        case .source: return source
        case .transfer(let index): return candidates[index]
        }
    }

    private func clearTabDrag() {
        activeTabDrag?.controller.endTabTransferDrag()
        activeTabDrag = nil
        controllers.forEach { $0.hideTabTransferTargets() }
    }

    @discardableResult
    private func transferDraggedTab(to destination: WorkspaceController, index: Int? = nil, cell: Int? = nil) -> Bool {
        guard let drag = activeTabDrag else { return false }
        clearTabDrag()
        guard drag.controller.session.transferWindow(drag.id, to: destination.session, at: index, cell: cell) else { return false }
        SavedLayout.upsert([savedWorkspace(drag.controller), savedWorkspace(destination)])
        destination.bringToFront()
        destination.scheduleSelectedWindowRaise()
        return true
    }

    /// The first "Workspace N" not used by an open or saved workspace.
    private func nextWorkspaceName() -> String {
        let used = Set(controllers.map(\.name) + SavedLayout.load().map(\.name))
        workspaceCounter = 1
        while used.contains(L("ワークスペース %d", workspaceCounter)) { workspaceCounter += 1 }
        return L("ワークスペース %d", workspaceCounter)
    }

    @objc private func renameWorkspace() {
        if let controller = activeController { rename(controller) }
    }

    private func rename(_ controller: WorkspaceController) {
        let alert = NSAlert()
        alert.messageText = L("ワークスペース名を変更")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = controller.name
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L("キャンセル"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = Set(controllers.filter { $0 !== controller }.map(\.name) + SavedLayout.load().map(\.name))
        if !name.isEmpty, taken.contains(name) {
            let notice = NSAlert()
            notice.messageText = L("同じ名前のワークスペースが既にあります。")
            notice.runModal()
        } else if !name.isEmpty {
            SavedLayout.remove(named: controller.name)
            controller.name = name
        }
    }

    @objc private func closeWorkspace() {
        if let controller = activeController { close(controller) }
    }

    @objc private func deleteWorkspace() {
        if let controller = activeController { delete(controller) }
    }

    private func delete(_ controller: WorkspaceController) {
        let alert = NSAlert()
        alert.messageText = L("ワークスペース「%@」を削除しますか？", controller.name)
        alert.informativeText = L("閉じるだけでは前回の構成に残ります。削除すると次回の復元候補からも外れます。")
        alert.addButton(withTitle: L("削除"))
        alert.addButton(withTitle: L("キャンセル"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        close(controller, forget: true)
    }

    private func savedWorkspace(_ controller: WorkspaceController) -> SavedWorkspace {
        SavedWorkspace(name: controller.name, windows: controller.session.windows.compactMap { window in
            guard let id = window.candidate.application.bundleIdentifier else { return nil }
            return SavedWindow(bundleID: id, title: window.candidate.title, frame: window.originalFrame)
        }, columns: controller.session.gridSize.columns, rows: controller.session.gridSize.rows)
    }

    /// Restores the workspace's windows to their original positions and closes it; closing the last workspace quits.
    /// A closed workspace stays in the saved layout unless `forget` is set.
    private func close(_ controller: WorkspaceController, forget: Bool = false) {
        clearTabDrag()
        if forget {
            SavedLayout.remove(named: controller.name)
        } else if controllers.count > 1 {
            let workspace = savedWorkspace(controller)
            if !workspace.windows.isEmpty { SavedLayout.upsert([workspace]) }
        }
        if controllers.count == 1 {
            skipLayoutSave = forget
            NSApp.terminate(nil)
            skipLayoutSave = false
            return
        }
        let failures = controller.session.restoreAll()
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("一部のウィンドウを元に戻せませんでした")
            alert.informativeText = failures.joined(separator: "\n")
            alert.addButton(withTitle: L("閉じる"))
            alert.addButton(withTitle: L("戻って再試行"))
            if alert.runModal() == .alertSecondButtonReturn { return }
        }
        controllers.removeAll { $0 === controller }
        if forget { SavedLayout.remove(named: controller.name) }
        controller.window.delegate = nil
        controller.window.orderOut(nil)
        controller.window.close()
        controllers.last?.bringToFront()
    }

    // MARK: Menu actions for the active workspace

    @objc private func showPicker() { activeController?.showPicker() }
    @objc private func removeSelected() { activeController?.removeSelected() }
    @objc private func selectNextTab() { activeController?.session.cycle(1) }
    @objc private func selectPreviousTab() { activeController?.session.cycle(-1) }
    @objc private func minimizeWorkspace() { activeController?.minimizeWorkspace() }
    @objc private func maximizeWorkspace() { activeController?.maximizeWorkspace() }
    @objc private func toggleSplit() { activeController?.toggleSplit() }
    @objc private func toggleStackedSplit() { activeController?.toggleStackedSplit() }

    // MARK: Input monitoring

    private func handleShortcut(_ event: NSEvent) -> Bool {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let target = controllers.first { $0.canHandleShortcut && $0.window.isKeyWindow } ??
            controllers.first { $0.canHandleShortcut && frontPID.map($0.visiblePIDs.contains) == true } ??
            controllers.first { $0.canHandleShortcut }
        guard let target, let direction = shortcutContext.direction(
            for: event, ownPID: ProcessInfo.processInfo.processIdentifier,
            frontPID: frontPID, visiblePIDs: target.visiblePIDs
        ) else { return false }
        target.session.cycle(direction)
        return true
    }

    @objc private func frontApplicationChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        shortcutContext.applicationDidActivate(app.processIdentifier)
    }

    private func refreshGlobalMonitor(force: Bool = false) {
        let trusted = WindowAccess.isTrusted
        guard force || monitorTrust != trusted || globalMonitor == nil else { return }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        monitorTrust = trusted
        let mask: NSEvent.EventTypeMask = trusted
            ? [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            : [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return }
            let point = NSEvent.mouseLocation
            switch event.type {
            case .leftMouseDown:
                self.shortcutContext.reset()
                DispatchQueue.main.async { self.controllers.forEach { $0.focusPane(at: point) } }
            case .rightMouseDown, .otherMouseDown:
                self.shortcutContext.reset()
                self.cancelWindowDrag()
            case .keyDown:
                _ = self.handleShortcut(event)
            default:
                break
            }
        }
        if globalMonitor == nil {
            activeController?.showNotice(.attention(L("キー・マウス監視を開始できませんでした。アクセシビリティ権限を確認し、WindowDock を起動し直してください。")))
            WindowAccess.logger.error("Could not install workspace input monitor")
        }
    }

    // MARK: Window drag and drop

    private func startWindowDragMonitoring() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollWindowDrag() }
        }
        dragTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pollWindowDrag() {
        guard activeTabDrag == nil else { return }
        guard !quitting, controllers.contains(where: \.acceptsWindowDrag), let screen = NSScreen.screens.first else {
            cancelWindowDrag()
            return
        }
        let down = NSEvent.pressedMouseButtons & 1 != 0
        let now = ProcessInfo.processInfo.systemUptime
        guard down || windowDragTracker.isTrackingPress || now - lastWindowSnapshot >= 0.2 else { return }
        lastWindowSnapshot = now
        let point = NSEvent.mouseLocation
        let axPoint = CGPoint(x: point.x, y: screen.frame.maxY - point.y)
        do {
            let windows = try WindowAccess.windowServerWindows()
            dragSamplingFailed = false
            switch windowDragTracker.update(
                buttonDown: down, point: axPoint, windows: windows.filter { $0.layer == 0 },
                ownPID: ProcessInfo.processInfo.processIdentifier
            ) {
            case .idle:
                windowDragRegistration.reset()
                controllers.forEach { $0.hideWindowDropTarget() }
            case .moving(let drag):
                if NSRunningApplication(processIdentifier: drag.window.processID)?.activationPolicy == .regular {
                    let target = try windowDropTarget(at: point, accessibilityPoint: axPoint, drag: drag, windows: windows)
                    for controller in controllers {
                        if controller === target {
                            controller.showWindowDropTarget(at: point)
                        } else {
                            controller.hideWindowDropTarget()
                        }
                    }
                } else {
                    controllers.forEach { $0.hideWindowDropTarget() }
                }
            case .released(let drag):
                defer { windowDragRegistration.reset() }
                let target = try windowDropTarget(at: point, accessibilityPoint: axPoint, drag: drag, windows: windows)
                controllers.forEach { $0.hideWindowDropTarget() }
                if NSRunningApplication(processIdentifier: drag.window.processID)?.activationPolicy == .regular {
                    target?.finishWindowDrag(drag, accessibilityPoint: axPoint, screenPoint: point)
                }
            }
        } catch {
            cancelWindowDrag()
            if !dragSamplingFailed {
                dragSamplingFailed = true
                WindowAccess.logger.error("\(error.localizedDescription, privacy: .public)")
                activeController?.showNotice(.attention(error.localizedDescription))
            }
        }
    }

    private func windowDropTarget(
        at point: NSPoint, accessibilityPoint: CGPoint, drag: WorkspaceWindowDrag, windows: [WindowServerWindow]
    ) throws -> WorkspaceController? {
        var excluded: Set<CGWindowID> = [drag.window.id]
        for controller in controllers {
            if let number = controller.windowDropPanelNumber, number > 0 {
                excluded.insert(CGWindowID(number))
            }
        }
        guard let frontmost = WindowHitTesting.frontmostWindow(
            at: accessibilityPoint, windows: windows.map { (id: $0.id, frame: $0.frame) }, excluding: excluded
        ) else { return nil }
        guard let target = controllers.first(where: {
            $0.window.windowNumber > 0 && CGWindowID($0.window.windowNumber) == frontmost &&
                $0.acceptsWindowDrop(at: point)
        }) else { return nil }
        let registered = controllers.flatMap { $0.session.windows.map(\.candidate) }
        guard try !windowDragRegistration.isRegistered(drag.window, among: registered) else { return nil }
        return target
    }

    private func cancelWindowDrag() {
        windowDragTracker.cancel()
        windowDragRegistration.reset()
        controllers.forEach { $0.hideWindowDropTarget() }
    }

    // MARK: Application lifecycle

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshGlobalMonitor()
        activation.applicationDidBecomeActive()
    }

    /// A Dock click brings back only the last used workspace; others are reachable from the Dock menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        activation.reopen()
        return false
    }

    func applicationDidHide(_ notification: Notification) {
        controllers.forEach { $0.applicationDidHide() }
    }

    func applicationDidUnhide(_ notification: Notification) {
        controllers.forEach { $0.applicationDidUnhide() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitting = true
        controllers.forEach { $0.quitting = true }
        let saved = controllers.map(savedWorkspace).filter { !$0.windows.isEmpty }
        if !saved.isEmpty && !skipLayoutSave { SavedLayout.upsert(saved) }
        let failures = controllers.flatMap { $0.session.restoreAll() }
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("一部のウィンドウを元に戻せませんでした")
            alert.informativeText = failures.joined(separator: "\n")
            alert.addButton(withTitle: L("終了"))
            alert.addButton(withTitle: L("戻って再試行"))
            if alert.runModal() == .alertSecondButtonReturn {
                quitting = false
                controllers.forEach { $0.quitting = false }
                return .terminateCancel
            }
        }
        timer?.invalidate()
        dragTimer?.invalidate()
        cancelWindowDrag()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        return .terminateNow
    }
}
