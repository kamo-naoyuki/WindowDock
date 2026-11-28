import AppKit
import QuartzCore
import WindowDockCore

final class WorkspaceWindow: NSWindow {
    private(set) var isApplyingWorkspaceFrame = false
    var onWorkspaceFrameChange: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private static var mousePassThroughMonitors: [Any] = []

    /// The window server treats a titled, resizable window as solid even where it is transparent, so it would take
    /// scrolling, hovering and clicks from the pane windows shown through its apertures.
    private var blocksTransparentMouseEvents: Bool { styleMask.isSuperset(of: [.titled, .resizable]) }

    /// Lets mouse events reach the pane window beneath an aperture while the pointer is over it. The state never
    /// changes while a button is down, so a drag keeps going to the window it started in.
    func updateMousePassThrough(at screenPoint: NSPoint = NSEvent.mouseLocation) {
        guard blocksTransparentMouseEvents, NSEvent.pressedMouseButtons == 0 else { return }
        Self.monitorMousePassThrough()
        let passes = (contentView as? WorkspaceBackgroundView)?.passesMouseEvents(at: screenPoint) == true
        guard ignoresMouseEvents != passes else { return }
        ignoresMouseEvents = passes
        // The window server receives the change with the next Core Animation commit.
        CATransaction.flush()
    }

    /// Pointer events go to whichever window is under the pointer, including other applications' windows while a
    /// workspace ignores the mouse, so follow them all to notice the pointer entering or leaving an aperture.
    private static func monitorMousePassThrough() {
        guard mousePassThroughMonitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [
            .mouseMoved, .mouseEntered, .mouseExited, .scrollWheel, .leftMouseUp, .rightMouseUp, .otherMouseUp,
        ]
        let update = {
            MainActor.assumeIsolated {
                let point = NSEvent.mouseLocation
                for case let window as WorkspaceWindow in NSApp.windows {
                    window.updateMousePassThrough(at: point)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { _ in update() }) {
            mousePassThroughMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
            update()
            return event
        }) {
            mousePassThroughMonitors.append(local)
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if !isMovable, event.type == .leftMouseDown,
           let workspace = contentView as? WorkspaceBackgroundView
        {
            let point = workspace.convert(event.locationInWindow, from: nil)
            let inTitlebar = event.locationInWindow.y >= contentLayoutRect.maxY
            // Panes and their cells cover most edges; the resize bands and grip must win over them.
            let onResizeEdge = !workspace.resizeEdges(at: point).isEmpty
            if inTitlebar || onResizeEdge {
                let nativeButtons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
                let overNativeButton = nativeButtons.contains { type in
                    guard let button = standardWindowButton(type), !button.isHidden else { return false }
                    return button.convert(button.bounds, to: nil).contains(event.locationInWindow)
                }
                var hit = workspace.hitTest(point)
                var overControl = false
                while let view = hit {
                    if view is NSControl || view is NSScrollView {
                        overControl = true
                        break
                    }
                    hit = view.superview
                }
                if !overNativeButton, !overControl {
                    makeKeyAndOrderFront(nil)
                    workspace.trackFrameChange(with: event)
                    return
                }
            }
        }
        super.sendEvent(event)
    }

    private var preparingFrameChange = false

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard !preparingFrameChange, !isApplyingWorkspaceFrame,
              frameRect != frame, let workspace = contentView as? WorkspaceBackgroundView
        else {
            super.setFrame(frameRect, display: flag)
            return
        }
        preparingFrameChange = true
        workspace.prepareForFrameChange(to: frameRect)
        defer {
            workspace.finishFrameChange()
            preparingFrameChange = false
        }
        super.setFrame(frameRect, display: flag)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        guard !preparingFrameChange, !isApplyingWorkspaceFrame,
              point != frame.origin, let workspace = contentView as? WorkspaceBackgroundView
        else {
            super.setFrameOrigin(point)
            return
        }
        preparingFrameChange = true
        workspace.prepareForFrameChange(to: NSRect(origin: point, size: frame.size))
        defer {
            workspace.finishFrameChange()
            preparingFrameChange = false
        }
        super.setFrameOrigin(point)
    }

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
}

class WorkspaceBackgroundView: NSView {
    /// Called when the user starts moving, resizing or maximizing the workspace with the mouse.
    var onFrameInteractionBegin: (() -> Void)?
    /// Called on release; false for a click on the auto-hidden tab bar that left the workspace where it was.
    var onFrameInteractionEnd: ((_ handsFocusBack: Bool) -> Void)?
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
    /// Grid cells kept opaque even where their window is shown, e.g. behind a window dragged in front of the workspace.
    var concealedGridCells: Set<Int> = [] {
        didSet { needsDisplay = true }
    }
    private var transitionClips: [NSRect]?

    private var resizeGrip: NSRect { WorkspaceResize.grip(in: bounds) }

    var visibleContentRects: [NSRect] {
        guard revealsWindow, let window else { return [] }
        let pairs: [(NSView?, NSRect?)] =
            gridContentAreas.isEmpty
                ? [(contentArea, coveredScreenRect), (secondaryContentArea, secondaryCoveredScreenRect)]
                : gridContentAreas.enumerated().map {
                    ($0.element, concealedGridCells.contains($0.offset) ? nil : gridCoveredScreenRects[$0.offset])
                }
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
            NSRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height),
        ].filter { !$0.isEmpty }
    }

    override var isOpaque: Bool { false }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        trackFrameChange(with: event)
    }

    /// Resizes from an edge or corner and moves from anywhere else, under application control.
    func trackFrameChange(with event: NSEvent) {
        guard let window = window as? WorkspaceWindow else { return }
        let startMouse = window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        trackFrameChange(
            with: event, edges: resizeEdges(at: convert(event.locationInWindow, from: nil)),
            startMouse: startMouse
        )
    }

    func trackFrameChangeFromToolbar(with event: NSEvent) {
        guard let window = window as? WorkspaceWindow,
              let eventWindow = event.window
        else { return }
        let startMouse = eventWindow.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        // The revealed auto-hidden bar covers the workspace's edges there; they resize it as they do uncovered.
        let edges = resizeEdges(at: convert(window.convertPoint(fromScreen: startMouse), from: nil))
        trackFrameChange(with: event, edges: edges, startMouse: startMouse)
    }

    private func trackFrameChange(with event: NSEvent, edges: WorkspaceResizeEdges, startMouse: NSPoint) {
        guard let window = window as? WorkspaceWindow else { return }
        onFrameInteractionBegin?()
        if edges.isEmpty, event.clickCount == 2 {
            window.toggleMaximize()
            onFrameInteractionEnd?(true)
            return
        }
        let startFrame = window.frame
        while let next = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            var mouse = NSEvent.mouseLocation
            if let location = next.cgEvent?.location,
               let primaryScreen = NSScreen.screens.first
            {
                mouse = NSPoint(x: location.x, y: primaryScreen.frame.maxY - location.y)
            }
            let delta = NSSize(width: mouse.x - startMouse.x, height: mouse.y - startMouse.y)
            let frame: NSRect
            if edges.isEmpty {
                frame = startFrame.offsetBy(dx: delta.width, dy: delta.height)
            } else {
                frame = WorkspaceResize.resizedFrame(
                    from: startFrame, delta: delta, edges: edges, minimumSize: window.minSize,
                    maximumTop: window.screen?.visibleFrame.maxY ?? .greatestFiniteMagnitude
                )
            }
            window.setWorkspaceFrame(frame)
            if next.type == .leftMouseUp {
                onFrameInteractionEnd?(event.window === window || window.frame != startFrame)
                break
            }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let edge = WorkspaceResize.edgeThickness
        addCursorRect(NSRect(x: 0, y: 0, width: edge, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.maxX - edge, y: 0, width: edge, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: edge), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: bounds.maxY - edge, width: bounds.width, height: edge), cursor: .resizeUpDown)
        addCursorRect(resizeGrip, cursor: .crosshair)
    }

    func resizeEdges(at point: NSPoint) -> WorkspaceResizeEdges {
        WorkspaceResize.edges(at: point, in: bounds)
    }

    /// Whether the point shows a pane window through an aperture, away from the resize edges.
    func passesMouseEvents(at screenPoint: NSPoint) -> Bool {
        guard let window, window.isVisible, window.frame.contains(screenPoint) else { return false }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return resizeEdges(at: point).isEmpty && visibleContentRects.contains { $0.contains(point) }
    }

    // Reports pointer moves while the application is inactive, so entering an aperture lets the mouse through.
    private lazy var pointerTracking = NSTrackingArea(
        rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
        userInfo: nil
    )

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !trackingAreas.contains(pointerTracking) { addTrackingArea(pointerTracking) }
    }

    func refreshCoverage() {
        needsDisplay = true
        displayIfNeeded()
        CATransaction.flush()
        // The window server derives click-through from the window's opaque shape; refresh it whenever the apertures change.
        window?.invalidateShadow()
        (window as? WorkspaceWindow)?.updateMousePassThrough()
    }

    func prepareForFrameChange(to frame: NSRect) {
        guard let window else { return }
        // Keep the aperture inside the target both before and after the parent's move.
        transitionClips = visibleContentRects.map { visible in
            visible.intersection(
                visible.offsetBy(
                    dx: window.frame.minX - frame.minX,
                    dy: window.frame.minY - frame.minY
                )
            )
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
