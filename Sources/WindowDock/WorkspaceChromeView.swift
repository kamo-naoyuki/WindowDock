import AppKit
import QuartzCore

private let workspaceTabDragType = NSPasteboard.PasteboardType("local.windowdock.tab-move")

private final class WorkspaceTabButton: NSButton, NSDraggingSource {
    var onDragBegin: ((WorkspaceTabButton, String) -> Void)?
    var onDragEnd: (() -> Void)?
    var makeContextMenu: (() -> NSMenu)?

    override func menu(for event: NSEvent) -> NSMenu? { makeContextMenu?() }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let start = convert(event.locationInWindow, from: nil)
        highlight(true)
        while let next = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture, inMode: .eventTracking, dequeue: true
        ) {
            let point = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseDragged && hypot(point.x - start.x, point.y - start.y) >= 4 {
                highlight(false)
                let token = UUID().uuidString
                let item = NSPasteboardItem()
                item.setString(token, forType: workspaceTabDragType)
                let draggingItem = NSDraggingItem(pasteboardWriter: item)
                let image = NSImage(size: bounds.size)
                image.lockFocus()
                NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
                (title as NSString).draw(in: bounds.insetBy(dx: 5, dy: 5), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.white
                ])
                image.unlockFocus()
                draggingItem.setDraggingFrame(bounds, contents: image)
                onDragBegin?(self, token)
                beginDraggingSession(with: [draggingItem], event: next, source: self)
                return
            }
            if next.type == .leftMouseUp {
                highlight(false)
                if bounds.contains(point) { performClick(nil) }
                return
            }
            highlight(bounds.contains(point))
        }
        highlight(false)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnd?()
    }
}

private final class WorkspaceTabMoveItem {
    weak var button: NSButton?
    init(_ button: NSButton) { self.button = button }
}

private final class WorkspaceTabDropOverlay: NSView {
    weak var chrome: WorkspaceChromeView?
    let cellIndex: Int

    init(chrome: WorkspaceChromeView, cellIndex: Int, frame: NSRect) {
        self.chrome = chrome
        self.cellIndex = cellIndex
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        registerForDraggedTypes([workspaceTabDragType])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.blended(withFraction: 0.3, of: .controlAccentColor)?.setFill()
        bounds.fill()
        let title = L("ここに移動 / 入れ替え") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        chrome?.acceptsTabDrag(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton) == true ? .move : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        chrome?.acceptsTabDrag(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton) == true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        chrome?.performTabDrop(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton, cell: cellIndex) == true
    }
}

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

final class WorkspaceChromeView: WorkspaceBackgroundView {
    let tabs = NSStackView()
    let stage = WorkspaceGridView(frame: .zero)
    var gridSize: WorkspaceGridSize { stage.gridSize }
    var gridAreas: [NSView] { stage.areas }
    var onGridChange: ((WorkspaceGridSize) -> Void)?
    var onActivateCell: ((Int) -> Void)?
    var onPaneLayoutChange: (() -> Void)?
    var onMoveTab: ((Int, Int) -> Void)?
    let closeButton = makeButton(symbol: "xmark.circle.fill", title: L("閉じる"), width: 18)
    let minimizeButton = makeButton(symbol: "minus.circle.fill", title: L("最小化"), width: 18)
    let maximizeButton = makeButton(symbol: "arrow.up.left.and.arrow.down.right.circle.fill", title: L("最大化 / 復元"), width: 18)
    let addButton = makeButton(symbol: "plus", title: L("ウィンドウを追加"), width: 26)
    let permissionButton = makeButton(symbol: "gearshape", title: L("権限設定"), width: 26)
    let columnSelector = NSPopUpButton(frame: .zero, pullsDown: false)
    let rowSelector = NSPopUpButton(frame: .zero, pullsDown: false)
    private var toolbar: NSView!
    private var hasManagedWindows = false
    private var settingGrid = false
    private weak var dragSource: NSButton?
    private var dragToken: String?
    private var dragOverlays: [NSView] = []
    private(set) var windowDropPanel: NSPanel?
    private var windowDropLabel: NSTextField?

    private let tabScroll = NSScrollView()
    private let notice = NSTextField(labelWithString: "")
    private let empty = WorkspaceEmptyLabel(wrappingLabelWithString: L("別のウィンドウをここへ移動して離す\nまたは、上の ＋ から追加\n\n異なるアプリをタブで切り替えられます。"))
    private var noticeHeight: NSLayoutConstraint!
    private var maximumTabWidth: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    deinit { windowDropPanel?.close() }

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

    private func build() {
        closeButton.contentTintColor = .systemRed
        minimizeButton.contentTintColor = .systemYellow
        maximizeButton.contentTintColor = .systemGreen
        maximizeButton.toolTip = L("最大化 / 復元（空き領域のダブルクリックでも切替）")
        let controls = NSStackView(views: [closeButton, minimizeButton, maximizeButton])
        controls.spacing = 4
        controls.setHuggingPriority(.required, for: .horizontal)
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
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor),
            tabs.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor),
            tabs.heightAnchor.constraint(equalToConstant: 32),
            tabScroll.heightAnchor.constraint(equalToConstant: 32),
            tabScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            maximumTabWidth
        ])
        let dragSpace = NSView()
        dragSpace.widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        dragSpace.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let preferredDragWidth = dragSpace.widthAnchor.constraint(equalToConstant: 30)
        preferredDragWidth.priority = .defaultLow
        preferredDragWidth.isActive = true
        dragSpace.toolTip = L("ドラッグして移動 / ダブルクリックで最大化")
        configureSelector(columnSelector, prefix: L("横"))
        configureSelector(rowSelector, prefix: L("縦"))
        let bar = NSStackView(views: [controls, tabScroll, addButton, dragSpace, columnSelector, rowSelector, permissionButton])
        toolbar = bar
        bar.spacing = 4
        bar.alignment = .centerY
        bar.distribution = .fill
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
        for view in [bar, notice, stage] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        noticeHeight = notice.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.heightAnchor.constraint(equalToConstant: 34),
            notice.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 1),
            notice.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            notice.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            noticeHeight,
            stage.topAnchor.constraint(equalTo: notice.bottomAnchor),
            stage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            stage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            stage.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            empty.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: stage.widthAnchor, constant: -24)
        ])
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
        let point = convert(window.convertFromScreen(NSRect(origin: screenPoint, size: .zero)).origin, from: nil)
        return convert(toolbar.bounds, from: toolbar).contains(point) ||
            (!hasManagedWindows && convert(stage.bounds, from: stage).contains(point))
    }

    func showWindowDropTarget(hovered: Bool, requiresPermission: Bool) {
        guard let window else { return }
        let frame = window.convertToScreen(toolbar.convert(toolbar.bounds, to: nil))
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
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .white
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(origin: .zero, size: frame.size).insetBy(dx: 8, dy: 6)
            label.autoresizingMask = [.width, .height]
            panel.contentView?.addSubview(label)
            windowDropPanel = panel
            windowDropLabel = label
        }
        windowDropLabel?.stringValue = requiresPermission
            ? L("追加にはアクセシビリティの許可が必要です")
            : hovered ? L("ここで離すとタブに追加") : L("この帯へ移動して離すとタブに追加")
        let color: NSColor = requiresPermission ? .systemOrange : hovered ? .controlAccentColor : .systemGray
        windowDropPanel?.backgroundColor = color.withAlphaComponent(0.96)
        windowDropPanel?.setFrame(frame, display: true)
        windowDropPanel?.orderFront(nil)
        addButton.contentTintColor = hovered ? .controlAccentColor : nil
    }

    func hideWindowDropTarget() {
        windowDropPanel?.orderOut(nil)
        addButton.contentTintColor = nil
    }

    func beginTabDrag(source: NSButton, token: String) {
        endTabDrag()
        dragSource = source
        dragToken = token
        dragOverlays = gridAreas.enumerated().map { index, area in
            let overlay = WorkspaceTabDropOverlay(chrome: self, cellIndex: index, frame: area.bounds)
            area.addSubview(overlay)
            return overlay
        }
        layoutSubtreeIfNeeded()
        updateTabDragOverlays()
        window?.orderFront(nil)
        window?.displayIfNeeded()
        CATransaction.flush()
    }

    private func updateTabDragOverlays() {
        for (area, overlay) in zip(gridAreas, dragOverlays) {
            overlay.frame = area.bounds
        }
    }

    func endTabDrag() {
        dragSource = nil
        dragToken = nil
        dragOverlays.forEach { $0.removeFromSuperview() }
        dragOverlays.removeAll()
        refreshCoverage()
    }

    func acceptsTabDrag(pasteboard: NSPasteboard, source: NSButton?) -> Bool {
        guard let dragSource, let dragToken, let source, source === dragSource else { return false }
        return pasteboard.string(forType: workspaceTabDragType) == dragToken
    }

    @discardableResult
    func performTabDrop(pasteboard: NSPasteboard, source: NSButton?, cell: Int) -> Bool {
        guard acceptsTabDrag(pasteboard: pasteboard, source: source),
              gridAreas.indices.contains(cell), let dragSource else { return false }
        let tag = dragSource.tag
        endTabDrag()
        onMoveTab?(tag, cell)
        return true
    }

    private func tabContextMenu(for button: NSButton) -> NSMenu {
        let menu = NSMenu()
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
        return menu
    }

    @objc private func moveTabFromMenu(_ item: NSMenuItem) {
        guard let button = (item.representedObject as? WorkspaceTabMoveItem)?.button,
              gridAreas.indices.contains(item.tag) else { return }
        onMoveTab?(button.tag, item.tag)
    }

    func clearTabs() {
        endTabDrag()
        for view in tabs.arrangedSubviews {
            tabs.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        maximumTabWidth.constant = 0
        tabScroll.isHidden = true
        tabScroll.contentView.scroll(to: .zero)
    }

    @discardableResult
    func appendTab(title: String, selected: Bool, displayed: Bool = false) -> (view: NSView, select: NSButton, close: NSButton) {
        let select = WorkspaceTabButton(title: title, target: nil, action: nil)
        select.onDragBegin = { [weak self] button, token in self?.beginTabDrag(source: button, token: token) }
        select.onDragEnd = { [weak self] in self?.endTabDrag() }
        select.makeContextMenu = { [weak self, weak select] in
            guard let self, let select else { return NSMenu() }
            return self.tabContextMenu(for: select)
        }
        select.isBordered = false
        select.font = .systemFont(ofSize: 12, weight: selected ? .semibold : .regular)
        select.lineBreakMode = .byTruncatingTail
        select.toolTip = title
        select.setAccessibilityValue(selected ? L("操作対象") : (displayed ? L("分割表示中") : L("未選択")))
        let close = Self.makeButton(symbol: "xmark", title: L("元の位置に戻してタブから解除"), width: 18)
        let group = NSStackView(views: [select, close])
        group.spacing = 4
        group.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 4)
        group.wantsLayer = true
        group.layer?.cornerRadius = 7
        group.layer?.borderWidth = displayed ? 1 : 0
        group.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        group.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        group.layer?.backgroundColor = (selected ? NSColor.controlBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.35)).cgColor
        NSLayoutConstraint.activate([
            select.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),
            select.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            select.heightAnchor.constraint(equalToConstant: 28),
            group.heightAnchor.constraint(equalToConstant: 32)
        ])
        tabs.addArrangedSubview(group)
        maximumTabWidth.constant = tabs.fittingSize.width
        tabScroll.isHidden = false
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
        return changed
    }
}
