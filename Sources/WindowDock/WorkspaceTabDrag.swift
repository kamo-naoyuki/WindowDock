import AppKit
import WindowDockCore

let workspaceTabDragType = NSPasteboard.PasteboardType("local.windowdock.tab-move")

private extension NSDraggingInfo {
    var tabDragScreenPoint: NSPoint? {
        draggingDestinationWindow?.convertPoint(toScreen: draggingLocation)
    }
}

final class WorkspaceTabGroup: NSStackView {
    var isFloating = false
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        isFloating ? nil : super.hitTest(point)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsTabDrop?(sender.draggingPasteboard, sender.draggingSource as? NSButton) == true,
              let screenPoint = sender.tabDragScreenPoint else { return [] }
        _ = updateTabDrop?(sender.draggingPasteboard, sender.draggingSource as? NSButton, screenPoint)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsTabDrop?(sender.draggingPasteboard, sender.draggingSource as? NSButton) == true,
              let screenPoint = sender.tabDragScreenPoint else { return [] }
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
            if next.type == .leftMouseDragged && hypot(screenPoint.x - startScreen.x, screenPoint.y - startScreen.y) >= 4 {
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
            (title as NSString).draw(in: dragView.bounds.insetBy(dx: 5, dy: 5), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.white
            ])
            image.unlockFocus()
        }
        onDragBegin?(self, token, anchor, image)
        var point = initialScreenPoint
        var cancelled = true
        onDragMove?(board, point)
        while true {
            guard let event = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                until: Date(timeIntervalSinceNow: 0.05), inMode: .eventTracking, dequeue: true
            ) else {
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
              let screenPoint = sender.tabDragScreenPoint else { return [] }
        _ = updateTabDrop?(sender.draggingPasteboard, sender.draggingSource as? NSButton, screenPoint)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsTabDrop?(sender.draggingPasteboard, sender.draggingSource as? NSButton) == true,
              let screenPoint = sender.tabDragScreenPoint else { return [] }
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
            .foregroundColor: NSColor.labelColor
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard chrome?.acceptsTabDrag(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton) == true,
              let screenPoint = sender.tabDragScreenPoint else { return [] }
        _ = chrome?.updateFloatingTab(pasteboard: sender.draggingPasteboard,
                                      source: sender.draggingSource as? NSButton,
                                      screenPoint: screenPoint)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard chrome?.acceptsTabDrag(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton) == true,
              let screenPoint = sender.tabDragScreenPoint else { return [] }
        _ = chrome?.updateFloatingTab(pasteboard: sender.draggingPasteboard,
                                      source: sender.draggingSource as? NSButton,
                                      screenPoint: screenPoint)
        return .move
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        chrome?.acceptsTabDrag(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton) == true
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        chrome?.dismissPaneDropOverlay(self)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        chrome?.performTabDrop(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton, cell: cellIndex) == true
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
        if let destination, destination !== revealed {
            revealed = destination
            reveal(destination)
        }
        // Resolve overlaps before showing (and raising) any pane overlay.
        (destination ?? drag.source).previewTabTransfer(pasteboard: pasteboard, source: button, at: point)
    }

    private func accepts(_ controller: WorkspaceController, token: String, button: NSButton?) -> Bool {
        guard let drag else { return false }
        return drag.source !== controller && drag.token == token && drag.button === button
    }

    private func drop(on destination: WorkspaceController, token: String, button: NSButton?, index: Int?, cell: Int?) -> Bool {
        guard let drag, accepts(destination, token: token, button: button) else { return false }
        // The source's floating tab must be gone before the transfer re-renders its tabs.
        hideTargets()
        guard drag.source.session.transferWindow(drag.id, to: destination.session, at: index, cell: cell) else { return false }
        transferred = true
        revealed = destination
        onTransfer(drag.source, destination)
        reveal(destination)
        destination.makeKeyAfterReveal()
        return true
    }

    private func end(token: String, pasteboard: NSPasteboard, at point: NSPoint, cancelled: Bool) {
        guard let drag, drag.token == token else { return }
        if !cancelled, drag.source.acceptsWindowDrag, let destination = self.destination(at: point, from: drag.source) {
            _ = destination.completeTabDrop(pasteboard: pasteboard, source: drag.button, at: point)
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
            destinationFrames: candidates.map { $0.window.frame }, destinationsInFront: destinationsInFront ?? 0
        ) {
        case .none: return nil
        case .source: return source
        case .transfer(let index): return candidates[index]
        }
    }
}
