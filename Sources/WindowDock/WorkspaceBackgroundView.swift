import AppKit
import QuartzCore

struct WorkspaceResizeEdges: OptionSet {
    let rawValue: Int
    static let left = Self(rawValue: 1 << 0)
    static let right = Self(rawValue: 1 << 1)
    static let bottom = Self(rawValue: 1 << 2)
    static let top = Self(rawValue: 1 << 3)
}

final class WorkspaceWindow: NSWindow {
    private(set) var isApplyingWorkspaceFrame = false
    var onWorkspaceFrameChange: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func toggleMaximize() { zoom(nil) }

    func setWorkspaceFrame(_ frame: NSRect) {
        guard frame != self.frame else { return }
        let workspace = contentView as? WorkspaceBackgroundView
        workspace?.prepareForFrameChange(to: frame)
        isApplyingWorkspaceFrame = true
        defer {
            isApplyingWorkspaceFrame = false
            workspace?.finishFrameChange()
        }
        setFrame(frame, display: true)
        onWorkspaceFrameChange?()
    }

    static func resizedFrame(
        from frame: NSRect,
        delta: NSSize,
        edges: WorkspaceResizeEdges,
        minimumSize: NSSize
    ) -> NSRect {
        var result = frame
        if edges.contains(.left) {
            result.size.width = max(minimumSize.width, frame.width - delta.width)
            result.origin.x = frame.maxX - result.width
        } else if edges.contains(.right) {
            result.size.width = max(minimumSize.width, frame.width + delta.width)
        }
        if edges.contains(.bottom) {
            result.size.height = max(minimumSize.height, frame.height - delta.height)
            result.origin.y = frame.maxY - result.height
        } else if edges.contains(.top) {
            result.size.height = max(minimumSize.height, frame.height + delta.height)
        }
        return result
    }
}

class WorkspaceBackgroundView: NSView {
    weak var contentArea: NSView?
    weak var secondaryContentArea: NSView?
    var gridContentAreas: [NSView] = [] { didSet { needsDisplay = true } }
    var gridCoveredScreenRects: [Int: NSRect] = [:] { didSet { needsDisplay = true } }
    var coveredScreenRect: NSRect? {
        didSet { needsDisplay = true }
    }
    var secondaryCoveredScreenRect: NSRect? {
        didSet { needsDisplay = true }
    }
    var revealsWindow = false {
        didSet { needsDisplay = true }
    }
    private var transitionClips: [NSRect]?

    private var resizeGrip: NSRect {
        NSRect(x: bounds.maxX - 18, y: bounds.minY, width: 18, height: 18)
    }

    private var visibleContentRects: [NSRect] {
        guard revealsWindow, let window else { return [] }
        let pairs: [(NSView?, NSRect?)] = gridContentAreas.isEmpty
            ? [(contentArea, coveredScreenRect), (secondaryContentArea, secondaryCoveredScreenRect)]
            : gridContentAreas.enumerated().map { ($0.element, gridCoveredScreenRects[$0.offset]) }
        let candidates = pairs.flatMap { area, coverage -> [NSRect] in
            guard let area, let coverage else { return [] }
            let contentRect = convert(area.bounds, from: area)
            let coveredRect = convert(window.convertFromScreen(coverage), from: nil)
            let visible = contentRect.intersection(coveredRect)
            return transitionClips.map { $0.map { visible.intersection($0) } } ?? [visible]
        }.filter { !$0.isEmpty }
        // Even-odd drawing must never receive overlapping holes, including during moves.
        var result: [NSRect] = []
        for candidate in candidates {
            var pieces = [candidate]
            for existing in result + [resizeGrip] {
                pieces = pieces.flatMap { Self.subtract(existing, from: $0) }
            }
            result.append(contentsOf: pieces)
        }
        return result
    }

    private static func subtract(_ cut: NSRect, from rect: NSRect) -> [NSRect] {
        let overlap = rect.intersection(cut)
        guard !overlap.isEmpty else { return [rect] }
        return [
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
            NSRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
            NSRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
            NSRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height)
        ].filter { !$0.isEmpty }
    }

    override var isOpaque: Bool { false }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window = window as? WorkspaceWindow else { return }
        let location = convert(event.locationInWindow, from: nil)
        let edges = resizeEdges(at: location)
        if edges.isEmpty, event.clickCount == 2 {
            window.toggleMaximize()
            return
        }
        let startFrame = window.frame
        let startMouse = window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        while let next = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            var mouse = NSEvent.mouseLocation
            if next.type == .leftMouseUp, let location = next.cgEvent?.location,
               let primaryScreen = NSScreen.screens.first {
                mouse = NSPoint(x: location.x, y: primaryScreen.frame.maxY - location.y)
            }
            let delta = NSSize(width: mouse.x - startMouse.x, height: mouse.y - startMouse.y)
            let frame: NSRect
            if edges.isEmpty {
                frame = startFrame.offsetBy(dx: delta.width, dy: delta.height)
            } else {
                frame = WorkspaceWindow.resizedFrame(
                    from: startFrame, delta: delta, edges: edges, minimumSize: window.minSize
                )
            }
            window.setWorkspaceFrame(frame)
            if next.type == .leftMouseUp { break }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(NSRect(x: 0, y: 0, width: 8, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.maxX - 8, y: 0, width: 8, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: 8), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: bounds.maxY - 8, width: bounds.width, height: 8), cursor: .resizeUpDown)
        addCursorRect(resizeGrip, cursor: .crosshair)
    }

    private func resizeEdges(at point: NSPoint) -> WorkspaceResizeEdges {
        if resizeGrip.contains(point) { return [.right, .bottom] }
        var edges: WorkspaceResizeEdges = []
        if point.x < bounds.minX + 8 { edges.insert(.left) }
        if point.x > bounds.maxX - 8 { edges.insert(.right) }
        if point.y < bounds.minY + 8 { edges.insert(.bottom) }
        if point.y > bounds.maxY - 8 { edges.insert(.top) }
        return edges
    }

    func refreshCoverage() {
        needsDisplay = true
        displayIfNeeded()
        CATransaction.flush()
        // The window server derives click-through from the window's opaque shape; refresh it whenever the apertures change.
        window?.invalidateShadow()
    }

    func prepareForFrameChange(to frame: NSRect) {
        guard let window else { return }
        // Keep the aperture inside the target both before and after the parent's move.
        transitionClips = visibleContentRects.map { visible in
            visible.intersection(visible.offsetBy(
                dx: window.frame.minX - frame.minX,
                dy: window.frame.minY - frame.minY
            ))
        }
        refreshCoverage()
    }

    func finishFrameChange() {
        transitionClips = nil
        refreshCoverage()
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        let background = NSBezierPath(rect: bounds)
        for visible in visibleContentRects {
            background.appendRect(visible)
            background.windingRule = .evenOdd
        }
        NSColor.windowBackgroundColor.setFill()
        background.fill()
        NSColor.secondaryLabelColor.setStroke()
        let grip = NSBezierPath()
        for offset in [CGFloat(4), 8, 12] {
            grip.move(to: NSPoint(x: bounds.maxX - offset, y: bounds.minY + 3))
            grip.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + offset))
        }
        grip.stroke()
    }
}
