import AppKit
import SwiftUI
import WindowDockCore

/// One workspace: a workspace window together with the session that manages its registered windows.
@MainActor
final class WorkspaceController: NSObject, NSWindowDelegate, NSMenuDelegate {
    let session: WindowSession
    let window: WorkspaceWindow
    private let workspace = WorkspaceChromeView(frame: .zero)
    private var picker: WindowPicker?
    private struct RestorePrompt {
        let id = UUID()
        let workspace: SavedWorkspace
        let excluding: [WindowCandidate]
        let completion: ([WindowCandidate]) -> Void
    }
    private struct ManagedWindowDrag {
        let id: UUID
        let element: AXUIElement
        let windowID: CGWindowID
        let processID: pid_t
        let startFrame: CGRect
        let startWindowServerFrame: CGRect
        let workspaceFrame: NSRect
        let pane: CGRect
        let workspaceContent: CGRect
        /// The resize or divider move applied while the mouse is still down.
        var liveInteraction: ManagedWindowInteraction?
        /// Whether the WindowServer last listed the window in front of the workspace; nil until it was checked.
        var inFrontOfWorkspace: Bool?
    }

    private var restorePrompt: RestorePrompt? {
        didSet { autoGrouping?.refresh() }
    }
    private var managedWindowDrag: ManagedWindowDrag? {
        didSet {
            guard managedWindowDrag == nil, !workspace.concealedGridCells.isEmpty else { return }
            workspace.concealedGridCells = []
            workspace.refreshCoverage()
        }
    }
    /// A window that was resized with the mouse, left out of syncing until its app finishes resizing it.
    private var settlingManagedWindowID: UUID?
    private var lastManagedWindowFollowSync = TimeInterval.zero
    private var lastManagedWindowFollowFrame: CGRect?
    /// Set while the workspace frame and its panes change together, so windows are synced once at the end.
    private var deferringWorkspaceSync = false
    private var reportedManagedWindowDragSamplingFailure = false
    private var startPages: [UUID: NSHostingView<NewTabPage>] = [:]
    private var tabIDs: [UUID] { session.tabIDs }
    private var windowObservers: [pid_t: WindowEventObserver] = [:]
    private var windowRaisePending = false
    private var windowRaiseScheduled = false
    private var tabBarHoverStart: TimeInterval?
    private var tabBarLastActive: TimeInterval = 0
    private var tabBarForcedVisibleUntil: TimeInterval = 0
    private var isToolbarMenuOpen = false
    /// When a focus handoff was requested; activation can complete well after the request.
    private var windowFocusRequest: TimeInterval?
    private var coverageGeneration = 0
    private(set) var suspended = false {
        didSet { if oldValue != suspended { autoGrouping?.refresh() } }
    }
    private(set) var autoHideTabs = false
    var quitting = false {
        didSet { if oldValue != quitting { autoGrouping?.refresh() } }
    }
    /// Apps whose new windows this workspace collects automatically.
    var autoGroupBundleIDs: [String] = [] {
        didSet {
            guard oldValue != autoGroupBundleIDs else { return }
            autoGroupPage.bundleIDs = autoGroupBundleIDs
            autoGrouping?.refresh()
            scheduleEmptyWorkspaceDeletion()
        }
    }
    weak var autoGrouping: AutoGroupCoordinator? {
        didSet { autoGroupPage.isAvailable = autoGrouping != nil }
    }
    let autoGroupPage = AutoGroupPageModel()
    var isRestoring: Bool { restorePrompt != nil }
    /// Automatic grouping pauses while the workspace is hidden, minimized or asking which windows to restore.
    var acceptsAutomaticWindows: Bool {
        !quitting && !suspended && restorePrompt == nil && !window.isMiniaturized
    }
    var deletesWhenEmpty = false {
        didSet { scheduleEmptyWorkspaceDeletion() }
    }
    private var hasContainedWindows = false
    private var emptyDeletionScheduled = false
    var managedWindowMoveAction: ManagedWindowMoveAction = .returnToPane {
        didSet {
            if oldValue != managedWindowMoveAction {
                managedWindowDrag = nil
                settlingManagedWindowID = nil
            }
            if managedWindowMoveAction == .nothing {
                displacedWindowTimer?.invalidate()
                displacedWindowTimer = nil
            }
        }
    }
    var returnsDisplacedWindows: Bool {
        get { managedWindowMoveAction != .nothing }
        set { managedWindowMoveAction = newValue ? .returnToPane : .nothing }
    }
    var returnsFullScreenWindows = false {
        didSet {
            if !returnsFullScreenWindows {
                fullScreenExitTimer?.invalidate()
                fullScreenExitTimer = nil
            }
        }
    }

    var name: String {
        didSet {
            window.title = name
            workspace.setWorkspaceName(name)
        }
    }
    var onClose: ((WorkspaceController) -> Void)?
    var onRename: ((WorkspaceController) -> Void)?
    var onSessionChange: ((WorkspaceController) -> Void)?
    var onDelete: ((WorkspaceController) -> Void)?
    var onAutoDelete: ((WorkspaceController) -> Void)?
    var onTabDragBegin: ((UUID, String, NSButton) -> Void)?
    var onTabDragMove: ((String, NSPasteboard, NSButton, NSPoint) -> Void)? {
        didSet { workspace.onTabDragMove = onTabDragMove }
    }
    var onTabDragEnd: ((String, NSPasteboard, NSPoint, Bool) -> Void)?
    var acceptsExternalTab: ((String, NSButton?) -> Bool)?
    var onExternalTabDrop: ((String, NSButton?, Int?, Int?) -> Bool)?
    /// Whether another workspace already manages the candidate window.
    var isRegisteredElsewhere: ((WindowCandidate) -> Bool)?
    private let audio: AudioPlaybackMonitor

    init(name: String, access: WindowAccessClient = WindowAccessClient(), audio: AudioPlaybackMonitor? = nil) {
        self.name = name
        session = WindowSession(access: access)
        self.audio = audio ?? .shared
        window = WorkspaceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildWindow()
        wireSession()
        NotificationCenter.default.addObserver(
            self, selector: #selector(audioPlaybackChanged), name: AudioPlaybackMonitor.didChange, object: self.audio
        )
        self.audio.start()
    }

    // MARK: Setup

    private func buildWindow() {
        window.title = name
        workspace.setWorkspaceName(name)
        // The selected window normally keeps its own application active.
        window.allowsToolTipsWhenApplicationIsInactive = true
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = workspace
        // Lets Stage Manager show the workspace in the set of whichever app owns the window shown over it.
        window.collectionBehavior = [.fullScreenNone, .canJoinAllApplications]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Server-side titlebar dragging bypasses the pre-move transparency mask.
        window.isMovable = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.center()

        workspace.addButton.target = self
        workspace.addButton.action = #selector(newTab)
        workspace.permissionButton.target = self
        workspace.permissionButton.action = #selector(openPermission)
    }

    private func wireSession() {
        session.isClaimedElsewhere = { [weak self] candidate in self?.isRegisteredElsewhere?(candidate) ?? false }
        session.onAddedWindow = { [weak self] candidate in self?.autoGrouping?.remember(candidate) }
        workspace.autoGroupMenuItems = { [weak self] tab in self?.autoGroupMenuItems(forTab: tab) ?? [] }
        autoGroupPage.register = { [weak self] urls in
            guard let self, self.restorePrompt == nil else { return false }
            return self.autoGrouping?.register(applicationsAt: urls, in: self) ?? false
        }
        autoGroupPage.remove = { [weak self] bundleID in
            guard let self else { return }
            self.autoGrouping?.unregister(bundleID, from: self)
        }
        session.onFocusStartPage = { [weak self] in
            guard let self, !self.quitting else { return }
            if !NSApp.isActive, !WindowAccess.activateFrontWindowOnly(ProcessInfo.processInfo.processIdentifier) {
                NSApp.activate(ignoringOtherApps: true)
            }
            self.window.makeKeyAndOrderFront(nil)
        }
        window.onWorkspaceFrameChange = { [weak self] in
            guard let self, !self.deferringWorkspaceSync, !self.suspended, self.picker == nil, !self.quitting
            else { return }
            self.workspace.refreshCoverage()
            self.syncManagedWindows()
        }
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
            let position = menu.addItem(withTitle: L("タブバーの位置"), action: nil, keyEquivalent: "")
            position.submenu = self?.tabBarPositionMenu()
            let pane = menu.addItem(withTitle: L("ペイン"), action: nil, keyEquivalent: "")
            pane.submenu = self?.activePaneMenu()
            menu.addItem(
                withTitle: L("新しいウィンドウを自動で追加するアプリ…"),
                action: self?.canChooseAutoGroupApplications == true
                    ? #selector(WorkspaceController.chooseAutoGroupApplications) : nil,
                keyEquivalent: ""
            ).target = self
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
        workspace.onReleaseTabs = { [weak self] request in
            guard let self else { return }
            for id in request.ids { self.session.remove(id, closeWindow: request.closeWindows) }
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
            guard let self, self.restorePrompt == nil, self.tabIDs.indices.contains(index) else { return }
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
            if let prompt = self.restorePrompt, !self.session.isStartPage(prompt.id) {
                // The tab's ×, ⌘W and bulk release dismiss the same prompt as Skip.
                self.finishRestore(prompt.id, choosing: [])
            }
            self.renderTabs()
            self.onSessionChange?(self)
            self.scheduleEmptyWorkspaceDeletion()
        }
        session.onMessage = { [weak self] message in self?.showNotice(message) }
        session.onConstraintWarningCleared = { [weak self] text in
            guard let self, self.workspace.currentNoticeText == text else { return }
            self.showNotice(.information(L("⌃ Tab / ⌃ ⇧ Tab でタブを切替")))
        }
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
        refreshWindowObservers()
        workspace.closesWindowsOnRelease = session.closesWindowsOnRelease
        if let layout = session.customLayout {
            workspace.setCustomLayout(layout, activeCell: session.activeCell)
        } else {
            workspace.setGrid(session.gridSize, activeCell: session.activeCell)
        }
        workspace.setPaneIndicators(switchTargetCell: session.tabSwitchCell, pinnedCells: session.pinnedCells)
        let tabs = workspace.setTabs(tabItems())
        for (index, tab) in tabs.enumerated() {
            tab.select.target = self
            tab.select.action = #selector(selectTab(_:))
            tab.select.tag = index
            tab.close.target = self
            tab.close.action = #selector(removeTab(_:))
            tab.close.tag = index
        }
        workspace.showManagedWindows(!tabIDs.isEmpty)
        updateStartPages()
        if let selected = tabs.first(where: { $0.id == session.selectedID }) { workspace.revealTab(selected.view) }
        window.invalidateShadow()
    }

    private func tabItems() -> [WorkspaceTabItem] {
        tabIDs.map { id in
            let selected = id == session.selectedID
            let cell = session.cellIndex(for: id)
            let displayed = session.isSplit && cell != nil
            let side =
                session.isSplit
                    ? cell.map {
                        session.customLayout == nil
                            ? L("%d行%d列 · ", $0 / session.gridSize.columns + 1, $0 % session.gridSize.columns + 1)
                            : L("ペイン %d", $0 + 1) + " · "
                    } ?? "" : ""
            let candidate = session.managedByID[id]?.candidate
            let title = candidate.map { $0.title.isEmpty ? $0.application.localizedName ?? "App" : $0.title }
                ?? L("新しいタブ")
            let pinned = cell.map { session.isPanePinned($0) } ?? false
            let playingAudio = candidate.map { audio.isPlaying($0) } ?? false
            return WorkspaceTabItem(
                id: id,
                title: side + title,
                toolTip: side + (candidate?.label ?? title) + (pinned ? " · " + L("固定中") : "")
                    + (playingAudio ? " · " + L("音声を再生中") : ""),
                icon: candidate?.application.icon,
                selected: selected,
                displayed: displayed,
                pinned: pinned,
                tabSwitchTarget: cell == session.tabSwitchCell,
                playingAudio: playingAudio
            )
        }
    }

    /// Reconfigures the tabs in place: `renderTabs` would end a tab drag and scroll to the selected tab.
    @objc private func audioPlaybackChanged() {
        guard !quitting else { return }
        workspace.updateTabs(tabItems())
    }

    private func updateStartPages() {
        let visible = Set(session.cells.compactMap { $0 }.filter(session.isStartPage))
        for (id, page) in startPages where !visible.contains(id) {
            page.removeFromSuperview()
            startPages.removeValue(forKey: id)
        }
        for id in visible {
            guard let cell = session.cellIndex(for: id) else { continue }
            let area = workspace.gridAreas[cell]
            let prompt = restorePrompt.flatMap { $0.id == id ? $0 : nil }
            let page = startPages[id] ?? NSHostingView(rootView: NewTabPage(
                restoration: prompt.map {
                    NewTabPage.Restoration(workspace: $0.workspace, skip: { [weak self] in
                        self?.finishRestore(id, choosing: [])
                    })
                },
                access: session.access,
                isAvailable: { [weak self] candidate in
                    guard let self, !self.quitting else { return false }
                    return !self.session.contains(candidate) && !self.session.isClaimedElsewhere(candidate)
                        && !(prompt?.excluding.contains { $0.isSameWindow(as: candidate) } ?? false)
                },
                launch: { [weak self] url in
                    guard let self, !self.quitting else { throw CancellationError() }
                    let windows = try await self.session.launchWindows(at: url, from: id)
                    if let appID = windows.first?.application.bundleIdentifier { RecentApplications().record(appID) }
                    return windows
                },
                choose: { [weak self] candidates in
                    guard let self, !self.quitting, self.session.cellIndex(for: id) != nil else { return false }
                    if prompt != nil { return self.finishRestore(id, choosing: candidates) }
                    return self.session.fillStartPage(id, with: candidates)
                },
                autoGroup: autoGroupPage
            ))
            if page.superview !== area {
                // The pane owns the viewport size, not the scroll view's ideal content size.
                page.sizingOptions = []
                page.translatesAutoresizingMaskIntoConstraints = false
                area.addSubview(page)
                NSLayoutConstraint.activate([
                    page.leadingAnchor.constraint(equalTo: area.leadingAnchor),
                    page.trailingAnchor.constraint(equalTo: area.trailingAnchor),
                    page.topAnchor.constraint(equalTo: area.topAnchor),
                    page.bottomAnchor.constraint(equalTo: area.bottomAnchor),
                ])
                startPages[id] = page
            }
        }
    }

    private func refreshWindowObservers() {
        let applications = Dictionary(
            session.windows.map { ($0.candidate.application.processIdentifier, $0.candidate.application) },
            uniquingKeysWith: { first, _ in first }
        )
        windowObservers = windowObservers.filter { applications[$0.key] != nil }
        for (pid, application) in applications {
            if windowObservers[pid] == nil {
                windowObservers[pid] = WindowEventObserver(
                    application: application,
                    onFocusChange: { [weak self] in
                        Task { @MainActor in self?.focusedWindowChanged(for: pid) }
                    },
                    onWindowChange: { [weak self] element in
                        MainActor.assumeIsolated {
                            guard let self, self.session.windows.contains(where: {
                                CFEqual($0.candidate.element, element)
                            }) else { return }
                            self.windowsChangedOutsideWorkspace(element)
                        }
                    },
                    onWindowRestore: { [weak self] element in
                        MainActor.assumeIsolated {
                            guard let self, self.session.windows.contains(where: {
                                CFEqual($0.candidate.element, element)
                            }) else { return }
                            self.windowRestoredOutsideWorkspace(element)
                        }
                    }
                )
            }
            windowObservers[pid]?.observeMinimizing(
                of: session.windows.filter { $0.candidate.application.processIdentifier == pid }
                    .map(\.candidate.element)
            )
        }
    }

    private var displacedWindowTimer: Timer?

    /// WindowDock's own changes also send notifications; refitting an aligned window is a no-op.
    func windowsChangedOutsideWorkspace(
        _ element: AXUIElement? = nil, mouseButtonDown: Bool = NSEvent.pressedMouseButtons & 1 != 0
    ) {
        if let element, followMinimizing(of: element) { return }
        guard returnsDisplacedWindows, !suspended, !quitting else { return }
        if managedWindowMoveAction == .follow, let element {
            if let drag = managedWindowDrag, CFEqual(drag.element, element) {
                do {
                    updateManagedWindowDrag(with: try session.access.frame(element), mouseButtonDown: mouseButtonDown)
                } catch {
                    managedWindowDragSamplingFailed(error)
                }
                return
            }
            // The timer below still runs, so the drag is finished even if the release is missed.
            if mouseButtonDown { beginManagedWindowResize(of: element) }
        }
        displacedWindowTimer?.invalidate()
        // Wait for the change, such as a zoom animation, to finish.
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.returnDisplacedWindows() }
        }
        displacedWindowTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func returnDisplacedWindows() {
        displacedWindowTimer = nil
        guard returnsDisplacedWindows, !suspended, !quitting, !window.isMiniaturized, picker == nil,
              window.attachedSheet == nil,
              fullScreenExitTimer?.isValid != true
        else {
            settlingManagedWindowID = nil
            return
        }
        // Windows dragged with the mouse are put back once the button is released.
        guard NSEvent.pressedMouseButtons == 0 else { return windowsChangedOutsideWorkspace() }
        // The release may not have been seen yet; finishing schedules this check again.
        guard managedWindowDrag == nil else { return finishManagedWindowDrag() }
        if let id = settlingManagedWindowID {
            settlingManagedWindowID = nil
            // Compare the resized window with its new pane, so it is fitted or its late zoom is followed.
            session.expectPaneFrame(for: id)
        }
        if returnsFullScreenWindows, session.leaveFullScreen() {
            refitAfterLeavingFullScreen(raiseWindows: false)
        } else if !followDisplacedWindow() {
            session.refitDisplacedWindows()
        }
    }

    /// In follow mode, restoring any window of a minimized workspace restores the workspace with all its windows.
    func windowRestoredOutsideWorkspace(_ element: AXUIElement) {
        if managedWindowMoveAction == .follow, !quitting, window.isMiniaturized,
           session.windows.contains(where: { CFEqual($0.candidate.element, element) }) {
            window.deminiaturize(nil)
            return
        }
        windowsChangedOutsideWorkspace(element)
    }

    /// In follow mode, minimizing a shown window minimizes its workspace along with the other windows.
    /// Returns true when the workspace followed.
    private func followMinimizing(of element: AXUIElement) -> Bool {
        guard managedWindowMoveAction == .follow, !quitting, !suspended, !window.isMiniaturized, window.isVisible,
              picker == nil, window.attachedSheet == nil,
              let managed = session.windows.first(where: { CFEqual($0.candidate.element, element) }),
              session.cells.contains(managed.id),
              (try? session.access.isMinimized(element)) == true
        else { return false }
        displacedWindowTimer?.invalidate()
        displacedWindowTimer = nil
        settlingManagedWindowID = nil
        window.miniaturize(nil)
        return true
    }

    /// Applies a settled move, resize or zoom of a shown window to the workspace, e.g. one that finished after the
    /// mouse was released or one the press did not reach. Returns false when nothing followed.
    private func followDisplacedWindow() -> Bool {
        guard managedWindowMoveAction == .follow else { return false }
        for id in session.cells.compactMap({ $0 }) {
            guard let managed = session.managedByID[id],
                  !session.access.isFullScreen(managed.candidate.element),
                  let minimized = try? session.access.isMinimized(managed.candidate.element)
            else { continue }
            if minimized, followMinimizing(of: managed.candidate.element) { return true }
            guard !minimized,
                  let aligned = session.alignedFrame(for: id),
                  let frame = try? session.access.frame(managed.candidate.element),
                  !WindowGeometry.fits(frame, requested: aligned, tolerance: 1),
                  let geometry = paneGeometry(for: id)
            else { continue }
            let interaction = classifyManagedWindowInteraction(
                start: aligned, current: frame, pane: geometry.pane, workspaceContent: geometry.workspaceContent
            )
            if applyManagedWindowInteraction(
                interaction, id: id, workspaceFrame: window.frame, pane: geometry.pane,
                workspaceContent: geometry.workspaceContent
            ) { return true }
        }
        return false
    }

    @discardableResult
    func beginManagedWindowDrag(windowServerWindow: WindowServerWindow) -> Bool {
        guard managedWindowMoveAction == .follow, managedWindowDrag == nil,
              let window = session.windows.first(where: {
                  session.access.windowID($0.candidate.element) == windowServerWindow.id
              }),
              let aligned = session.alignedFrame(for: window.id),
              let geometry = paneGeometry(for: window.id)
        else { return false }
        do {
            let frame = try session.access.frame(window.candidate.element)
            guard WindowGeometry.fits(frame, requested: aligned, tolerance: 1) else { return false }
            guard window.candidate.application.processIdentifier == windowServerWindow.processID,
                  WindowGeometry.fits(frame, requested: windowServerWindow.frame, tolerance: 3)
            else { return false }
            startManagedWindowDrag(ManagedWindowDrag(
                id: window.id, element: window.candidate.element, windowID: windowServerWindow.id,
                processID: windowServerWindow.processID, startFrame: frame,
                startWindowServerFrame: windowServerWindow.frame, workspaceFrame: self.window.frame,
                pane: geometry.pane, workspaceContent: geometry.workspaceContent
            ))
            return true
        } catch {
            WindowAccess.logger
                .error("Could not begin following managed window: \(error.localizedDescription, privacy: .public)")
            showNotice(.attention(error.localizedDescription))
            return false
        }
    }

    private func startManagedWindowDrag(_ drag: ManagedWindowDrag) {
        if let id = settlingManagedWindowID {
            settlingManagedWindowID = nil
            session.expectPaneFrame(for: id)
        }
        settledSyncGeneration += 1
        lastManagedWindowFollowSync = 0
        lastManagedWindowFollowFrame = nil
        reportedManagedWindowDragSamplingFailure = false
        managedWindowDrag = drag
    }

    /// Follows a shown window that is being resized although the press did not start a drag for it, e.g. because its
    /// resize area sticks out over the window behind it.
    private func beginManagedWindowResize(of element: AXUIElement) {
        guard let managed = session.windows.first(where: { CFEqual($0.candidate.element, element) }),
              session.cells.contains(managed.id),
              !session.access.isFullScreen(element),
              let windowID = session.access.windowID(element),
              let aligned = session.alignedFrame(for: managed.id),
              let geometry = paneGeometry(for: managed.id),
              let frame = try? session.access.frame(element)
        else { return }
        switch classifyManagedWindowInteraction(
            start: aligned, current: frame, pane: geometry.pane, workspaceContent: geometry.workspaceContent
        ) {
        case .resizeWorkspace, .moveDivider:
            break
        default:
            return
        }
        if let drag = managedWindowDrag {
            // Take over only from a press that has not changed anything yet.
            guard drag.liveInteraction == nil, window.frame == drag.workspaceFrame,
                  let leaderFrame = try? session.access.frame(drag.element),
                  WindowGeometry.fits(leaderFrame, requested: drag.startFrame, tolerance: 1)
            else { return }
        }
        startManagedWindowDrag(ManagedWindowDrag(
            id: managed.id, element: element, windowID: windowID,
            processID: managed.candidate.application.processIdentifier, startFrame: aligned,
            startWindowServerFrame: aligned, workspaceFrame: window.frame,
            pane: geometry.pane, workspaceContent: geometry.workspaceContent
        ))
        updateManagedWindowDrag(with: frame, mouseButtonDown: true)
    }

    var isTrackingManagedWindowDrag: Bool { managedWindowDrag != nil }

    func updateManagedWindowDrag(using windows: [WindowServerWindow], mouseButtonDown: Bool) {
        guard let drag = managedWindowDrag, mouseButtonDown,
              let window = windows.first(where: { $0.id == drag.windowID && $0.processID == drag.processID })
        else { return }
        concealDraggedWindowPane(stackedWindows: windows)
        // Move each edge of the AX frame as far as the WindowServer frame's, which can differ by rounding.
        let start = drag.startFrame
        let sample = window.frame
        let sampleStart = drag.startWindowServerFrame
        let minX = start.minX + sample.minX - sampleStart.minX
        let minY = start.minY + sample.minY - sampleStart.minY
        let maxX = start.maxX + sample.maxX - sampleStart.maxX
        let maxY = start.maxY + sample.maxY - sampleStart.maxY
        updateManagedWindowDrag(
            with: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
            mouseButtonDown: mouseButtonDown
        )
    }

    /// Moves or resizes the workspace along with the window being dragged.
    private func updateManagedWindowDrag(with frame: CGRect, mouseButtonDown: Bool) {
        guard let drag = managedWindowDrag, mouseButtonDown, frame.width > 0, frame.height > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastManagedWindowFollowSync >= 1.0 / 60 else { return }
        if let last = lastManagedWindowFollowFrame,
           abs(frame.minX - last.minX) + abs(frame.minY - last.minY)
           + abs(frame.maxX - last.maxX) + abs(frame.maxY - last.maxY) < 1
        { return }
        lastManagedWindowFollowSync = now
        lastManagedWindowFollowFrame = frame
        let start = drag.startFrame
        let widthChange = abs(frame.width - start.width)
        let heightChange = abs(frame.height - start.height)
        if widthChange <= 2, heightChange <= 2 {
            let offset = CGVector(dx: frame.minX - start.minX, dy: frame.minY - start.minY)
            applyLiveManagedWindowInteraction(nil, offset: hypot(offset.dx, offset.dy) >= 4 ? offset : .zero)
        } else if widthChange <= Self.frameRounding.width, heightChange <= Self.frameRounding.height {
            // Too small to tell from an app rounding the size.
            applyLiveManagedWindowInteraction(nil)
        } else {
            let interaction = classifyManagedWindowInteraction(
                start: start, current: frame, pane: drag.pane, workspaceContent: drag.workspaceContent
            )
            switch interaction {
            case .resizeWorkspace, .moveDivider:
                applyLiveManagedWindowInteraction(interaction)
            default:
                // Keep the last shape until the resize can be told apart again.
                break
            }
        }
    }

    /// Keeps the dragged window's pane opaque while the window is drawn in front of the workspace: the workspace lags
    /// behind the window, so the pane's aperture would otherwise show the windows behind the workspace.
    /// `windows` is the WindowServer list, front to back.
    private func concealDraggedWindowPane(stackedWindows windows: [WindowServerWindow]) {
        guard let drag = managedWindowDrag else { return }
        let workspaceID = CGWindowID(window.windowNumber)
        if let leader = windows.firstIndex(where: { $0.id == drag.windowID && $0.processID == drag.processID }),
           let workspaceIndex = windows.firstIndex(where: { $0.id == workspaceID })
        {
            managedWindowDrag?.inFrontOfWorkspace = leader < workspaceIndex
        } else if drag.inFrontOfWorkspace == nil {
            managedWindowDrag?.inFrontOfWorkspace = false
        }
        let cells: Set<Int> =
            managedWindowDrag?.inFrontOfWorkspace == true
                ? Set(session.cells.firstIndex(of: drag.id).map { [$0] } ?? [])
                : []
        guard workspace.concealedGridCells != cells else { return }
        workspace.concealedGridCells = cells
        workspace.refreshCoverage()
    }

    /// Shapes the workspace for the dragged window's move, resize or divider move, measured from the drag's start.
    /// Only the dragged window's pane changes size: its inner edges that are not being dragged stay where they were.
    private func applyLiveManagedWindowInteraction(_ interaction: ManagedWindowInteraction?, offset: CGVector = .zero) {
        guard let drag = managedWindowDrag else { return }
        // Notifications can move the workspace before the WindowServer list was sampled for this drag.
        if drag.inFrontOfWorkspace == nil {
            concealDraggedWindowPane(stackedWindows: (try? WindowAccess.windowServerWindows()) ?? [])
        }
        var frame = drag.workspaceFrame.offsetBy(dx: offset.dx, dy: -offset.dy)
        var dividerEdge: WorkspaceResizeEdges = []
        var dividerDelta: CGFloat = 0
        switch interaction {
        case .resizeWorkspace(let edges, let delta)?:
            frame = WorkspaceResize.resizedFrame(
                from: drag.workspaceFrame,
                delta: delta,
                edges: edges,
                minimumSize: window.minSize,
                maximumTop: window.screen?.visibleFrame.maxY ?? .greatestFiniteMagnitude
            )
        case .moveDivider(let edge, let delta)?:
            dividerEdge = edge
            dividerDelta = delta
        default:
            break
        }
        let pane = drag.pane.offsetBy(dx: offset.dx, dy: offset.dy)
        var changed = frame != window.frame
        deferringWorkspaceSync = true
        window.setWorkspaceFrame(frame)
        for edge in [WorkspaceResizeEdges.left, .right, .top, .bottom]
            where Self.isInnerEdge(edge, of: drag.pane, in: drag.workspaceContent) {
            let position = Self.position(of: edge, in: pane) + (edge == dividerEdge ? dividerDelta : 0)
            if movePaneEdge(edge, of: drag.id, to: position) { changed = true }
        }
        deferringWorkspaceSync = false
        managedWindowDrag?.liveInteraction = interaction
        guard changed, !suspended, picker == nil, !quitting else { return }
        workspace.refreshCoverage()
        syncManagedWindows()
    }

    /// Moves an inner edge of a window's pane to a screen position in Accessibility coordinates.
    @discardableResult
    private func movePaneEdge(_ edge: WorkspaceResizeEdges, of id: UUID, to position: CGFloat) -> Bool {
        guard let paneIndex = session.cells.firstIndex(of: id), let pane = targetFrames()[paneIndex] else {
            return false
        }
        let delta = position - Self.position(of: edge, in: pane)
        guard abs(delta) >= 0.5 else { return false }
        return workspace.stage.resizePaneBoundary(at: paneIndex, edge: edge, by: delta)
    }

    /// Keeps a resized window's pane edges that were not dragged where they were before the resize.
    private func keepUndraggedPaneEdges(
        of id: UUID, resized edges: WorkspaceResizeEdges, pane: CGRect, workspaceContent: CGRect
    ) {
        for edge in [WorkspaceResizeEdges.left, .right, .top, .bottom]
            where !edges.contains(edge) && Self.isInnerEdge(edge, of: pane, in: workspaceContent) {
            movePaneEdge(edge, of: id, to: Self.position(of: edge, in: pane))
        }
    }

    private static func position(of edge: WorkspaceResizeEdges, in frame: CGRect) -> CGFloat {
        switch edge {
        case .left: frame.minX
        case .right: frame.maxX
        case .top: frame.minY
        default: frame.maxY
        }
    }

    private static func isInnerEdge(_ edge: WorkspaceResizeEdges, of pane: CGRect,
                                    in workspaceContent: CGRect) -> Bool {
        abs(position(of: edge, in: pane) - position(of: edge, in: workspaceContent)) > 1
    }

    private func paneGeometry(for id: UUID) -> (pane: CGRect, workspaceContent: CGRect)? {
        let targets = targetFrames()
        guard let paneIndex = session.cells.firstIndex(of: id), let pane = targets[paneIndex] else { return nil }
        let workspaceContent = targets.values.reduce(CGRect.null) { $0.union($1) }
        return workspaceContent.isNull ? nil : (pane, workspaceContent)
    }

    private static let frameRounding = CGSize(width: 12, height: 20)

    private func classifyManagedWindowInteraction(
        start: CGRect, current: CGRect, pane: CGRect, workspaceContent: CGRect
    ) -> ManagedWindowInteraction {
        guard let primaryScreen = NSScreen.screens.first else { return .ignore }
        let visibleFrames = NSScreen.screens.map {
            WindowGeometry.accessibilityRect(from: $0.visibleFrame, primaryScreenTop: primaryScreen.frame.maxY)
        }
        let interaction = ManagedWindowInteractionClassifier.classify(
            start: start,
            current: current,
            pane: pane,
            workspaceContent: workspaceContent,
            screenVisibleFrames: visibleFrames,
            roundingTolerance: Self.frameRounding
        )
        // A window that moved one edge a little was resized, not moved; it is put back into its pane.
        if case .move = interaction,
           abs(current.width - start.width) > 2 || abs(current.height - start.height) > 2
        { return .ignore }
        return interaction
    }

    /// Changes the workspace to match a managed window's move, resize or zoom. Returns false when it did not change.
    private func applyManagedWindowInteraction(
        _ interaction: ManagedWindowInteraction, id: UUID, workspaceFrame: NSRect, pane: CGRect,
        workspaceContent: CGRect
    ) -> Bool {
        switch interaction {
        case .maximize:
            settledSyncGeneration += 1
            if window.isZoomed {
                session.realign(raiseWindows: false)
            } else {
                window.toggleMaximize()
            }
        case .move(let offset):
            window.setWorkspaceFrame(workspaceFrame.offsetBy(dx: offset.dx, dy: -offset.dy))
            settledSyncGeneration += 1
            session.realign(raiseWindows: false)
        case .resizeWorkspace(let edges, let delta):
            deferringWorkspaceSync = true
            window.setWorkspaceFrame(WorkspaceResize.resizedFrame(
                from: workspaceFrame,
                delta: delta,
                edges: edges,
                minimumSize: window.minSize,
                maximumTop: window.screen?.visibleFrame.maxY ?? .greatestFiniteMagnitude
            ))
            keepUndraggedPaneEdges(of: id, resized: edges, pane: pane, workspaceContent: workspaceContent)
            deferringWorkspaceSync = false
            workspace.refreshCoverage()
            session.realign(raiseWindows: false)
        case .moveDivider(let edge, let delta):
            guard movePaneEdge(edge, of: id, to: Self.position(of: edge, in: pane) + delta) else { return false }
            session.realign(raiseWindows: false)
        case .ignore:
            return false
        }
        return true
    }

    func managedWindowDragSamplingFailed(_ error: Error) {
        guard managedWindowDrag != nil, !reportedManagedWindowDragSamplingFailure else { return }
        reportedManagedWindowDragSamplingFailure = true
        WindowAccess.logger
            .error("Could not sample managed-window movement: \(error.localizedDescription, privacy: .public)")
        showNotice(.attention(error.localizedDescription))
    }

    func finishManagedWindowDrag() {
        guard let drag = managedWindowDrag else { return }
        reportedManagedWindowDragSamplingFailure = false
        guard managedWindowMoveAction == .follow,
              !suspended, !quitting, !window.isMiniaturized, picker == nil, window.attachedSheet == nil
        else {
            managedWindowDrag = nil
            return
        }
        var settles = drag.liveInteraction != nil || window.frame != drag.workspaceFrame
        do {
            let frame = try session.access.frame(drag.element)
            let interaction = classifyManagedWindowInteraction(
                start: drag.startFrame, current: frame, pane: drag.pane, workspaceContent: drag.workspaceContent
            )
            switch interaction {
            case .move(let offset):
                applyLiveManagedWindowInteraction(nil, offset: offset)
                managedWindowDrag = nil
                if applyManagedWindowInteraction(
                    interaction, id: drag.id, workspaceFrame: drag.workspaceFrame, pane: drag.pane,
                    workspaceContent: drag.workspaceContent
                ) { return }
            case .resizeWorkspace, .moveDivider:
                // The app may still be resizing the window, so leave it alone until it settles.
                applyLiveManagedWindowInteraction(interaction)
                settles = true
            case .maximize:
                applyLiveManagedWindowInteraction(nil)
                settles = true
            case .ignore:
                if settles { applyLiveManagedWindowInteraction(nil) }
            }
        } catch {
            WindowAccess.logger
                .error("Could not follow managed window: \(error.localizedDescription, privacy: .public)")
            showNotice(.attention(L("管理ウィンドウの位置を取得できませんでした。ペインに戻します。")))
            if settles { applyLiveManagedWindowInteraction(nil) }
        }
        managedWindowDrag = nil
        if settles {
            settlingManagedWindowID = drag.id
            // Its last synced frame is stale; a press before it settles compares it with its new pane.
            session.expectPaneFrame(for: drag.id)
        }
        // Resizes and zooms can finish after the release, and a press outside a window's edge can reach the window
        // behind it, so decide once the frames settle.
        windowsChangedOutsideWorkspace()
    }

    func cancelManagedWindowDrag() {
        finishManagedWindowDrag()
    }

    func applicationDidBecomeFrontmost(_ application: NSRunningApplication) {
        guard session.windows
            .contains(where: { $0.candidate.application.processIdentifier == application.processIdentifier })
        else { return }
        refreshWindowObservers()
        focusedWindowChanged(for: application.processIdentifier)
    }

    private func focusedWindowChanged(for processIdentifier: pid_t) {
        guard !quitting,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
              let application = session.windows.first(where: {
                  $0.candidate.application.processIdentifier == processIdentifier
              })?.candidate.application,
              let focused = WindowAccess.focusedWindow(application)
        else { return }
        session.observeFocusedWindow(focused)
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
        setTabBarPosition(saved.tabBarPosition ?? .top)
        setAutoHideTabs(saved.autoHideTabs ?? false)
        if let layout = saved.paneLayout {
            session.setCustomLayout(layout)
        } else if let grid = saved.gridSize {
            session.setGrid(grid)
        }
        session.setPinnedCells(saved.pinnedPanes ?? [])
    }

    var tabBarPosition: TabBarPosition { workspace.tabBarPosition }

    func setShowsTabIconsOnly(_ enabled: Bool) {
        guard workspace.showsTabIconsOnly != enabled else { return }
        workspace.showsTabIconsOnly = enabled
        workspace.layoutSubtreeIfNeeded()
        // Narrower tabs can fold a wrapped second row, which changes the pane area.
        syncIfVisible()
    }

    func setWrapsCrowdedTabs(_ enabled: Bool) {
        guard workspace.wrapsCrowdedTabs != enabled else { return }
        workspace.wrapsCrowdedTabs = enabled
        workspace.layoutSubtreeIfNeeded()
        syncIfVisible()
    }

    func setTabBarPosition(_ position: TabBarPosition) {
        guard position != tabBarPosition else { return }
        workspace.setTabBarPosition(position)
        tabBarHoverStart = nil
        syncIfVisible()
        onSessionChange?(self)
    }

    func tabBarPositionMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, position) in TabBarPosition.allCases.enumerated() {
            let item = menu.addItem(
                withTitle: position.title,
                action: #selector(changeTabBarPosition(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            item.state = position == tabBarPosition ? .on : .off
        }
        return menu
    }

    @objc private func changeTabBarPosition(_ item: NSMenuItem) {
        guard TabBarPosition.allCases.indices.contains(item.tag) else { return }
        setTabBarPosition(TabBarPosition.allCases[item.tag])
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

    /// Long enough to ignore a pointer that only passes over the edge handle on its way elsewhere.
    static let autoHiddenTabBarRevealDelay: TimeInterval = 0.08

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
            if now - (tabBarHoverStart ?? now) >= Self.autoHiddenTabBarRevealDelay {
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

    /// Moves the windows and automatically grouped apps of `others` into this workspace. The caller closes them.
    @discardableResult
    func absorbWorkspaces(_ others: [WorkspaceController]) -> Int {
        var moved = 0
        var bundleIDs = autoGroupBundleIDs
        for other in others where other !== self {
            other.cancelManagedWindowDrag()
            moved += session.absorbWindows(from: other.session)
            let added = other.autoGroupBundleIDs.filter { !bundleIDs.contains($0) }
            bundleIDs += added
        }
        autoGroupBundleIDs = bundleIDs
        return moved
    }

    /// Closes only the workspace UI; its managed windows must already have been restored or transferred.
    func finishClosing() {
        quitting = true
        if let prompt = restorePrompt { finishRestore(prompt.id, choosing: []) }
        workspace.hideAutoHiddenToolbar()
        window.delegate = nil
        window.orderOut(nil)
        window.close()
    }

    private func scheduleEmptyWorkspaceDeletion() {
        // A restore prompt isn't a user-created tab. Skipping it must not delete the saved workspace.
        if tabIDs.contains(where: { $0 != restorePrompt?.id }) { hasContainedWindows = true }
        guard deletesWhenEmpty, hasContainedWindows, tabIDs.isEmpty, autoGroupBundleIDs.isEmpty, !quitting,
              picker == nil, !emptyDeletionScheduled
        else { return }
        emptyDeletionScheduled = true
        // A tab transfer still presents the destination and saves both workspaces after its source becomes empty.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.emptyDeletionScheduled = false
                guard self.deletesWhenEmpty, self.hasContainedWindows, self.tabIDs.isEmpty,
                      self.autoGroupBundleIDs.isEmpty, !self.quitting, self.picker == nil,
                      let onAutoDelete = self.onAutoDelete
                else { return }
                self.hasContainedWindows = false
                SavedLayout.remove(named: self.name)
                onAutoDelete(self)
                self.finishClosing()
            }
        }
    }

    @objc private func renameFromMenu() { onRename?(self) }

    @objc private func deleteFromMenu() { onDelete?(self) }

    @objc func minimizeWorkspace() { window.miniaturize(nil) }

    @objc func maximizeWorkspace() { window.toggleMaximize() }

    @objc func newTab() {
        guard !quitting, restorePrompt == nil, window.attachedSheet == nil else { return }
        session.newTab()
    }

    // MARK: Automatic grouping

    /// Adds a window opened by a collected app without selecting it. If the user is already working in the new
    /// window, the usual focus tracking shows its tab.
    @discardableResult
    func addAutomatically(_ candidate: WindowCandidate) throws -> Bool {
        guard acceptsAutomaticWindows, try session.addInBackground(candidate) != nil else { return false }
        focusedWindowChanged(for: candidate.application.processIdentifier)
        return true
    }

    private func autoGroupMenuItems(forTab tab: Int) -> [NSMenuItem] {
        guard tabIDs.indices.contains(tab) else { return [] }
        let available = autoGrouping != nil && restorePrompt == nil
        var items: [NSMenuItem] = []
        if let application = session.managedByID[tabIDs[tab]]?.candidate.application {
            let toggle = NSMenuItem(
                title: L("「%@」の新しいウィンドウを自動でこのワークスペースに追加", application.localizedName ?? L("対象アプリ")),
                action: nil, keyEquivalent: ""
            )
            if let bundleID = autoGrouping?.bundleIdentifier(application) ?? application.bundleIdentifier {
                toggle.state = autoGroupBundleIDs.contains(bundleID) ? .on : .off
                if available {
                    toggle.action = #selector(toggleAutoGroupFromMenu(_:))
                    toggle.target = self
                    toggle.representedObject = bundleID
                }
            } else {
                toggle.toolTip = L("このアプリは識別できないため、新しいウィンドウを自動で追加できません。")
            }
            items.append(toggle)
        }
        let choose = NSMenuItem(
            title: items.isEmpty ? L("新しいウィンドウを自動で追加するアプリを選ぶ…") : L("別のアプリを選ぶ…"),
            action: available ? #selector(chooseAutoGroupApplications) : nil, keyEquivalent: ""
        )
        choose.target = self
        items.append(choose)
        return items
    }

    var canChooseAutoGroupApplications: Bool {
        autoGrouping != nil && restorePrompt == nil && !quitting && !isRestoring
    }

    @objc private func toggleAutoGroupFromMenu(_ item: NSMenuItem) {
        guard let bundleID = item.representedObject as? String, let autoGrouping else { return }
        if autoGroupBundleIDs.contains(bundleID) {
            autoGrouping.unregister(bundleID, from: self)
        } else {
            autoGrouping.register([bundleID], in: self)
        }
    }

    @objc func chooseAutoGroupApplications() {
        guard canChooseAutoGroupApplications else { return }
        autoGrouping?.chooseApplications(for: self)
    }

    func collectRestoration(_ saved: SavedWorkspace, excluding: [WindowCandidate],
                            completion: @escaping ([WindowCandidate]) -> Void) {
        guard !quitting, restorePrompt == nil, picker == nil, ensureWindowAccess() else { return completion([]) }
        let prompt = RestorePrompt(workspace: saved, excluding: excluding, completion: completion)
        restorePrompt = prompt
        session.newTab(id: prompt.id)
    }

    @discardableResult
    private func finishRestore(_ id: UUID, choosing candidates: [WindowCandidate]) -> Bool {
        guard let prompt = restorePrompt, prompt.id == id else { return false }
        restorePrompt = nil
        if session.isStartPage(id) { session.remove(id, closeWindow: false) }
        // Let removal/closing finish before presenting the next workspace or registering any AX windows.
        DispatchQueue.main.async { prompt.completion(candidates) }
        return true
    }

    private func ensureWindowAccess() -> Bool {
        guard !session.access.isTrusted() else { return true }
        session.access.requestPermission()
        showNotice(.attention(L("システム設定 → プライバシーとセキュリティ → アクセシビリティで WindowDock を許可し、もう一度追加してください。")))
        return false
    }

    @objc func showPicker() {
        guard !quitting, picker == nil, restorePrompt == nil, ensureWindowAccess() else { return }
        let scan = session.access.scan()
        let candidates = scan.windows.filter { candidate in
            !session.contains(candidate) && !(isRegisteredElsewhere?(candidate) ?? false)
        }
        var selected: [WindowCandidate]?
        picker = WindowPicker(candidates: candidates, failedApplications: scan.failedApplications) { selected = $0 }
        picker?.present(on: window) { [weak self] in
            self?.picker = nil
            // Add before checking emptiness, but only after the sheet has left the screen.
            if let selected { self?.session.add(selected) }
            self?.scheduleSelectedWindowRaise(activate: true)
            self?.scheduleEmptyWorkspaceDeletion()
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
        !tabIDs.isEmpty && picker == nil && window.attachedSheet == nil && !suspended && !window
            .isMiniaturized && !NSApp.isHidden
            && !quitting
    }

    var acceptsWindowDrag: Bool {
        restorePrompt == nil && picker == nil && !suspended && !quitting && window.isVisible
            && window.isOnActiveSpace && !window.isMiniaturized && !NSApp.isHidden
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

    func showWindowDropTarget(at point: NSPoint, application: NSRunningApplication?, title: String?) {
        guard acceptsWindowDrag else { return hideWindowDropTarget() }
        workspace.showWindowDropTarget(
            at: point, requiresPermission: !WindowAccess.isTrusted, application: application, title: title
        )
    }

    func hideWindowDropTarget() { workspace.hideWindowDropTarget() }

    func windowDropInsertionIndex(at point: NSPoint) -> Int { workspace.tabInsertionIndex(at: point) }

    func acceptsWindowDrop(at point: NSPoint) -> Bool {
        acceptsWindowDrag && workspace.acceptsWindowDrop(at: point)
    }

    func finishWindowDrag(_ drag: WorkspaceWindowDrag, accessibilityPoint: CGPoint, insertionIndex: Int) {
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
                    candidate, originalFrame: drag.originalFrame, at: insertionIndex
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
        guard managedWindowDrag == nil else { return }
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
        syncManagedWindows()
    }

    /// Leaves out the window the user is moving or resizing; setting its frame would fight the user or its app.
    private func syncManagedWindows() {
        if let id = managedWindowDrag?.id ?? settlingManagedWindowID {
            session.sync(excluding: id)
        } else {
            session.sync()
        }
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
        if returnsFullScreenWindows, session.leaveFullScreen() {
            refitAfterLeavingFullScreen(raiseWindows: true, activate: activate)
            return
        }
        session.refitDisplacedWindows()
        session.raiseSelected(activate: activate)
    }

    private var fullScreenExitTimer: Timer?

    private func refitAfterLeavingFullScreen(raiseWindows: Bool, activate: Bool = false) {
        let start = ProcessInfo.processInfo.systemUptime
        var lastRequest = start
        fullScreenExitTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, !self.suspended, !self.quitting, !self.window.isMiniaturized, self.picker == nil,
                      self.returnsFullScreenWindows,
                      raiseWindows || self.returnsDisplacedWindows
                else {
                    return timer.invalidate()
                }
                guard NSEvent.pressedMouseButtons == 0 else { return }
                guard !self.session.hasFullScreenWindow else {
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - start > 5 {
                        timer.invalidate()
                        WindowAccess.logger.error("Timed out waiting for a managed window to leave full screen")
                    } else if now - lastRequest >= 1 {
                        // A window still entering full screen ignores the request to leave it.
                        lastRequest = now
                        _ = self.session.leaveFullScreen()
                    }
                    return
                }
                timer.invalidate()
                self.fullScreenExitTimer = nil
                self.session.refitDisplacedWindows()
                guard raiseWindows, NSApp.isActive, self.window.isKeyWindow else { return }
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
