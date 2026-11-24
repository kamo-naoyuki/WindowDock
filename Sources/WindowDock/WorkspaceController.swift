import AppKit
import WindowDockCore

/// One workspace: a workspace window together with the session that manages its registered windows.
@MainActor
final class WorkspaceController: NSObject, NSWindowDelegate, NSMenuDelegate {
    let session: WindowSession
    let window: WorkspaceWindow
    private let workspace = WorkspaceChromeView(frame: .zero)
    private var picker: WindowPicker?
    private var tabIDs: [UUID] = []
    private var windowRaisePending = false
    private var windowRaiseScheduled = false
    private var tabBarHoverStart: TimeInterval?
    private var tabBarLastActive: TimeInterval = 0
    private var tabBarForcedVisibleUntil: TimeInterval = 0
    private var isToolbarMenuOpen = false
    /// When a focus handoff was requested; activation can complete well after the request.
    private var windowFocusRequest: TimeInterval?
    private var coverageGeneration = 0
    private(set) var suspended = false
    private(set) var autoHideTabs = false
    var quitting = false

    var name: String {
        didSet {
            window.title = name
            workspace.workspaceButton.title = name
        }
    }
    var onClose: ((WorkspaceController) -> Void)?
    var onRename: ((WorkspaceController) -> Void)?
    var onSessionChange: ((WorkspaceController) -> Void)?
    var onDelete: ((WorkspaceController) -> Void)?
    var onTabDragBegin: ((UUID, String, NSButton) -> Void)?
    var onTabDragMove: ((String, NSPasteboard, NSButton, NSPoint) -> Void)? {
        didSet { workspace.onTabDragMove = onTabDragMove }
    }
    var onTabDragEnd: ((String, NSPasteboard, NSPoint, Bool) -> Void)?
    var acceptsExternalTab: ((String, NSButton?) -> Bool)?
    var onExternalTabDrop: ((String, NSButton?, Int?, Int?) -> Bool)?
    /// Whether another workspace already manages the candidate window.
    var isRegisteredElsewhere: ((WindowCandidate) -> Bool)?

    init(name: String, access: WindowAccessClient = WindowAccessClient()) {
        self.name = name
        session = WindowSession(access: access)
        window = WorkspaceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildWindow()
        wireSession()
    }

    // MARK: Setup

    private func buildWindow() {
        window.title = name
        workspace.workspaceButton.title = name
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = workspace
        window.collectionBehavior = [.fullScreenNone]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Server-side titlebar dragging bypasses the pre-move transparency mask.
        window.isMovable = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.center()

        workspace.addButton.target = self
        workspace.addButton.action = #selector(showPicker)
        workspace.permissionButton.target = self
        workspace.permissionButton.action = #selector(openPermission)
    }

    private func wireSession() {
        session.isClaimedElsewhere = { [weak self] candidate in self?.isRegisteredElsewhere?(candidate) ?? false }
        window.onWorkspaceFrameChange = { [weak self] in self?.syncIfVisible() }
        workspace.onFrameInteractionEnd = { [weak self] in self?.scheduleSelectedWindowRaise(activate: true) }
        session.targetFrames = { [weak self] in self?.targetFrames() ?? [:] }
        session.fitMinimumSizes = { [weak self] sizes in
            guard let self else { return false }
            let fits = self.workspace.fitPanesToMinimumSizes(sizes)
            self.window.contentView?.layoutSubtreeIfNeeded()
            return fits
        }
        workspace.workspaceMenu = { [weak self] in
            let menu = NSMenu()
            menu.delegate = self
            let autoHide = NSMenuItem(
                title: L("タブバーを自動的に隠す"),
                action: #selector(WorkspaceController.toggleAutoHideTabs),
                keyEquivalent: ""
            )
            autoHide.target = self
            autoHide.state = self?.autoHideTabs == true ? .on : .off
            menu.addItem(autoHide)
            let pane = menu.addItem(withTitle: L("ペイン"), action: nil, keyEquivalent: "")
            pane.submenu = self?.activePaneMenu()
            menu.addItem(.separator())
            menu.addItem(
                withTitle: L("ワークスペース名を変更…"), action: #selector(WorkspaceController.renameFromMenu), keyEquivalent: ""
            ).target = self
            menu.addItem(
                withTitle: L("ワークスペースを削除…"), action: #selector(WorkspaceController.deleteFromMenu), keyEquivalent: ""
            ).target = self
            return menu
        }
        workspace.onGridChange = { [weak self] in self?.session.setGrid($0) }
        workspace.splitRestriction = { [weak self] index, axis in
            guard let self else { return .layout }
            return self.session.splitRestriction(at: index, axis: axis, currentLayout: self.workspace.stage.paneLayout)
        }
        workspace.onSplitPane = { [weak self] index, axis in
            guard let self else { return }
            self.session.splitPane(at: index, axis: axis, currentLayout: self.workspace.stage.paneLayout)
        }
        workspace.onClosePane = { [weak self] index in
            guard let self else { return }
            self.session.closePane(at: index, currentLayout: self.workspace.stage.paneLayout)
        }
        workspace.isPanePinned = { [weak self] in self?.session.isPanePinned($0) ?? false }
        workspace.onTogglePanePin = { [weak self] index in
            guard let self else { return }
            self.session.setPanePinned(!self.session.isPanePinned(index), at: index)
        }
        workspace.paneForTab = { [weak self] tab in
            guard let self, self.tabIDs.indices.contains(tab) else { return nil }
            return self.session.cellIndex(for: self.tabIDs[tab])
        }
        workspace.stage.onCustomLayoutChange = { [weak self] layout in
            guard let self else { return }
            self.session.updatePaneProportions(layout)
            self.onSessionChange?(self)
        }
        workspace.onActivateCell = { [weak self] index in
            guard let self else { return }
            self.session.activateCell(index)
            // A click can land on this window's transparent aperture instead of the managed window; hand focus over explicitly.
            if self.session.cells.indices.contains(index), let id = self.session.cells[index] {
                self.session.select(id, activate: true)
            }
        }
        workspace.onReleaseTabs = { [weak self] ids in
            guard let self else { return }
            for id in ids { self.session.remove(id) }
        }
        workspace.onMoveTab = { [weak self] tab, cell in
            guard let self, self.tabIDs.indices.contains(tab) else { return }
            self.session.moveWindow(self.tabIDs[tab], toCell: cell)
        }
        workspace.onReorderTabs = { [weak self] order in
            guard let self, order.count == self.tabIDs.count,
                  Set(order) == Set(self.tabIDs.indices)
            else { return }
            self.session.reorderWindows(order.map { self.tabIDs[$0] })
        }
        workspace.onTabDragBegin = { [weak self] index, token, button in
            guard let self, self.tabIDs.indices.contains(index) else { return }
            self.onTabDragBegin?(self.tabIDs[index], token, button)
        }
        workspace.onTabDragEnd = { [weak self] token, board, point, cancelled in
            self?.onTabDragEnd?(token, board, point, cancelled)
        }
        workspace.acceptsExternalTab = { [weak self] token, button in
            guard let self, self.acceptsWindowDrag else { return false }
            return self.acceptsExternalTab?(token, button) == true
        }
        workspace.onExternalTabDrop = { [weak self] token, button, index, cell in
            guard let self, self.acceptsWindowDrag else { return false }
            return self.onExternalTabDrop?(token, button, index, cell) == true
        }
        workspace.onPaneLayoutChange = { [weak self] in
            DispatchQueue.main.async { self?.syncIfVisible() }
        }
        workspace.onToolbarMenuTracking = { [weak self] isOpen in
            guard let self else { return }
            self.isToolbarMenuOpen = isOpen
            if !isOpen { self.tabBarLastActive = ProcessInfo.processInfo.systemUptime }
        }
        workspace.onAutoHiddenToolbarMouseDown = { [weak self] event in
            self?.activateFromAutoHiddenToolbar(event)
        }
        session.onChange = { [weak self] in
            guard let self else { return }
            self.renderTabs()
            self.onSessionChange?(self)
        }
        session.onMessage = { [weak self] message in self?.showNotice(message) }
        session.onPresentedFrames = { [weak self] frames in
            guard let self else { return }
            self.coverageGeneration += 1
            self.presentConfirmedFrames(frames, generation: self.coverageGeneration)
        }
    }

    private func presentConfirmedFrames(_ frames: [UUID: CGRect], generation: Int, attempt: Int = 0) {
        guard generation == coverageGeneration, let screen = NSScreen.screens.first else { return }
        if frames.isEmpty {
            workspace.presentFrames([:])
            return
        }
        guard !suspended, !quitting else { return }
        do {
            let rendered = try WindowAccess.windowServerWindows().filter { $0.layer == 0 }
            var covered: [Int: CGRect] = [:]
            var pending = false
            for (index, id) in session.cells.enumerated() {
                guard let id, let frame = frames[id],
                      let managed = session.windows.first(where: { $0.id == id })
                else { continue }
                let candidates = rendered.filter {
                    $0.processID == managed.candidate.application.processIdentifier
                }.map(\.frame)
                if let confirmed = WindowGeometry.confirmedCoverage(for: frame, renderedFrames: candidates) {
                    covered[index] = WindowGeometry.screenRect(from: confirmed, primaryScreenTop: screen.frame.maxY)
                    pending = pending || confirmed != frame
                } else {
                    pending = true
                }
            }
            workspace.presentFrames(covered)
            if attempt == 0 { window.orderFront(nil) }
            if pending, attempt < 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.presentConfirmedFrames(frames, generation: generation, attempt: attempt + 1)
                }
            }
        } catch {
            workspace.presentFrames([:])
            WindowAccess.logger.error("\(error.localizedDescription, privacy: .public)")
            showNotice(.attention(error.localizedDescription))
        }
    }

    // MARK: Layout

    private func targetFrames() -> [Int: CGRect] {
        guard let primaryScreen = NSScreen.screens.first else { return [:] }
        window.contentView?.layoutSubtreeIfNeeded()
        return Dictionary(
            uniqueKeysWithValues: workspace.gridAreas.enumerated().map { index, stage in
                let rect = window.convertToScreen(stage.convert(stage.bounds, to: nil))
                return (index, WindowGeometry.accessibilityRect(from: rect, primaryScreenTop: primaryScreen.frame.maxY))
            }
        )
    }

    private func renderTabs() {
        workspace.closesWindowsOnRelease = session.closesWindowsOnRelease
        if let layout = session.customLayout {
            workspace.setCustomLayout(layout, activeCell: session.activeCell)
        } else {
            workspace.setGrid(session.gridSize, activeCell: session.activeCell)
        }
        workspace.setPaneIndicators(switchTargetCell: session.tabSwitchCell, pinnedCells: session.pinnedCells)
        workspace.clearTabs()
        tabIDs = session.windows.map(\.id)
        var selectedTab: NSView?
        for (index, managed) in session.windows.enumerated() {
            let selected = managed.id == session.selectedID
            let cell = session.cellIndex(for: managed.id)
            let displayed = session.isSplit && cell != nil
            let side =
                session.isSplit
                    ? cell.map {
                        session.customLayout == nil
                            ? L("%d行%d列 · ", $0 / session.gridSize.columns + 1, $0 % session.gridSize.columns + 1)
                            : L("ペイン %d", $0 + 1) + " · "
                    } ?? "" : ""
            let candidate = managed.candidate
            let title = candidate.title.isEmpty ? candidate.application.localizedName ?? "App" : candidate.title
            let pinned = cell.map { session.isPanePinned($0) } ?? false
            let tab = workspace.appendTab(
                id: managed.id,
                title: side + title,
                toolTip: side + candidate.label + (pinned ? " · " + L("固定中") : ""),
                icon: candidate.application.icon,
                selected: selected,
                displayed: displayed,
                pinned: pinned,
                tabSwitchTarget: cell == session.tabSwitchCell
            )
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

    func showNotice(_ notice: WorkspaceNotice) {
        if workspace.showNotice(notice) {
            DispatchQueue.main.async { [weak self] in self?.syncIfVisible() }
        }
    }

    // MARK: Actions

    func focusPane(at point: NSPoint) {
        guard !suspended, !quitting, picker == nil,
              window.isVisible, !window.isMiniaturized
        else { return }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for (index, area) in workspace.gridAreas.enumerated() {
            guard session.cells.indices.contains(index), let id = session.cells[index],
                  let managed = session.windows.first(where: { $0.id == id }),
                  managed.candidate.application.processIdentifier == frontPID
            else { continue }
            let rect = window.convertToScreen(area.convert(area.bounds, to: nil))
            if rect.contains(point) {
                // Clicking a managed window directly must also bring this workspace's backdrop above other workspaces'.
                window.orderFront(nil)
                if session.isSplit { session.focusVisibleWindow(id) }
                return
            }
        }
    }

    func toggleSplit() {
        session.setGrid(WorkspaceGridSize(columns: session.gridSize.columns == 2 ? 1 : 2, rows: session.gridSize.rows))
    }

    func toggleStackedSplit() {
        session.setGrid(WorkspaceGridSize(columns: session.gridSize.columns, rows: session.gridSize.rows == 2 ? 1 : 2))
    }

    func activePaneMenu() -> NSMenu { workspace.paneMenu(for: session.activeCell) }

    func restoreLayout(_ saved: SavedWorkspace) {
        setAutoHideTabs(saved.autoHideTabs ?? false)
        if let layout = saved.paneLayout {
            session.setCustomLayout(layout)
        } else if let grid = saved.gridSize {
            session.setGrid(grid)
        }
        session.setPinnedCells(saved.pinnedPanes ?? [])
    }

    @objc private func toggleAutoHideTabs() {
        setAutoHideTabs(!autoHideTabs)
    }

    func setAutoHideTabs(_ enabled: Bool) {
        guard autoHideTabs != enabled else { return }
        autoHideTabs = enabled
        tabBarHoverStart = nil
        tabBarForcedVisibleUntil = 0
        workspace.setAutoHideTabBar(enabled)
        if !enabled { tabBarLastActive = 0 }
        syncIfVisible()
        onSessionChange?(self)
    }

    func updateAutoHiddenTabBar(at point: NSPoint, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard autoHideTabs, !suspended, !quitting, picker == nil,
              window.isVisible, !window.isMiniaturized, window.isOnActiveSpace, !NSApp.isHidden
        else {
            tabBarHoverStart = nil
            workspace.hideAutoHiddenToolbar()
            return
        }
        if isToolbarMenuOpen { return }
        if workspace.toolbarHoverFrame.contains(point) {
            if tabBarHoverStart == nil { tabBarHoverStart = now }
            tabBarLastActive = now
            if now - (tabBarHoverStart ?? now) >= 0.25 {
                workspace.setAutoHiddenToolbarVisible(true)
            }
            return
        }
        tabBarHoverStart = nil
        if workspace.autoHiddenToolbarVisible,
           let panel = workspace.autoHiddenToolbarPanel,
           panel.frame.contains(point)
        {
            tabBarLastActive = now
            return
        }
        guard workspace.autoHiddenToolbarVisible else { return }
        guard now >= tabBarForcedVisibleUntil, now - tabBarLastActive >= 0.8 else { return }
        workspace.hideAutoHiddenToolbar()
    }

    func revealAutoHiddenTabBarTemporarily() {
        guard autoHideTabs else { return }
        let now = ProcessInfo.processInfo.systemUptime
        tabBarForcedVisibleUntil = now + 1.5
        tabBarLastActive = now
        tabBarHoverStart = nil
        workspace.setAutoHiddenToolbarVisible(true)
    }

    func cycleTabs(_ offset: Int) {
        revealAutoHiddenTabBarTemporarily()
        session.cycle(offset)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isToolbarMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isToolbarMenuOpen = false
        tabBarLastActive = ProcessInfo.processInfo.systemUptime
    }

    @objc private func selectTab(_ sender: NSButton) {
        guard tabIDs.indices.contains(sender.tag) else { return }
        session.select(tabIDs[sender.tag], activate: true)
    }

    @objc private func removeTab(_ sender: NSButton) {
        guard tabIDs.indices.contains(sender.tag) else { return }
        session.remove(tabIDs[sender.tag])
    }

    func removeSelected() {
        if let id = session.selectedID { session.remove(id) }
    }

    @objc private func closeWorkspace() { requestClose() }

    func requestClose() { onClose?(self) }

    @objc private func renameFromMenu() { onRename?(self) }

    @objc private func deleteFromMenu() { onDelete?(self) }

    @objc func minimizeWorkspace() { window.miniaturize(nil) }

    @objc func maximizeWorkspace() { window.toggleMaximize() }

    @objc func showPicker() { presentPicker(restoring: nil, completion: nil) }

    /// With `restoring`, the matching windows start out selected. With `collect`, the chosen windows are handed
    /// over instead of being added, and `excluding` hides windows already chosen for another workspace.
    /// `completion` runs once the sheet is gone.
    func presentPicker(
        restoring saved: [SavedWindow]?,
        excluding: [WindowCandidate] = [],
        collect: (([WindowCandidate]) -> Void)? = nil,
        completion: (() -> Void)?
    ) {
        guard picker == nil else {
            completion?()
            return
        }
        guard WindowAccess.isTrusted else {
            defer { completion?() }
            WindowAccess.requestPermission()
            showNotice(.attention(L("システム設定 → プライバシーとセキュリティ → アクセシビリティで WindowDock を許可し、もう一度追加してください。")))
            return
        }
        let scan = WindowAccess.scan()
        let candidates = scan.windows.filter { candidate in
            !session.contains(candidate) && !(isRegisteredElsewhere?(candidate) ?? false)
                && !excluding.contains { $0.isSameWindow(as: candidate) }
        }
        picker = WindowPicker(
            candidates: candidates,
            failedApplications: scan.failedApplications,
            suggested: saved.map { SavedLayout.suggest($0, among: candidates) } ?? []
        ) { [weak self] candidates in
            // Wait until the sheet has left the screen before raising the selected window.
            if let collect {
                collect(candidates)
                return
            }
            DispatchQueue.main.async { self?.session.add(candidates) }
        }
        picker?.present(on: window) { [weak self] in
            self?.picker = nil
            if collect == nil { self?.scheduleSelectedWindowRaise(activate: true) }
            completion?()
        }
    }

    @objc private func openPermission() {
        WindowAccess.requestPermission()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        if !NSWorkspace.shared.open(url) {
            showNotice(.attention(L("システム設定を開けませんでした。アクセシビリティ設定を手動で開いてください。")))
        }
    }

    /// Whether a view under a click (window-server coordinates) acts on the click itself, such as a tab,
    /// a toolbar control or a pane, instead of leaving the workspace in front of its windows.
    func handlesActivatingClick(at point: CGPoint) -> Bool {
        guard let screen = NSScreen.screens.first, let frameView = window.contentView?.superview else { return false }
        let location = window.convertPoint(fromScreen: NSPoint(x: point.x, y: screen.frame.maxY - point.y))
        return Self.handlesClick(in: frameView, at: location)
    }

    private static func handlesClick(in frameView: NSView, at location: NSPoint) -> Bool {
        var view = frameView.hitTest(location)
        while let current = view {
            if current is NSControl || current is NSScrollView || current.acceptsFirstMouse(for: nil) { return true }
            view = current.superview
        }
        return false
    }

    /// The auto-hidden tab bar is a non-activating panel, so WindowDock does not activate on its own when it is
    /// clicked. Activate this workspace the way a click on its embedded tab bar does.
    private func activateFromAutoHiddenToolbar(_ event: NSEvent) {
        guard !NSApp.isActive || !window.isKeyWindow,
              !suspended, !quitting, !window.isMiniaturized, picker == nil
        else { return }
        let handlesClick =
            event.window?.contentView?.superview
                .map { Self.handlesClick(in: $0, at: event.locationInWindow) } ?? false
        if !NSApp.isActive {
            toolbarActivationRequest = ProcessInfo.processInfo.systemUptime
            // A click raises only the clicked window; activating normally would raise every workspace.
            window.orderFrontRegardless()
            if !WindowAccess.activateFrontWindowOnly(ProcessInfo.processInfo.processIdentifier) {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        window.makeKey()
        scheduleSelectedWindowRaise(activate: !handlesClick)
    }

    private var toolbarActivationRequest: TimeInterval?

    /// Whether a click on the auto-hidden tab bar has just asked WindowDock to activate. Activation restores
    /// the previous key window, so the caller makes this workspace key again.
    func claimToolbarActivation() -> Bool {
        defer { toolbarActivationRequest = nil }
        return toolbarActivationRequest.map { ProcessInfo.processInfo.systemUptime - $0 < 2 } ?? false
    }

    func bringToFront() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Brings the workspace and then its windows to the front without waiting for WindowDock to be active,
    /// such as while a tab is dragged over it.
    func reveal() {
        guard acceptsWindowDrag, window.attachedSheet == nil else { return }
        window.orderFrontRegardless()
        session.raiseSelected(activate: true)
    }

    /// Makes this the workspace that comes back when WindowDock is activated again. Activating WindowDock now would
    /// bring every workspace forward, and while it is still active, the raise that becoming key schedules could
    /// order the frame above windows that `reveal()` has just handed focus to.
    func makeKeyAfterReveal() {
        window.makeKey()
        windowRaisePending = false
    }

    // MARK: Shortcuts and drag and drop

    var visiblePIDs: Set<pid_t> {
        Set(session.visibleWindows.map { $0.candidate.application.processIdentifier })
    }

    var canHandleShortcut: Bool {
        !session.windows.isEmpty && picker == nil && !suspended && !window.isMiniaturized && !NSApp.isHidden
            && !quitting
    }

    var acceptsWindowDrag: Bool {
        picker == nil && !suspended && !quitting && window.isVisible && window.isOnActiveSpace && !window.isMiniaturized
            && !NSApp.isHidden
    }

    var windowDropPanelNumber: Int? { workspace.windowDropPanel?.windowNumber }
    var toolbarPanelNumber: Int? { workspace.toolbarPanelWindowNumber }
    var autoHideHoverFrame: NSRect { workspace.toolbarHoverFrame }
    var isAutoHiddenToolbarVisible: Bool { workspace.autoHiddenToolbarVisible }

    func hideTabTransferTargets() {
        workspace.hideExternalTabTargets()
        workspace.hideWindowDropTarget()
    }
    func endTabTransferDrag() { workspace.endTabDrag() }
    func tabRowContains(_ point: NSPoint) -> Bool { workspace.tabRowContains(point) }
    func previewTabTransfer(pasteboard: NSPasteboard, source: NSButton, at point: NSPoint) {
        _ = workspace.updateFloatingTab(pasteboard: pasteboard, source: source, screenPoint: point)
    }
    func completeTabDrop(pasteboard: NSPasteboard, source: NSButton, at point: NSPoint) -> Bool {
        workspace.completeTabDrop(pasteboard: pasteboard, source: source, screenPoint: point)
    }

    func showWindowDropTarget(at point: NSPoint) {
        guard acceptsWindowDrag else { return hideWindowDropTarget() }
        workspace.showWindowDropTarget(
            at: point, requiresPermission: !WindowAccess.isTrusted
        )
    }

    func hideWindowDropTarget() { workspace.hideWindowDropTarget() }

    func acceptsWindowDrop(at point: NSPoint) -> Bool {
        acceptsWindowDrag && workspace.acceptsWindowDrop(at: point)
    }

    func finishWindowDrag(_ drag: WorkspaceWindowDrag, accessibilityPoint: CGPoint, screenPoint: NSPoint) {
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
            } else if isRegisteredElsewhere?(candidate) == true {
                showNotice(.information(L("このウィンドウは別のワークスペースに登録されています。")))
            } else {
                session.add(
                    candidate, originalFrame: drag.originalFrame, at: workspace.tabInsertionIndex(at: screenPoint)
                )
            }
        } catch {
            WindowAccess.logger.error("\(error.localizedDescription, privacy: .public)")
            showNotice(.attention(error.localizedDescription))
        }
    }

    // MARK: Window state

    func windowDidMove(_ notification: Notification) {
        workspace.updateToolbarPanelFrame()
        if !window.isApplyingWorkspaceFrame { syncIfVisible() }
        scheduleSettledSync()
    }

    func windowDidResize(_ notification: Notification) {
        workspace.updateToolbarPanelFrame()
        if !window.isApplyingWorkspaceFrame { syncIfVisible() }
        scheduleSettledSync()
    }

    private var settledSyncGeneration = 0

    /// Zoom animates the frame, and target apps resize asynchronously; realign once everything has settled
    /// so the managed window fully covers its pane instead of leaving the opaque pane exposed.
    private func scheduleSettledSync() {
        settledSyncGeneration += 1
        let generation = settledSyncGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, generation == self.settledSyncGeneration,
                  !self.suspended, self.picker == nil, !self.quitting, !self.window.isMiniaturized
            else { return }
            self.workspace.refreshCoverage()
            self.session.realign()
        }
    }

    func syncIfVisible() {
        guard !suspended, picker == nil, !quitting else { return }
        workspace.refreshCoverage()
        session.sync()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        scheduleSelectedWindowRaise()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Another window became key first; a later handoff would steal its focus.
        windowRaisePending = false
        windowFocusRequest = nil
    }

    func scheduleSelectedWindowRaiseIfPending() {
        if windowRaisePending { scheduleSelectedWindowRaise() }
    }

    /// Brings the workspace forward and then its windows above it, handing focus to the selected window.
    func present() {
        bringToFront()
        scheduleSelectedWindowRaise(activate: true)
    }

    func scheduleSelectedWindowRaise(activate: Bool = false) {
        windowRaisePending = true
        if activate { windowFocusRequest = ProcessInfo.processInfo.systemUptime }
        guard !windowRaiseScheduled else { return }
        windowRaiseScheduled = true
        // Do not change window ordering during button tracking or window dragging.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated { self?.raiseSelectedWindowIfReady() }
        }
    }

    private func raiseSelectedWindowIfReady() {
        windowRaiseScheduled = false
        // The mouse-up monitor retries once the button is released.
        guard windowRaisePending, NSEvent.pressedMouseButtons == 0 else { return }
        guard !suspended, !quitting, !window.isMiniaturized, picker == nil, window.attachedSheet == nil else {
            windowRaisePending = false
            windowFocusRequest = nil
            return
        }
        // A click on an inactive workspace can be handled before the app's activation arrives. Keep the request
        // until the app is active and this window is key, which schedules it again.
        guard NSApp.isActive, window.isKeyWindow else { return }
        let activate = windowFocusRequest.map { ProcessInfo.processInfo.systemUptime - $0 < 2 } ?? false
        windowRaisePending = false
        windowFocusRequest = nil
        // Order the frame first so that the windows end up above it.
        window.orderFront(nil)
        fullScreenExitTimer?.invalidate()
        fullScreenExitTimer = nil
        // Focusing a full-screen window would switch to its Space instead of showing it in its pane.
        guard !session.leaveFullScreen() else {
            raiseAfterLeavingFullScreen(activate: activate)
            return
        }
        session.refitDisplacedWindows()
        session.raiseSelected(activate: activate)
    }

    private var fullScreenExitTimer: Timer?

    private func raiseAfterLeavingFullScreen(activate: Bool) {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        fullScreenExitTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, !self.suspended, !self.quitting, !self.window.isMiniaturized, self.picker == nil else {
                    return timer.invalidate()
                }
                guard !self.session.hasFullScreenWindow else {
                    if ProcessInfo.processInfo.systemUptime > deadline { timer.invalidate() }
                    return
                }
                timer.invalidate()
                self.fullScreenExitTimer = nil
                self.session.refitDisplacedWindows()
                guard NSApp.isActive, self.window.isKeyWindow else { return }
                self.window.orderFront(nil)
                self.session.raiseSelected(activate: activate)
            }
        }
    }

    var onSuspend: (() -> Void)?

    func windowWillMiniaturize(_ notification: Notification) {
        onSuspend?()
        suspended = true
        workspace.hideAutoHiddenToolbar()
        session.suspend()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        suspended = false
        session.resume()
        scheduleSelectedWindowRaise(activate: true)
    }

    func applicationDidHide() {
        onSuspend?()
        suspended = true
        workspace.hideAutoHiddenToolbar()
        session.suspend()
    }

    func applicationDidUnhide() {
        suspended = false
        if !window.isMiniaturized {
            session.resume()
            scheduleSelectedWindowRaise()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestClose()
        return false
    }
}
