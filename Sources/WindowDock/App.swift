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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private let session = WindowSession()
    private var window: WorkspaceWindow!
    private let workspace = WorkspaceChromeView(frame: .zero)
    private var picker: WindowPicker?
    private var timer: Timer?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var tabIDs: [UUID] = []
    private var quitting = false
    private var suspended = false
    private var windowRaisePending = false
    private var windowRaiseScheduled = false
    private var monitorTrust: Bool?
    private var shortcutContext = WorkspaceShortcutContext()
    private var windowDragTracker = WorkspaceWindowDragTracker()
    private var dragTimer: Timer?
    private var lastWindowSnapshot: TimeInterval = 0
    private var dragSamplingFailed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        window.onWorkspaceFrameChange = { [weak self] in self?.syncIfVisible() }
        session.targetFrames = { [weak self] in self?.targetFrames() ?? [:] }
        session.fitMinimumSizes = { [weak self] sizes in
            guard let self else { return false }
            let fits = self.workspace.fitPanesToMinimumSizes(sizes)
            self.window.contentView?.layoutSubtreeIfNeeded()
            return fits
        }
        workspace.onGridChange = { [weak self] in self?.session.setGrid($0) }
        workspace.onActivateCell = { [weak self] in self?.session.activateCell($0) }
        workspace.onMoveTab = { [weak self] tab, cell in
            guard let self, self.tabIDs.indices.contains(tab) else { return }
            self.session.moveWindow(self.tabIDs[tab], toCell: cell)
        }
        workspace.onPaneLayoutChange = { [weak self] in
            DispatchQueue.main.async { self?.syncIfVisible() }
        }
        session.onChange = { [weak self] in self?.renderTabs() }
        session.onMessage = { [weak self] message in self?.showNotice(message) }
        session.onPresentedFrames = { [weak self] frames in
            guard let self, let screen = NSScreen.screens.first else { return }
            var covered: [Int: CGRect] = [:]
            for (index, id) in self.session.cells.enumerated() {
                if let id, let frame = frames[id] {
                    covered[index] = WindowGeometry.screenRect(from: frame, primaryScreenTop: screen.frame.maxY)
                }
            }
            self.workspace.presentFrames(covered)
            if !frames.isEmpty { self.window.orderFront(nil) }
            self.workspace.refreshCoverage()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp]) { [weak self] event in
            if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
                self?.shortcutContext.reset()
                self?.cancelWindowDrag()
                return event
            }
            if event.type == .leftMouseUp {
                if self?.windowRaisePending == true { self?.scheduleSelectedWindowRaise() }
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
                self?.session.pruneClosedWindows()
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

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
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L("ウィンドウ"))
        windowMenu.addItem(withTitle: L("ウィンドウを追加…"), action: #selector(showPicker), keyEquivalent: "o")
        windowMenu.addItem(withTitle: L("選択中のタブを解除"), action: #selector(removeSelected), keyEquivalent: "w")
        windowMenu.addItem(withTitle: L("最小化"), action: #selector(minimizeWorkspace), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("最大化 / 復元"), action: #selector(maximizeWorkspace), keyEquivalent: "")
        windowMenu.addItem(withTitle: L("列数を1 / 2に切替"), action: #selector(toggleSplit), keyEquivalent: "")
        windowMenu.addItem(withTitle: L("行数を1 / 2に切替"), action: #selector(toggleStackedSplit), keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
    }

    private func buildWindow() {
        window = WorkspaceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.borderless, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WindowDock"
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = workspace
        window.collectionBehavior = [.fullScreenNone]
        window.tabbingMode = .disallowed
        window.delegate = self
        window.center()

        workspace.closeButton.target = self
        workspace.closeButton.action = #selector(closeWorkspace)
        workspace.minimizeButton.target = self
        workspace.minimizeButton.action = #selector(minimizeWorkspace)
        workspace.maximizeButton.target = self
        workspace.maximizeButton.action = #selector(maximizeWorkspace)
        workspace.addButton.target = self
        workspace.addButton.action = #selector(showPicker)
        workspace.permissionButton.target = self
        workspace.permissionButton.action = #selector(openPermission)
    }

    private func targetFrames() -> [Int: CGRect] {
        guard let primaryScreen = NSScreen.screens.first else { return [:] }
        window.contentView?.layoutSubtreeIfNeeded()
        return Dictionary(uniqueKeysWithValues: workspace.gridAreas.enumerated().map { index, stage in
            let rect = window.convertToScreen(stage.convert(stage.bounds, to: nil))
            return (index, WindowGeometry.accessibilityRect(from: rect, primaryScreenTop: primaryScreen.frame.maxY))
        })
    }

    private func renderTabs() {
        workspace.setGrid(session.gridSize, activeCell: session.activeCell)
        workspace.clearTabs()
        tabIDs = session.windows.map(\.id)
        var selectedTab: NSView?
        for (index, managed) in session.windows.enumerated() {
            let selected = managed.id == session.selectedID
            let cell = session.cellIndex(for: managed.id)
            let displayed = session.isSplit && cell != nil
            let side = session.isSplit ? cell.map {
                L("%d行%d列 · ", $0 / session.gridSize.columns + 1, $0 % session.gridSize.columns + 1)
            } ?? "" : ""
            let tab = workspace.appendTab(title: side + managed.candidate.label, selected: selected, displayed: displayed)
            tab.select.target = self
            tab.select.action = #selector(selectTab(_:))
            tab.select.tag = index
            tab.close.target = self
            tab.close.action = #selector(removeTab(_:))
            tab.close.tag = index
            if selected { selectedTab = tab.view }
        }
        workspace.showManagedWindows(!session.windows.isEmpty)
        if let selectedTab { workspace.revealTab(selectedTab) }
        window.invalidateShadow()
    }

    private func focusPane(at point: NSPoint) {
        guard session.isSplit, !suspended, !quitting, picker == nil,
              window.isVisible, !window.isMiniaturized else { return }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for (index, area) in workspace.gridAreas.enumerated() {
            guard session.cells.indices.contains(index), let id = session.cells[index],
                  let managed = session.windows.first(where: { $0.id == id }),
                  managed.candidate.application.processIdentifier == frontPID else { continue }
            let rect = window.convertToScreen(area.convert(area.bounds, to: nil))
            if rect.contains(point) {
                session.focusVisibleWindow(id)
                return
            }
        }
    }

    @objc private func toggleSplit() {
        session.setGrid(WorkspaceGridSize(columns: session.gridSize.columns == 2 ? 1 : 2, rows: session.gridSize.rows))
    }

    @objc private func toggleStackedSplit() {
        session.setGrid(WorkspaceGridSize(columns: session.gridSize.columns, rows: session.gridSize.rows == 2 ? 1 : 2))
    }

    private func showNotice(_ notice: WorkspaceNotice) {
        if workspace.showNotice(notice) {
            DispatchQueue.main.async { [weak self] in self?.syncIfVisible() }
        }
    }

    @objc private func selectTab(_ sender: NSButton) {
        guard tabIDs.indices.contains(sender.tag) else { return }
        session.select(tabIDs[sender.tag])
    }

    @objc private func removeTab(_ sender: NSButton) {
        guard tabIDs.indices.contains(sender.tag) else { return }
        session.remove(tabIDs[sender.tag])
    }

    @objc private func removeSelected() {
        if let id = session.selectedID { session.remove(id) }
    }

    @objc private func closeWorkspace() {
        NSApp.terminate(nil)
    }

    @objc private func minimizeWorkspace() {
        window.miniaturize(nil)
    }

    @objc private func maximizeWorkspace() {
        window.toggleMaximize()
    }

    @objc private func showPicker() {
        guard picker == nil else { return }
        guard WindowAccess.isTrusted else {
            WindowAccess.requestPermission()
            showNotice(.attention(L("システム設定 → プライバシーとセキュリティ → アクセシビリティで WindowDock を許可し、もう一度追加してください。")))
            return
        }
        let scan = WindowAccess.scan()
        picker = WindowPicker(
            candidates: scan.windows.filter { !session.contains($0) },
            failedApplications: scan.failedApplications
        ) { [weak self] candidates in
            // Wait until the sheet has left the screen before raising the selected window.
            DispatchQueue.main.async { self?.session.add(candidates) }
        }
        picker?.present(on: window) { [weak self] in
            self?.picker = nil
            self?.scheduleSelectedWindowRaise()
        }
    }

    @objc private func openPermission() {
        WindowAccess.requestPermission()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        if !NSWorkspace.shared.open(url) {
            showNotice(.attention(L("システム設定を開けませんでした。アクセシビリティ設定を手動で開いてください。")))
        }
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard !session.windows.isEmpty, picker == nil, !suspended,
              !window.isMiniaturized, !NSApp.isHidden, !quitting else { return false }
        guard let direction = shortcutContext.direction(
            for: event, ownPID: ProcessInfo.processInfo.processIdentifier,
            frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            visiblePIDs: Set(session.visibleWindows.map { $0.candidate.application.processIdentifier })
        ) else { return false }
        session.cycle(direction)
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
                DispatchQueue.main.async { self.focusPane(at: point) }
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
            showNotice(.attention(L("キー・マウス監視を開始できませんでした。アクセシビリティ権限を確認し、WindowDock を起動し直してください。")))
            WindowAccess.logger.error("Could not install workspace input monitor")
        }
    }

    private var acceptsWindowDrag: Bool {
        picker == nil && !suspended && !quitting && window.isVisible &&
            window.isOnActiveSpace && !window.isMiniaturized && !NSApp.isHidden
    }

    private func startWindowDragMonitoring() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollWindowDrag() }
        }
        dragTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pollWindowDrag() {
        guard acceptsWindowDrag, let screen = NSScreen.screens.first else {
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
                workspace.hideWindowDropTarget()
            case .moving(let drag):
                if NSRunningApplication(processIdentifier: drag.window.processID)?.activationPolicy == .regular {
                    workspace.showWindowDropTarget(
                        hovered: workspace.acceptsWindowDrop(at: point), requiresPermission: !WindowAccess.isTrusted
                    )
                } else {
                    workspace.hideWindowDropTarget()
                }
            case .released(let drag):
                workspace.hideWindowDropTarget()
                finishWindowDrag(drag, at: point, accessibilityPoint: axPoint)
            }
        } catch {
            cancelWindowDrag()
            if !dragSamplingFailed {
                dragSamplingFailed = true
                WindowAccess.logger.error("\(error.localizedDescription, privacy: .public)")
                showNotice(.attention(error.localizedDescription))
            }
        }
    }

    private func finishWindowDrag(_ drag: WorkspaceWindowDrag, at point: NSPoint, accessibilityPoint: CGPoint) {
        guard acceptsWindowDrag, workspace.acceptsWindowDrop(at: point) else { return }
        guard WindowAccess.isTrusted else {
            WindowAccess.requestPermission()
            showNotice(.attention(L("追加にはアクセシビリティ権限が必要です。システム設定で現在の WindowDock を許可してください。")))
            return
        }
        do {
            let candidate = try WindowAccess.candidate(matching: drag.window)
            let actual = try WindowAccess.frame(candidate.element)
            guard drag.canDrop(at: accessibilityPoint, actualFrame: actual, acceptsPoint: true) else {
                showNotice(.attention(L("ウィンドウの位置・サイズが変わったため追加できませんでした。もう一度移動して離してください。")))
                return
            }
            if let registered = session.windows.first(where: { $0.candidate.isSameWindow(as: candidate) }) {
                session.select(registered.id)
                showNotice(.information(L("このウィンドウは既に登録されています。")))
            } else {
                session.add(candidate, originalFrame: drag.originalFrame)
            }
        } catch {
            WindowAccess.logger.error("\(error.localizedDescription, privacy: .public)")
            showNotice(.attention(error.localizedDescription))
        }
    }

    private func cancelWindowDrag() {
        windowDragTracker.cancel()
        workspace.hideWindowDropTarget()
    }

    func windowDidMove(_ notification: Notification) {
        if !window.isApplyingWorkspaceFrame { syncIfVisible() }
    }

    func windowDidResize(_ notification: Notification) {
        if !window.isApplyingWorkspaceFrame { syncIfVisible() }
    }

    private func syncIfVisible() {
        guard !suspended, picker == nil, !quitting else { return }
        workspace.refreshCoverage()
        session.sync()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        scheduleSelectedWindowRaise()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshGlobalMonitor()
        scheduleSelectedWindowRaise()
    }

    private func scheduleSelectedWindowRaise() {
        windowRaisePending = true
        guard !windowRaiseScheduled else { return }
        windowRaiseScheduled = true
        // Do not change window ordering during button tracking or window dragging.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.windowRaiseScheduled = false
                guard self.windowRaisePending, NSEvent.pressedMouseButtons == 0 else { return }
                self.windowRaisePending = false
                guard NSApp.isActive, self.window.isKeyWindow,
                      !self.suspended, !self.quitting, !self.window.isMiniaturized,
                      self.picker == nil, self.window.attachedSheet == nil else { return }
                self.session.raiseSelected()
                self.window.orderFront(nil)
            }
        }
    }

    func windowWillMiniaturize(_ notification: Notification) {
        cancelWindowDrag()
        shortcutContext.reset()
        suspended = true
        session.suspend()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        suspended = false
        session.resume()
        scheduleSelectedWindowRaise()
    }

    func applicationDidHide(_ notification: Notification) {
        cancelWindowDrag()
        shortcutContext.reset()
        suspended = true
        session.suspend()
    }

    func applicationDidUnhide(_ notification: Notification) {
        suspended = false
        if !window.isMiniaturized {
            session.resume()
            scheduleSelectedWindowRaise()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitting = true
        let failures = session.restoreAll()
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("一部のウィンドウを元に戻せませんでした")
            alert.informativeText = failures.joined(separator: "\n")
            alert.addButton(withTitle: L("終了"))
            alert.addButton(withTitle: L("戻って再試行"))
            if alert.runModal() == .alertSecondButtonReturn {
                quitting = false
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
