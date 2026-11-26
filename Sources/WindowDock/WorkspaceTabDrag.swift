import AppKit
import WindowDockCore

let workspaceTabDragType = NSPasteboard.PasteboardType("local.windowdock.tab-move")

enum TabOutsideDropAction: String, CaseIterable {
    case release
    case newWorkspace
    case nothing

    var title: String {
        switch self {
        case .release: L("タブを解除")
        case .newWorkspace: L("ワークスペースを作成")
        case .nothing: L("何もしない")
        }
    }
}

@MainActor
final class TabOutsideDropSettings: NSObject {
    private static let key = "tabOutsideDropAction"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var action: TabOutsideDropAction {
        guard let value = defaults.string(forKey: Self.key) else { return .release }
        guard let action = TabOutsideDropAction(rawValue: value) else {
            WindowAccess.logger.error("Invalid tab outside drop action: \(value, privacy: .public)")
            return .release
        }
        return action
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        for action in TabOutsideDropAction.allCases {
            let item = menu.addItem(withTitle: action.title, action: #selector(selectAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            item.state = action == self.action ? .on : .off
        }
        return menu
    }

    @objc private func selectAction(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, TabOutsideDropAction(rawValue: value) != nil else {
            WindowAccess.logger.error("Invalid tab outside drop menu selection")
            return
        }
        defaults.set(value, forKey: Self.key)
    }
}

extension NSDraggingInfo {
    fileprivate var tabDragScreenPoint: NSPoint? {
        draggingDestinationWindow?.convertPoint(toScreen: draggingLocation)
    }
}

private extension NSView {
    func trackTabHover() {
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
}

final class WorkspaceTabCloseButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        trackTabHover()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseEntered(with event: NSEvent) {
        guard (superview as? WorkspaceTabGroup)?.isFloating != true else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.30).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        // The pointer may still be inside the tab; don't forward this button's exit to the group's responder.
        layer?.backgroundColor = nil
    }
}

final class WorkspaceTabGroup: NSStackView {
    var isFloating = false {
        didSet { if isFloating { hovered = false } }
    }
    private var selected: Bool?
    private var hovered = false {
        didSet { if oldValue != hovered { updateBackground() } }
    }
    var acceptsTabDrop: ((NSPasteboard, NSButton?) -> Bool)?
    var updateTabDrop: ((NSPasteboard, NSButton?, NSPoint) -> Bool)?
    var performTabDrop: ((NSPasteboard, NSButton?, NSPoint) -> Bool)?

    init(views: [NSView]) {
        super.init(frame: .zero)
        views.forEach(addArrangedSubview)
        registerForDraggedTypes([workspaceTabDragType])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([workspaceTabDragType])
    }

    func setSelectedAppearance(_ value: Bool) {
        if selected == nil {
            trackTabHover()
        }
        selected = value
        updateBackground()
    }

    override func mouseEntered(with event: NSEvent) {
        if !isFloating { hovered = true }
    }

    override func mouseExited(with event: NSEvent) { hovered = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        guard let selected else { return } // Drop previews have their own appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = selected ? NSColor.controlBackgroundColor
                : NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.35)
            let color = hovered ? base.blended(withFraction: 0.13, of: .controlAccentColor) ?? base : base
            layer?.backgroundColor = color.cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isFloating ? nil : super.hitTest(point)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsTabDrop?(sender.draggingPasteboard, sender.draggingSource as? NSButton) == true,
              let screenPoint = sender.tabDragScreenPoint
        else { return [] }
        _ = updateTabDrop?(sender.draggingPasteboard, sender.draggingSource as? NSButton, screenPoint)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsTabDrop?(sender.draggingPasteboard, sender.draggingSource as? NSButton) == true,
              let screenPoint = sender.tabDragScreenPoint
        else { return [] }
        _ = updateTabDrop?(sender.draggingPasteboard, sender.draggingSource as? NSButton, screenPoint)
        return .move
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptsTabDrop?(sender.draggingPasteboard, sender.draggingSource as? NSButton) == true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let screenPoint = sender.tabDragScreenPoint else { return false }
        return performTabDrop?(sender.draggingPasteboard, sender.draggingSource as? NSButton, screenPoint) == true
    }
}

/// Keeps the title and image clear of indicators drawn over the button's trailing edge.
final class WorkspaceTabButtonCell: NSButtonCell {
    var trailingInset: CGFloat = 0

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        var frame = cellFrame
        frame.size.width = max(0, frame.width - trailingInset)
        super.drawInterior(withFrame: frame, in: controlView)
    }

    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        // Beside an indicator, a title without room for its ellipsis would leave just a sliver of a glyph.
        if trailingInset > 0, frame.width < title.size().width {
            let ellipsis = NSAttributedString(
                string: "…", attributes: title.length > 0 ? title.attributes(at: 0, effectiveRange: nil) : [:]
            )
            if frame.width < ellipsis.size().width { return .zero }
        }
        return super.drawTitle(title, withFrame: frame, in: controlView)
    }
}

/// Draws over a tab without taking its clicks or drags.
private final class WorkspaceTabIndicatorView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Tracks internal tab drags without requiring the destination to be the frontmost native window.
final class WorkspaceTabButton: NSButton {
    weak var chrome: WorkspaceChromeView?
    var onDragBegin: ((WorkspaceTabButton, String, NSPoint, NSImage) -> Void)?
    var onDragMove: ((NSPasteboard, NSPoint) -> Void)?
    var onDragEnd: ((NSPasteboard, NSPoint, Bool) -> Void)?
    var makeContextMenu: (() -> NSMenu)?
    var acceptsTabDrop: ((NSPasteboard, NSButton?) -> Bool)?
    var updateTabDrop: ((NSPasteboard, NSButton?, NSPoint) -> Bool)?
    var performTabDrop: ((NSPasteboard, NSButton?, NSPoint) -> Bool)?
    /// Shows a speaker at the trailing edge, like browser tabs playing audio.
    var showsAudioIndicator = false {
        didSet { if showsAudioIndicator != oldValue { updateAudioIndicator() } }
    }
    /// Whether the tab's pin badge covers the button's top trailing corner; the speaker moves clear of it.
    var hasPinBadge = false {
        didSet { if hasPinBadge != oldValue { updateAudioIndicator() } }
    }
    private(set) var audioIndicator: NSImageView?

    override class var cellClass: AnyClass? {
        get { WorkspaceTabButtonCell.self }
        set {}
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateAudioIndicator()
    }

    private func updateAudioIndicator() {
        let pinWidth: CGFloat = hasPinBadge ? 14 : 0
        // A narrow tab keeps its application icon instead.
        let visible = showsAudioIndicator && bounds.width >= 36 + pinWidth
        if visible, audioIndicator == nil {
            let indicator = WorkspaceTabIndicatorView()
            indicator.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
            indicator.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            indicator.imageScaling = .scaleProportionallyDown
            indicator.contentTintColor = .secondaryLabelColor
            indicator.setAccessibilityElement(false)
            addSubview(indicator)
            audioIndicator = indicator
        }
        audioIndicator?.isHidden = !visible
        audioIndicator?.frame = NSRect(x: bounds.maxX - pinWidth - 17, y: (bounds.height - 16) / 2,
                                       width: 16, height: 16)
        let inset = visible ? pinWidth + 20 : 0
        if let cell = cell as? WorkspaceTabButtonCell, cell.trailingInset != inset {
            cell.trailingInset = inset
            needsDisplay = true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeContextMenu?() }

    // Like browser tabs, a tab of an inactive workspace can be chosen or dragged with the first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let start = convert(event.locationInWindow, from: nil)
        guard let window else { return }
        let startScreen = window.convertPoint(toScreen: event.locationInWindow)
        highlight(true)
        while let next = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture, inMode: .eventTracking, dequeue: true
        ) {
            let screenPoint = tabScreenPoint(for: next)
            let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
            if next.type == .leftMouseDragged
                && hypot(screenPoint.x - startScreen.x, screenPoint.y - startScreen.y) >= 4
            {
                highlight(false)
                trackTabDrag(anchor: start, initialScreenPoint: screenPoint)
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

    private func tabScreenPoint(for event: NSEvent) -> NSPoint {
        if let location = event.cgEvent?.location, let screen = NSScreen.screens.first {
            return NSPoint(x: location.x, y: screen.frame.maxY - location.y)
        }
        return window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    private func trackTabDrag(anchor: NSPoint, initialScreenPoint: NSPoint) {
        let token = UUID().uuidString
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString(token, forType: workspaceTabDragType)
        let dragView = superview ?? self
        let image = NSImage(size: dragView.bounds.size)
        if let bitmap = dragView.bitmapImageRepForCachingDisplay(in: dragView.bounds) {
            dragView.cacheDisplay(in: dragView.bounds, to: bitmap)
            image.addRepresentation(bitmap)
        } else {
            image.lockFocus()
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: dragView.bounds, xRadius: 5, yRadius: 5).fill()
            (title as NSString).draw(
                in: dragView.bounds.insetBy(dx: 5, dy: 5),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.white,
                ]
            )
            image.unlockFocus()
        }
        onDragBegin?(self, token, anchor, image)
        var point = initialScreenPoint
        var cancelled = true
        onDragMove?(board, point)
        while true {
            guard
                let event = NSApp.nextEvent(
                    matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                    until: Date(timeIntervalSinceNow: 0.05), inMode: .eventTracking, dequeue: true
                )
            else {
                // Bringing a workspace forward activates another app, which must not leave the drag without its
                // mouse-up, so follow the pointer directly while no events arrive.
                let released = NSEvent.pressedMouseButtons & 1 == 0
                if released || NSEvent.mouseLocation != point {
                    point = NSEvent.mouseLocation
                    onDragMove?(board, point)
                }
                if released {
                    cancelled = false
                    break
                }
                continue
            }
            if event.type == .keyDown {
                if event.keyCode == 53 { break }
                continue
            }
            point = tabScreenPoint(for: event)
            onDragMove?(board, point)
            if event.type == .leftMouseUp {
                cancelled = false
                break
            }
        }
        onDragEnd?(board, point, cancelled)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsTabDrop?(sender.draggingPasteboard, sender.draggingSource as? NSButton) == true,
              let screenPoint = sender.tabDragScreenPoint
        else { return [] }
        _ = updateTabDrop?(sender.draggingPasteboard, sender.draggingSource as? NSButton, screenPoint)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsTabDrop?(sender.draggingPasteboard, sender.draggingSource as? NSButton) == true,
              let screenPoint = sender.tabDragScreenPoint
        else { return [] }
        _ = updateTabDrop?(sender.draggingPasteboard, sender.draggingSource as? NSButton, screenPoint)
        return .move
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptsTabDrop?(sender.draggingPasteboard, sender.draggingSource as? NSButton) == true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let screenPoint = sender.tabDragScreenPoint else { return false }
        return performTabDrop?(sender.draggingPasteboard, sender.draggingSource as? NSButton, screenPoint) == true
    }

}

final class WorkspaceTabMoveItem {
    weak var button: NSButton?
    init(_ button: NSButton) { self.button = button }
}

/// Drop target laid over a pane while a tab is being dragged.
final class WorkspaceTabDropOverlay: NSView {
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
            .foregroundColor: NSColor.labelColor,
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes
        )
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard
            chrome?.acceptsTabDrag(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton)
            == true,
            let screenPoint = sender.tabDragScreenPoint
        else { return [] }
        _ = chrome?.updateFloatingTab(
            pasteboard: sender.draggingPasteboard,
            source: sender.draggingSource as? NSButton,
            screenPoint: screenPoint
        )
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard
            chrome?.acceptsTabDrag(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton)
            == true,
            let screenPoint = sender.tabDragScreenPoint
        else { return [] }
        _ = chrome?.updateFloatingTab(
            pasteboard: sender.draggingPasteboard,
            source: sender.draggingSource as? NSButton,
            screenPoint: screenPoint
        )
        return .move
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        chrome?.acceptsTabDrag(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton)
            == true
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        chrome?.dismissPaneDropOverlay(self)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        chrome?.performTabDrop(
            pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton, cell: cellIndex
        ) == true
    }
}

/// Moves dragged tabs between workspaces. As with browser tabs, the workspace under the pointer comes to the front
/// with its windows, so the user sees where the tab will land instead of only an insertion line.
@MainActor
final class WorkspaceTabTransfer {
    private struct Drag {
        let source: WorkspaceController
        let id: UUID
        let token: String
        let button: NSButton
    }

    private let controllers: () -> [WorkspaceController]
    var orderedWindows: () -> [NSWindow] = { NSApp.orderedWindows }
    var reveal: (WorkspaceController) -> Void = { $0.reveal() }
    var onBegin: () -> Void = {}
    /// Called after a tab moved from the first workspace to the second.
    var onTransfer: (WorkspaceController, WorkspaceController) -> Void = { _, _ in }
    var outsideDropAction: () -> TabOutsideDropAction = { .release }
    var createWorkspace: (NSPoint) -> WorkspaceController? = { _ in nil }
    var discardWorkspace: (WorkspaceController) -> Void = { _ in }
    var onRelease: (WorkspaceController) -> Void = { _ in }

    private var drag: Drag?
    private var revealed: WorkspaceController?
    private var transferred = false

    init(controllers: @escaping () -> [WorkspaceController]) {
        self.controllers = controllers
    }

    var isActive: Bool { drag != nil }

    /// Routes the workspace's tab drags through this coordinator.
    func attach(_ controller: WorkspaceController) {
        controller.onTabDragBegin = { [weak self, weak controller] id, token, button in
            guard let self, let controller else { return }
            self.begin(from: controller, id: id, token: token, button: button)
        }
        controller.onTabDragMove = { [weak self] token, board, button, point in
            self?.move(token: token, pasteboard: board, button: button, at: point)
        }
        controller.acceptsExternalTab = { [weak self, weak controller] token, button in
            guard let self, let controller else { return false }
            return self.accepts(controller, token: token, button: button)
        }
        controller.onExternalTabDrop = { [weak self, weak controller] token, button, index, cell in
            guard let self, let controller else { return false }
            return self.drop(on: controller, token: token, button: button, index: index, cell: cell)
        }
        controller.onTabDragEnd = { [weak self] token, board, point, cancelled in
            self?.end(token: token, pasteboard: board, at: point, cancelled: cancelled)
        }
    }

    private func begin(from source: WorkspaceController, id: UUID, token: String, button: NSButton) {
        clear()
        onBegin()
        drag = Drag(source: source, id: id, token: token, button: button)
        revealed = source
    }

    private func move(token: String, pasteboard: NSPasteboard, button: NSButton, at point: NSPoint) {
        guard let drag, drag.token == token, drag.button === button else { return }
        let destination = self.destination(at: point, from: drag.source)
        let target = destination === drag.source ? nil : destination
        for controller in controllers() where controller !== target {
            controller.hideTabTransferTargets()
        }
        let visibleWorkspace = destination ?? (drag.source.window.frame.contains(point) ? drag.source : nil)
        if let visibleWorkspace, visibleWorkspace !== revealed {
            revealed = visibleWorkspace
            reveal(visibleWorkspace)
        }
        // Resolve overlaps before showing (and raising) any pane overlay.
        (destination ?? drag.source).previewTabTransfer(pasteboard: pasteboard, source: button, at: point)
    }

    private func accepts(_ controller: WorkspaceController, token: String, button: NSButton?) -> Bool {
        guard let drag else { return false }
        return drag.source !== controller && drag.token == token && drag.button === button
    }

    private func drop(on destination: WorkspaceController, token: String, button: NSButton?, index: Int?, cell: Int?)
        -> Bool
    {
        guard let drag, accepts(destination, token: token, button: button) else { return false }
        // The source's floating tab must be gone before the transfer re-renders its tabs.
        hideTargets()
        guard drag.source.session.transferWindow(drag.id, to: destination.session, at: index, cell: cell) else {
            return false
        }
        transferred = true
        revealed = destination
        onTransfer(drag.source, destination)
        reveal(destination)
        destination.makeKeyAfterReveal()
        return true
    }

    private func end(token: String, pasteboard: NSPasteboard, at point: NSPoint, cancelled: Bool) {
        guard let drag, drag.token == token else { return }
        if !cancelled, drag.source.acceptsWindowDrag {
            if let destination = self.destination(at: point, from: drag.source) {
                _ = destination.completeTabDrop(pasteboard: pasteboard, source: drag.button, at: point)
            } else if drag.source.session.tabIDs.contains(drag.id) {
                hideTargets()
                switch outsideDropAction() {
                case .release:
                    if drag.source.session.remove(drag.id),
                       !drag.source.session.tabIDs.contains(drag.id)
                    {
                        onRelease(drag.source)
                    }
                case .newWorkspace:
                    if let destination = createWorkspace(point) {
                        if drag.source.session.transferWindow(drag.id, to: destination.session) {
                            transferred = true
                            revealed = destination
                            onTransfer(drag.source, destination)
                            reveal(destination)
                            destination.makeKeyAfterReveal()
                        } else {
                            discardWorkspace(destination)
                        }
                    } else {
                        WindowAccess.logger.error("Could not create a workspace for the dropped tab")
                        drag.source.showNotice(.attention(L("タブを移動できませんでした。移動先と対象ウィンドウを確認してください。")))
                    }
                case .nothing:
                    break
                }
            }
        }
        // The tab stayed in its workspace, so bring that workspace back in front of those it passed over.
        let restoresSource = !transferred && revealed !== drag.source
        clear()
        if restoresSource { reveal(drag.source) }
    }

    func clear() {
        hideTargets()
        drag = nil
        revealed = nil
        transferred = false
    }

    private func hideTargets() {
        drag?.source.endTabTransferDrag()
        controllers().forEach { $0.hideTabTransferTargets() }
    }

    /// The workspace that receives the tab at `point`: the frontmost one there, as the user sees it.
    private func destination(at point: NSPoint, from source: WorkspaceController) -> WorkspaceController? {
        let controllers = controllers()
        var candidates: [WorkspaceController] = []
        var destinationsInFront: Int?
        for window in orderedWindows() {
            if window === source.window {
                destinationsInFront = candidates.count
            } else if let controller = controllers.first(where: {
                $0 !== source && $0.window === window && $0.acceptsWindowDrag
            }) {
                candidates.append(controller)
            }
        }
        switch WorkspaceTabDragRoute.resolve(
            at: point, sourceFrame: source.window.frame, sourceTabRowContains: source.tabRowContains(point),
            sourceHasMultiplePanes: source.session.isSplit,
            destinationFrames: candidates.map { $0.window.frame }, destinationsInFront: destinationsInFront ?? 0
        ) {
        case .none: return nil
        case .source: return source
        case .transfer(let index): return candidates[index]
        }
    }
}
