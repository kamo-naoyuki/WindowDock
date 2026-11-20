import AppKit

let workspaceTabDragType = NSPasteboard.PasteboardType("local.windowdock.tab-move")

/// Tab button that distinguishes click from drag and starts a tab-move drag session.
final class WorkspaceTabButton: NSButton, NSDraggingSource {
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
        chrome?.acceptsTabDrag(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton) == true ? .move : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        chrome?.acceptsTabDrag(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton) == true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        chrome?.performTabDrop(pasteboard: sender.draggingPasteboard, source: sender.draggingSource as? NSButton, cell: cellIndex) == true
    }
}
