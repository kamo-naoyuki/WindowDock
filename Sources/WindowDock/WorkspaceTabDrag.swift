import AppKit

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
        while let event = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
            until: .distantFuture, inMode: .eventTracking, dequeue: true
        ) {
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

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        chrome?.performTabDrop(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton, cell: cellIndex) == true
    }
}
