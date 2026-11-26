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

    private let updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var controllers: [WorkspaceController] = []
    private var workspaceCounter = 0
    private var skipLayoutSave = false
    private var workspaceMenu: NSMenu!
    private var timer: Timer?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var quitting = false
    private var monitorTrust: Bool?
    private var tabMenu: NSMenu!
    private var viewMenu: NSMenu!
    private var settingsMenu: NSMenu!
    private var shortcutContext = WorkspaceShortcutContext()
    private let tabOutsideDropSettings = TabOutsideDropSettings()
    private var dragTimer: Timer?
    private var leftMousePress = LeftMousePress()
    private lazy var tabTransfer: WorkspaceTabTransfer = {
        let transfer = WorkspaceTabTransfer { [weak self] in self?.controllers ?? [] }
        transfer.onBegin = { [weak self] in self?.cancelWindowDrag() }
        transfer.onTransfer = { [weak self] source, destination in
            guard let self else { return }
            SavedLayout.upsert([self.savedWorkspace(source), self.savedWorkspace(destination)])
        }
        transfer.outsideDropAction = { [weak self] in self?.tabOutsideDropSettings.action ?? .release }
        transfer.createWorkspace = { [weak self] point in self?.addWorkspace(dropPoint: point) }
        transfer.discardWorkspace = { [weak self] controller in
            self?.controllers.removeAll { $0 === controller }
            controller.finishClosing()
            self?.autoGrouping.refresh()
        }
        transfer.onRelease = { [weak self] source in
            guard let self else { return }
            SavedLayout.upsert([self.savedWorkspace(source)])
        }
        return transfer
    }()
    private lazy var activation = WorkspaceActivation { [weak self] in self?.controllers ?? [] }
    private lazy var autoGrouping: AutoGroupCoordinator = {
        let coordinator = AutoGroupCoordinator { [weak self] in self?.controllers ?? [] }
        coordinator.save = { [weak self] in self?.persist($0) }
        return coordinator
    }()
    private lazy var windowDrop: WorkspaceWindowDrop = {
        let drop = WorkspaceWindowDrop { [weak self] in self?.controllers ?? [] }
        drop.isEnabled = isSettingEnabled(.addWindowsByDragging)
        drop.onSamplingFailure = { [weak self] error in
            self?.activeController?.showNotice(.attention(error.localizedDescription))
        }
        return drop
    }()

    private var activeController: WorkspaceController? { activation.activeController }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            Setting.closeOnRelease.rawValue: false,
            Setting.controlTabSwitching.rawValue: true,
            Setting.addWindowsByDragging.rawValue: true,
            Setting.autoHideNewWorkspaces.rawValue: false,
            Setting.wrapCrowdedTabs.rawValue: false,
            Setting.showTabIconsOnly.rawValue: false,
            Setting.returnFullScreenWindows.rawValue: false,
            Setting.deleteEmptyWorkspaces.rawValue: false,
        ])
        buildMenu()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp,
        ]) { [weak self] event in
                if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
                    self?.shortcutContext.reset()
                    self?.cancelWindowDrag()
                    if event.type == .leftMouseDown {
                        self?.beginLeftMousePress()
                    } else {
                        self?.leftMousePress.cancel()
                        self?.controllers.forEach { $0.cancelManagedWindowDrag() }
                    }
                    return event
                }
                if event.type == .leftMouseUp {
                    self?.finishLeftMousePress()
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
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.sessionInactive = true
            }
        }
        center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.sessionInactive = false
                self?.pruneResumeDate = Date().addingTimeInterval(5)
                // Global event monitors can stop delivering events across a session switch.
                self?.refreshGlobalMonitor(force: true)
            }
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.sessionInactive = true
            }
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) {
            [weak self] _ in
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
                guard let self, !self.tabTransfer.isActive, !self.sessionInactive,
                      !Self.isScreenUnavailable, Date() >= self.pruneResumeDate
                else { return }
                self.controllers.forEach { $0.session.pruneClosedWindows() }
                self.autoGrouping.poll()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        let layouts = SavedLayout.load().filter { !$0.windows.isEmpty || !($0.autoGroupBundleIDs ?? []).isEmpty }
        let saved = chooseWorkspacesToRestore(layouts)
        WorkspaceRestore.start(saved) { self.addWorkspace(name: $0) }
        autoGrouping.start()
    }

    private func summary(of workspace: SavedWorkspace) -> String {
        var summary = "\(workspace.name) — " + L("%d個のウィンドウ", workspace.windows.count)
        if let rules = workspace.autoGroupBundleIDs, !rules.isEmpty {
            summary += L("、新しいウィンドウを自動で追加するアプリ%d個", rules.count)
        }
        return summary
    }

    /// Lets the user pick which saved workspaces to bring back; a single workspace needs no question.
    private func chooseWorkspacesToRestore(_ workspaces: [SavedWorkspace]) -> [SavedWorkspace] {
        guard workspaces.count > 1 else { return workspaces }
        let checks = workspaces.map { workspace -> NSButton in
            let check = NSButton(checkboxWithTitle: summary(of: workspace), target: nil, action: nil)
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

    // MARK: Menu

    private enum Setting: String {
        case closeOnRelease = "closeWindowsOnTabRelease"
        case controlTabSwitching = "controlTabSwitching"
        case addWindowsByDragging = "addWindowsByDragging"
        case autoHideNewWorkspaces = "autoHideNewWorkspaces"
        case wrapCrowdedTabs
        case showTabIconsOnly
        case returnFullScreenWindows = "returnFullScreenWindowsToPanes"
        case deleteEmptyWorkspaces = "deleteEmptyWorkspaces"

        var defaultValue: Bool {
            switch self {
            case .closeOnRelease, .autoHideNewWorkspaces, .returnFullScreenWindows, .deleteEmptyWorkspaces,
                 .wrapCrowdedTabs, .showTabIconsOnly: false
            case .controlTabSwitching, .addWindowsByDragging: true
            }
        }
    }

    private var managedWindowMoveAction: ManagedWindowMoveAction {
        let defaults = UserDefaults.standard
        let key = "managedWindowMoveAction"
        if let value = defaults.string(forKey: key) {
            guard let action = ManagedWindowMoveAction(rawValue: value) else {
                WindowAccess.logger.error("Invalid managed window move action: \(value, privacy: .public)")
                return .follow
            }
            return action
        }
        let legacy = defaults.object(forKey: "returnDraggedWindowsToPanes") as? Bool
        let action = ManagedWindowMoveAction.migrated(from: legacy)
        defaults.set(action.rawValue, forKey: key)
        return action
    }

    private func isSettingEnabled(_ setting: Setting) -> Bool {
        UserDefaults.standard.object(forKey: setting.rawValue) as? Bool ?? setting.defaultValue
    }

    @objc private func toggleSetting(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let setting = Setting(rawValue: rawValue) else {
            return
        }
        let enabled = !isSettingEnabled(setting)
        UserDefaults.standard.set(enabled, forKey: setting.rawValue)
        sender.state = enabled ? .on : .off
        switch setting {
        case .closeOnRelease:
            for controller in controllers { controller.session.closesWindowsOnRelease = enabled }
        case .controlTabSwitching:
            shortcutContext.reset()
        case .addWindowsByDragging:
            windowDrop.isEnabled = enabled
        case .returnFullScreenWindows:
            for controller in controllers { controller.returnsFullScreenWindows = enabled }
        case .deleteEmptyWorkspaces:
            for controller in controllers { controller.deletesWhenEmpty = enabled }
        case .wrapCrowdedTabs:
            for controller in controllers { controller.setWrapsCrowdedTabs(enabled) }
        case .showTabIconsOnly:
            for controller in controllers { controller.setShowsTabIconsOnly(enabled) }
        case .autoHideNewWorkspaces:
            break
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let updateItem = NSMenuItem(
            title: L("アップデートを確認…"), action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: "")
        updateItem.target = updater
        appMenu.addItem(updateItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: L("WindowDock を終了"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let workspaceItem = NSMenuItem()
        workspaceMenu = NSMenu(title: L("ワークスペース"))
        workspaceMenu.delegate = self
        workspaceItem.submenu = workspaceMenu
        menu.addItem(workspaceItem)

        let tabItem = NSMenuItem()
        tabMenu = NSMenu(title: L("タブ"))
        tabMenu.delegate = self
        tabItem.submenu = tabMenu
        menu.addItem(tabItem)

        let viewItem = NSMenuItem()
        viewMenu = NSMenu(title: L("表示"))
        viewMenu.delegate = self
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)

        let settingsItem = NSMenuItem()
        settingsMenu = NSMenu(title: L("設定"))
        settingsMenu.delegate = self
        updateSettingsMenu(settingsMenu)
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        NSApp.mainMenu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === workspaceMenu {
            updateWorkspaceMenu(menu)
        } else if menu === tabMenu {
            updateTabMenu(menu)
        } else if menu === viewMenu {
            updateViewMenu(menu)
        } else if menu === settingsMenu {
            updateSettingsMenu(menu)
        }
    }

    private func updateWorkspaceMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: L("新規ワークスペース"), action: #selector(newWorkspace), keyEquivalent: "n")
        menu.addItem(withTitle: L("ワークスペース名を変更…"), action: #selector(renameWorkspace), keyEquivalent: "")
        let close = menu.addItem(
            withTitle: L("ワークスペースを閉じる"), action: #selector(closeWorkspace), keyEquivalent: "w")
        close.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: L("ワークスペースを削除…"), action: #selector(deleteWorkspace), keyEquivalent: "")
        menu.addItem(
            withTitle: L("新しいウィンドウを自動で追加するアプリ…"),
            action: activeController?.canChooseAutoGroupApplications == true
                ? #selector(chooseAutoGroupApplications) : nil,
            keyEquivalent: "")
        menu.addItem(.separator())
        let switchable = controllers.filter { !$0.window.isMiniaturized }.count > 1
        let nextWorkspace = menu.addItem(
            withTitle: L("次のワークスペース"), action: switchable ? #selector(selectNextWorkspace) : nil,
            keyEquivalent: "\t")
        nextWorkspace.keyEquivalentModifierMask = [.control, .option]
        let previousWorkspace = menu.addItem(
            withTitle: L("前のワークスペース"), action: switchable ? #selector(selectPreviousWorkspace) : nil,
            keyEquivalent: "\t")
        previousWorkspace.keyEquivalentModifierMask = [.control, .option, .shift]
        menu.addItem(
            withTitle: L("全てのワークスペースを現在のワークスペースに統合"),
            action: controllers.count > 1 ? #selector(mergeAllWorkspaces) : nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("最小化"), action: #selector(minimizeWorkspace), keyEquivalent: "m")
        menu.addItem(withTitle: L("最大化 / 復元"), action: #selector(maximizeWorkspace), keyEquivalent: "")
        menu.addItem(.separator())
        let active = activeController
        for controller in controllers {
            let item = NSMenuItem(
                title: "\(controller.name) — " + L("%d個のウィンドウ", controller.session.windows.count),
                action: #selector(showWorkspace(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = controller
            item.state = controller === active ? .on : .off
            menu.addItem(item)
        }
        appendClosedWorkspaces(to: menu)
    }

    private func updateTabMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: L("新しいタブ"), action: #selector(newTab), keyEquivalent: "t")
        menu.addItem(withTitle: L("ウィンドウを追加…"), action: #selector(showPicker), keyEquivalent: "o")
        let releaseTitle = isSettingEnabled(.closeOnRelease) ? L("選択中のタブのウィンドウを閉じる") : L("選択中のタブを解除")
        menu.addItem(withTitle: releaseTitle, action: #selector(removeSelected), keyEquivalent: "w")
        let controlTabEnabled = isSettingEnabled(.controlTabSwitching)
        let nextTab = menu.addItem(
            withTitle: L("次のタブ"), action: controlTabEnabled ? #selector(selectNextTab) : nil, keyEquivalent: "\t")
        nextTab.target = self
        nextTab.keyEquivalentModifierMask = [.control]
        let previousTab = menu.addItem(
            withTitle: L("前のタブ"), action: controlTabEnabled ? #selector(selectPreviousTab) : nil, keyEquivalent: "\t")
        previousTab.target = self
        previousTab.keyEquivalentModifierMask = [.control, .shift]
        previousTab.isEnabled = controlTabEnabled
        nextTab.isEnabled = controlTabEnabled
        let populatedWorkspaces = controllers.filter { !$0.session.tabIDs.isEmpty }
        guard !populatedWorkspaces.isEmpty else { return }
        menu.addItem(.separator())
        for controller in populatedWorkspaces {
            let workspaceItem = menu.addItem(
                withTitle: "\(controller.name) — " + L("%d個のウィンドウ", controller.session.windows.count),
                action: nil, keyEquivalent: "")
            workspaceItem.isEnabled = false
            for id in controller.session.tabIDs {
                let item = menu.addItem(
                    withTitle: controller.session.managedByID[id]?.candidate.label ?? L("新しいタブ"),
                    action: #selector(showWorkspaceWindow(_:)),
                    keyEquivalent: "")
                item.target = self
                item.indentationLevel = 1
                item.representedObject = WorkspaceWindowRef(controller: controller, id: id)
                item.state = controller.session.selectedID == id ? .mixed : .off
            }
        }
    }

    private func updateViewMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let active = activeController
        let autoHide = menu.addItem(
            withTitle: L("タブバーを自動的に隠す"), action: #selector(toggleAutoHideTabs), keyEquivalent: "")
        autoHide.target = self
        autoHide.state = active?.autoHideTabs == true ? .on : .off
        if let active {
            let position = menu.addItem(withTitle: L("タブバーの位置"), action: nil, keyEquivalent: "")
            position.submenu = active.tabBarPositionMenu()
            let pane = menu.addItem(withTitle: L("ペイン"), action: nil, keyEquivalent: "")
            pane.submenu = active.activePaneMenu()
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("列数を1 / 2に切替"), action: #selector(toggleSplit), keyEquivalent: "")
        menu.addItem(withTitle: L("行数を1 / 2に切替"), action: #selector(toggleStackedSplit), keyEquivalent: "")
    }

    private func updateSettingsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings: [(Setting, String)] = [
            (.closeOnRelease, "タブを解除するときにウィンドウも閉じる"),
            (.controlTabSwitching, "Control+Tabでワークスペースのタブを切り替える"),
            (.addWindowsByDragging, "ウィンドウをドラッグしてワークスペースに追加する"),
            (.returnFullScreenWindows, "フルスクリーンのウィンドウもペインに戻す"),
            (.deleteEmptyWorkspaces, "空になったワークスペースを自動的に削除する"),
            (.autoHideNewWorkspaces, "新しいワークスペースではタブバーを自動的に隠す"),
            (.wrapCrowdedTabs, "タブが収まらないときは2段にする"),
            (.showTabIconsOnly, "タブにアイコンだけを表示する（ウィンドウ名を隠す）"),
        ]
        for (setting, title) in settings {
            let item = menu.addItem(withTitle: L(title), action: #selector(toggleSetting(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = setting.rawValue
            item.state = isSettingEnabled(setting) ? .on : .off
        }
        let moveAction = menu.addItem(withTitle: L("ウィンドウを直接動かしたとき"), action: nil, keyEquivalent: "")
        let moveMenu = NSMenu()
        for action in ManagedWindowMoveAction.allCases {
            let title: String
            switch action {
            case .follow: title = "ワークスペースを追従させる"
            case .returnToPane: title = "ペインに戻す"
            case .nothing: title = "何もしない"
            }
            let item = moveMenu.addItem(
                withTitle: L(title), action: #selector(selectManagedWindowMoveAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            item.state = action == managedWindowMoveAction ? .on : .off
        }
        moveAction.submenu = moveMenu
        menu.addItem(.separator())
        let outsideDrop = menu.addItem(withTitle: L("タブをワークスペースの外にドロップしたとき"), action: nil, keyEquivalent: "")
        outsideDrop.submenu = tabOutsideDropSettings.menu()
    }

    /// Saved workspaces that are not open right now; each can be reopened or deleted.
    private func appendClosedWorkspaces(to menu: NSMenu) {
        let open = Set(controllers.map(\.name))
        let closed = SavedLayout.load().filter { !open.contains($0.name) }
        guard !closed.isEmpty else { return }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("閉じているワークスペース"), action: nil, keyEquivalent: "").isEnabled = false
        for workspace in closed {
            let item = NSMenuItem(title: summary(of: workspace), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let reopen = NSMenuItem(title: L("開く"), action: #selector(reopenSavedWorkspace(_:)), keyEquivalent: "")
            let delete = NSMenuItem(
                title: L("ワークスペースを削除…"), action: #selector(deleteSavedWorkspace(_:)), keyEquivalent: "")
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
              let workspace = SavedLayout.load().first(where: { $0.name == name })
        else { return }
        if workspace.windows.isEmpty {
            let controller = addWorkspace(name: name)
            controller.autoGroupBundleIDs = workspace.autoGroupBundleIDs ?? []
            controller.restoreLayout(workspace)
            controller.showPicker()
        } else {
            WorkspaceRestore.start([workspace]) { self.addWorkspace(name: $0) }
        }
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
    private func addWorkspace(name: String? = nil, dropPoint: NSPoint? = nil) -> WorkspaceController {
        let controller = WorkspaceController(name: name ?? nextWorkspaceName())
        controller.session.closesWindowsOnRelease = isSettingEnabled(.closeOnRelease)
        controller.managedWindowMoveAction = managedWindowMoveAction
        controller.returnsFullScreenWindows = isSettingEnabled(.returnFullScreenWindows)
        controller.deletesWhenEmpty = isSettingEnabled(.deleteEmptyWorkspaces)
        controller.setAutoHideTabs(isSettingEnabled(.autoHideNewWorkspaces))
        controller.setWrapsCrowdedTabs(isSettingEnabled(.wrapCrowdedTabs))
        controller.setShowsTabIconsOnly(isSettingEnabled(.showTabIconsOnly))
        controller.onClose = { [weak self] in self?.close($0) }
        controller.onSessionChange = { [weak self] controller in self?.persist(controller) }
        controller.onRename = { [weak self] in self?.rename($0) }
        controller.onDelete = { [weak self] in self?.delete($0) }
        controller.onAutoDelete = { [weak self] controller in
            guard let self, !self.quitting, self.controllers.contains(where: { $0 === controller }) else { return }
            self.tabTransfer.clear()
            self.controllers.removeAll { $0 === controller }
            self.autoGrouping.refresh()
        }
        controller.onSuspend = { [weak self] in
            self?.shortcutContext.reset()
            self?.cancelWindowDrag()
            self?.tabTransfer.clear()
        }
        controller.isRegisteredElsewhere = { [weak self, weak controller] candidate in
            guard let self else { return false }
            return self.controllers.contains { $0 !== controller && $0.session.contains(candidate) }
        }
        tabTransfer.attach(controller)
        controller.autoGrouping = autoGrouping
        if let dropPoint,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(dropPoint) }) ?? NSScreen.main
        {
            let visible = screen.visibleFrame
            let size = controller.window.frame.size
            let x = min(max(dropPoint.x - size.width / 2, visible.minX), max(visible.minX, visible.maxX - size.width))
            let y = min(
                max(dropPoint.y - size.height + 20, visible.minY),
                max(visible.minY, visible.maxY - size.height))
            controller.window.setFrameOrigin(NSPoint(x: x, y: y))
        } else if let origin = activeController?.window.frame.origin {
            controller.window.setFrameOrigin(NSPoint(x: origin.x + 30, y: origin.y - 30))
        }
        controllers.append(controller)
        controller.bringToFront()
        return controller
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
            persist(controller)
        }
    }

    @objc private func closeWorkspace() {
        if let controller = activeController { close(controller) }
    }

    @objc private func selectNextWorkspace() { activation.cycle(1) }
    @objc private func selectPreviousWorkspace() { activation.cycle(-1) }

    @objc private func chooseAutoGroupApplications() {
        activeController?.chooseAutoGroupApplications()
    }

    /// Moves every other workspace's windows into the active one and closes the emptied workspaces.
    @objc private func mergeAllWorkspaces() {
        guard let destination = activeController else { return }
        let others = controllers.filter { $0 !== destination }
        guard !others.isEmpty else { return }
        tabTransfer.clear()
        cancelWindowDrag()
        shortcutContext.reset()
        destination.absorbWorkspaces(others)
        for other in others {
            controllers.removeAll { $0 === other }
            SavedLayout.remove(named: other.name)
            other.finishClosing()
        }
        autoGrouping.refresh()
        persist(destination)
        activation.show(destination)
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
        controller.savedWorkspace()
    }

    /// Saves a workspace that has windows or collects apps. A workspace being restored keeps its saved record.
    private func persist(_ controller: WorkspaceController) {
        guard !quitting, !controller.isRestoring else { return }
        let workspace = savedWorkspace(controller)
        if !workspace.windows.isEmpty || workspace.autoGroupBundleIDs != nil {
            SavedLayout.upsert([workspace])
        } else {
            SavedLayout.setAutoGroupBundleIDs([], forWorkspaceNamed: controller.name)
        }
    }

    /// Restores the workspace's windows to their original positions and closes it; closing the last workspace quits.
    /// A closed workspace stays in the saved layout unless `forget` is set.
    private func close(_ controller: WorkspaceController, forget: Bool = false) {
        tabTransfer.clear()
        if forget {
            SavedLayout.remove(named: controller.name)
        } else if controllers.count > 1 {
            persist(controller)
        }
        if controllers.count == 1 {
            skipLayoutSave = forget
            NSApp.terminate(nil)
            skipLayoutSave = false
            return
        }
        // The restored windows are still in the session; don't put them back into their panes.
        let moveAction = controller.managedWindowMoveAction
        controller.managedWindowMoveAction = .nothing
        controller.returnsFullScreenWindows = false
        let failures = controller.session.restoreAll()
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("一部のウィンドウを元に戻せませんでした")
            alert.informativeText = failures.joined(separator: "\n")
            alert.addButton(withTitle: L("閉じる"))
            alert.addButton(withTitle: L("戻って再試行"))
            if alert.runModal() == .alertSecondButtonReturn {
                controller.managedWindowMoveAction = moveAction
                controller.returnsFullScreenWindows = isSettingEnabled(.returnFullScreenWindows)
                return
            }
        }
        controllers.removeAll { $0 === controller }
        if forget { SavedLayout.remove(named: controller.name) }
        controller.finishClosing()
        autoGrouping.refresh()
        controllers.last?.present()
    }

    // MARK: Menu actions for the active workspace

    @objc private func showPicker() { activeController?.showPicker() }
    @objc private func newTab() { activeController?.newTab() }
    @objc private func removeSelected() { activeController?.removeSelected() }
    @objc private func selectNextTab() { activeController?.cycleTabs(1) }
    @objc private func selectPreviousTab() { activeController?.cycleTabs(-1) }
    @objc private func minimizeWorkspace() { activeController?.minimizeWorkspace() }
    @objc private func maximizeWorkspace() { activeController?.maximizeWorkspace() }
    @objc private func toggleSplit() { activeController?.toggleSplit() }
    @objc private func toggleStackedSplit() { activeController?.toggleStackedSplit() }

    @objc private func toggleAutoHideTabs() {
        guard let controller = activeController else { return }
        controller.setAutoHideTabs(!controller.autoHideTabs)
    }

    // MARK: Input monitoring

    private func handleShortcut(_ event: NSEvent) -> Bool {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let direction = WorkspaceShortcutContext.workspaceDirection(
            for: event, ownPID: ProcessInfo.processInfo.processIdentifier, frontPID: frontPID,
            managedPIDs: controllers.reduce(into: Set<pid_t>()) { $0.formUnion($1.visiblePIDs) })
        {
            shortcutContext.reset()
            return activation.cycle(direction) != nil
        }
        let target =
            controllers.first { $0.canHandleShortcut && $0.window.isKeyWindow } ?? controllers.first {
                $0.canHandleShortcut && frontPID.map($0.visiblePIDs.contains) == true
            } ?? controllers.first { $0.canHandleShortcut }
        guard let target,
              let direction = shortcutContext.direction(
                  for: event, ownPID: ProcessInfo.processInfo.processIdentifier,
                  frontPID: frontPID, visiblePIDs: target.visiblePIDs,
                  enabled: isSettingEnabled(.controlTabSwitching))
        else { return false }
        target.cycleTabs(direction)
        return true
    }

    @objc private func frontApplicationChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        if app != .current, app.activationPolicy == .regular, let id = app.bundleIdentifier {
            RecentApplications().record(id)
        }
        shortcutContext.applicationDidActivate(app.processIdentifier)
        controllers.forEach { $0.applicationDidBecomeFrontmost(app) }
    }

    private func refreshGlobalMonitor(force: Bool = false) {
        let trusted = WindowAccess.isTrusted
        guard force || monitorTrust != trusted || globalMonitor == nil else { return }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        monitorTrust = trusted
        let mask: NSEvent.EventTypeMask =
            trusted
                ? [.keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown]
                : [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return }
            let point = NSEvent.mouseLocation
            switch event.type {
            case .leftMouseDown:
                self.beginLeftMousePress()
                self.shortcutContext.reset()
                DispatchQueue.main.async { self.controllers.forEach { $0.focusPane(at: point) } }
            case .rightMouseDown, .otherMouseDown:
                self.leftMousePress.cancel()
                self.shortcutContext.reset()
                self.cancelWindowDrag()
                self.controllers.forEach { $0.cancelManagedWindowDrag() }
            case .leftMouseUp:
                self.finishLeftMousePress()
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

    private func beginLeftMousePress() {
        let point = NSEvent.mouseLocation
        if leftMousePress.begin(at: point) {
            controllers.forEach { $0.finishManagedWindowDrag() }
        }
        beginManagedWindowDrag(at: point)
    }

    private func finishLeftMousePress() {
        guard let dragged = leftMousePress.end(at: NSEvent.mouseLocation) else { return }
        controllers.forEach { $0.finishManagedWindowDrag() }
        if dragged, managedWindowMoveAction == .returnToPane {
            controllers.forEach { $0.windowsChangedOutsideWorkspace() }
        }
    }

    @objc private func selectManagedWindowMoveAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let action = ManagedWindowMoveAction(rawValue: rawValue)
        else {
            WindowAccess.logger.error("Invalid managed window move action selection")
            return
        }
        UserDefaults.standard.set(action.rawValue, forKey: "managedWindowMoveAction")
        for controller in controllers { controller.managedWindowMoveAction = action }
    }

    private func beginManagedWindowDrag(at point: NSPoint) {
        guard managedWindowMoveAction == .follow else { return }
        let excluded = Set(controllers.flatMap { controller in
            [controller.window.windowNumber, controller.toolbarPanelNumber ?? 0, controller.windowDropPanelNumber ?? 0]
                .filter { $0 > 0 }.map { CGWindowID($0) }
        })
        guard let windowID = WindowAccess.windowReceivingClick(at: point, excluding: excluded) else { return }
        guard let controller = controllers.first(where: { controller in
            controller.session.windows.contains {
                controller.session.access.windowID($0.candidate.element) == windowID
            }
        })
        else { return }
        do {
            guard let window = try WindowAccess.windowServerWindows().first(where: { $0.id == windowID })
            else { return }
            _ = controller.beginManagedWindowDrag(windowServerWindow: window)
        } catch {
            WindowAccess.logger
                .error("Could not begin managed-window sampling: \(error.localizedDescription, privacy: .public)")
            controller.showNotice(.attention(error.localizedDescription))
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
        let point = NSEvent.mouseLocation
        controllers.forEach { $0.updateAutoHiddenTabBar(at: point) }
        let tracking = controllers.filter(\.isTrackingManagedWindowDrag)
        var sampledWindows: [WindowServerWindow]?
        if !tracking.isEmpty, NSEvent.pressedMouseButtons & 1 != 0 {
            do {
                let windows = try WindowAccess.windowServerWindows()
                sampledWindows = windows
                tracking.forEach {
                    $0.updateManagedWindowDrag(using: windows, mouseButtonDown: true)
                }
            } catch {
                tracking.forEach { $0.managedWindowDragSamplingFailed(error) }
            }
        }
        guard !tabTransfer.isActive else { return }
        guard !quitting else { return cancelWindowDrag() }
        if let sampledWindows {
            windowDrop.poll(sampledWindows: sampledWindows)
        } else if tracking.isEmpty {
            windowDrop.poll()
        }
    }

    private func cancelWindowDrag() {
        windowDrop.cancel()
    }

    // MARK: Application lifecycle

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshGlobalMonitor()
        activation.applicationDidBecomeActive()
    }

    /// A Dock click brings back only the last used workspace; others are reachable from the Dock menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if controllers.isEmpty {
            addWorkspace()
        } else {
            activation.reopen()
        }
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
        // A workspace still asking what to restore would overwrite its saved windows with none.
        let saved = controllers.filter { !$0.isRestoring }.map(savedWorkspace)
            .filter { !$0.windows.isEmpty || $0.autoGroupBundleIDs != nil }
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
        autoGrouping.stop()
        cancelWindowDrag()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        return .terminateNow
    }
}
