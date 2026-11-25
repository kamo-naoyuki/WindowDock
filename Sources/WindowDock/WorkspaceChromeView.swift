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

enum TabBarPosition: String, Codable, CaseIterable {
    case top, bottom, left, right

    var isVertical: Bool { self == .left || self == .right }

    var title: String {
        switch self {
        case .top: return L("上")
        case .bottom: return L("下")
        case .left: return L("左")
        case .right: return L("右")
        }
    }
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

struct TabReleaseRequest: Equatable {
    let ids: [UUID]
    let closeWindows: Bool
}

struct WorkspaceTabItem {
    let id: UUID
    var title: String
    var toolTip: String?
    var icon: NSImage?
    var selected: Bool
    var displayed = false
    var pinned = false
    var tabSwitchTarget = false
}

final class WorkspaceChromeView: WorkspaceBackgroundView, NSMenuDelegate {
    let tabs = WorkspaceTabStrip()
    var wrapsCrowdedTabs = false {
        didSet {
            if wrapsCrowdedTabs != oldValue {
                endTabDrag()
                endCloseSizing()
                updateTabWidths()
                needsLayout = true
            }
        }
    }
    let stage = WorkspaceGridView(frame: .zero)
    var gridSize: WorkspaceGridSize { stage.gridSize }
    var gridAreas: [NSView] { stage.areas }
    /// With a single pane, dropping a tab onto it cannot change the layout, so the whole workspace acts as the tab bar.
    private var hasSinglePane: Bool { gridAreas.count <= 1 }
    var onGridChange: ((WorkspaceGridSize) -> Void)?
    var splitRestriction: ((Int, PaneLayout.Axis) -> PaneSplitRestriction?)?
    var onSplitPane: ((Int, PaneLayout.Axis) -> Void)?
    var onClosePane: ((Int) -> Void)?
    var isPanePinned: ((Int) -> Bool)?
    var onTogglePanePin: ((Int) -> Void)?
    var paneForTab: ((Int) -> Int?)?
    var onActivateCell: ((Int) -> Void)?
    var onPaneLayoutChange: (() -> Void)?
    var onMoveTab: ((Int, Int) -> Void)?
    var onReorderTabs: (([Int]) -> Void)?
    var closesWindowsOnRelease = false
    var onReleaseTabs: ((TabReleaseRequest) -> Void)?
    var onToolbarMenuTracking: ((Bool) -> Void)?
    var onAutoHiddenToolbarMouseDown: ((NSEvent) -> Void)?
    var onTabDragBegin: ((Int, String, NSButton) -> Void)?
    var onTabDragMove: ((String, NSPasteboard, NSButton, NSPoint) -> Void)?
    var onTabDragEnd: ((String, NSPasteboard, NSPoint, Bool) -> Void)?
    var acceptsExternalTab: ((String, NSButton?) -> Bool)?
    var onExternalTabDrop: ((String, NSButton?, Int?, Int?) -> Bool)?
    let addButton = makeButton(symbol: "plus", title: L("新しいタブ"), width: 26)
    let permissionButton = makeButton(symbol: "gearshape", title: L("権限設定"), width: 26)
    let columnSelector = NSPopUpButton(frame: .zero, pullsDown: false)
    let rowSelector = NSPopUpButton(frame: .zero, pullsDown: false)
    let workspaceButton = NSButton(title: "", target: nil, action: nil)
    var workspaceMenu: (() -> NSMenu)?
    private var toolbar: NSStackView!
    private let titlebarControls = NSView()
    private let toolbarHost = NSView()
    private var toolbarConstraints: [NSLayoutConstraint] = []
    private var toolbarOverlayConstraints: [NSLayoutConstraint] = []
    private var placementConstraints: [NSLayoutConstraint] = []
    private var horizontalTabConstraints: [NSLayoutConstraint] = []
    private var verticalTabConstraints: [NSLayoutConstraint] = []
    private var preferredVerticalTabHeight: NSLayoutConstraint!
    private lazy var horizontalStripHeight = tabs.heightAnchor.constraint(equalToConstant: 32)
    private lazy var horizontalViewportHeight = tabScroll.heightAnchor.constraint(equalToConstant: 32)
    private lazy var horizontalHostHeight = toolbarHost.heightAnchor.constraint(equalToConstant: 34)
    private var toolbarPanel: WorkspaceToolbarPanel?
    private var toolbarPanelContent: NSVisualEffectView?
    private(set) var autoHideTabBar = false
    private(set) var autoHiddenToolbarVisible = false
    private(set) var tabBarPosition: TabBarPosition = .top
    private static let minimumWorkspaceNameWidth: CGFloat = 48
    private var hasManagedWindows = false
    private var settingGrid = false
    private weak var dragSource: NSButton?
    private var dragGroup: WorkspaceTabGroup?
    private var dragPlaceholder: NSView?
    private var dragToken: String?
    private var dragInitialOrder: [Int]?
    private var dragAnchorX: CGFloat = 0
    private var dragAnchorY: CGFloat = 0
    private var dragAnchorInGroup = NSPoint.zero
    private var dragPreviewImage: NSImage?
    private var isPaneTabDrag = false
    private var paneDropOverlay: WorkspaceTabDropOverlay?
    private(set) var windowDropPanel: NSPanel?
    private weak var windowDropLabel: NSTextField?
    private weak var windowDropPreviewImage: NSImageView?
    private(set) var windowDropPreview: NSView?
    private var windowDropPreviewWidth: NSLayoutConstraint?
    private(set) var tabDragPreviewPanel: NSPanel?
    private weak var tabDragPreviewImageView: NSImageView?

    private let tabScroll = NSScrollView()
    private let clippedTabDivider = NSBox()
    private let notice = NSTextField(labelWithString: "")
    var currentNoticeText: String? { notice.isHidden ? nil : notice.stringValue }
    private let empty = WorkspaceEmptyLabel(
        wrappingLabelWithString: L("別のウィンドウをここへ移動して離す\nまたは、上の ＋ から追加\n\n異なるアプリをタブで切り替えられます。"))
    private var noticeHeight: NSLayoutConstraint!
    private var maximumTabWidth: NSLayoutConstraint!
    private var preferredTabWidth: NSLayoutConstraint!
    struct Tab {
        let id: UUID
        let view: WorkspaceTabGroup
        let select: WorkspaceTabButton
        let close: NSButton
        fileprivate let pin: NSImageView
        fileprivate let constraint: NSLayoutConstraint
    }

    private var tabSizing: [Tab] = []
    private var updatingTabWidths = false
    private var pointerInToolbar = false
    private var toolbarTracking: NSTrackingArea?
    private var closeSizing: (documentWidth: NSLayoutConstraint, windowSize: NSSize)?

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
        if let closeSizing, closeSizing.windowSize != bounds.size { endCloseSizing() }
        updateTabWidths()
        updateClippedTabDivider()
        updateToolbarPanelFrame()
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === toolbarTracking { pointerInToolbar = true } else { super.mouseEntered(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === toolbarTracking {
            pointerInToolbar = false
            endCloseSizing()
        } else {
            super.mouseExited(with: event)
        }
    }

    private func endCloseSizing() {
        guard let closeSizing else { return }
        closeSizing.documentWidth.isActive = false
        self.closeSizing = nil
        updateTabWidths()
        needsLayout = true
    }

    @objc private func updateClippedTabDivider() {
        let visible = tabScroll.documentVisibleRect
        clippedTabDivider.isHidden = tabBarPosition.isVertical || tabScroll.isHidden || visible.isEmpty
            || visible.minX <= tabs.bounds.minX + 0.5
    }

    var toolbarPanelWindowNumber: Int? { toolbarPanel?.windowNumber }
    var autoHiddenToolbarPanel: NSPanel? { toolbarPanel }
    private var toolbarScreenFrame: NSRect? {
        if autoHideTabBar, let toolbarPanel { return toolbarPanel.frame }
        guard let toolbarWindow = toolbar.window else { return nil }
        return toolbarWindow.convertToScreen(toolbar.convert(toolbar.bounds, to: nil))
    }

    /// Where the tab bar sits, whether it is embedded or auto-hidden.
    private var toolbarHostScreenFrame: NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(toolbarHost.convert(toolbarHost.bounds, to: nil))
    }

    var toolbarHoverFrame: NSRect {
        guard let window else { return .zero }
        let host = toolbarHost.frame
        let strip: NSRect
        switch tabBarPosition {
        case .top:
            strip = NSRect(x: host.minX + 64, y: bounds.maxY - 4, width: max(0, host.width - 64), height: 4)
        case .bottom:
            strip = NSRect(x: host.minX, y: bounds.minY, width: host.width, height: 4)
        case .left:
            strip = NSRect(x: bounds.minX, y: host.minY, width: 4, height: host.height)
        case .right:
            strip = NSRect(x: bounds.maxX - 4, y: host.minY, width: 4, height: host.height)
        }
        return window.convertToScreen(convert(strip, to: nil))
    }

    func setTabBarPosition(_ position: TabBarPosition) {
        guard tabBarPosition != position else { return }
        endCloseSizing()
        endTabDrag()
        hideWindowDropTarget()
        tabBarPosition = position
        titlebarControls.isHidden = position != .top
        NSLayoutConstraint.deactivate(position.isVertical ? horizontalTabConstraints : verticalTabConstraints)
        tabs.orientation = position.isVertical ? .vertical : .horizontal
        toolbar.orientation = position.isVertical ? .vertical : .horizontal
        toolbar.alignment = position.isVertical ? .centerX : .centerY
        tabScroll.hasHorizontalScroller = !position.isVertical
        tabScroll.hasVerticalScroller = position.isVertical
        NSLayoutConstraint.activate(position.isVertical ? verticalTabConstraints : horizontalTabConstraints)
        if autoHideTabBar { configureToolbarOverlay() }
        configurePlacement()
        updateTabWidths()
        needsLayout = true
        layoutSubtreeIfNeeded()
        updateToolbarPanelFrame()
    }

    func setWorkspaceName(_ name: String) {
        workspaceButton.title = name
        workspaceButton.toolTip = name
    }

    func setAutoHideTabBar(_ enabled: Bool) {
        guard enabled != autoHideTabBar else { return }
        endCloseSizing()
        pointerInToolbar = false
        if enabled {
            autoHideTabBar = true
            createToolbarPanelIfNeeded()
            NSLayoutConstraint.deactivate(toolbarConstraints)
            toolbar.removeFromSuperview()
            toolbarPanelContent?.addSubview(toolbar)
            configureToolbarOverlay()
            toolbarHost.isHidden = true
            configurePlacement()
            layoutSubtreeIfNeeded()
            updateToolbarPanelFrame()
        } else {
            hideAutoHiddenToolbar()
            NSLayoutConstraint.deactivate(toolbarOverlayConstraints)
            toolbar.removeFromSuperview()
            toolbarHost.addSubview(toolbar)
            NSLayoutConstraint.activate(toolbarConstraints)
            toolbarHost.isHidden = false
            autoHideTabBar = false
            configurePlacement()
            layoutSubtreeIfNeeded()
        }
    }

    private func configureToolbarOverlay() {
        guard let content = toolbarPanelContent else { return }
        NSLayoutConstraint.deactivate(toolbarOverlayConstraints)
        toolbarOverlayConstraints = [
            toolbar.leadingAnchor.constraint(
                equalTo: content.leadingAnchor,
                constant: tabBarPosition == .top ? -64 : 0),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ]
        NSLayoutConstraint.activate(toolbarOverlayConstraints)
    }

    func setAutoHiddenToolbarVisible(_ visible: Bool) {
        guard autoHideTabBar, autoHiddenToolbarVisible != visible else { return }
        autoHiddenToolbarVisible = visible
        updateToolbarPanelFrame()
        if visible {
            toolbarPanel?.orderFrontRegardless()
        } else {
            endCloseSizing()
            pointerInToolbar = false
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
            defer: false)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.allowsToolTipsWhenApplicationIsInactive = true
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
        if tabBarPosition == .top {
            frame.origin.x += 64
            frame.size.width = max(0, frame.width - 64)
        }
        toolbarPanel.setFrame(frame, display: false)
    }

    private func updateTabWidths() {
        guard !updatingTabWidths, dragSource == nil, closeSizing == nil, toolbar != nil else { return }
        updatingTabWidths = true
        defer { updatingTabWidths = false }

        let widths = tabSizing.map(\.constraint) + (windowDropPreviewWidth.map { [$0] } ?? [])
        if tabBarPosition.isVertical {
            setSecondRow(nil)
            for width in widths where width.constant != 146 { width.constant = 146 }
            let naturalHeight = CGFloat(widths.count) * 32 + CGFloat(max(0, widths.count - 1)) * tabs.spacing
            let controls = toolbar.arrangedSubviews.filter { $0 !== tabScroll && !$0.isHidden }
            let fixedHeight = controls.reduce(CGFloat(0)) { $0 + $1.fittingSize.height }
                + CGFloat(controls.count) * toolbar.spacing + toolbar.edgeInsets.top + toolbar.edgeInsets.bottom
            preferredVerticalTabHeight.constant = min(naturalHeight, max(0, bounds.height - 37 - fixedHeight))
            return
        }
        let fixedGroupWidth: CGFloat = 34
        let nameWidth = min(ceil(workspaceButton.intrinsicContentSize.width), Self.minimumWorkspaceNameWidth)
        let fixedControlsWidth = toolbar.arrangedSubviews
            .filter { $0 !== tabScroll && $0 !== workspaceButton }
            .reduce(nameWidth) { $0 + $1.fittingSize.width }
        let toolbarGaps = CGFloat(toolbar.arrangedSubviews.count - 1) * toolbar.spacing
        let availableWidth = max(
            0,
            bounds.width - fixedControlsWidth - toolbarGaps
                - toolbar.edgeInsets.left - toolbar.edgeInsets.right)
        let layout = WindowGeometry.horizontalTabRows(count: widths.count, available: availableWidth,
                                                      chrome: fixedGroupWidth, spacing: tabs.spacing,
                                                      wrap: wrapsCrowdedTabs)
        setSecondRow(layout.secondRow)
        let targetWidth = layout.viewport
        if abs(maximumTabWidth.constant - targetWidth) > 0.5 {
            maximumTabWidth.constant = targetWidth
            preferredTabWidth.constant = targetWidth
        }
        for width in widths where abs(width.constant - layout.contentWidth) > 0.01 {
            width.constant = layout.contentWidth
        }
    }

    private func setSecondRow(_ split: Int?) {
        guard tabs.secondRow != split else { return }
        tabs.secondRow = split
        let height = split == nil ? 32 : 64 + tabs.spacing
        horizontalStripHeight.constant = height
        horizontalViewportHeight.constant = height
        horizontalHostHeight.constant = height + 2
    }

    private static func makeButton(_ button: NSButton = NSButton(), symbol: String, title: String,
                                   width: CGFloat) -> NSButton {
        button.title = title
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
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
        return button
    }

    @objc private func showWorkspaceMenu() {
        workspaceMenu?().popUp(
            positioning: nil, at: NSPoint(x: 0, y: workspaceButton.bounds.height), in: workspaceButton)
    }

    private func build() {
        registerForDraggedTypes([workspaceTabDragType])
        // Space for the native traffic-light buttons.
        titlebarControls.widthAnchor.constraint(equalToConstant: 64).isActive = true
        tabs.orientation = .horizontal
        tabScroll.documentView = tabs
        tabScroll.hasHorizontalScroller = true
        tabScroll.scrollerStyle = .overlay
        tabScroll.autohidesScrollers = true
        tabScroll.drawsBackground = false
        tabScroll.automaticallyAdjustsContentInsets = false
        tabScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        tabScroll.isHidden = true
        tabs.translatesAutoresizingMaskIntoConstraints = false
        maximumTabWidth = tabScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 0)
        preferredTabWidth = tabScroll.widthAnchor.constraint(equalToConstant: 0)
        preferredTabWidth.priority = NSLayoutConstraint.Priority(749)
        horizontalTabConstraints = [
            tabs.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor),
            tabs.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor),
            horizontalStripHeight,
            horizontalViewportHeight,
            tabScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            maximumTabWidth,
            preferredTabWidth,
        ]
        preferredVerticalTabHeight = tabScroll.heightAnchor.constraint(equalToConstant: 0)
        preferredVerticalTabHeight.priority = NSLayoutConstraint.Priority(749)
        verticalTabConstraints = [
            tabs.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor),
            tabs.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor),
            tabs.widthAnchor.constraint(equalTo: tabScroll.contentView.widthAnchor),
            tabScroll.widthAnchor.constraint(equalToConstant: 180),
            tabScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            preferredVerticalTabHeight,
        ]
        NSLayoutConstraint.activate(horizontalTabConstraints)
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
        let minimumName = workspaceButton.widthAnchor.constraint(
            greaterThanOrEqualToConstant: Self.minimumWorkspaceNameWidth)
        minimumName.priority = NSLayoutConstraint.Priority(480)
        minimumName.isActive = true
        let bar = NSStackView(views: [
            titlebarControls, workspaceButton, tabScroll, addButton, dragSpace, columnSelector, rowSelector,
            permissionButton,
        ])
        toolbar = bar
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        toolbarTracking = tracking
        bar.addTrackingArea(tracking)
        bar.wantsLayer = true
        bar.spacing = 4
        bar.alignment = .centerY
        bar.distribution = .fill
        for view in bar.arrangedSubviews {
            bar.setVisibilityPriority(.mustHold, for: view)
        }
        clippedTabDivider.boxType = .separator
        clippedTabDivider.isHidden = true
        clippedTabDivider.setAccessibilityElement(false)
        clippedTabDivider.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(clippedTabDivider, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            clippedTabDivider.leadingAnchor.constraint(equalTo: workspaceButton.trailingAnchor, constant: 1),
            clippedTabDivider.centerYAnchor.constraint(equalTo: workspaceButton.centerYAnchor),
            clippedTabDivider.widthAnchor.constraint(equalToConstant: 1),
            clippedTabDivider.heightAnchor.constraint(equalToConstant: 20),
        ])
        tabScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateClippedTabDivider),
                                               name: NSView.boundsDidChangeNotification, object: tabScroll.contentView)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        notice.font = .systemFont(ofSize: 11)
        notice.textColor = .labelColor
        notice.lineBreakMode = .byTruncatingTail
        notice.isHidden = true
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        stage.onActivate = { [weak self] index in self?.onActivateCell?(index) }
        stage.menuForPane = { [weak self] index in self?.paneMenu(for: index) }
        stage.onGeometryChange = { [weak self] in
            guard let self else { return }
            self.needsDisplay = true
            if let overlay = self.paneDropOverlay, let area = overlay.superview {
                overlay.frame = area.bounds
            }
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
            bar.bottomAnchor.constraint(equalTo: toolbarHost.bottomAnchor),
        ]
        noticeHeight = notice.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            notice.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            notice.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            noticeHeight,
            empty.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: stage.widthAnchor, constant: -24),
        ])
        NSLayoutConstraint.activate(toolbarConstraints)
        configurePlacement()
        showNotice(.information(L("⌃ Tab / ⌃ ⇧ Tab でタブを切替")))
    }

    private func configurePlacement() {
        NSLayoutConstraint.deactivate(placementConstraints)
        let host: [NSLayoutConstraint]
        switch tabBarPosition {
        case .top:
            host = [
                toolbarHost.leadingAnchor.constraint(equalTo: leadingAnchor),
                toolbarHost.trailingAnchor.constraint(equalTo: trailingAnchor),
                toolbarHost.topAnchor.constraint(equalTo: topAnchor),
                horizontalHostHeight,
            ]
        case .bottom:
            host = [
                toolbarHost.leadingAnchor.constraint(equalTo: leadingAnchor),
                toolbarHost.trailingAnchor.constraint(equalTo: trailingAnchor),
                toolbarHost.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
                horizontalHostHeight,
            ]
        case .left, .right:
            host = [
                tabBarPosition == .left
                    ? toolbarHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3)
                    : toolbarHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
                toolbarHost.topAnchor.constraint(equalTo: topAnchor, constant: 34),
                toolbarHost.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
                toolbarHost.widthAnchor.constraint(equalToConstant: 190),
            ]
        }
        let noticeTop: NSLayoutConstraint
        if tabBarPosition == .top, !autoHideTabBar || !notice.isHidden {
            noticeTop = notice.topAnchor.constraint(equalTo: toolbarHost.bottomAnchor, constant: 1)
        } else {
            noticeTop = notice.topAnchor.constraint(equalTo: topAnchor, constant: tabBarPosition == .top ? 0 : 34)
        }
        placementConstraints = host + [
            noticeTop,
            stage.topAnchor.constraint(equalTo: notice.bottomAnchor),
            tabBarPosition == .left && !autoHideTabBar
                ? stage.leadingAnchor.constraint(equalTo: toolbarHost.trailingAnchor, constant: 3)
                : stage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            tabBarPosition == .right && !autoHideTabBar
                ? stage.trailingAnchor.constraint(equalTo: toolbarHost.leadingAnchor, constant: -3)
                : stage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            tabBarPosition == .bottom && !autoHideTabBar
                ? stage.bottomAnchor.constraint(equalTo: toolbarHost.topAnchor, constant: -3)
                : stage.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ]
        NSLayoutConstraint.activate(placementConstraints)
    }

    private func configureSelector(_ selector: NSPopUpButton, prefix: String) {
        selector.addItems(withTitles: (1 ... 4).map { "\(prefix)\($0)" })
        selector.addItem(withTitle: L("カスタム"))
        selector.lastItem?.isEnabled = false
        selector.menu?.autoenablesItems = false
        selector.controlSize = .small
        selector.font = .systemFont(ofSize: 11)
        selector.toolTip = L("%@の分割数", prefix.trimmingCharacters(in: .whitespaces))
        selector.target = self
        selector.action = #selector(gridSelectorChanged(_:))
        selector.widthAnchor.constraint(equalToConstant: 55).isActive = true
        selector.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    @objc private func gridSelectorChanged(_ sender: NSPopUpButton) {
        let columns = columnSelector.indexOfSelectedItem
        let rows = rowSelector.indexOfSelectedItem
        let requested = WorkspaceGridSize(
            columns: columns < 4 ? columns + 1 : gridSize.columns,
            rows: rows < 4 ? rows + 1 : gridSize.rows)
        columnSelector.selectItem(at: stage.customLayout == nil ? gridSize.columns - 1 : 4)
        rowSelector.selectItem(at: stage.customLayout == nil ? gridSize.rows - 1 : 4)
        if requested != gridSize || stage.customLayout != nil { onGridChange?(requested) }
    }

    func setGrid(_ size: WorkspaceGridSize, activeCell: Int) {
        guard size.isValid else { return }
        let changed = size != gridSize || stage.customLayout != nil
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

    func setCustomLayout(_ layout: PaneLayout, activeCell: Int) {
        let changed = stage.customLayout == nil || layout.paneCount != gridAreas.count
        if changed {
            endTabDrag()
            gridCoveredScreenRects = [:]
        }
        settingGrid = true
        stage.setCustomLayout(layout, activeCell: activeCell)
        gridContentAreas = stage.areas
        settingGrid = false
        columnSelector.selectItem(at: 4)
        rowSelector.selectItem(at: 4)
        refreshCoverage()
        if changed { onPaneLayoutChange?() }
    }

    func paneMenu(for index: Int) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let pin = menu.addItem(
            withTitle: L("ペインを固定"),
            action: gridAreas.count > 1 ? #selector(togglePanePin(_:)) : nil,
            keyEquivalent: "")
        pin.target = self
        pin.tag = index
        pin.state = isPanePinned?(index) == true ? .on : .off
        pin.isEnabled = gridAreas.count > 1
        menu.addItem(.separator())
        func add(_ title: String, _ action: Selector?) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = action != nil
        }
        func addSplit(_ title: String, _ axis: PaneLayout.Axis, _ action: Selector) {
            let restriction: PaneSplitRestriction?
            if let splitRestriction {
                restriction = splitRestriction(index, axis)
            } else {
                restriction = stage.paneLayout.canSplitPane(at: index, axis: axis) ? nil : .layout
            }
            if case .minimumSize(let apps) = restriction {
                add(L("%@（%@のウィンドウが収まりません）", title, apps), nil)
            } else {
                add(title, restriction == nil ? action : nil)
            }
        }
        addSplit(L("左右に分割"), .horizontal, #selector(splitPaneHorizontally(_:)))
        addSplit(L("上下に分割"), .vertical, #selector(splitPaneVertically(_:)))
        add(L("ペインを閉じる"), gridAreas.count > 1 ? #selector(closePane(_:)) : nil)
        return menu
    }

    @objc private func splitPaneHorizontally(_ item: NSMenuItem) { onSplitPane?(item.tag, .horizontal) }
    @objc private func splitPaneVertically(_ item: NSMenuItem) { onSplitPane?(item.tag, .vertical) }
    @objc private func closePane(_ item: NSMenuItem) { onClosePane?(item.tag) }
    @objc private func togglePanePin(_ item: NSMenuItem) { onTogglePanePin?(item.tag) }

    func setActiveCell(_ index: Int) { stage.setActiveCell(index) }
    func setPaneIndicators(switchTargetCell: Int?, pinnedCells: Set<Int>) {
        stage.setPaneIndicators(switchTargetCell: switchTargetCell, pinnedCells: pinnedCells)
    }

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
        return convert(toolbar.bounds, from: toolbar).contains(point)
            || (!hasManagedWindows && convert(stage.bounds, from: stage).contains(point))
    }

    func showWindowDropTarget(
        at screenPoint: NSPoint, requiresPermission: Bool, application: NSRunningApplication? = nil,
        title: String? = nil) {
        guard acceptsWindowDrop(at: screenPoint), window != nil else { return hideWindowDropTarget() }
        if requiresPermission {
            removeWindowDropPreview()
            showDropFeedback(
                frame: toolbarScreenFrame ?? toolbarHostScreenFrame,
                color: NSColor.systemOrange.withAlphaComponent(0.96),
                message: L("追加にはアクセシビリティの許可が必要です"))
            addButton.contentTintColor = .controlAccentColor
            return
        }
        addButton.contentTintColor = nil
        let index = tabInsertionIndex(at: screenPoint)
        if windowDropPreview == nil {
            endCloseSizing()
            let label = title.flatMap { $0.isEmpty ? nil : $0 } ?? application?.localizedName ?? L("ウィンドウを追加")
            let button = NSButton(title: label, target: nil, action: nil)
            button.alignment = .left
            button.isBordered = false
            button.font = .systemFont(ofSize: 12)
            button.lineBreakMode = .byTruncatingTail
            if let icon = application?.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                button.image = icon
                button.imagePosition = .imageLeading
                button.imageHugsTitle = true
            }
            let close = Self.makeButton(symbol: "xmark", title: L("ウィンドウを追加"), width: 18)
            let preview = WorkspaceTabGroup(views: [button, close])
            preview.isFloating = true
            preview.spacing = 4
            preview.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 4)
            preview.wantsLayer = true
            preview.layer?.cornerRadius = 7
            preview.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            preview.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            preview.alphaValue = 0.55
            let width = button.widthAnchor.constraint(equalToConstant: 100)
            NSLayoutConstraint.activate([
                width,
                button.heightAnchor.constraint(equalToConstant: 28),
                preview.heightAnchor.constraint(equalToConstant: 32),
            ])
            windowDropPreview = preview
            windowDropPreviewWidth = width
            tabs.insertArrangedSubview(preview, at: index)
            tabScroll.isHidden = false
            updateTabWidths()
            layoutSubtreeIfNeeded()
        } else if let preview = windowDropPreview, tabs.arrangedSubviews.firstIndex(of: preview) != index {
            tabs.removeArrangedSubview(preview)
            tabs.insertArrangedSubview(preview, at: index)
            tabs.layoutSubtreeIfNeeded()
        }
        showWindowDragToolbarImage()
    }

    func hideWindowDropTarget() {
        windowDropPanel?.orderOut(nil)
        removeWindowDropPreview()
        addButton.contentTintColor = nil
    }

    private func removeWindowDropPreview() {
        guard let preview = windowDropPreview else { return }
        tabs.removeArrangedSubview(preview)
        preview.removeFromSuperview()
        windowDropPreview = nil
        windowDropPreviewWidth = nil
        if tabSizing.isEmpty {
            maximumTabWidth.constant = 0
            preferredTabWidth.constant = 0
            tabScroll.isHidden = true
        } else {
            updateTabWidths()
        }
        needsLayout = true
    }

    private func showWindowDragToolbarImage() {
        guard let toolbarWindow = toolbar.window else { return }
        layoutSubtreeIfNeeded()
        let frame = toolbarWindow.convertToScreen(toolbar.convert(toolbar.bounds, to: nil))
        var visible = toolbarHostScreenFrame
        if tabBarPosition == .top {
            visible.origin.x += 64
            visible.size.width = max(0, visible.width - 64)
        }
        let clipped = frame.intersection(visible)
        guard !clipped.isEmpty, !clipped.isNull else {
            windowDropPanel?.orderOut(nil)
            return
        }
        guard let bitmap = toolbar.bitmapImageRepForCachingDisplay(in: toolbar.bounds) else {
            WindowAccess.logger.error("Could not render the window drop toolbar")
            windowDropPanel?.orderOut(nil)
            return
        }
        toolbar.cacheDisplay(in: toolbar.bounds, to: bitmap)
        let image = NSImage(size: toolbar.bounds.size)
        image.addRepresentation(bitmap)
        showDropFeedback(frame: clipped, color: NSColor.windowBackgroundColor.withAlphaComponent(0.96))
        if windowDropPreviewImage == nil {
            let imageView = NSImageView()
            imageView.imageScaling = .scaleNone
            windowDropPanel?.contentView?.addSubview(imageView)
            windowDropPreviewImage = imageView
        }
        windowDropPreviewImage?.image = image
        windowDropPreviewImage?.frame = NSRect(
            x: frame.minX - clipped.minX, y: frame.minY - clipped.minY,
            width: frame.width, height: frame.height)
        windowDropPreviewImage?.isHidden = false
        windowDropPanel?.displayIfNeeded()
    }

    private func paneDropIndex(at screenPoint: NSPoint) -> Int? {
        guard !hasSinglePane, !tabRowContains(screenPoint), let window else { return nil }
        let point = stage.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return gridAreas.firstIndex { $0.frame.contains(point) }
    }

    private func highlightPane(_ index: Int?) {
        guard paneDropOverlay?.cellIndex != index else { return }
        paneDropOverlay?.removeFromSuperview()
        paneDropOverlay = nil
        if let index {
            let area = gridAreas[index]
            let overlay = WorkspaceTabDropOverlay(chrome: self, cellIndex: index, frame: area.bounds)
            area.addSubview(overlay)
            paneDropOverlay = overlay
            // The managed window may be above the backdrop. Its siblings still show through their apertures.
            window?.orderFrontRegardless()
        }
        refreshCoverage()
    }

    func dismissPaneDropOverlay(_ overlay: WorkspaceTabDropOverlay) {
        if paneDropOverlay === overlay { highlightPane(nil) }
    }

    func hideExternalTabTargets() {
        hideIncomingTabMarker()
        if dragSource == nil { highlightPane(nil) }
    }

    func tabInsertionIndex(at screenPoint: NSPoint) -> Int {
        layoutSubtreeIfNeeded()
        let realTabs = tabs.arrangedSubviews.filter { $0 !== windowDropPreview }
        guard let toolbarWindow = toolbar.window else { return realTabs.count }
        let point = tabs.convert(toolbarWindow.convertPoint(fromScreen: screenPoint), from: nil)
        if tabBarPosition.isVertical {
            return WindowGeometry.tabInsertionIndex(
                at: -point.y,
                tabFrames: realTabs.map { NSRect(x: -$0.frame.maxY, y: 0, width: $0.frame.height, height: 0) },
                visibleMinX: -tabs.visibleRect.maxY, visibleMaxX: -tabs.visibleRect.minY)
        }
        let row = tabs.row(at: point.y)
        let preceding = tabs.arrangedSubviews.prefix(row.startIndex).filter { $0 !== windowDropPreview }.count
        return preceding + WindowGeometry.tabInsertionIndex(
            at: point.x, tabFrames: row.filter { $0 !== windowDropPreview }.map(\.frame),
            visibleMinX: tabs.visibleRect.minX, visibleMaxX: tabs.visibleRect.maxX)
    }

    func tabRowContains(_ screenPoint: NSPoint) -> Bool {
        guard let toolbarWindow = toolbar.window,
              autoHideTabBar ? autoHiddenToolbarVisible : true,
              toolbarWindow.frame.contains(screenPoint)
        else { return false }
        let point = tabScroll.convert(toolbarWindow.convertPoint(fromScreen: screenPoint), from: nil)
        if tabBarPosition.isVertical {
            return point.x >= tabScroll.bounds.minX && point.x <= tabScroll.bounds.maxX
        }
        return point.y >= tabScroll.bounds.minY && point.y <= tabScroll.bounds.maxY
    }

    @discardableResult
    func completeTabDrop(pasteboard: NSPasteboard, source: NSButton?, screenPoint: NSPoint) -> Bool {
        guard window != nil else { return false }
        if let cell = paneDropIndex(at: screenPoint) {
            return performTabDrop(pasteboard: pasteboard, source: source, cell: cell)
        }
        return performTabReorder(pasteboard: pasteboard, source: source, screenPoint: screenPoint)
    }

    private func showIncomingTabMarker(at screenPoint: NSPoint) {
        guard let window else { return }
        removeWindowDropPreview()
        guard hasSinglePane || toolbarScreenFrame?.contains(screenPoint) == true || !window.frame.contains(screenPoint)
        else {
            hideIncomingTabMarker()
            return
        }
        showInsertionMarker(at: screenPoint, color: .controlAccentColor)
    }

    private func showInsertionMarker(at screenPoint: NSPoint, color: NSColor) {
        guard let toolbarWindow = toolbar.window else { return }
        let index = tabInsertionIndex(at: screenPoint)
        let barRect = toolbar.bounds
        let stripRect =
            tabs.arrangedSubviews.isEmpty
                ? toolbar.bounds
                : toolbar.convert(tabScroll.contentView.bounds, from: tabScroll.contentView)
        if tabBarPosition.isVertical {
            let frames = tabs.arrangedSubviews.map { toolbar.convert($0.frame, from: tabs) }
            let y = WindowGeometry.tabInsertionLineX(
                index: index,
                tabFrames: frames.map { NSRect(x: -$0.maxY, y: 0, width: $0.height, height: 0) },
                emptyX: -toolbar.convert(workspaceButton.bounds, from: workspaceButton).minY + 6,
                visibleMinX: -stripRect.maxY, visibleMaxX: -stripRect.minY, lineWidth: 3)
            let marker = NSRect(x: stripRect.minX, y: -y - 3, width: stripRect.width, height: 3)
            showDropFeedback(frame: toolbarWindow.convertToScreen(toolbar.convert(marker, to: nil)), color: color)
            addButton.contentTintColor = nil
            return
        }
        let point = tabs.convert(toolbarWindow.convertPoint(fromScreen: screenPoint), from: nil)
        let row = tabs.row(at: point.y)
        let frames = row.map { toolbar.convert($0.frame, from: tabs) }
        let x = WindowGeometry.tabInsertionLineX(
            index: index - row.startIndex, tabFrames: frames,
            emptyX: toolbar.convert(workspaceButton.bounds, from: workspaceButton).maxX + 6,
            visibleMinX: stripRect.minX, visibleMaxX: stripRect.maxX, lineWidth: 3)
        let markerRect = NSRect(x: x, y: (frames.first?.midY ?? barRect.midY) - 14, width: 3, height: 28)
        let frame = toolbarWindow.convertToScreen(toolbar.convert(markerRect, to: nil))
        showDropFeedback(frame: frame, color: color)
        addButton.contentTintColor = nil
    }

    private func showDropFeedback(frame: NSRect, color: NSColor, message: String? = nil) {
        if windowDropPanel == nil {
            let panel = NSPanel(
                contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
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
        windowDropPreviewImage?.isHidden = true
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
        windowDropPanel?.orderFrontRegardless()
    }

    private func hideIncomingTabMarker() {
        hideWindowDropTarget()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsTabDrag(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton),
              let destination = sender.draggingDestinationWindow
        else { return [] }
        let point = destination.convertPoint(toScreen: sender.draggingLocation)
        _ = updateFloatingTab(
            pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton,
            screenPoint: point)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideIncomingTabMarker()
        highlightPane(nil)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptsTabDrag(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let destination = sender.draggingDestinationWindow else { return false }
        let point = destination.convertPoint(toScreen: sender.draggingLocation)
        return completeTabDrop(
            pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton,
            screenPoint: point)
    }

    func beginTabDrag(source: NSButton, token: String, anchor: NSPoint? = nil, previewImage: NSImage? = nil) {
        endCloseSizing()
        endTabDrag()
        guard let group = source.superview as? WorkspaceTabGroup,
              let index = tabs.arrangedSubviews.firstIndex(of: group)
        else { return }
        let frame = group.frame
        dragSource = source
        dragToken = token
        dragInitialOrder = orderedTabTags()
        let sourceAnchor = anchor ?? NSPoint(x: source.bounds.midX, y: source.bounds.midY)
        dragAnchorX = tabs.convert(sourceAnchor, from: source).x - frame.minX
        dragAnchorY = tabs.convert(sourceAnchor, from: source).y - frame.minY
        dragAnchorInGroup = source.convert(sourceAnchor, to: group)
        dragPreviewImage = previewImage ?? makeTabDragPreview(for: group)
        let placeholder = NSView(frame: frame)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholder.widthAnchor.constraint(equalToConstant: frame.width),
            placeholder.heightAnchor.constraint(equalToConstant: frame.height),
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
        layoutSubtreeIfNeeded()
        // A tab of an inactive workspace can be dragged with the first click, before WindowDock is active.
        window?.orderFrontRegardless()
        window?.displayIfNeeded()
        CATransaction.flush()
        onTabDragBegin?(source.tag, token, source)
    }

    func endTabDrag(at destination: Int? = nil) {
        if let group = dragGroup, let placeholder = dragPlaceholder {
            let originalIndex =
                dragInitialOrder?.firstIndex(of: dragSource?.tag ?? -1)
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
        dragAnchorY = 0
        dragAnchorInGroup = .zero
        dragPreviewImage = nil
        isPaneTabDrag = false
        tabDragPreviewPanel?.orderOut(nil)
        highlightPane(nil)
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
           acceptsExternalTab?(token, source) == true
        {
            (source as? WorkspaceTabButton)?.chrome?.showDetachedTab(at: screenPoint)
            highlightPane(paneDropIndex(at: screenPoint))
            showIncomingTabMarker(at: screenPoint)
            return true
        }
        guard acceptsTabDrag(pasteboard: pasteboard, source: source),
              window != nil, let dragGroup
        else { return false }
        highlightPane(paneDropIndex(at: screenPoint))
        if tabRowContains(screenPoint) {
            enterTabReorderMode()
        } else {
            enterPaneTabDragMode()
            showTabDragPreview(at: screenPoint)
            return true
        }
        tabDragPreviewPanel?.orderOut(nil)
        guard let toolbarWindow = tabs.window else { return false }
        let pointInTabs = tabs.convert(toolbarWindow.convertPoint(fromScreen: screenPoint), from: nil)
        var frame = dragGroup.frame
        if tabBarPosition.isVertical {
            frame.origin.y = pointInTabs.y - dragAnchorY
        } else {
            frame.origin.x = pointInTabs.x - dragAnchorX
            if tabs.secondRow != nil { frame.origin.y = pointInTabs.y - dragAnchorY }
        }
        dragGroup.frame = frame
        guard let placeholder = dragPlaceholder,
              var index = tabs.arrangedSubviews.firstIndex(of: placeholder)
        else { return true }
        if tabs.secondRow != nil {
            let row = tabs.row(at: pointInTabs.y)
            if let slot = row.indices
                .min(by: { abs(row[$0].frame.midX - frame.midX) < abs(row[$1].frame.midX - frame.midX) }),
                slot != index {
                moveDragPlaceholder(placeholder, to: slot)
            }
            return true
        }
        func coordinate(_ frame: NSRect) -> CGFloat {
            tabBarPosition.isVertical ? -frame.midY : frame.midX
        }
        let center = coordinate(frame)
        while index + 1 < tabs.arrangedSubviews.count,
              center > coordinate(tabs.arrangedSubviews[index + 1].frame)
        {
            index += 1
            moveDragPlaceholder(placeholder, to: index)
        }
        while index > 0,
              center < coordinate(tabs.arrangedSubviews[index - 1].frame)
        {
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
        highlightPane(nil)
        enterPaneTabDragMode()
        showTabDragPreview(at: screenPoint)
    }

    private func showTabDragPreview(at screenPoint: NSPoint) {
        guard let image = dragPreviewImage else { return }
        if tabDragPreviewPanel == nil {
            let frame = NSRect(origin: .zero, size: image.size)
            let panel = NSPanel(
                contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
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
        tabDragPreviewPanel?.setFrameOrigin(
            NSPoint(
                x: screenPoint.x - dragAnchorInGroup.x,
                y: screenPoint.y - dragAnchorInGroup.y))
        tabDragPreviewPanel?.orderFront(nil)
    }

    private func enterPaneTabDragMode() {
        guard !isPaneTabDrag, let group = dragGroup, let placeholder = dragPlaceholder else { return }
        let index =
            dragInitialOrder?.firstIndex(of: dragSource?.tag ?? -1)
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
              let index = tabs.arrangedSubviews.firstIndex(of: group)
        else { return }
        let frame = group.frame
        let placeholder = NSView(frame: frame)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholder.widthAnchor.constraint(equalToConstant: frame.width),
            placeholder.heightAnchor.constraint(equalToConstant: frame.height),
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
           acceptsExternalTab?(token, source) == true
        {
            let index = tabInsertionIndex(at: screenPoint)
            hideExternalTabTargets()
            return onExternalTabDrop?(token, source, index, nil) == true
        }
        guard acceptsTabDrag(pasteboard: pasteboard, source: source),
              let dragSource
        else { return false }
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
           acceptsExternalTab?(token, source) == true, gridAreas.indices.contains(cell)
        {
            hideExternalTabTargets()
            return onExternalTabDrop?(token, source, nil, cell) == true
        }
        guard acceptsTabDrag(pasteboard: pasteboard, source: source),
              gridAreas.indices.contains(cell), let dragSource
        else { return false }
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
        for index in gridAreas.indices {
            let row = index / gridSize.columns + 1
            let column = index % gridSize.columns + 1
            let title = stage.customLayout == nil ? L("%d行 %d列", row, column) : L("ペイン %d", index + 1)
            let item = NSMenuItem(title: title, action: #selector(moveTabFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = WorkspaceTabMoveItem(button)
            destinations.addItem(item)
        }
        move.submenu = destinations
        menu.addItem(move)
        if let pane = paneForTab?(button.tag) {
            let item = menu.addItem(withTitle: L("ペイン"), action: nil, keyEquivalent: "")
            item.submenu = paneMenu(for: pane)
        }
        menu.addItem(.separator())
        let count = tabSizing.count
        let all = IndexSet(integersIn: 0 ..< count)
        let own = all.intersection(IndexSet(integer: button.tag))
        func addRelease(_ title: String, _ indexes: IndexSet, closeWindows: Bool) {
            let item = NSMenuItem(
                title: L(title), action: indexes.isEmpty ? nil : #selector(releaseTabsFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = TabReleaseRequest(
                ids: indexes.map { tabSizing[$0].id },
                closeWindows: closeWindows)
            menu.addItem(item)
        }
        addRelease("タブを解除", own, closeWindows: false)
        addRelease("ウィンドウを閉じる", own, closeWindows: true)
        menu.addItem(.separator())
        let releases: [(String, IndexSet)] = [
            (closesWindowsOnRelease ? "他のタブのウィンドウをすべて閉じる" : "他のタブをすべて解除", all.subtracting(own)),
            (
                closesWindowsOnRelease ? "右側のタブのウィンドウを閉じる" : "右側のタブを解除",
                IndexSet(integersIn: min(button.tag + 1, count) ..< count)),
            (
                closesWindowsOnRelease ? "左側のタブのウィンドウを閉じる" : "左側のタブを解除",
                IndexSet(integersIn: 0 ..< min(button.tag, count))),
            (closesWindowsOnRelease ? "すべてのタブのウィンドウを閉じる" : "すべてのタブを解除", all),
        ]
        for (title, indexes) in releases {
            addRelease(title, indexes, closeWindows: closesWindowsOnRelease)
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
        guard let request = item.representedObject as? TabReleaseRequest else { return }
        onReleaseTabs?(request)
    }

    @objc private func moveTabFromMenu(_ item: NSMenuItem) {
        guard let button = (item.representedObject as? WorkspaceTabMoveItem)?.button,
              gridAreas.indices.contains(item.tag)
        else { return }
        onMoveTab?(button.tag, item.tag)
    }

    func clearTabs() {
        endCloseSizing()
        endTabDrag()
        removeWindowDropPreview()
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
        setSecondRow(nil)
    }

    private func tabBarFrame(of view: NSView) -> CGRect? {
        guard let layer = view.layer, let bar = toolbar.layer else { return nil }
        if let current = layer.presentation(), let root = bar.presentation() {
            return current.convert(current.bounds, to: root)
        }
        return layer.convert(layer.bounds, to: bar)
    }

    /// Animate the visual frame only. AppKit already has the final layout and hit targets.
    private func animateTabEntryLayout(_ view: NSView, from oldFrame: CGRect?) {
        guard let layer = view.layer, let parent = layer.superlayer, let bar = toolbar.layer else { return }
        let end = layer.frame
        guard !end.isEmpty else { return }
        let start = oldFrame.map { parent.convert($0, from: bar) }
            ?? end.insetBy(dx: end.width * 0.065, dy: end.height * 0.065)
        guard !start.isEmpty, start != end else { return }
        // AppKit layer anchors aren't necessarily centered. Keep a new tab centered throughout the pop.
        let transform = CGAffineTransform(
            a: start.width / end.width, b: 0, c: 0, d: start.height / end.height,
            tx: start.minX - end.minX + layer.anchorPoint.x * (start.width - end.width),
            ty: start.minY - end.minY + layer.anchorPoint.y * (start.height - end.height))
        let motion = CABasicAnimation(keyPath: "transform")
        motion.duration = 0.18
        motion.timingFunction = CAMediaTimingFunction(name: .easeOut)
        motion.fromValue = CATransform3DMakeAffineTransform(transform)
        motion.toValue = CATransform3DIdentity
        layer.add(motion, forKey: "tabEntryLayout")
        if oldFrame == nil {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.duration = motion.duration
            fade.fromValue = 0
            fade.toValue = 1
            layer.add(fade, forKey: "tabEntryOpacity")
        }
    }

    @discardableResult
    func setTabs(_ items: [WorkspaceTabItem]) -> [Tab] {
        let oldIDs = tabSizing.map(\.id)
        let ids = items.map(\.id)
        let remaining = Set(ids)
        if oldIDs != ids {
            let onlyRemoved = !ids.isEmpty && ids == oldIDs.filter(remaining.contains) && ids.count < oldIDs.count
            if onlyRemoved, pointerInToolbar, !tabBarPosition.isVertical, dragSource == nil, windowDropPreview == nil {
                if closeSizing == nil {
                    // Keep the scroll range as well as the slots: clamping the offset would move the next ×.
                    let width = tabs.widthAnchor.constraint(greaterThanOrEqualToConstant: tabs.bounds.width)
                    width.isActive = true
                    closeSizing = (width, bounds.size)
                }
            } else {
                endCloseSizing()
            }
        }
        let animate = Set(oldIDs) != remaining && toolbar.window?.isVisible == true
            && dragSource == nil && windowDropPreview == nil && !NSWorkspace.shared
            .accessibilityDisplayShouldReduceMotion
        if dragSource != nil { endTabDrag() }
        removeWindowDropPreview()
        if animate { toolbar.superview?.layoutSubtreeIfNeeded() }
        let old = Dictionary(uniqueKeysWithValues: tabSizing.map { ($0.id, $0) })
        let entering = animate && ids.contains { old[$0] == nil }
        let oldFrames = entering ? old.compactMapValues { tabBarFrame(of: $0.view) } : [:]
        let oldPlus = entering ? tabBarFrame(of: addButton) : nil
        for tab in tabSizing where !remaining.contains(tab.id) {
            tabs.removeArrangedSubview(tab.view)
            tab.view.removeFromSuperview()
        }
        tabSizing = items.enumerated().map { index, item in
            let tab = old[item.id] ?? makeTab(id: item.id)
            configure(tab, for: item)
            if tab.view.superview !== tabs || tabs.arrangedSubviews[index] !== tab.view {
                if tab.view.superview === tabs { tabs.removeArrangedSubview(tab.view) }
                tabs.insertArrangedSubview(tab.view, at: index)
            }
            return tab
        }
        tabScroll.isHidden = items.isEmpty
        if items.isEmpty {
            setSecondRow(nil)
            preferredTabWidth.constant = 0
            maximumTabWidth.constant = 0
            tabScroll.contentView.scroll(to: .zero)
        } else {
            updateTabWidths()
        }
        if entering {
            toolbar.superview?.layoutSubtreeIfNeeded()
            if let selected = items.firstIndex(where: \.selected) {
                tabs.scrollToVisible(tabSizing[selected].view.frame)
            }
            // AppKit installs the backing layers of newly inserted stack views on its display pass.
            // Prepare them before adding the pop, without committing the transaction in between.
            toolbar.window?.displayIfNeeded()
            for tab in tabSizing { animateTabEntryLayout(tab.view, from: oldFrames[tab.id]) }
            if let oldPlus { animateTabEntryLayout(addButton, from: oldPlus) }
        } else if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                toolbar.superview?.layoutSubtreeIfNeeded()
            }
        }
        return tabSizing
    }

    @discardableResult
    func appendTab(
        id: UUID = UUID(), title: String, toolTip: String? = nil, icon: NSImage? = nil, selected: Bool,
        displayed: Bool = false,
        pinned: Bool = false, tabSwitchTarget: Bool = false) -> Tab {
        endCloseSizing()
        let tab = makeTab(id: id)
        configure(tab, for: WorkspaceTabItem(id: id, title: title, toolTip: toolTip, icon: icon, selected: selected,
                                             displayed: displayed, pinned: pinned, tabSwitchTarget: tabSwitchTarget))
        tabSizing.append(tab)
        tabs.addArrangedSubview(tab.view)
        tabScroll.isHidden = false
        updateTabWidths()
        needsLayout = true
        return tab
    }

    private func makeTab(id: UUID) -> Tab {
        let select = WorkspaceTabButton(title: "", target: nil, action: nil)
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
            if let route = self.onTabDragMove {
                route(token, board, select, point)
            } else {
                self.updateFloatingTab(pasteboard: board, source: select, screenPoint: point)
            }
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
        select.isBordered = false
        select.alignment = .left
        select.imageHugsTitle = true
        select.lineBreakMode = .byTruncatingTail
        let pin = NSImageView()
        pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: L("固定中"))
        pin.contentTintColor = .controlAccentColor
        pin.imageScaling = .scaleProportionallyDown
        pin.translatesAutoresizingMaskIntoConstraints = false
        pin.toolTip = L("固定中")
        let close = Self.makeButton(
            WorkspaceTabCloseButton(frame: .zero), symbol: "xmark", title: "×", width: 18)
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
        group.addSubview(pin, positioned: .above, relativeTo: nil)
        pin.widthAnchor.constraint(equalToConstant: 12).isActive = true
        pin.heightAnchor.constraint(equalToConstant: 12).isActive = true
        NSLayoutConstraint.activate([
            pin.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -26),
            pin.topAnchor.constraint(equalTo: group.topAnchor, constant: 3),
        ])
        group.wantsLayer = true
        group.layer?.cornerRadius = 7
        group.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        let selectWidth = select.widthAnchor.constraint(equalToConstant: 200)
        NSLayoutConstraint.activate([
            select.widthAnchor.constraint(greaterThanOrEqualToConstant: WindowGeometry.minimumTabContentWidth),
            select.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            selectWidth,
            select.heightAnchor.constraint(equalToConstant: 28),
            group.heightAnchor.constraint(equalToConstant: 32),
        ])
        return Tab(id: id, view: group, select: select, close: close, pin: pin, constraint: selectWidth)
    }

    private func configure(_ tab: Tab, for item: WorkspaceTabItem) {
        let select = tab.select
        select.title = item.title
        let icon = item.icon?.copy() as? NSImage
        icon?.size = NSSize(width: 16, height: 16)
        select.image = icon
        select.imagePosition = icon == nil ? .noImage : .imageLeading
        let tabToolTip = item.toolTip ?? item.title
        select.toolTip = tabToolTip
        tab.view.toolTip = tabToolTip
        select.font = .systemFont(ofSize: 12, weight: item.selected ? .semibold : .regular)
        select.setAccessibilityValue(item.selected ? L("操作対象") : (item.displayed ? L("分割表示中") : L("未選択")))
        let closeTitle = closesWindowsOnRelease ? L("ウィンドウを閉じる") : L("元の位置に戻してタブから解除")
        // Assigning NSButton.title again would switch its cell out of image-only mode.
        tab.close.toolTip = closeTitle
        tab.close.setAccessibilityLabel(closeTitle)
        tab.pin.isHidden = !item.pinned
        tab.view.setSelectedAppearance(item.selected)
        tab.view.layer?.borderWidth = item.tabSwitchTarget ? 2 : (item.displayed ? 1 : 0)
        tab.view.layer?.borderColor = (item.pinned ? NSColor.systemOrange : NSColor.controlAccentColor)
            .withAlphaComponent(item.tabSwitchTarget ? 0.9 : 0.6).cgColor
    }

    func revealTab(_ view: NSView) {
        layoutSubtreeIfNeeded()
        tabs.window?.contentView?.layoutSubtreeIfNeeded()
        if closeSizing == nil { tabs.scrollToVisible(view.frame) }
        // Submit the highlight before synchronous AX calls can block the next display pass.
        tabs.window?.displayIfNeeded()
        CATransaction.flush()
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
                setAutoHiddenToolbarVisible(true)
            }
            configurePlacement()
        }
        return changed
    }
}
