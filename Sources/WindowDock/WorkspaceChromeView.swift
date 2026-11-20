import AppKit
import QuartzCore

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
    var onSwapTabs: ((Int, Int) -> Void)?
    var onCloseTabs: ((Range<Int>) -> Void)?
    let addButton = makeButton(symbol: "plus", title: L("ウィンドウを追加"), width: 26)
    let permissionButton = makeButton(symbol: "gearshape", title: L("権限設定"), width: 26)
    let columnSelector = NSPopUpButton(frame: .zero, pullsDown: false)
    let rowSelector = NSPopUpButton(frame: .zero, pullsDown: false)
    let workspaceButton = NSButton(title: "", target: nil, action: nil)
    var workspaceMenu: (() -> NSMenu)?
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
    private var noticeCollapse: DispatchWorkItem?
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

    @objc private func showWorkspaceMenu() {
        workspaceMenu?().popUp(positioning: nil, at: NSPoint(x: 0, y: workspaceButton.bounds.height), in: workspaceButton)
    }

    private func build() {
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
        workspaceButton.isBordered = false
        workspaceButton.font = .boldSystemFont(ofSize: 12)
        workspaceButton.contentTintColor = .secondaryLabelColor
        workspaceButton.lineBreakMode = .byTruncatingTail
        workspaceButton.alignment = .left
        workspaceButton.toolTip = L("ワークスペースの操作")
        workspaceButton.target = self
        workspaceButton.action = #selector(showWorkspaceMenu)
        workspaceButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        workspaceButton.widthAnchor.constraint(lessThanOrEqualToConstant: 160).isActive = true
        let bar = NSStackView(views: [controls, workspaceButton, tabScroll, addButton, dragSpace, columnSelector, rowSelector, permissionButton])
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
        watchTabDrag(token: token)
    }

    /// The drag session's end callback can be lost (e.g. the source tab is re-rendered); never leave the overlays covering the panes.
    private func watchTabDrag(token: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.dragToken == token else { return }
            if NSEvent.pressedMouseButtons & 1 == 0 {
                self.endTabDrag()
            } else {
                self.watchTabDrag(token: token)
            }
        }
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

    @discardableResult
    func performTabSwap(pasteboard: NSPasteboard, source: NSButton?, target: NSButton) -> Bool {
        guard acceptsTabDrag(pasteboard: pasteboard, source: source),
              let dragSource, dragSource !== target else { return false }
        let sourceTag = dragSource.tag
        let targetTag = target.tag
        endTabDrag()
        onSwapTabs?(sourceTag, targetTag)
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
        menu.addItem(.separator())
        let count = tabs.arrangedSubviews.count
        let closers: [(String, Range<Int>)] = [
            ("閉じる", button.tag..<button.tag + 1),
            ("すべて閉じる", 0..<count),
            ("右側のタブを閉じる", min(button.tag + 1, count)..<count),
            ("左側のタブを閉じる", 0..<min(button.tag, count))
        ]
        for (title, range) in closers {
            let item = NSMenuItem(title: L(title), action: range.isEmpty ? nil : #selector(closeTabsFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = RangeBox(range)
            menu.addItem(item)
        }
        return menu
    }

    private final class RangeBox: NSObject {
        let range: Range<Int>
        init(_ range: Range<Int>) { self.range = range }
    }

    @objc private func closeTabsFromMenu(_ item: NSMenuItem) {
        guard let range = (item.representedObject as? RangeBox)?.range else { return }
        onCloseTabs?(range)
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
    func appendTab(title: String, icon: NSImage? = nil, selected: Bool, displayed: Bool = false) -> (view: NSView, select: NSButton, close: NSButton) {
        let select = WorkspaceTabButton(title: title, target: nil, action: nil)
        select.onDragBegin = { [weak self] button, token in self?.beginTabDrag(source: button, token: token) }
        select.onDragEnd = { [weak self] in self?.endTabDrag() }
        select.registerForDraggedTypes([workspaceTabDragType])
        select.acceptsTabDrop = { [weak self] pasteboard, source in
            self?.acceptsTabDrag(pasteboard: pasteboard, source: source) == true
        }
        select.performTabDrop = { [weak self, weak select] pasteboard, source in
            guard let self, let select else { return false }
            return self.performTabSwap(pasteboard: pasteboard, source: source, target: select)
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
        // Collapse only after a delay: resizing the stage re-triggers a sync that can toggle the notice again (flicker loop).
        noticeCollapse?.cancel()
        noticeCollapse = nil
        let height: CGFloat = message.needsAttention ? 22 : noticeHeight.constant
        let changed = noticeHeight.constant != height
        notice.stringValue = message.text
        notice.toolTip = message.text
        notice.isHidden = !message.needsAttention
        if changed {
            noticeHeight.constant = height
            needsLayout = true
        }
        if !message.needsAttention, noticeHeight.constant != 0 {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.notice.isHidden, self.noticeHeight.constant != 0 else { return }
                self.noticeHeight.constant = 0
                self.needsLayout = true
            }
            noticeCollapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
        permissionButton.toolTip = L("権限設定\n%@", message.text)
        permissionButton.contentTintColor = message.needsAttention ? .systemOrange : .secondaryLabelColor
        return changed
    }
}
