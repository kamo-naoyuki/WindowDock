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
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var controllers: [WorkspaceController] = []
    private var projectCounter = 0
    private var skipLayoutSave = false
    private var projectMenu: NSMenu!
    private var timer: Timer?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var quitting = false
    private var monitorTrust: Bool?
    private var shortcutContext = WorkspaceShortcutContext()
    private var windowDragTracker = WorkspaceWindowDragTracker()
    private var dragTimer: Timer?
    private var lastWindowSnapshot: TimeInterval = 0
    private var dragSamplingFailed = false

    /// The project whose window is key, falling back to the main or first one.
    private var activeController: WorkspaceController? {
        controllers.first { $0.window.isKeyWindow } ??
            controllers.first { $0.window.isMainWindow } ?? controllers.first
    }

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
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshGlobalMonitor()
                self?.controllers.forEach { $0.session.pruneClosedWindows() }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        let saved = chooseProjectsToRestore(SavedLayout.load().filter { !$0.windows.isEmpty })
        let first = addProject(name: saved.first?.name)
        if !saved.isEmpty { restore(saved[...], in: first) }
    }

    /// Lets the user pick which saved projects to bring back; a single project needs no question.
    private func chooseProjectsToRestore(_ projects: [SavedProject]) -> [SavedProject] {
        guard projects.count > 1 else { return projects }
        let checks = projects.map { project -> NSButton in
            let check = NSButton(
                checkboxWithTitle: "\(project.name) — " + L("%d個のウィンドウ", project.windows.count),
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
        alert.messageText = L("前回のプロジェクトを復元")
        alert.informativeText = L("復元するプロジェクトを選んでください。")
        alert.accessoryView = list
        alert.addButton(withTitle: L("復元"))
        alert.addButton(withTitle: L("復元しない"))
        guard alert.runModal() == .alertFirstButtonReturn else { return [] }
        return zip(projects, checks).filter { $0.1.state == .on }.map { $0.0 }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let active = activeController
        for controller in controllers {
            let item = NSMenuItem(title: controller.name, action: #selector(showProject(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = controller
            item.state = controller === active ? .on : .off
            menu.addItem(item)
        }
        appendClosedProjects(to: menu)
        menu.addItem(.separator())
        let new = NSMenuItem(title: L("新規プロジェクト"), action: #selector(newProject), keyEquivalent: "")
        new.target = self
        menu.addItem(new)
        return menu
    }

    /// Asks for every project's windows first and adds them all afterwards, so that activating one project's
    /// windows never covers the dialog of the next project.
    private func restore(_ projects: ArraySlice<SavedProject>, in controller: WorkspaceController,
                         chosen: [(WorkspaceController, [WindowCandidate], WorkspaceGridSize?)] = []) {
        guard let project = projects.first else { return }
        var chosen = chosen
        var picked: [WindowCandidate] = []
        controller.presentPicker(
            restoring: project.windows,
            excluding: chosen.flatMap { $0.1 },
            collect: { picked = $0 }
        ) { [weak self] in
            guard let self else { return }
            chosen.append((controller, picked, project.gridSize))
            if let next = projects.dropFirst().first {
                self.restore(projects.dropFirst(), in: self.addProject(name: next.name), chosen: chosen)
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

        let projectItem = NSMenuItem()
        projectMenu = NSMenu(title: L("プロジェクト"))
        projectMenu.delegate = self
        projectItem.submenu = projectMenu
        menu.addItem(projectItem)

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

    /// Rebuilt each time it opens: fixed commands, then every project with its registered windows.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === projectMenu else { return }
        menu.removeAllItems()
        menu.addItem(withTitle: L("新規プロジェクト"), action: #selector(newProject), keyEquivalent: "n")
        menu.addItem(withTitle: L("プロジェクト名を変更…"), action: #selector(renameProject), keyEquivalent: "")
        let close = menu.addItem(withTitle: L("プロジェクトを閉じる"), action: #selector(closeProject), keyEquivalent: "w")
        close.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: L("プロジェクトを削除…"), action: #selector(deleteProject), keyEquivalent: "")
        menu.addItem(.separator())
        let active = activeController
        for controller in controllers {
            let item = NSMenuItem(
                title: "\(controller.name) — " + L("%d個のウィンドウ", controller.session.windows.count),
                action: #selector(showProject(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = controller
            item.state = controller === active ? .on : .off
            menu.addItem(item)
            for managed in controller.session.windows {
                let windowItem = NSMenuItem(title: managed.candidate.label, action: #selector(showProjectWindow(_:)), keyEquivalent: "")
                windowItem.target = self
                windowItem.indentationLevel = 1
                windowItem.representedObject = ProjectWindowRef(controller: controller, id: managed.id)
                windowItem.state = controller.session.selectedID == managed.id ? .mixed : .off
                menu.addItem(windowItem)
            }
        }
        appendClosedProjects(to: menu)
    }

    /// Saved projects that are not open right now; each can be reopened or deleted.
    private func appendClosedProjects(to menu: NSMenu) {
        let open = Set(controllers.map(\.name))
        let closed = SavedLayout.load().filter { !open.contains($0.name) }
        guard !closed.isEmpty else { return }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("閉じているプロジェクト"), action: nil, keyEquivalent: "").isEnabled = false
        for project in closed {
            let item = NSMenuItem(
                title: "\(project.name) — " + L("%d個のウィンドウ", project.windows.count),
                action: nil, keyEquivalent: ""
            )
            let submenu = NSMenu()
            let reopen = NSMenuItem(title: L("開く"), action: #selector(reopenSavedProject(_:)), keyEquivalent: "")
            let delete = NSMenuItem(title: L("プロジェクトを削除…"), action: #selector(deleteSavedProject(_:)), keyEquivalent: "")
            for entry in [reopen, delete] {
                entry.target = self
                entry.representedObject = project.name
                submenu.addItem(entry)
            }
            item.submenu = submenu
            menu.addItem(item)
        }
    }

    @objc private func reopenSavedProject(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let project = SavedLayout.load().first(where: { $0.name == name }) else { return }
        let controller = addProject(name: project.name)
        if let grid = project.gridSize { controller.session.setGrid(grid) }
        controller.presentPicker(restoring: project.windows, completion: nil)
    }

    @objc private func deleteSavedProject(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = L("プロジェクト「%@」を削除しますか？", name)
        alert.informativeText = L("閉じるだけでは前回の構成に残ります。削除すると次回の復元候補からも外れます。")
        alert.addButton(withTitle: L("削除"))
        alert.addButton(withTitle: L("キャンセル"))
        if alert.runModal() == .alertFirstButtonReturn { SavedLayout.remove(named: name) }
    }

    private final class ProjectWindowRef: NSObject {
        let controller: WorkspaceController
        let id: UUID
        init(controller: WorkspaceController, id: UUID) {
            self.controller = controller
            self.id = id
        }
    }

    @objc private func showProject(_ sender: NSMenuItem) {
        (sender.representedObject as? WorkspaceController)?.bringToFront()
    }

    @objc private func showProjectWindow(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? ProjectWindowRef else { return }
        ref.controller.session.select(ref.id)
        ref.controller.bringToFront()
    }

    // MARK: Projects

    @objc private func newProject() { addProject() }

    @discardableResult
    private func addProject(name: String? = nil) -> WorkspaceController {
        let controller = WorkspaceController(name: name ?? nextProjectName())
        controller.onClose = { [weak self] in self?.close($0) }
        controller.onSessionChange = { [weak self] controller in
            guard let self, !self.quitting else { return }
            let project = self.savedProject(controller)
            if !project.windows.isEmpty { SavedLayout.upsert([project]) }
        }
        controller.onRename = { [weak self] in self?.rename($0) }
        controller.onDelete = { [weak self] in self?.delete($0) }
        controller.onSuspend = { [weak self] in
            self?.shortcutContext.reset()
            self?.cancelWindowDrag()
        }
        controller.isRegisteredElsewhere = { [weak self, weak controller] candidate in
            guard let self else { return false }
            return self.controllers.contains { $0 !== controller && $0.session.contains(candidate) }
        }
        if let origin = activeController?.window.frame.origin {
            controller.window.setFrameOrigin(NSPoint(x: origin.x + 30, y: origin.y - 30))
        }
        controllers.append(controller)
        controller.bringToFront()
        return controller
    }

    /// The first "Project N" not used by an open or saved project.
    private func nextProjectName() -> String {
        let used = Set(controllers.map(\.name) + SavedLayout.load().map(\.name))
        projectCounter = 1
        while used.contains(L("プロジェクト %d", projectCounter)) { projectCounter += 1 }
        return L("プロジェクト %d", projectCounter)
    }

    @objc private func renameProject() {
        if let controller = activeController { rename(controller) }
    }

    private func rename(_ controller: WorkspaceController) {
        let alert = NSAlert()
        alert.messageText = L("プロジェクト名を変更")
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
            notice.messageText = L("同じ名前のプロジェクトが既にあります。")
            notice.runModal()
        } else if !name.isEmpty {
            SavedLayout.remove(named: controller.name)
            controller.name = name
        }
    }

    @objc private func closeProject() {
        if let controller = activeController { close(controller) }
    }

    @objc private func deleteProject() {
        if let controller = activeController { delete(controller) }
    }

    private func delete(_ controller: WorkspaceController) {
        let alert = NSAlert()
        alert.messageText = L("プロジェクト「%@」を削除しますか？", controller.name)
        alert.informativeText = L("閉じるだけでは前回の構成に残ります。削除すると次回の復元候補からも外れます。")
        alert.addButton(withTitle: L("削除"))
        alert.addButton(withTitle: L("キャンセル"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        close(controller, forget: true)
    }

    private func savedProject(_ controller: WorkspaceController) -> SavedProject {
        SavedProject(name: controller.name, windows: controller.session.windows.compactMap { window in
            guard let id = window.candidate.application.bundleIdentifier else { return nil }
            return SavedWindow(bundleID: id, title: window.candidate.title, frame: window.originalFrame)
        }, columns: controller.session.gridSize.columns, rows: controller.session.gridSize.rows)
    }

    /// Restores the project's windows to their original positions and closes it; closing the last project quits.
    /// A closed project stays in the saved layout unless `forget` is set.
    private func close(_ controller: WorkspaceController, forget: Bool = false) {
        if forget {
            SavedLayout.remove(named: controller.name)
        } else if controllers.count > 1 {
            let project = savedProject(controller)
            if !project.windows.isEmpty { SavedLayout.upsert([project]) }
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

    // MARK: Menu actions for the active project

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

    private func refreshGlobalMonitor() {
        let trusted = WindowAccess.isTrusted
        guard monitorTrust != trusted || globalMonitor == nil else { return }
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
                buttonDown: down, point: axPoint, windows: windows,
                ownPID: ProcessInfo.processInfo.processIdentifier
            ) {
            case .idle:
                controllers.forEach { $0.hideWindowDropTarget() }
            case .moving(let drag):
                if NSRunningApplication(processIdentifier: drag.window.processID)?.activationPolicy == .regular {
                    controllers.forEach { $0.showWindowDropTarget(at: point) }
                } else {
                    controllers.forEach { $0.hideWindowDropTarget() }
                }
            case .released(let drag):
                controllers.forEach { $0.hideWindowDropTarget() }
                controllers.first { $0.acceptsWindowDrop(at: point) }?
                    .finishWindowDrag(drag, accessibilityPoint: axPoint)
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

    private func cancelWindowDrag() {
        windowDragTracker.cancel()
        controllers.forEach { $0.hideWindowDropTarget() }
    }

    // MARK: Application lifecycle

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshGlobalMonitor()
        activeController?.scheduleSelectedWindowRaise()
    }

    /// A Dock click brings back only the last used project; others are reachable from the Dock menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        activeController?.bringToFront()
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
        let saved = controllers.map(savedProject).filter { !$0.windows.isEmpty }
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
