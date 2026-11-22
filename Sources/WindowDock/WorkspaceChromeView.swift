import AppKit
import QuartzCore
import WindowDockCore

enum WorkspaceNotice {
    case information(String)
    case attention(String)

    var text: String {
        switch self {
        case .information(let text), .attention(let text): return text
        }
    }

    var needsAttention: Bool {
        if case .attention = self { return true }
        return false
    }
}

enum WorkspaceSplitLayout {
    case sideBySide
    case stacked

    var primaryTitle: String { self == .sideBySide ? L("左") : L("上") }
    var secondaryTitle: String { self == .sideBySide ? L("右") : L("下") }
}

private final class WorkspaceEmptyLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class WorkspaceToolbarPanel: NSPanel {
    var onMouseDown: ((NSEvent) -> Void)?

    // The workspace window stays key so that its focus handoff and the menu bar commands target it.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { onMouseDown?(event) }
        super.sendEvent(event)
    }
}

private final class WorkspaceToolbarDragSpace: NSView {
    weak var chrome: WorkspaceChromeView?

    override func mouseDown(with event: NSEvent) {
        chrome?.trackFrameChangeFromToolbar(with: event)
    }
}

final class WorkspaceChromeView: WorkspaceBackgroundView, NSMenuDelegate {
    let tabs = NSStackView()
    let stage = WorkspaceGridView(frame: .zero)
    var gridSize: WorkspaceGridSize { stage.gridSize }
    var gridAreas: [NSView] { stage.areas }
    /// With a single pane, dropping a tab onto it cannot change the layout, so the whole workspace acts as the tab bar.
    private var hasSinglePane: Bool { gridAreas.count <= 1 }
    var onGridChange: ((WorkspaceGridSize) -> Void)?
    var onActivateCell: ((Int) -> Void)?
    var onPaneLayoutChange: (() -> Void)?
    var onMoveTab: ((Int, Int) -> Void)?
    var onReorderTabs: (([Int]) -> Void)?
    var onReleaseTabs: ((IndexSet) -> Void)?
    var onToolbarMenuTracking: ((Bool) -> Void)?
    var onAutoHiddenToolbarMouseDown: ((NSEvent) -> Void)?
    var onTabDragBegin: ((Int, String, NSButton) -> Void)?
    var onTabDragMove: ((String, NSPasteboard, NSButton, NSPoint) -> Void)?
    var onTabDragEnd: ((String, NSPasteboard, NSPoint, Bool) -> Void)?
    var acceptsExternalTab: ((String, NSButton?) -> Bool)?
    var onExternalTabDrop: ((String, NSButton?, Int?, Int?) -> Bool)?
    let addButton = makeButton(symbol: "plus", title: L("ウィンドウを追加"), width: 26)
    let permissionButton = makeButton(symbol: "gearshape", title: L("権限設定"), width: 26)
    let columnSelector = NSPopUpButton(frame: .zero, pullsDown: false)
    let rowSelector = NSPopUpButton(frame: .zero, pullsDown: false)
    let workspaceButton = NSButton(title: "", target: nil, action: nil)
    var workspaceMenu: (() -> NSMenu)?
    private var toolbar: NSStackView!
    private let toolbarHost = NSView()
    private var toolbarConstraints: [NSLayoutConstraint] = []
    private var toolbarOverlayConstraints: [NSLayoutConstraint] = []
    private var toolbarOverlayWidthConstraint: NSLayoutConstraint?
    private var toolbarPanel: WorkspaceToolbarPanel?
    private var toolbarPanelContent: NSVisualEffectView?
    private var stageTopConstraint: NSLayoutConstraint!
    private var expandedStageTopConstraint: NSLayoutConstraint!
    private(set) var autoHideTabBar = false
    private(set) var autoHiddenToolbarVisible = false
    private static let minimumWorkspaceNameWidth: CGFloat = 48
    private var hasManagedWindows = false
    private var settingGrid = false
    private weak var dragSource: NSButton?
    private var dragGroup: WorkspaceTabGroup?
    private var dragPlaceholder: NSView?
    private var dragToken: String?
    private var dragInitialOrder: [Int]?
    private var dragAnchorX: CGFloat = 0
    private var dragAnchorInGroup = NSPoint.zero
    private var dragPreviewImage: NSImage?
    private var isPaneTabDrag = false
    private var dragOverlays: [NSView] = []
    private(set) var windowDropPanel: NSPanel?
    private weak var windowDropLabel: NSTextField?
    private(set) var tabDragPreviewPanel: NSPanel?
    private weak var tabDragPreviewImageView: NSImageView?

    private let tabScroll = NSScrollView()
    private let notice = NSTextField(labelWithString: "")
    private let empty = WorkspaceEmptyLabel(wrappingLabelWithString: L("別のウィンドウをここへ移動して離す\nまたは、上の ＋ から追加\n\n異なるアプリをタブで切り替えられます。"))
    private var noticeHeight: NSLayoutConstraint!
    private var maximumTabWidth: NSLayoutConstraint!
    private var preferredTabWidth: NSLayoutConstraint!
    private var tabSizing: [(button: NSButton, constraint: NSLayoutConstraint)] = []
    private var updatingTabWidths = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    deinit {
        windowDropPanel?.close()
        tabDragPreviewPanel?.close()
        toolbarPanel?.close()
    }

    override func layout() {
        super.layout()
        updateTabWidths()
        toolbarOverlayWidthConstraint?.constant = toolbarHost.bounds.width
        updateToolbarPanelFrame()
    }

    var toolbarPanelWindowNumber: Int? { toolbarPanel?.windowNumber }
    var autoHiddenToolbarPanel: NSPanel? { toolbarPanel }
    private var toolbarScreenFrame: NSRect? {
        if autoHideTabBar, let toolbarPanel { return toolbarPanel.frame }
        guard let toolbarWindow = toolbar.window else { return nil }
        return toolbarWindow.convertToScreen(toolbar.convert(toolbar.bounds, to: nil))
    }

    /// Where the tab bar sits at the top of the workspace, whether it is embedded or auto-hidden.
    private var toolbarHostScreenFrame: NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(toolbarHost.convert(toolbarHost.bounds, to: nil))
    }

    var toolbarHoverFrame: NSRect {
        guard let window else { return .zero }
        let strip = NSRect(x: bounds.minX + 64, y: bounds.maxY - 4,
                           width: max(0, bounds.width - 64), height: 4)
        return window.convertToScreen(convert(strip, to: nil))
    }

    func setAutoHideTabBar(_ enabled: Bool) {
        guard enabled != autoHideTabBar else { return }
        if enabled {
            autoHideTabBar = true
            createToolbarPanelIfNeeded()
            NSLayoutConstraint.deactivate(toolbarConstraints)
            toolbar.removeFromSuperview()
            if let content = toolbarPanelContent {
                content.addSubview(toolbar)
                toolbarOverlayConstraints = [
                    toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: -64),
                    toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                    toolbar.topAnchor.constraint(equalTo: content.topAnchor),
                    toolbar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                    toolbar.widthAnchor.constraint(equalToConstant: toolbarHost.bounds.width)
                ]
                toolbarOverlayWidthConstraint = toolbarOverlayConstraints.last
                NSLayoutConstraint.activate(toolbarOverlayConstraints)
            }
            toolbarHost.isHidden = true
            if notice.isHidden {
                stageTopConstraint.isActive = false
                expandedStageTopConstraint.isActive = true
            } else {
                expandedStageTopConstraint.isActive = false
                stageTopConstraint.isActive = true
            }
            layoutSubtreeIfNeeded()
            updateToolbarPanelFrame()
        } else {
            hideAutoHiddenToolbar()
            NSLayoutConstraint.deactivate(toolbarOverlayConstraints)
            toolbar.removeFromSuperview()
            toolbarHost.addSubview(toolbar)
            NSLayoutConstraint.activate(toolbarConstraints)
            toolbarHost.isHidden = false
            stageTopConstraint.isActive = true
            expandedStageTopConstraint.isActive = false
            autoHideTabBar = false
            layoutSubtreeIfNeeded()
        }
    }

    func setAutoHiddenToolbarVisible(_ visible: Bool) {
        guard autoHideTabBar, autoHiddenToolbarVisible != visible else { return }
        autoHiddenToolbarVisible = visible
        updateToolbarPanelFrame()
        if visible {
            toolbarPanel?.orderFrontRegardless()
        } else {
            toolbarPanel?.orderOut(nil)
        }
    }

    func hideAutoHiddenToolbar() {
        setAutoHiddenToolbarVisible(false)
    }

    private func createToolbarPanelIfNeeded() {
        guard toolbarPanel == nil else { return }
        let panel = WorkspaceToolbarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.onMouseDown = { [weak self] event in self?.onAutoHiddenToolbarMouseDown?(event) }

        let content = NSVisualEffectView()
        content.material = .titlebar
        content.blendingMode = .withinWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 0
        panel.contentView = content
        toolbarPanel = panel
        toolbarPanelContent = content
    }

    func updateToolbarPanelFrame() {
        guard autoHideTabBar, let toolbarPanel, window != nil else { return }
        var frame = toolbarHostScreenFrame
        frame.origin.x += 64
        frame.size.width = max(0, frame.width - 64)
        toolbarPanel.setFrame(frame, display: false)
    }

    private func updateTabWidths() {
        guard !updatingTabWidths, dragSource == nil, !tabSizing.isEmpty else { return }
        updatingTabWidths = true
        defer { updatingTabWidths = false }

        let count = CGFloat(tabSizing.count)
        let spacing = CGFloat(max(0, tabSizing.count - 1)) * tabs.spacing
        let fixedGroupWidth: CGFloat = 34
        let nameWidth = min(ceil(workspaceButton.intrinsicContentSize.width), Self.minimumWorkspaceNameWidth)
        let fixedControlsWidth = toolbar.arrangedSubviews
            .filter { $0 !== tabScroll && $0 !== workspaceButton }
            .reduce(nameWidth) { $0 + $1.fittingSize.width }
        let toolbarGaps = CGFloat(toolbar.arrangedSubviews.count - 1) * toolbar.spacing
        let availableWidth = max(0, bounds.width - fixedControlsWidth - toolbarGaps
            - toolbar.edgeInsets.left - toolbar.edgeInsets.right)
        let fixedWidth = count * fixedGroupWidth + spacing
        let widths = WindowGeometry.tabWidths(
            preferredWidths: tabSizing.map { $0.button.intrinsicContentSize.width },
            available: max(0, availableWidth - fixedWidth)
        )
        let targetWidth = min(widths.reduce(0, +) + fixedWidth, availableWidth)
        if abs(maximumTabWidth.constant - targetWidth) > 0.5 {
            maximumTabWidth.constant = targetWidth
            preferredTabWidth.constant = targetWidth
        }
        for (sizing, width) in zip(tabSizing, widths) where abs(sizing.constraint.constant - width) > 0.5 {
            sizing.constraint.constant = width
        }
    }

    private static func makeButton(symbol: String, title: String, width: CGFloat) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            button.image = image
            button.imagePosition = .imageOnly
        }
        button.isBordered = false
        button.controlSize = .small
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = title
        button.setAccessibilityLabel(title)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width),
            button.heightAnchor.constraint(equalToConstant: 22)
        ])
        return button
    }

    @objc private func showWorkspaceMenu() {
        workspaceMenu?().popUp(positioning: nil, at: NSPoint(x: 0, y: workspaceButton.bounds.height), in: workspaceButton)
    }

    private func build() {
        registerForDraggedTypes([workspaceTabDragType])
        // Space for the native traffic-light buttons.
        let controls = NSView()
        controls.widthAnchor.constraint(equalToConstant: 64).isActive = true
        tabs.orientation = .horizontal
        tabs.spacing = 2
        tabs.alignment = .centerY
        tabScroll.documentView = tabs
        tabScroll.hasHorizontalScroller = true
        tabScroll.scrollerStyle = .overlay
        tabScroll.autohidesScrollers = true
        tabScroll.drawsBackground = false
        tabScroll.automaticallyAdjustsContentInsets = false
        tabScroll.isHidden = true
        tabs.translatesAutoresizingMaskIntoConstraints = false
        maximumTabWidth = tabScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 0)
        preferredTabWidth = tabScroll.widthAnchor.constraint(equalToConstant: 0)
        preferredTabWidth.priority = NSLayoutConstraint.Priority(749)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor),
            tabs.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor),
            tabs.heightAnchor.constraint(equalToConstant: 32),
            tabScroll.heightAnchor.constraint(equalToConstant: 32),
            tabScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            maximumTabWidth,
            preferredTabWidth
        ])
        let dragSpace = WorkspaceToolbarDragSpace()
        dragSpace.chrome = self
        dragSpace.widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        dragSpace.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let preferredDragWidth = dragSpace.widthAnchor.constraint(equalToConstant: 30)
        preferredDragWidth.priority = .defaultLow
        preferredDragWidth.isActive = true
        dragSpace.toolTip = L("ドラッグして移動 / ダブルクリックで最大化")
        configureSelector(columnSelector, prefix: L("横"))
        configureSelector(rowSelector, prefix: L("縦"))
        workspaceButton.isBordered = false
        workspaceButton.font = .boldSystemFont(ofSize: 12)
        workspaceButton.contentTintColor = .secondaryLabelColor
        workspaceButton.lineBreakMode = .byTruncatingTail
        workspaceButton.alignment = .left
        workspaceButton.toolTip = L("ワークスペースの操作")
        workspaceButton.target = self
        workspaceButton.action = #selector(showWorkspaceMenu)
        // Hug the name tightly and let tabs take its space first; keep a short prefix visible.
        workspaceButton.setContentHuggingPriority(NSLayoutConstraint.Priority(490), for: .horizontal)
        workspaceButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        workspaceButton.widthAnchor.constraint(lessThanOrEqualToConstant: 160).isActive = true
        let minimumName = workspaceButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWorkspaceNameWidth)
        minimumName.priority = NSLayoutConstraint.Priority(480)
        minimumName.isActive = true
        let bar = NSStackView(views: [controls, workspaceButton, tabScroll, addButton, dragSpace, columnSelector, rowSelector, permissionButton])
        toolbar = bar
        bar.spacing = 4
        bar.alignment = .centerY
        bar.distribution = .fill
        for view in bar.arrangedSubviews {
            bar.setVisibilityPriority(.mustHold, for: view)
        }
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        notice.font = .systemFont(ofSize: 11)
        notice.textColor = .labelColor
        notice.lineBreakMode = .byTruncatingTail
        notice.isHidden = true
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        stage.onActivate = { [weak self] index in self?.onActivateCell?(index) }
        stage.onGeometryChange = { [weak self] in
            guard let self else { return }
            self.needsDisplay = true
            self.updateTabDragOverlays()
            if !self.settingGrid { self.onPaneLayoutChange?() }
        }
        gridContentAreas = stage.areas
        empty.alignment = .center
        empty.font = .systemFont(ofSize: 14)
        empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(empty)
        for view in [toolbarHost, notice, stage] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        bar.translatesAutoresizingMaskIntoConstraints = false
        toolbarHost.addSubview(bar)
        toolbarConstraints = [
            bar.leadingAnchor.constraint(equalTo: toolbarHost.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: toolbarHost.trailingAnchor),
            bar.topAnchor.constraint(equalTo: toolbarHost.topAnchor),
            bar.bottomAnchor.constraint(equalTo: toolbarHost.bottomAnchor)
        ]
        noticeHeight = notice.heightAnchor.constraint(equalToConstant: 0)
        stageTopConstraint = stage.topAnchor.constraint(equalTo: notice.bottomAnchor)
        expandedStageTopConstraint = stage.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            toolbarHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarHost.topAnchor.constraint(equalTo: topAnchor),
            toolbarHost.heightAnchor.constraint(equalToConstant: 34),
            notice.topAnchor.constraint(equalTo: toolbarHost.bottomAnchor, constant: 1),
            notice.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            notice.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            noticeHeight,
            stageTopConstraint,
            stage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            stage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            stage.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            empty.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: stage.widthAnchor, constant: -24)
        ])
        NSLayoutConstraint.activate(toolbarConstraints)
        showNotice(.information(L("⌃ Tab / ⌃ ⇧ Tab で切替 · タブの × で元に戻す")))
    }

    private func configureSelector(_ selector: NSPopUpButton, prefix: String) {
        selector.addItems(withTitles: (1...4).map { "\(prefix)\($0)" })
        selector.controlSize = .small
        selector.font = .systemFont(ofSize: 11)
        selector.toolTip = L("%@の分割数", prefix.trimmingCharacters(in: .whitespaces))
        selector.target = self
        selector.action = #selector(gridSelectorChanged(_:))
        selector.widthAnchor.constraint(equalToConstant: 55).isActive = true
        selector.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    @objc private func gridSelectorChanged(_ sender: NSPopUpButton) {
        let requested = WorkspaceGridSize(columns: columnSelector.indexOfSelectedItem + 1, rows: rowSelector.indexOfSelectedItem + 1)
        columnSelector.selectItem(at: gridSize.columns - 1)
        rowSelector.selectItem(at: gridSize.rows - 1)
        if requested != gridSize { onGridChange?(requested) }
    }

    func setGrid(_ size: WorkspaceGridSize, activeCell: Int) {
        guard size.isValid else { return }
        let changed = size != gridSize
        if changed {
            endTabDrag()
            gridCoveredScreenRects = [:]
            settingGrid = true
            stage.setGrid(size, activeCell: activeCell)
            gridContentAreas = stage.areas
            settingGrid = false
        } else {
            stage.setGrid(size, activeCell: activeCell)
        }
        columnSelector.selectItem(at: size.columns - 1)
        rowSelector.selectItem(at: size.rows - 1)
        refreshCoverage()
        if changed { onPaneLayoutChange?() }
    }

    func setActiveCell(_ index: Int) { stage.setActiveCell(index) }

    @discardableResult
    func fitPanesToMinimumSizes(_ sizes: [Int: CGSize]) -> Bool {
        layoutSubtreeIfNeeded()
        return stage.fitMinimumSizes(sizes)
    }

    func presentFrames(_ frames: [Int: CGRect]) {
        gridCoveredScreenRects = frames.filter { $0.key >= 0 && $0.key < gridAreas.count }
        refreshCoverage()
    }

    func acceptsWindowDrop(at screenPoint: NSPoint) -> Bool {
        guard let window else { return false }
        if autoHideTabBar {
            return (toolbarScreenFrame ?? toolbarHostScreenFrame).contains(screenPoint)
        }
        let point = convert(window.convertFromScreen(NSRect(origin: screenPoint, size: .zero)).origin, from: nil)
        return convert(toolbar.bounds, from: toolbar).contains(point) ||
            (!hasManagedWindows && convert(stage.bounds, from: stage).contains(point))
    }

    func showWindowDropTarget(at screenPoint: NSPoint, requiresPermission: Bool) {
        guard acceptsWindowDrop(at: screenPoint), window != nil else { return hideWindowDropTarget() }
        let frame = toolbarScreenFrame ?? toolbarHostScreenFrame
        let message = requiresPermission
            ? L("追加にはアクセシビリティの許可が必要です")
            : L("ここで離すとタブに追加")
        showDropFeedback(frame: frame,
                         color: (requiresPermission ? NSColor.systemOrange : .controlAccentColor).withAlphaComponent(0.96),
                         message: message)
        addButton.contentTintColor = .controlAccentColor
    }

    func hideWindowDropTarget() {
        windowDropPanel?.orderOut(nil)
        addButton.contentTintColor = nil
    }

    func showExternalTabTargets() {
        guard dragSource == nil, dragOverlays.isEmpty, !hasSinglePane else { return }
        dragOverlays = gridAreas.enumerated().map { index, area in
            let overlay = WorkspaceTabDropOverlay(chrome: self, cellIndex: index, frame: area.bounds)
            area.addSubview(overlay)
            return overlay
        }
    }

    func hideExternalTabTargets() {
        hideIncomingTabMarker()
        guard dragSource == nil else { return }
        dragOverlays.forEach { $0.removeFromSuperview() }
        dragOverlays.removeAll()
    }

    func tabInsertionIndex(at screenPoint: NSPoint) -> Int {
        layoutSubtreeIfNeeded()
        guard let toolbarWindow = toolbar.window else { return tabs.arrangedSubviews.count }
        let point = tabs.convert(toolbarWindow.convertPoint(fromScreen: screenPoint), from: nil)
        return WindowGeometry.tabInsertionIndex(
            at: point.x, tabFrames: tabs.arrangedSubviews.map(\.frame),
            visibleMinX: tabs.visibleRect.minX, visibleMaxX: tabs.visibleRect.maxX
        )
    }

    func tabRowContains(_ screenPoint: NSPoint) -> Bool {
        guard let toolbarWindow = toolbar.window,
              autoHideTabBar ? autoHiddenToolbarVisible : true,
              toolbarWindow.frame.contains(screenPoint) else { return false }
        let point = tabScroll.convert(toolbarWindow.convertPoint(fromScreen: screenPoint), from: nil)
        return point.y >= tabScroll.bounds.minY && point.y <= tabScroll.bounds.maxY
    }

    @discardableResult
    func completeTabDrop(pasteboard: NSPasteboard, source: NSButton?, screenPoint: NSPoint) -> Bool {
        guard let window else { return false }
        if !hasSinglePane, !tabRowContains(screenPoint), let cell = gridAreas.firstIndex(where: {
            window.convertToScreen($0.convert($0.bounds, to: nil)).contains(screenPoint)
        }) {
            return performTabDrop(pasteboard: pasteboard, source: source, cell: cell)
        }
        return performTabReorder(pasteboard: pasteboard, source: source, screenPoint: screenPoint)
    }

    private func showIncomingTabMarker(at screenPoint: NSPoint) {
        guard let window else { return }
        guard hasSinglePane || toolbarScreenFrame?.contains(screenPoint) == true ||
                !window.frame.contains(screenPoint) else {
            hideIncomingTabMarker()
            return
        }
        showInsertionMarker(at: screenPoint, color: .controlAccentColor)
    }

    private func showInsertionMarker(at screenPoint: NSPoint, color: NSColor) {
        guard let toolbarWindow = toolbar.window else { return }
        let barRect = toolbar.bounds
        let stripRect = tabs.arrangedSubviews.isEmpty
            ? toolbar.bounds
            : toolbar.convert(tabScroll.contentView.bounds, from: tabScroll.contentView)
        let x = WindowGeometry.tabInsertionLineX(
            index: tabInsertionIndex(at: screenPoint),
            tabFrames: tabs.arrangedSubviews.map { toolbar.convert($0.frame, from: tabs) },
            emptyX: toolbar.convert(workspaceButton.bounds, from: workspaceButton).maxX + 6,
            visibleMinX: stripRect.minX, visibleMaxX: stripRect.maxX, lineWidth: 3
        )
        let markerRect = NSRect(x: x, y: barRect.midY - 14, width: 3, height: 28)
        let frame = toolbarWindow.convertToScreen(toolbar.convert(markerRect, to: nil))
        showDropFeedback(frame: frame, color: color)
        addButton.contentTintColor = nil
    }

    private func showDropFeedback(frame: NSRect, color: NSColor, message: String? = nil) {
        if windowDropPanel == nil {
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.title = L("ウィンドウを追加")
            panel.level = .floating
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isExcludedFromWindowsMenu = true
            panel.collectionBehavior = [.transient, .ignoresCycle]
            panel.isOpaque = false
            panel.hasShadow = false
            windowDropPanel = panel
        }
        windowDropPanel?.backgroundColor = color
        windowDropPanel?.setFrame(frame, display: false)
        if let message {
            if windowDropLabel == nil {
                let label = NSTextField(labelWithString: "")
                label.font = .systemFont(ofSize: 13, weight: .semibold)
                label.textColor = .white
                label.alignment = .center
                label.lineBreakMode = .byTruncatingTail
                windowDropPanel?.contentView?.addSubview(label)
                windowDropLabel = label
            }
            windowDropLabel?.frame = NSRect(origin: .zero, size: frame.size).insetBy(dx: 8, dy: 6)
            windowDropLabel?.stringValue = message
            windowDropLabel?.isHidden = false
        } else {
            windowDropLabel?.isHidden = true
        }
        windowDropPanel?.contentView?.displayIfNeeded()
        windowDropPanel?.displayIfNeeded()
        windowDropPanel?.orderFront(nil)
    }

    private func hideIncomingTabMarker() {
        hideWindowDropTarget()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsTabDrag(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton),
              let destination = sender.draggingDestinationWindow else { return [] }
        let point = destination.convertPoint(toScreen: sender.draggingLocation)
        _ = updateFloatingTab(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton,
                              screenPoint: point)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hideIncomingTabMarker() }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptsTabDrag(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let destination = sender.draggingDestinationWindow else { return false }
        let point = destination.convertPoint(toScreen: sender.draggingLocation)
        if !hasSinglePane, let cell = gridAreas.firstIndex(where: {
            destination.convertToScreen($0.convert($0.bounds, to: nil)).contains(point)
        }) {
            return performTabDrop(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton, cell: cell)
        }
        return performTabReorder(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton,
                                 screenPoint: point)
    }

    func beginTabDrag(source: NSButton, token: String, anchor: NSPoint? = nil, previewImage: NSImage? = nil) {
        endTabDrag()
        guard let group = source.superview as? WorkspaceTabGroup,
              let index = tabs.arrangedSubviews.firstIndex(of: group) else { return }
        let frame = group.frame
        dragSource = source
        dragToken = token
        dragInitialOrder = orderedTabTags()
        let sourceAnchor = anchor ?? NSPoint(x: source.bounds.midX, y: source.bounds.midY)
        dragAnchorX = tabs.convert(sourceAnchor, from: source).x - frame.minX
        dragAnchorInGroup = source.convert(sourceAnchor, to: group)
        dragPreviewImage = previewImage ?? makeTabDragPreview(for: group)
        let placeholder = NSView(frame: frame)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholder.widthAnchor.constraint(equalToConstant: frame.width),
            placeholder.heightAnchor.constraint(equalToConstant: frame.height)
        ])
        tabs.removeArrangedSubview(group)
        tabs.insertArrangedSubview(placeholder, at: index)
        tabs.addSubview(group, positioned: .above, relativeTo: nil)
        group.translatesAutoresizingMaskIntoConstraints = true
        group.isFloating = true
        group.frame = frame
        group.layer?.shadowOpacity = 0.25
        group.layer?.shadowRadius = 8
        isPaneTabDrag = false
        dragGroup = group
        dragPlaceholder = placeholder
        dragOverlays = hasSinglePane ? [] : gridAreas.enumerated().map { index, area in
            let overlay = WorkspaceTabDropOverlay(chrome: self, cellIndex: index, frame: area.bounds)
            area.addSubview(overlay)
            return overlay
        }
        layoutSubtreeIfNeeded()
        updateTabDragOverlays()
        // A tab of an inactive workspace can be dragged with the first click, before WindowDock is active.
        window?.orderFrontRegardless()
        window?.displayIfNeeded()
        CATransaction.flush()
        onTabDragBegin?(source.tag, token, source)
    }

    private func updateTabDragOverlays() {
        for (area, overlay) in zip(gridAreas, dragOverlays) {
            overlay.frame = area.bounds
        }
    }

    func endTabDrag(at destination: Int? = nil) {
        if let group = dragGroup, let placeholder = dragPlaceholder {
            let originalIndex = dragInitialOrder?.firstIndex(of: dragSource?.tag ?? -1)
                ?? tabs.arrangedSubviews.firstIndex(of: placeholder)
                ?? tabs.arrangedSubviews.count - 1
            let index = max(0, min(destination ?? originalIndex, tabs.arrangedSubviews.count - 1))
            tabs.removeArrangedSubview(placeholder)
            placeholder.removeFromSuperview()
            group.translatesAutoresizingMaskIntoConstraints = false
            group.isFloating = false
            group.layer?.shadowOpacity = 0
            group.layer?.shadowRadius = 0
            group.alphaValue = 1
            tabs.insertArrangedSubview(group, at: index)
        } else if let group = dragGroup {
            group.isFloating = false
            group.layer?.shadowOpacity = 0
            group.layer?.shadowRadius = 0
            group.alphaValue = 1
        }
        dragSource = nil
        dragGroup = nil
        dragPlaceholder = nil
        dragToken = nil
        dragInitialOrder = nil
        dragAnchorX = 0
        dragAnchorInGroup = .zero
        dragPreviewImage = nil
        isPaneTabDrag = false
        tabDragPreviewPanel?.orderOut(nil)
        dragOverlays.forEach { $0.removeFromSuperview() }
        dragOverlays.removeAll()
        needsLayout = true
        refreshCoverage()
    }

    private func orderedTabTags() -> [Int] {
        tabs.arrangedSubviews.compactMap { group in
            if group === dragPlaceholder { return dragSource?.tag }
            return (group as? NSStackView)?.arrangedSubviews.compactMap { $0 as? WorkspaceTabButton }.first?.tag
        }
    }

    private func finishTabDrag(commit: Bool = false) {
        guard dragSource != nil else { return }
        let order = orderedTabTags()
        let changed = commit && order != dragInitialOrder
        let destination = changed ? order.firstIndex(of: dragSource?.tag ?? -1) : nil
        endTabDrag(at: destination)
        if changed { onReorderTabs?(order) }
    }

    func acceptsTabDrag(pasteboard: NSPasteboard, source: NSButton?) -> Bool {
        guard let token = pasteboard.string(forType: workspaceTabDragType) else { return false }
        if let dragSource, let source, source === dragSource { return token == dragToken }
        return acceptsExternalTab?(token, source) == true
    }

    @discardableResult
    func updateFloatingTab(pasteboard: NSPasteboard, source: NSButton?, screenPoint: NSPoint) -> Bool {
        if let token = pasteboard.string(forType: workspaceTabDragType),
           acceptsExternalTab?(token, source) == true {
            (source as? WorkspaceTabButton)?.chrome?.showDetachedTab(at: screenPoint)
            showIncomingTabMarker(at: screenPoint)
            return true
        }
        guard acceptsTabDrag(pasteboard: pasteboard, source: source),
              let window, let dragGroup else { return false }
        let pointInWindow = window.convertPoint(fromScreen: screenPoint)
        if tabRowContains(screenPoint) || (hasSinglePane && window.frame.contains(screenPoint)) {
            enterTabReorderMode()
        } else {
            enterPaneTabDragMode()
            showTabDragPreview(at: screenPoint)
            return true
        }
        tabDragPreviewPanel?.orderOut(nil)
        let pointInTabs = tabs.convert(pointInWindow, from: nil)
        var frame = dragGroup.frame
        frame.origin.x = pointInTabs.x - dragAnchorX
        dragGroup.frame = frame
        guard let placeholder = dragPlaceholder,
              var index = tabs.arrangedSubviews.firstIndex(of: placeholder) else { return true }
        let center = frame.midX
        while index + 1 < tabs.arrangedSubviews.count,
              center > tabs.arrangedSubviews[index + 1].frame.midX {
            index += 1
            moveDragPlaceholder(placeholder, to: index)
        }
        while index > 0,
              center < tabs.arrangedSubviews[index - 1].frame.midX {
            index -= 1
            moveDragPlaceholder(placeholder, to: index)
        }
        return true
    }

    private func makeTabDragPreview(for group: NSView) -> NSImage {
        let image = NSImage(size: group.bounds.size)
        if let bitmap = group.bitmapImageRepForCachingDisplay(in: group.bounds) {
            group.cacheDisplay(in: group.bounds, to: bitmap)
            image.addRepresentation(bitmap)
        }
        return image
    }

    private func showDetachedTab(at screenPoint: NSPoint) {
        enterPaneTabDragMode()
        showTabDragPreview(at: screenPoint)
    }

    private func showTabDragPreview(at screenPoint: NSPoint) {
        guard let image = dragPreviewImage else { return }
        if tabDragPreviewPanel == nil {
            let frame = NSRect(origin: .zero, size: image.size)
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = .floating
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isExcludedFromWindowsMenu = true
            panel.collectionBehavior = [.transient, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            let imageView = NSImageView(frame: frame)
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.autoresizingMask = [.width, .height]
            panel.contentView?.addSubview(imageView)
            tabDragPreviewPanel = panel
            tabDragPreviewImageView = imageView
        }
        tabDragPreviewImageView?.image = image
        tabDragPreviewImageView?.frame = NSRect(origin: .zero, size: image.size)
        tabDragPreviewPanel?.setContentSize(image.size)
        tabDragPreviewPanel?.setFrameOrigin(NSPoint(
            x: screenPoint.x - dragAnchorInGroup.x,
            y: screenPoint.y - dragAnchorInGroup.y
        ))
        tabDragPreviewPanel?.orderFront(nil)
    }

    private func enterPaneTabDragMode() {
        guard !isPaneTabDrag, let group = dragGroup, let placeholder = dragPlaceholder else { return }
        let index = dragInitialOrder?.firstIndex(of: dragSource?.tag ?? -1)
            ?? tabs.arrangedSubviews.firstIndex(of: placeholder)
            ?? tabs.arrangedSubviews.count - 1
        tabs.removeArrangedSubview(placeholder)
        placeholder.removeFromSuperview()
        group.translatesAutoresizingMaskIntoConstraints = false
        group.isFloating = false
        group.layer?.shadowOpacity = 0
        group.layer?.shadowRadius = 0
        group.alphaValue = 0.4
        tabs.insertArrangedSubview(group, at: max(0, min(index, tabs.arrangedSubviews.count)))
        dragPlaceholder = nil
        isPaneTabDrag = true
    }

    private func enterTabReorderMode() {
        guard isPaneTabDrag, let group = dragGroup,
              let index = tabs.arrangedSubviews.firstIndex(of: group) else { return }
        let frame = group.frame
        let placeholder = NSView(frame: frame)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholder.widthAnchor.constraint(equalToConstant: frame.width),
            placeholder.heightAnchor.constraint(equalToConstant: frame.height)
        ])
        tabs.removeArrangedSubview(group)
        tabs.insertArrangedSubview(placeholder, at: index)
        tabs.addSubview(group, positioned: .above, relativeTo: nil)
        group.translatesAutoresizingMaskIntoConstraints = true
        group.isFloating = true
        group.alphaValue = 1
        group.layer?.shadowOpacity = 0.25
        group.layer?.shadowRadius = 8
        group.frame = frame
        dragPlaceholder = placeholder
        isPaneTabDrag = false
    }

    private func moveDragPlaceholder(_ placeholder: NSView, to index: Int) {
        tabs.removeArrangedSubview(placeholder)
        tabs.insertArrangedSubview(placeholder, at: index)
        tabs.layoutSubtreeIfNeeded()
    }

    @discardableResult
    func performTabReorder(pasteboard: NSPasteboard, source: NSButton?, screenPoint: NSPoint) -> Bool {
        if let token = pasteboard.string(forType: workspaceTabDragType),
           acceptsExternalTab?(token, source) == true {
            let index = tabInsertionIndex(at: screenPoint)
            hideIncomingTabMarker()
            return onExternalTabDrop?(token, source, index, nil) == true
        }
        guard acceptsTabDrag(pasteboard: pasteboard, source: source),
              let dragSource else { return false }
        _ = updateFloatingTab(pasteboard: pasteboard, source: source, screenPoint: screenPoint)
        let order = orderedTabTags()
        let changed = order != dragInitialOrder
        let insertionIndex = order.firstIndex(of: dragSource.tag)
        endTabDrag(at: insertionIndex)
        if changed { onReorderTabs?(order) }
        return true
    }

    @discardableResult
    func performTabDrop(pasteboard: NSPasteboard, source: NSButton?, cell: Int) -> Bool {
        if let token = pasteboard.string(forType: workspaceTabDragType),
           acceptsExternalTab?(token, source) == true, gridAreas.indices.contains(cell) {
            hideIncomingTabMarker()
            return onExternalTabDrop?(token, source, nil, cell) == true
        }
        guard acceptsTabDrag(pasteboard: pasteboard, source: source),
              gridAreas.indices.contains(cell), let dragSource else { return false }
        let tag = dragSource.tag
        let order = orderedTabTags()
        let changed = order != dragInitialOrder
        let destination = changed ? order.firstIndex(of: tag) : nil
        endTabDrag(at: destination)
        onMoveTab?(tag, cell)
        if changed { onReorderTabs?(order) }
        return true
    }

    private func tabContextMenu(for button: NSButton) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let move = NSMenuItem(title: L("配置を入れ替え"), action: nil, keyEquivalent: "")
        let destinations = NSMenu()
        for index in 0..<gridSize.cellCount {
            let row = index / gridSize.columns + 1
            let column = index % gridSize.columns + 1
            let item = NSMenuItem(title: L("%d行 %d列", row, column), action: #selector(moveTabFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = WorkspaceTabMoveItem(button)
            destinations.addItem(item)
        }
        move.submenu = destinations
        menu.addItem(move)
        menu.addItem(.separator())
        let count = tabs.arrangedSubviews.count
        let own = IndexSet(integer: button.tag)
        let all = IndexSet(integersIn: 0..<count)
        let releases: [(String, IndexSet)] = [
            ("タブを解除", all.intersection(own)),
            ("他のタブをすべて解除", all.subtracting(own)),
            ("右側のタブを解除", IndexSet(integersIn: min(button.tag + 1, count)..<count)),
            ("左側のタブを解除", IndexSet(integersIn: 0..<min(button.tag, count))),
            ("すべてのタブを解除", all)
        ]
        for (title, indexes) in releases {
            let item = NSMenuItem(title: L(title), action: indexes.isEmpty ? nil : #selector(releaseTabsFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = indexes
            menu.addItem(item)
        }
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        onToolbarMenuTracking?(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        onToolbarMenuTracking?(false)
    }

    @objc private func releaseTabsFromMenu(_ item: NSMenuItem) {
        guard let indexes = item.representedObject as? IndexSet else { return }
        onReleaseTabs?(indexes)
    }

    @objc private func moveTabFromMenu(_ item: NSMenuItem) {
        guard let button = (item.representedObject as? WorkspaceTabMoveItem)?.button,
              gridAreas.indices.contains(item.tag) else { return }
        onMoveTab?(button.tag, item.tag)
    }

    func clearTabs() {
        endTabDrag()
        NSLayoutConstraint.deactivate(tabSizing.map(\.constraint))
        tabSizing.removeAll()
        for view in tabs.arrangedSubviews {
            tabs.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        maximumTabWidth.constant = 0
        preferredTabWidth.constant = 0
        tabScroll.isHidden = true
        tabScroll.contentView.scroll(to: .zero)
    }

    @discardableResult
    func appendTab(title: String, toolTip: String? = nil, icon: NSImage? = nil, selected: Bool, displayed: Bool = false) -> (view: NSView, select: NSButton, close: NSButton) {
        let select = WorkspaceTabButton(title: title, target: nil, action: nil)
        select.chrome = self
        select.onDragBegin = { [weak self] button, token, anchor, image in
            self?.beginTabDrag(source: button, token: token, anchor: anchor, previewImage: image)
            button.onDragEnd = { [weak self] board, point, cancelled in
                self?.onTabDragEnd?(token, board, point, cancelled)
                self?.finishTabDrag(commit: false)
            }
        }
        select.onDragMove = { [weak self, weak select] board, point in
            guard let self, let select, let token = self.dragToken else { return }
            _ = self.updateFloatingTab(pasteboard: board, source: select, screenPoint: point)
            self.onTabDragMove?(token, board, select, point)
        }
        select.registerForDraggedTypes([workspaceTabDragType])
        select.acceptsTabDrop = { [weak self] pasteboard, source in
            self?.acceptsTabDrag(pasteboard: pasteboard, source: source) == true
        }
        select.updateTabDrop = { [weak self] pasteboard, source, point in
            self?.updateFloatingTab(pasteboard: pasteboard, source: source, screenPoint: point) == true
        }
        select.performTabDrop = { [weak self] pasteboard, source, point in
            guard let self else { return false }
            return self.performTabReorder(pasteboard: pasteboard, source: source, screenPoint: point)
        }
        select.makeContextMenu = { [weak self, weak select] in
            guard let self, let select else { return NSMenu() }
            return self.tabContextMenu(for: select)
        }
        if let icon {
            let small = icon.copy() as! NSImage
            small.size = NSSize(width: 16, height: 16)
            select.image = small
            select.imagePosition = .imageLeading
            select.imageHugsTitle = true
        }
        select.isBordered = false
        select.font = .systemFont(ofSize: 12, weight: selected ? .semibold : .regular)
        select.lineBreakMode = .byTruncatingTail
        select.toolTip = toolTip ?? title
        select.setAccessibilityValue(selected ? L("操作対象") : (displayed ? L("分割表示中") : L("未選択")))
        let close = Self.makeButton(symbol: "xmark", title: L("元の位置に戻してタブから解除"), width: 18)
        let group = WorkspaceTabGroup(views: [select, close])
        group.acceptsTabDrop = { [weak self] pasteboard, source in
            self?.acceptsTabDrag(pasteboard: pasteboard, source: source) == true
        }
        group.updateTabDrop = { [weak self] pasteboard, source, point in
            guard let self else { return false }
            return self.updateFloatingTab(pasteboard: pasteboard, source: source, screenPoint: point)
        }
        group.performTabDrop = { [weak self] pasteboard, source, point in
            guard let self else { return false }
            return self.performTabReorder(pasteboard: pasteboard, source: source, screenPoint: point)
        }
        group.spacing = 4
        group.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 4)
        group.wantsLayer = true
        group.layer?.cornerRadius = 7
        group.layer?.borderWidth = displayed ? 1 : 0
        group.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        group.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        group.layer?.backgroundColor = (selected ? NSColor.controlBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.35)).cgColor
        let selectWidth = select.widthAnchor.constraint(equalToConstant: 200)
        tabSizing.append((select, selectWidth))
        NSLayoutConstraint.activate([
            select.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
            select.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            selectWidth,
            select.heightAnchor.constraint(equalToConstant: 28),
            group.heightAnchor.constraint(equalToConstant: 32)
        ])
        tabs.addArrangedSubview(group)
        let count = CGFloat(tabSizing.count)
        let naturalWidth = count * 234 + CGFloat(max(0, tabSizing.count - 1)) * tabs.spacing
        maximumTabWidth.constant = naturalWidth
        preferredTabWidth.constant = naturalWidth
        tabScroll.isHidden = false
        updateTabWidths()
        needsLayout = true
        return (group, select, close)
    }

    func revealTab(_ view: NSView) {
        layoutSubtreeIfNeeded()
        tabs.scrollToVisible(view.frame)
    }

    func showManagedWindows(_ hasWindows: Bool) {
        hasManagedWindows = hasWindows
        empty.isHidden = hasWindows
        revealsWindow = hasWindows
        stage.layer?.backgroundColor = (hasWindows ? NSColor.clear : NSColor.controlBackgroundColor).cgColor
    }

    @discardableResult
    func showNotice(_ message: WorkspaceNotice) -> Bool {
        let height: CGFloat = message.needsAttention ? 22 : 0
        let changed = noticeHeight.constant != height
        notice.stringValue = message.text
        notice.toolTip = message.text
        notice.isHidden = !message.needsAttention
        if changed {
            noticeHeight.constant = height
            needsLayout = true
        }
        permissionButton.toolTip = L("権限設定\n%@", message.text)
        permissionButton.contentTintColor = message.needsAttention ? .systemOrange : .secondaryLabelColor
        if autoHideTabBar {
            if message.needsAttention {
                expandedStageTopConstraint.isActive = false
                stageTopConstraint.isActive = true
                setAutoHiddenToolbarVisible(true)
            } else {
                stageTopConstraint.isActive = false
                expandedStageTopConstraint.isActive = true
            }
        }
        return changed
    }
}
