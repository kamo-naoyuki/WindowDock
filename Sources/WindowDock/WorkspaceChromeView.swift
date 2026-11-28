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

/// The thin strip that marks the edge where the auto-hidden tab bar appears.
private final class WorkspaceAutoHideHandle: NSView {
    var isVertical = false { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        dirtyRect.fill(using: .sourceOver)
        let length = min(40, isVertical ? bounds.height : bounds.width)
        let grip = isVertical
            ? NSRect(x: bounds.midX - 1.5, y: bounds.midY - length / 2, width: 3, height: length)
            : NSRect(x: bounds.midX - length / 2, y: bounds.midY - 1.5, width: length, height: 3)
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
    }
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

/// Paints the auto-hidden tab bar like the regular one; a vibrant material would gray out its tabs.
private final class WorkspaceToolbarPanelBackground: NSView {
    weak var chrome: WorkspaceChromeView?

    /// Clicks on empty parts of the bar reach the workspace view when the bar is embedded; do the same here.
    override func mouseDown(with event: NSEvent) {
        chrome?.trackFrameChangeFromToolbar(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

private final class WorkspaceToolbarDragSpace: NSView {
    weak var chrome: WorkspaceChromeView?

    override func mouseDown(with event: NSEvent) {
        chrome?.trackFrameChangeFromToolbar(with: event)
    }
}

/// Draw over the native bezel without intercepting a click, tooltip, or accessibility hit on the control.
private final class WorkspaceControlHover: NSView {
    private var hovering = false { didSet { needsDisplay = true } }
    private var enabledObservation: NSKeyValueObservation?

    init(on button: NSButton) {
        super.init(frame: button.bounds)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
        button.addSubview(self)
        button.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        enabledObservation = button.observe(\.isEnabled) { [weak self] _, _ in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hovering = false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering, (superview as? NSButton)?.isEnabled == true else { return }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5)
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        shape.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        shape.lineWidth = 1.5
        shape.stroke()
    }
}

/// The compact tab bar's trailing grip: hovering it shows the hidden controls, dragging it moves the workspace.
private final class WorkspaceCompactControlsHandle: NSView {
    weak var chrome: WorkspaceChromeView?
    var isVertical = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
            userInfo: nil))
    }

    required init?(coder: NSCoder) { nil }

    override func mouseEntered(with event: NSEvent) {
        chrome?.updateCompactControlsHover(at: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        chrome?.trackFrameChangeFromToolbar(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setFill()
        for offset in [-4.0, 0, 4] {
            let center = isVertical ? NSPoint(x: bounds.midX + offset, y: bounds.midY)
                : NSPoint(x: bounds.midX, y: bounds.midY + offset)
            NSBezierPath(ovalIn: NSRect(x: center.x - 1.25, y: center.y - 1.25, width: 2.5, height: 2.5)).fill()
        }
    }
}

/// Holds the compact tab bar's controls above the tabs while they are shown.
private final class WorkspaceCompactControlsTray: NSView {
    weak var chrome: WorkspaceChromeView?
    let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        chrome?.trackFrameChangeFromToolbar(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
    }
}

/// Sizes of the tab bar; the compact tab bar trims the tabs' height and padding.
private struct TabBarMetrics {
    let tabHeight: CGFloat
    let titleHeight: CGFloat
    let leadingInset: CGFloat
    let trailingInset: CGFloat
    let titleSpacing: CGFloat
    let toolbarSpacing: CGFloat
    let toolbarInset: CGFloat
    static let closeWidth: CGFloat = 18
    /// Width a tab group adds around its title: insets, the gap and the × button.
    var chromeWidth: CGFloat { leadingInset + titleSpacing + Self.closeWidth + trailingInset }
    /// A pinned tab hides × and uses only the group's horizontal insets.
    var pinnedChromeWidth: CGFloat { leadingInset + trailingInset }
    var pinOffset: CGFloat { trailingInset + Self.closeWidth + titleSpacing }

    static let regular = TabBarMetrics(
        tabHeight: 32, titleHeight: 28, leadingInset: 8, trailingInset: 4, titleSpacing: 4, toolbarSpacing: 4,
        toolbarInset: 6)
    static let compact = TabBarMetrics(
        tabHeight: 26, titleHeight: 22, leadingInset: 4, trailingInset: 2, titleSpacing: 2, toolbarSpacing: 2,
        toolbarInset: 2)
}

struct TabReleaseRequest: Equatable {
    let ids: [UUID]
    let closeWindows: Bool
}

private struct TabPinRequest {
    let id: UUID
    let pinned: Bool
}

struct WorkspaceTabItem {
    let id: UUID
    var title: String
    var toolTip: String?
    var icon: NSImage?
    var selected: Bool
    var displayed = false
    var pinned = false
    var tabPinned = false
    var tabSwitchTarget = false
    var shortcutNumber: Int? = nil
    var canPinTab = false
    var playingAudio = false
    /// A combined tab: it shows a remembered pane state, so its tab only reorders when dragged.
    var paneGroup = false
    /// The windows of a combined tab, each shown as its icon and a name shortened to keep every window visible.
    var combinedWindows: [(name: String, icon: NSImage?)] = []
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
    /// Shows only each tab's icon. The window name stays in the tab's tooltip and accessibility label.
    var showsTabIconsOnly = false {
        didSet {
            if showsTabIconsOnly != oldValue {
                endTabDrag()
                endCloseSizing()
                reconfigureTabs()
                updateTabWidths()
                needsLayout = true
            }
        }
    }
    /// Tighter tabs without the workspace name; the controls after the tabs appear from a handle at the end.
    var compactTabBar = false {
        didSet { if compactTabBar != oldValue { applyCompactTabBar() } }
    }
    let stage = WorkspaceGridView(frame: .zero)
    var gridSize: WorkspaceGridSize { stage.gridSize }
    var gridAreas: [NSView] { stage.areas }
    /// With a single pane, dropping a tab onto it cannot change the layout, so the whole workspace acts as the tab bar.
    private var hasSinglePane: Bool { gridAreas.count <= 1 }
    var onGridChange: ((WorkspaceGridSize) -> Void)?
    var splitRestriction: ((Int, PaneLayout.Axis) -> PaneSplitRestriction?)?
    var onSplitPane: ((Int, PaneLayout.Axis) -> Void)?
    var onEqualizePane: ((Int) -> Void)?
    var onClosePane: ((Int) -> Void)?
    var isPanePinned: ((Int) -> Bool)?
    var onTogglePanePin: ((Int) -> Void)?
    var paneForTab: ((Int) -> Int?)?
    /// Menu items for automatically collecting the app of the tab at an index.
    var autoGroupMenuItems: ((Int) -> [NSMenuItem])?
    var onSetTabPinned: ((UUID, Bool) -> Void)?
    var onActivateCell: ((Int) -> Void)?
    var onTabScroll: ((Int) -> Void)?
    var onTabHover: ((UUID, Bool) -> Void)?
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
    var canCombinePanes: (() -> Bool)?
    var onCombinePanes: (() -> Void)?
    var onUngroupTab: ((Int) -> Void)?
    /// Ungroups the combined tab being shown, from the combine button.
    var onUngroupShownTab: (() -> Void)?
    private(set) var combineButtonUngroups = false
    let addButton = makeButton(symbol: "plus", title: L("新しいタブ"), width: 26)
    let combineButton = makeButton(
        symbol: "rectangle.stack.badge.plus", title: L("表示中のペインを1つのタブにまとめる"), width: 26)
    let permissionButton = makeButton(symbol: "gearshape", title: L("権限設定"), width: 26)
    let columnSelector = NSPopUpButton(frame: .zero, pullsDown: false)
    let rowSelector = NSPopUpButton(frame: .zero, pullsDown: false)
    let workspaceButton = NSButton(title: "", target: nil, action: nil)
    /// Opens the workspace menu from the compact tab bar, which hides the workspace name.
    let workspaceMenuButton = makeButton(symbol: "ellipsis.circle", title: L("ワークスペースの操作"), width: 26)
    var workspaceMenu: (() -> NSMenu)?
    private var toolbar: NSStackView!
    private let titlebarControls = NSView()
    private let toolbarHost = NSView()
    private let dragSpace = WorkspaceToolbarDragSpace()
    private var dragSpaceWidths: [NSLayoutConstraint] = []
    private let compactHandle = WorkspaceCompactControlsHandle()
    private var compactHandleSize: [NSLayoutConstraint] = []
    private let compactTray = WorkspaceCompactControlsTray()
    private var compactTrayConstraints: [NSLayoutConstraint] = []
    private var clippedTabDividerLeading: NSLayoutConstraint!
    private(set) var compactControlsRevealed = false
    private var compactControlsExitDate: Date?
    private var compactControlsTimer: Timer?
    static let compactControlsHideDelay: TimeInterval = 0.3
    private var metrics: TabBarMetrics { compactTabBar ? .compact : .regular }
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
    private var toolbarPanelContent: NSView?
    private let autoHideHandle = WorkspaceAutoHideHandle()
    private static let autoHideHandleThickness: CGFloat = 6
    var isAutoHideHandleVisible: Bool { !autoHideHandle.isHiddenOrHasHiddenAncestor && autoHideHandle.window != nil }
    private(set) var autoHideTabBar = false
    private(set) var autoHiddenToolbarVisible = false
    private(set) var tabBarPosition: TabBarPosition = .top
    private static let minimumWorkspaceNameWidth: CGFloat = 48
    private static let verticalTabWidth: CGFloat = 180
    private var hasManagedWindows = false
    private var settingGrid = false
    private weak var dragSource: NSButton?
    private var dragGroup: WorkspaceTabGroup?
    private var dragPlaceholder: NSView?
    private var dragToken: String?
    /// The dragged tab is a combined tab: it can only change its place in the tab bar.
    private var dragReordersOnly = false
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
    private var tabPreviewPanel: NSPanel?
    private weak var tabPreviewImageView: NSImageView?
    var isTabPreviewVisible: Bool { tabPreviewPanel?.isVisible == true }
    var tabPreviewFrame: NSRect? { tabPreviewPanel?.frame }
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
        fileprivate let titleHeight: NSLayoutConstraint
        fileprivate let groupHeight: NSLayoutConstraint
        fileprivate let pinTrailing: NSLayoutConstraint
    }

    private var tabSizing: [Tab] = []
    private var tabItems: [UUID: WorkspaceTabItem] = [:]
    private var updatingTabWidths = false
    private var pointerInToolbar = false
    private var toolbarTracking: NSTrackingArea?
    private var closeSizing: (constraints: [NSLayoutConstraint], windowSize: NSSize)?
    private var tabWheelGesture = TabWheelGesture()
    private var tabReorderGesture = TabWheelGesture()

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
        tabPreviewPanel?.close()
        toolbarPanel?.close()
    }

    func showTabPreview(_ image: CGImage) {
        if tabPreviewPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false)
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isExcludedFromWindowsMenu = true
            panel.collectionBehavior = [.transient, .ignoresCycle]
            let imageView = NSImageView()
            imageView.imageScaling = .scaleNone
            imageView.wantsLayer = true
            imageView.layer?.backgroundColor = NSColor.clear.cgColor
            imageView.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView?.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
                imageView.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            ])
            tabPreviewPanel = panel
            tabPreviewImageView = imageView
        }
        tabPreviewImageView?.image = NSImage(
            cgImage: image, size: NSSize(width: image.width, height: image.height))
        let panel = tabPreviewPanel!
        panel.setContentSize(NSSize(width: image.width, height: image.height))
        let size = panel.frame.size
        let point = NSEvent.mouseLocation
        let visible = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: point.x + 16, y: point.y + 16)
        if origin.x + size.width > visible.maxX { origin.x = point.x - size.width - 16 }
        if origin.y + size.height > visible.maxY { origin.y = point.y - size.height - 16 }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func hideTabPreview() {
        tabPreviewPanel?.orderOut(nil)
    }

    override func layout() {
        super.layout()
        if let closeSizing, closeSizing.windowSize != bounds.size { endCloseSizing() }
        updateTabWidths()
        updateClippedTabDivider()
        updateToolbarPanelFrame()
        autoHideHandle.frame = autoHideHandleRect
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
        NSLayoutConstraint.deactivate(closeSizing.constraints)
        self.closeSizing = nil
        updateTabWidths()
        needsLayout = true
    }

    private func handleTabScrollWheel(_ event: NSEvent, over id: UUID) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == [.shift] {
            let delta = event.deltaY == 0 ? event.deltaX : event.deltaY
            guard let direction = tabReorderGesture.direction(
                deltaY: delta, phase: event.phase, momentumPhase: event.momentumPhase)
            else { return false }
            _ = reorderTab(id, by: direction)
            return true
        }
        guard flags.isEmpty,
              onTabScroll != nil, !tabBarPosition.isVertical, !tabScroll.isHidden,
              tabScroll.contentView.bounds.width >= tabs.bounds.width - 1,
              let direction = tabWheelGesture.direction(
                  deltaY: event.deltaY, phase: event.phase, momentumPhase: event.momentumPhase)
        else { return false }
        onTabScroll?(direction)
        return true
    }

    @discardableResult
    func reorderTab(_ id: UUID, by direction: Int) -> Bool {
        guard abs(direction) == 1, let index = tabSizing.firstIndex(where: { $0.id == id }),
              let onReorderTabs
        else { return false }
        let destination = index + direction
        guard tabSizing.indices.contains(destination) else { return false }
        var order = Array(tabSizing.indices)
        order.swapAt(index, destination)
        onReorderTabs(order)
        return true
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

    /// The edge strip kept visible while the tab bar is auto-hidden; hovering it reveals the bar.
    private var autoHideHandleRect: NSRect {
        let thickness = Self.autoHideHandleThickness
        switch tabBarPosition {
        case .top:
            return NSRect(x: bounds.minX + 64, y: bounds.maxY - thickness, width: max(0, bounds.width - 64),
                          height: thickness)
        case .bottom:
            return NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: thickness)
        case .left:
            return NSRect(x: bounds.minX, y: bounds.minY + 3, width: thickness, height: max(0, bounds.height - 37))
        case .right:
            return NSRect(x: bounds.maxX - thickness, y: bounds.minY + 3, width: thickness,
                          height: max(0, bounds.height - 37))
        }
    }

    var toolbarHoverFrame: NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(autoHideHandleRect, to: nil))
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
        autoHideHandle.isVertical = position.isVertical
        configureCompactControls()
        configurePlacement()
        if showsTabIconsOnly { reconfigureTabs() }
        updateTabWidths()
        needsLayout = true
        layoutSubtreeIfNeeded()
        updateToolbarPanelFrame()
    }

    func setWorkspaceName(_ name: String) {
        workspaceButton.title = name
        workspaceButton.toolTip = name
    }

    /// The controls that the compact tab bar keeps out of sight until its handle is hovered.
    private var compactTrayControls: [NSView] { [combineButton, columnSelector, rowSelector, permissionButton] }

    private func applyCompactTabBar() {
        endTabDrag()
        endCloseSizing()
        hideWindowDropTarget()
        let metrics = metrics
        toolbar.spacing = metrics.toolbarSpacing
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: metrics.toolbarInset, bottom: 0, right: metrics.toolbarInset)
        clippedTabDividerLeading.constant = 1 - metrics.toolbarSpacing
        workspaceButton.isHidden = compactTabBar
        // The handle is the grip of the compact tab bar; the drag space only takes what the tabs leave.
        for constraint in dragSpaceWidths {
            constraint.constant = compactTabBar ? 0 : 30
        }
        if compactTabBar {
            compactTray.stack.addArrangedSubview(workspaceMenuButton)
            for view in compactTrayControls {
                toolbar.removeArrangedSubview(view)
                view.removeFromSuperview()
                compactTray.stack.addArrangedSubview(view)
            }
            toolbar.addArrangedSubview(compactHandle)
            toolbar.setVisibilityPriority(.mustHold, for: compactHandle)
            toolbar.addSubview(compactTray, positioned: .above, relativeTo: nil)
            configureCompactControls()
        } else {
            setCompactControlsRevealed(false)
            NSLayoutConstraint.deactivate(compactHandleSize + compactTrayConstraints)
            compactTray.removeFromSuperview()
            toolbar.removeArrangedSubview(compactHandle)
            compactHandle.removeFromSuperview()
            compactTray.stack.removeArrangedSubview(workspaceMenuButton)
            workspaceMenuButton.removeFromSuperview()
            for view in compactTrayControls {
                compactTray.stack.removeArrangedSubview(view)
                view.removeFromSuperview()
                toolbar.addArrangedSubview(view)
                toolbar.setVisibilityPriority(.mustHold, for: view)
            }
        }
        for tab in tabSizing {
            applyMetrics(to: tab)
        }
        updateStripHeight()
        updateTabWidths()
        needsLayout = true
        layoutSubtreeIfNeeded()
        updateToolbarPanelFrame()
    }

    private func configureCompactControls() {
        guard compactTabBar else { return }
        let vertical = tabBarPosition.isVertical
        NSLayoutConstraint.deactivate(compactHandleSize + compactTrayConstraints)
        compactHandle.isVertical = vertical
        compactHandleSize = [
            compactHandle.widthAnchor.constraint(equalToConstant: vertical ? 40 : 12),
            compactHandle.heightAnchor.constraint(equalToConstant: vertical ? 12 : 22),
        ]
        compactTray.stack.orientation = vertical ? .vertical : .horizontal
        compactTray.stack.alignment = vertical ? .centerX : .centerY
        compactTrayConstraints = vertical
            ? [
                compactTray.bottomAnchor.constraint(equalTo: compactHandle.topAnchor, constant: -2),
                compactTray.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),
            ]
            : [
                compactTray.trailingAnchor.constraint(equalTo: compactHandle.leadingAnchor, constant: -2),
                compactTray.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            ]
        NSLayoutConstraint.activate(compactHandleSize + compactTrayConstraints)
    }

    var compactControlsHandleScreenFrame: NSRect? { screenFrame(of: compactHandle) }
    var compactControlsScreenFrame: NSRect? { screenFrame(of: compactTray) }

    private func screenFrame(of view: NSView) -> NSRect? {
        guard let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    /// Shows the compact tab bar's controls while the pointer is on its handle or on them, and hides them shortly
    /// after it leaves.
    func updateCompactControlsHover(at point: NSPoint, now: Date = Date()) {
        guard compactTabBar, let handle = compactControlsHandleScreenFrame else {
            setCompactControlsRevealed(false)
            return
        }
        let overControls = compactControlsRevealed
            && compactControlsScreenFrame.map { $0.insetBy(dx: -4, dy: -4).contains(point) } == true
        if handle.insetBy(dx: -1, dy: -1).contains(point) || overControls {
            setCompactControlsRevealed(true)
        } else if compactControlsRevealed {
            let exit = compactControlsExitDate ?? now
            compactControlsExitDate = exit
            if now.timeIntervalSince(exit) >= Self.compactControlsHideDelay { setCompactControlsRevealed(false) }
        }
    }

    private func setCompactControlsRevealed(_ revealed: Bool) {
        let revealed = revealed && compactTabBar
        compactControlsExitDate = nil
        guard compactControlsRevealed != revealed else { return }
        compactControlsRevealed = revealed
        compactTray.isHidden = !revealed
        compactControlsTimer?.invalidate()
        compactControlsTimer = nil
        guard revealed else { return }
        // A default-mode timer pauses while a control's menu is open, so the controls stay until it closes.
        compactControlsTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.updateCompactControlsHover(at: NSEvent.mouseLocation)
            }
        }
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
            autoHideHandle.isHidden = false
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
            autoHideHandle.isHidden = true
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
            setCompactControlsRevealed(false)
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

        let content = WorkspaceToolbarPanelBackground()
        content.chrome = self
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

        if tabBarPosition.isVertical {
            setSecondRow(nil)
            let verticalContentWidth = Self.verticalTabWidth - metrics.chromeWidth
            for tab in tabSizing where tab.constraint.constant != verticalContentWidth {
                tab.constraint.constant = verticalContentWidth
            }
            if let windowDropPreviewWidth, windowDropPreviewWidth.constant != verticalContentWidth {
                windowDropPreviewWidth.constant = verticalContentWidth
            }
            let count = tabSizing.count + (windowDropPreviewWidth == nil ? 0 : 1)
            let naturalHeight = CGFloat(count) * metrics.tabHeight + CGFloat(max(0, count - 1)) * tabs.spacing
            let controls = toolbar.arrangedSubviews.filter { $0 !== tabScroll && !$0.isHidden }
            let fixedHeight = controls.reduce(CGFloat(0)) { $0 + $1.fittingSize.height }
                + CGFloat(controls.count) * toolbar.spacing + toolbar.edgeInsets.top + toolbar.edgeInsets.bottom
            preferredVerticalTabHeight.constant = min(naturalHeight, max(0, bounds.height - 37 - fixedHeight))
            return
        }
        let fixedGroupWidth = metrics.chromeWidth
        let nameWidth = workspaceButton.isHidden ? 0
            : min(ceil(workspaceButton.intrinsicContentSize.width), Self.minimumWorkspaceNameWidth)
        // Hidden views are detached from the bar and take no space.
        let controls = toolbar.arrangedSubviews.filter { $0 !== tabScroll && !$0.isHidden }
        let fixedControlsWidth = controls
            .filter { $0 !== workspaceButton }
            .reduce(nameWidth) { $0 + $1.fittingSize.width }
        let toolbarGaps = CGFloat(controls.count) * toolbar.spacing
        let availableWidth = max(
            0,
            bounds.width - fixedControlsWidth - toolbarGaps
                - toolbar.edgeInsets.left - toolbar.edgeInsets.right)
        let pinnedCount = tabSizing.filter { tabItems[$0.id]?.tabPinned == true }.count
        let regularCount = tabSizing.count - pinnedCount + (windowDropPreviewWidth == nil ? 0 : 1)
        let pinnedTotalWidth = CGFloat(pinnedCount)
            * (WindowGeometry.iconOnlyTabContentWidth + metrics.pinnedChromeWidth)
            + CGFloat(max(0, pinnedCount - 1)) * tabs.spacing
        let dividerSpacing = pinnedCount > 0 && regularCount > 0 ? tabs.spacing : 0
        let regularAvailableWidth = max(0, availableWidth - pinnedTotalWidth - dividerSpacing)
        let layout = WindowGeometry.horizontalTabRows(
            count: regularCount, available: regularAvailableWidth, chrome: fixedGroupWidth, spacing: tabs.spacing,
            wrap: wrapsCrowdedTabs,
            maximumContent: showsTabIconsOnly ? WindowGeometry.iconOnlyTabContentWidth
                : WindowGeometry.maximumTabContentWidth)
        setSecondRow(layout.secondRow.map { $0 + pinnedCount })
        let targetWidth = min(availableWidth, pinnedTotalWidth + dividerSpacing + layout.viewport)
        if abs(maximumTabWidth.constant - targetWidth) > 0.5 {
            maximumTabWidth.constant = targetWidth
            preferredTabWidth.constant = targetWidth
        }
        for tab in tabSizing {
            let contentWidth = tabItems[tab.id]?.tabPinned == true
                ? WindowGeometry.iconOnlyTabContentWidth : layout.contentWidth
            if abs(tab.constraint.constant - contentWidth) > 0.01 {
                tab.constraint.constant = contentWidth
            }
        }
        if let windowDropPreviewWidth, abs(windowDropPreviewWidth.constant - layout.contentWidth) > 0.01 {
            windowDropPreviewWidth.constant = layout.contentWidth
        }
    }

    /// While closed tabs keep their slots, pull the + button in behind the last visible tab.
    private func fitCloseSizingViewport() {
        guard closeSizing != nil, !tabBarPosition.isVertical, !tabSizing.isEmpty else { return }
        let split = min(tabs.secondRow ?? tabSizing.count, tabSizing.count)
        func extent(_ row: ArraySlice<Tab>) -> CGFloat {
            row.reduce(0) {
                let chrome = tabItems[$1.id]?.tabPinned == true ? metrics.pinnedChromeWidth : metrics.chromeWidth
                return $0 + $1.constraint.constant + chrome
            }
                + CGFloat(max(0, row.count - 1)) * tabs.spacing
        }
        let content = max(extent(tabSizing[..<split]), extent(tabSizing[split...]))
        let visible = min(maximumTabWidth.constant, max(0, content - tabScroll.contentView.bounds.minX))
        guard abs(maximumTabWidth.constant - visible) > 0.5 else { return }
        maximumTabWidth.constant = visible
        preferredTabWidth.constant = visible
    }

    private func setSecondRow(_ split: Int?) {
        guard tabs.secondRow != split else { return }
        tabs.secondRow = split
        updateStripHeight()
    }

    private func updateStripHeight() {
        let height = tabs.secondRow == nil ? metrics.tabHeight : 2 * metrics.tabHeight + tabs.spacing
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

    @objc private func showWorkspaceMenu(_ sender: NSButton) {
        workspaceMenu?().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
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
            tabScroll.widthAnchor.constraint(equalToConstant: Self.verticalTabWidth),
            tabScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            preferredVerticalTabHeight,
        ]
        NSLayoutConstraint.activate(horizontalTabConstraints)
        dragSpace.chrome = self
        dragSpace.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let preferredDragWidth = dragSpace.widthAnchor.constraint(equalToConstant: 30)
        preferredDragWidth.priority = .defaultLow
        dragSpaceWidths = [dragSpace.widthAnchor.constraint(greaterThanOrEqualToConstant: 30), preferredDragWidth]
        NSLayoutConstraint.activate(dragSpaceWidths)
        dragSpace.toolTip = L("ドラッグして移動 / ダブルクリックで最大化")
        compactHandle.chrome = self
        compactHandle.toolTip = L("ドラッグして移動 / ダブルクリックで最大化")
        compactTray.chrome = self
        compactTray.isHidden = true
        compactTray.translatesAutoresizingMaskIntoConstraints = false
        workspaceMenuButton.target = self
        workspaceMenuButton.action = #selector(showWorkspaceMenu(_:))
        configureSelector(columnSelector, prefix: L("横"))
        configureSelector(rowSelector, prefix: L("縦"))
        combineButton.target = self
        combineButton.action = #selector(combineButtonPressed)
        combineButton.isEnabled = false
        workspaceButton.isBordered = false
        workspaceButton.font = .boldSystemFont(ofSize: 12)
        workspaceButton.contentTintColor = .secondaryLabelColor
        workspaceButton.lineBreakMode = .byTruncatingTail
        workspaceButton.alignment = .left
        workspaceButton.toolTip = L("ワークスペースの操作")
        workspaceButton.target = self
        workspaceButton.action = #selector(showWorkspaceMenu(_:))
        for button in [addButton, workspaceButton, workspaceMenuButton, combineButton, columnSelector, rowSelector,
                       permissionButton] {
            _ = WorkspaceControlHover(on: button)
        }
        // Hug the name tightly and let tabs take its space first; keep a short prefix visible.
        workspaceButton.setContentHuggingPriority(NSLayoutConstraint.Priority(490), for: .horizontal)
        workspaceButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        workspaceButton.widthAnchor.constraint(lessThanOrEqualToConstant: 160).isActive = true
        let minimumName = workspaceButton.widthAnchor.constraint(
            greaterThanOrEqualToConstant: Self.minimumWorkspaceNameWidth)
        minimumName.priority = NSLayoutConstraint.Priority(480)
        minimumName.isActive = true
        let bar = NSStackView(views: [
            titlebarControls, workspaceButton, tabScroll, addButton, dragSpace, combineButton, columnSelector,
            rowSelector, permissionButton,
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
        // Anchored to the tabs rather than the workspace name, which the compact tab bar hides.
        clippedTabDividerLeading = clippedTabDivider.leadingAnchor.constraint(
            equalTo: tabScroll.leadingAnchor, constant: 1 - bar.spacing)
        NSLayoutConstraint.activate([
            clippedTabDividerLeading,
            clippedTabDivider.centerYAnchor.constraint(equalTo: tabScroll.centerYAnchor),
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
            if !self.settingGrid {
                self.updateGridSelectors()
                self.onPaneLayoutChange?()
            }
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
        autoHideHandle.isHidden = true
        addSubview(autoHideHandle)
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
        let handleInset = Self.autoHideHandleThickness + 1
        let noticeTop: NSLayoutConstraint
        if tabBarPosition == .top, !autoHideTabBar || !notice.isHidden {
            noticeTop = notice.topAnchor.constraint(equalTo: toolbarHost.bottomAnchor, constant: 1)
        } else {
            noticeTop = notice.topAnchor.constraint(
                equalTo: topAnchor, constant: tabBarPosition == .top ? handleInset : 34)
        }
        placementConstraints = host + [
            noticeTop,
            stage.topAnchor.constraint(equalTo: notice.bottomAnchor),
            tabBarPosition == .left && !autoHideTabBar
                ? stage.leadingAnchor.constraint(equalTo: toolbarHost.trailingAnchor, constant: 3)
                : stage.leadingAnchor.constraint(
                    equalTo: leadingAnchor, constant: tabBarPosition == .left ? handleInset : 3),
            tabBarPosition == .right && !autoHideTabBar
                ? stage.trailingAnchor.constraint(equalTo: toolbarHost.leadingAnchor, constant: -3)
                : stage.trailingAnchor.constraint(
                    equalTo: trailingAnchor, constant: tabBarPosition == .right ? -handleInset : -3),
            tabBarPosition == .bottom && !autoHideTabBar
                ? stage.bottomAnchor.constraint(equalTo: toolbarHost.topAnchor, constant: -3)
                : stage.bottomAnchor.constraint(
                    equalTo: bottomAnchor, constant: tabBarPosition == .bottom ? -handleInset : -3),
        ]
        NSLayoutConstraint.activate(placementConstraints)
    }

    private func configureSelector(_ selector: NSPopUpButton, prefix: String) {
        selector.addItems(withTitles: (1 ... 4).map { "\(prefix)\($0)" })
        selector.addItem(withTitle: L("カスタム"))
        selector.lastItem?.isEnabled = false
        selector.menu?.autoenablesItems = false
        // Keeps the auto-hidden tab bar while the pop-up menu is open.
        selector.menu?.delegate = self
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
        updateGridSelectors()
        if requested != gridSize || stage.customLayout != nil { onGridChange?(requested) }
    }

    private func updateGridSelectors() {
        let size = stage.displayedGridSize
        columnSelector.selectItem(at: size.map { $0.columns - 1 } ?? PaneLayout.maximumDivisions)
        rowSelector.selectItem(at: size.map { $0.rows - 1 } ?? PaneLayout.maximumDivisions)
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
        updateGridSelectors()
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
        updateGridSelectors()
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
        add(L("この分割を均等にする"), stage.canEqualizePane(at: index) ? #selector(equalizePane(_:)) : nil)
        menu.addItem(.separator())
        add(L("表示中のペインを1つのタブにまとめる"), canCombinePanes?() == true ? #selector(combinePanes) : nil)
        return menu
    }

    @objc private func combinePanes() { onCombinePanes?() }
    @objc private func combineButtonPressed() { combineButtonUngroups ? onUngroupShownTab?() : onCombinePanes?() }
    @objc private func ungroupTabFromMenu(_ item: NSMenuItem) { onUngroupTab?(item.tag) }

    /// While a combined tab is shown, the combine button ungroups it instead.
    func setCombineButton(ungroups: Bool, enabled: Bool) {
        combineButton.isEnabled = enabled
        guard ungroups != combineButtonUngroups else { return }
        combineButtonUngroups = ungroups
        let title = ungroups ? L("タブのまとめを解除") : L("表示中のペインを1つのタブにまとめる")
        combineButton.image = NSImage(
            systemSymbolName: ungroups ? "rectangle.stack.badge.minus" : "rectangle.stack.badge.plus",
            accessibilityDescription: title)
        combineButton.toolTip = title
        combineButton.setAccessibilityLabel(title)
    }

    @objc private func splitPaneHorizontally(_ item: NSMenuItem) { onSplitPane?(item.tag, .horizontal) }
    @objc private func splitPaneVertically(_ item: NSMenuItem) { onSplitPane?(item.tag, .vertical) }
    @objc private func equalizePane(_ item: NSMenuItem) { onEqualizePane?(item.tag) }
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
            preview.spacing = metrics.titleSpacing
            preview.edgeInsets = NSEdgeInsets(
                top: 0, left: metrics.leadingInset, bottom: 0, right: metrics.trailingInset)
            preview.wantsLayer = true
            preview.layer?.cornerRadius = 7
            preview.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            preview.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            preview.alphaValue = 0.55
            let width = button.widthAnchor.constraint(equalToConstant: 100)
            NSLayoutConstraint.activate([
                width,
                button.heightAnchor.constraint(equalToConstant: metrics.titleHeight),
                preview.heightAnchor.constraint(equalToConstant: metrics.tabHeight),
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

    /// The visible control before the tabs; an empty tab bar's insertion line goes just past it.
    private var emptyTabBarAnchor: NSRect? {
        [workspaceButton, titlebarControls].first { !$0.isHidden }.map { toolbar.convert($0.bounds, from: $0) }
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
                emptyX: -(emptyTabBarAnchor?.minY ?? toolbar.bounds.maxY) + 6,
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
            emptyX: (emptyTabBarAnchor?.maxX ?? toolbar.edgeInsets.left) + 6,
            visibleMinX: stripRect.minX, visibleMaxX: stripRect.maxX, lineWidth: 3)
        let markerHeight = metrics.titleHeight
        let markerRect = NSRect(
            x: x, y: (frames.first?.midY ?? barRect.midY) - markerHeight / 2, width: 3, height: markerHeight)
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

    func beginTabDrag(
        source: NSButton, token: String, anchor: NSPoint? = nil, previewImage: NSImage? = nil,
        reordersOnly: Bool = false) {
        endCloseSizing()
        endTabDrag()
        guard let group = source.superview as? WorkspaceTabGroup,
              let index = tabs.arrangedSubviews.firstIndex(of: group)
        else { return }
        let frame = group.frame
        dragSource = source
        dragToken = token
        dragReordersOnly = reordersOnly
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
        if !reordersOnly { onTabDragBegin?(source.tag, token, source) }
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
        dragReordersOnly = false
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
        highlightPane(dragReordersOnly ? nil : paneDropIndex(at: screenPoint))
        if tabRowContains(screenPoint) || dragReordersOnly {
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
        let isPaneGroup = tabSizing.indices.contains(button.tag)
            && tabItems[tabSizing[button.tag].id]?.paneGroup == true
        if isPaneGroup {
            let ungroup = menu.addItem(
                withTitle: L("タブのまとめを解除"), action: #selector(ungroupTabFromMenu(_:)), keyEquivalent: "")
            ungroup.target = self
            ungroup.tag = button.tag
        } else {
            addPaneItems(to: menu, for: button)
        }
        if tabSizing.indices.contains(button.tag),
           tabItems[tabSizing[button.tag].id]?.canPinTab == true {
            menu.addItem(.separator())
            let id = tabSizing[button.tag].id
            let tabPinned = tabItems[id]?.tabPinned == true
            let pin = menu.addItem(
                withTitle: L("タブを固定"),
                action: #selector(setTabPinFromMenu(_:)),
                keyEquivalent: "")
            pin.target = self
            pin.state = tabPinned ? .on : .off
            pin.representedObject = TabPinRequest(id: id, pinned: !tabPinned)
        }
        if let items = autoGroupMenuItems?(button.tag), !items.isEmpty {
            menu.addItem(.separator())
            items.forEach(menu.addItem)
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

    @objc private func setTabPinFromMenu(_ item: NSMenuItem) {
        guard let request = item.representedObject as? TabPinRequest else { return }
        onSetTabPinned?(request.id, request.pinned)
    }

    private func addPaneItems(to menu: NSMenu, for button: NSButton) {
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
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Only the top-level menu decides: a submenu can close while its parent stays open.
        guard menu.supermenu == nil else { return }
        onToolbarMenuTracking?(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu.supermenu == nil else { return }
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
            // Closing the rightmost tab resizes at once, which slides the new last × under the pointer.
            let removedLast = oldIDs.last.map { !remaining.contains($0) } == true
            if onlyRemoved, !removedLast, pointerInToolbar, !tabBarPosition.isVertical, dragSource == nil,
               windowDropPreview == nil {
                if closeSizing == nil {
                    // Keep the scroll range and the name width as well as the slots: either could move the next ×.
                    let constraints = [
                        tabs.widthAnchor.constraint(greaterThanOrEqualToConstant: tabs.bounds.width),
                        workspaceButton.widthAnchor.constraint(equalToConstant: workspaceButton.frame.width),
                    ]
                    NSLayoutConstraint.activate(constraints)
                    closeSizing = (constraints, bounds.size)
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
            tabItems.removeValue(forKey: tab.id)
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
            fitCloseSizingViewport()
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

    /// Updates the current tabs in place. Unlike `setTabs`, it keeps a tab drag going and doesn't animate.
    func updateTabs(_ items: [WorkspaceTabItem]) {
        guard items.map(\.id) == tabSizing.map(\.id) else { return }
        for (tab, item) in zip(tabSizing, items) { configure(tab, for: item) }
    }

    @discardableResult
    func appendTab(
        id: UUID = UUID(), title: String, toolTip: String? = nil, icon: NSImage? = nil, selected: Bool,
        displayed: Bool = false,
        pinned: Bool = false, tabSwitchTarget: Bool = false, playingAudio: Bool = false) -> Tab {
        endCloseSizing()
        let tab = makeTab(id: id)
        configure(tab, for: WorkspaceTabItem(id: id, title: title, toolTip: toolTip, icon: icon, selected: selected,
                                             displayed: displayed, pinned: pinned, tabSwitchTarget: tabSwitchTarget,
                                             playingAudio: playingAudio))
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
            guard let self else { return }
            let reordersOnly = self.tabItems[id]?.paneGroup == true
            self.beginTabDrag(
                source: button, token: token, anchor: anchor, previewImage: image, reordersOnly: reordersOnly)
            button.onDragEnd = { [weak self] board, point, cancelled in
                if reordersOnly {
                    self?.finishTabDrag(commit: !cancelled)
                    return
                }
                self?.onTabDragEnd?(token, board, point, cancelled)
                self?.finishTabDrag(commit: false)
            }
        }
        select.onDragMove = { [weak self, weak select] board, point in
            guard let self, let select, let token = self.dragToken else { return }
            if let route = self.onTabDragMove, !self.dragReordersOnly {
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
        group.detachesHiddenViews = true
        group.onHover = { [weak self] isHovering in self?.onTabHover?(id, isHovering) }
        group.onScrollWheel = { [weak self] event in self?.handleTabScrollWheel(event, over: id) == true }
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
        group.spacing = metrics.titleSpacing
        group.edgeInsets = NSEdgeInsets(top: 0, left: metrics.leadingInset, bottom: 0, right: metrics.trailingInset)
        group.addSubview(pin, positioned: .above, relativeTo: nil)
        pin.widthAnchor.constraint(equalToConstant: 12).isActive = true
        pin.heightAnchor.constraint(equalToConstant: 12).isActive = true
        let pinTrailing = pin.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -metrics.pinOffset)
        NSLayoutConstraint.activate([
            pinTrailing,
            pin.topAnchor.constraint(equalTo: group.topAnchor, constant: 3),
        ])
        group.wantsLayer = true
        group.layer?.cornerRadius = 7
        group.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        let selectWidth = select.widthAnchor.constraint(equalToConstant: 200)
        let titleHeight = select.heightAnchor.constraint(equalToConstant: metrics.titleHeight)
        let groupHeight = group.heightAnchor.constraint(equalToConstant: metrics.tabHeight)
        NSLayoutConstraint.activate([
            select.widthAnchor.constraint(greaterThanOrEqualToConstant: WindowGeometry.minimumTabContentWidth),
            select.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            selectWidth,
            titleHeight,
            groupHeight,
        ])
        return Tab(
            id: id, view: group, select: select, close: close, pin: pin, constraint: selectWidth,
            titleHeight: titleHeight, groupHeight: groupHeight, pinTrailing: pinTrailing)
    }

    private func applyMetrics(to tab: Tab) {
        let metrics = metrics
        tab.view.spacing = metrics.titleSpacing
        tab.view.edgeInsets = NSEdgeInsets(
            top: 0, left: metrics.leadingInset, bottom: 0, right: metrics.trailingInset)
        tab.pinTrailing.constant = -metrics.pinOffset
        tab.titleHeight.constant = metrics.titleHeight
        tab.groupHeight.constant = metrics.tabHeight
    }

    private func reconfigureTabs() {
        for tab in tabSizing {
            if let item = tabItems[tab.id] { configure(tab, for: item) }
        }
    }

    private func configure(_ tab: Tab, for item: WorkspaceTabItem) {
        tabItems[tab.id] = item
        let select = tab.select
        let iconOnly = showsTabIconsOnly || item.tabPinned
        select.title = iconOnly ? "" : item.title
        select.alignment = item.tabPinned ? .center : .left
        (select.cell as? WorkspaceTabButtonCell)?.combinedWindows = iconOnly ? [] : item.combinedWindows
        let image = item.icon ?? (iconOnly ? Self.combinedIcon(item.combinedWindows.compactMap(\.icon)) : nil)
            ?? (iconOnly ? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil) : nil)
        let icon = image?.copy() as? NSImage
        icon?.size = NSSize(width: 16, height: 16)
        select.image = icon
        // A vertical bar keeps its width, so its icons stay where the titles start.
        select.imagePosition = icon == nil ? .noImage
            : item.tabPinned || iconOnly && !tabBarPosition.isVertical ? .imageOnly : .imageLeading
        select.setAccessibilityLabel(iconOnly ? item.title : nil)
        let tabToolTip = item.toolTip ?? item.title
        select.toolTip = tabToolTip
        tab.view.toolTip = tabToolTip
        select.font = .systemFont(ofSize: 12, weight: item.selected ? .semibold : .regular)
        select.setAccessibilityValue(item.selected ? L("操作対象") : (item.displayed ? L("分割表示中") : L("未選択")))
        let closeTitle = closesWindowsOnRelease ? L("ウィンドウを閉じる") : L("元の位置に戻してタブから解除")
        // Assigning NSButton.title again would switch its cell out of image-only mode.
        tab.close.toolTip = closeTitle
        tab.close.setAccessibilityLabel(closeTitle)
        tab.close.isHidden = item.tabPinned
        let showsPin = item.pinned
        tab.pin.isHidden = !showsPin
        tab.pin.toolTip = L("固定中")
        tab.pin.setAccessibilityLabel(L("固定中"))
        select.hasPinBadge = showsPin
        select.showsAudioIndicator = item.playingAudio
        select.shortcutNumber = item.shortcutNumber
        tab.view.setSelectedAppearance(item.selected)
        tab.view.isTabPinned = item.tabPinned
        tab.view.layer?.borderWidth = item.tabSwitchTarget ? 2 : (item.tabPinned ? 1.5 : item.displayed ? 1 : 0)
        tab.view.layer?.borderColor = (item.tabPinned ? NSColor.systemOrange : NSColor.controlAccentColor)
            .withAlphaComponent(item.tabSwitchTarget ? 0.9 : 0.6).cgColor
    }

    /// The icons of a combined tab's windows merged into one tab icon, for tabs that show only icons.
    private static func combinedIcon(_ icons: [NSImage]) -> NSImage? {
        guard icons.count > 1 else { return icons.first }
        let shown = Array(icons.prefix(4))
        return NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            let frames = shown.count == 2
                ? [NSRect(x: 0, y: 5, width: 11, height: 11), NSRect(x: 5, y: 0, width: 11, height: 11)]
                : shown.indices.map {
                    NSRect(x: CGFloat($0 % 2) * 8, y: CGFloat(1 - $0 / 2) * 8, width: 8, height: 8)
                }
            for (icon, frame) in zip(shown, frames) {
                icon.draw(in: frame)
            }
            return true
        }
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
