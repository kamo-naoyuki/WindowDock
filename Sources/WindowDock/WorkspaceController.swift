import AppKit
import WindowDockCore

/// One workspace: a workspace window together with the session that manages its registered windows.
@MainActor
final class WorkspaceController: NSObject, NSWindowDelegate {
    let session = WindowSession()
    let window: WorkspaceWindow
    private let workspace = WorkspaceChromeView(frame: .zero)
    private var picker: WindowPicker?
    private var tabIDs: [UUID] = []
    private var windowRaisePending = false
    private var windowRaiseScheduled = false
    private(set) var suspended = false
    var quitting = false

    var name: String {
        didSet { window.title = name; workspace.workspaceButton.title = name }
    }
    var onClose: ((WorkspaceController) -> Void)?
    var onRename: ((WorkspaceController) -> Void)?
    var onSessionChange: ((WorkspaceController) -> Void)?
    var onDelete: ((WorkspaceController) -> Void)?
    /// Whether another workspace already manages the candidate window.
    var isRegisteredElsewhere: ((WindowCandidate) -> Bool)?

    init(name: String) {
        self.name = name
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
        window.tabbingMode = .disallowed
        window.delegate = self
        window.center()

        workspace.addButton.target = self
        workspace.addButton.action = #selector(showPicker)
        workspace.permissionButton.target = self
        workspace.permissionButton.action = #selector(openPermission)
    }

    private func wireSession() {
        window.onWorkspaceFrameChange = { [weak self] in self?.syncIfVisible() }
        session.targetFrames = { [weak self] in self?.targetFrames() ?? [:] }
        session.fitMinimumSizes = { [weak self] sizes in
            guard let self else { return false }
            let fits = self.workspace.fitPanesToMinimumSizes(sizes)
            self.window.contentView?.layoutSubtreeIfNeeded()
            return fits
        }
        workspace.workspaceMenu = { [weak self] in
            let menu = NSMenu()
            menu.addItem(withTitle: L("ワークスペース名を変更…"), action: #selector(WorkspaceController.renameFromMenu), keyEquivalent: "").target = self
            menu.addItem(withTitle: L("ワークスペースを削除…"), action: #selector(WorkspaceController.deleteFromMenu), keyEquivalent: "").target = self
            return menu
        }
        workspace.onGridChange = { [weak self] in self?.session.setGrid($0) }
        workspace.onActivateCell = { [weak self] index in
            guard let self else { return }
            self.session.activateCell(index)
            // A click can land on this window's transparent aperture instead of the managed window; hand focus over explicitly.
            if self.session.cells.indices.contains(index), let id = self.session.cells[index] {
                self.session.select(id, activate: true)
            }
        }
        workspace.onCloseTabs = { [weak self] range in
            guard let self else { return }
            let ids = Array(self.tabIDs[range.clamped(to: self.tabIDs.indices)])
            for id in ids { self.session.remove(id) }
        }
        workspace.onMoveTab = { [weak self] tab, cell in
            guard let self, self.tabIDs.indices.contains(tab) else { return }
            self.session.moveWindow(self.tabIDs[tab], toCell: cell)
        }
        workspace.onSwapTabs = { [weak self] source, target in
            guard let self, self.tabIDs.indices.contains(source), self.tabIDs.indices.contains(target) else { return }
            self.session.swapWindows(self.tabIDs[source], self.tabIDs[target])
        }
        workspace.onPaneLayoutChange = { [weak self] in
            DispatchQueue.main.async { self?.syncIfVisible() }
        }
        session.onChange = { [weak self] in
            guard let self else { return }
            self.renderTabs()
            self.onSessionChange?(self)
        }
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
    }

    // MARK: Layout

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
            let tab = workspace.appendTab(title: side + managed.candidate.label, icon: managed.candidate.application.icon, selected: selected, displayed: displayed)
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
              window.isVisible, !window.isMiniaturized else { return }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for (index, area) in workspace.gridAreas.enumerated() {
            guard session.cells.indices.contains(index), let id = session.cells[index],
                  let managed = session.windows.first(where: { $0.id == id }),
                  managed.candidate.application.processIdentifier == frontPID else { continue }
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
        guard picker == nil else { completion?(); return }
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
            if let collect { collect(candidates); return }
            DispatchQueue.main.async { self?.session.add(candidates) }
        }
        picker?.present(on: window) { [weak self] in
            self?.picker = nil
            if collect == nil { self?.scheduleSelectedWindowRaise() }
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

    func bringToFront() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Shortcuts and drag and drop

    var visiblePIDs: Set<pid_t> {
        Set(session.visibleWindows.map { $0.candidate.application.processIdentifier })
    }

    var canHandleShortcut: Bool {
        !session.windows.isEmpty && picker == nil && !suspended &&
            !window.isMiniaturized && !NSApp.isHidden && !quitting
    }

    var acceptsWindowDrag: Bool {
        picker == nil && !suspended && !quitting && window.isVisible &&
            window.isOnActiveSpace && !window.isMiniaturized && !NSApp.isHidden
    }

    var windowDropPanelNumber: Int? { workspace.windowDropPanel?.windowNumber }

    func showWindowDropTarget(at point: NSPoint) {
        guard acceptsWindowDrag else { return hideWindowDropTarget() }
        workspace.showWindowDropTarget(
            hovered: workspace.acceptsWindowDrop(at: point), requiresPermission: !WindowAccess.isTrusted
        )
    }

    func hideWindowDropTarget() { workspace.hideWindowDropTarget() }

    func acceptsWindowDrop(at point: NSPoint) -> Bool {
        acceptsWindowDrag && workspace.acceptsWindowDrop(at: point)
    }

    func finishWindowDrag(_ drag: WorkspaceWindowDrag, accessibilityPoint: CGPoint) {
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
                session.add(candidate, originalFrame: drag.originalFrame)
            }
        } catch {
            WindowAccess.logger.error("\(error.localizedDescription, privacy: .public)")
            showNotice(.attention(error.localizedDescription))
        }
    }

    // MARK: Window state

    func windowDidMove(_ notification: Notification) {
        if !window.isApplyingWorkspaceFrame { syncIfVisible() }
        scheduleSettledSync()
    }

    func windowDidResize(_ notification: Notification) {
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
                  !self.suspended, self.picker == nil, !self.quitting, !self.window.isMiniaturized else { return }
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

    func scheduleSelectedWindowRaiseIfPending() {
        if windowRaisePending { scheduleSelectedWindowRaise() }
    }

    func scheduleSelectedWindowRaise() {
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

    var onSuspend: (() -> Void)?

    func windowWillMiniaturize(_ notification: Notification) {
        onSuspend?()
        suspended = true
        session.suspend()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        suspended = false
        session.resume()
        scheduleSelectedWindowRaise()
    }

    func applicationDidHide() {
        onSuspend?()
        suspended = true
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
