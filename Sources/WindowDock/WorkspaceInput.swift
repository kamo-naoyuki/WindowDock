import AppKit

struct WorkspaceShortcutContext {
    private var originPID: pid_t?

    mutating func reset() { originPID = nil }

    mutating func applicationDidActivate(_ pid: pid_t) {
        if pid != originPID { reset() }
    }

    mutating func direction(for event: NSEvent, ownPID: pid_t, frontPID: pid_t?, visiblePIDs: Set<pid_t>) -> Int? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.contains(.command), event.keyCode == 48 || event.keyCode == 50 { reset() }
        guard event.keyCode == 48, let frontPID else { return nil }
        guard flags == [.control] || flags == [.control, .shift],
              frontPID == ownPID || visiblePIDs.contains(frontPID) || frontPID == originPID else { return nil }
        // AXRaise need not transfer keyboard focus. Keep a shortcut sequence usable until focus or a click changes.
        originPID = frontPID == ownPID ? nil : frontPID
        return flags.contains(.shift) ? -1 : 1
    }
}

struct WorkspaceWindowDrag {
    let window: WindowServerWindow
    let originalFrame: CGRect
    let startPoint: CGPoint

    func canDrop(at point: CGPoint, actualFrame: CGRect, acceptsPoint: Bool) -> Bool {
        acceptsPoint &&
        hypot(point.x - startPoint.x, point.y - startPoint.y) >= 8 &&
        hypot(actualFrame.minX - originalFrame.minX, actualFrame.minY - originalFrame.minY) >= 8 &&
        abs(actualFrame.width - originalFrame.width) <= 2 &&
        abs(actualFrame.height - originalFrame.height) <= 2
    }
}

struct WindowServerWindow: Equatable {
    let id: CGWindowID
    let processID: pid_t
    let frame: CGRect
}

struct WorkspaceWindowDragTracker {
    enum Update {
        case idle
        case moving(WorkspaceWindowDrag)
        case released(WorkspaceWindowDrag)
    }

    private(set) var isTrackingPress = false
    private var idleWindows: [CGWindowID: WindowServerWindow] = [:]
    private var startWindows: [CGWindowID: WindowServerWindow] = [:]
    private var resizedWindows: Set<CGWindowID> = []
    private var startPoint = CGPoint.zero
    private var suppressed = false

    mutating func cancel() {
        suppressed = true
        isTrackingPress = true
        idleWindows.removeAll()
        startWindows.removeAll()
    }

    mutating func update(buttonDown: Bool, point: CGPoint, windows: [WindowServerWindow], ownPID: pid_t) -> Update {
        if !buttonDown {
            let completed = isTrackingPress && !suppressed ? movedWindow(at: point, windows: windows) : nil
            idleWindows = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
            startWindows.removeAll()
            resizedWindows.removeAll()
            isTrackingPress = false
            suppressed = false
            return completed.map(Update.released) ?? .idle
        }
        guard !suppressed else { return .idle }
        if !isTrackingPress {
            isTrackingPress = true
            startPoint = point
            for window in windows where window.processID != ownPID && window.frame.contains(point) {
                let previous = idleWindows[window.id]
                startWindows[window.id] = previous?.processID == window.processID ? previous : window
            }
        }
        return movedWindow(at: point, windows: windows).map(Update.moving) ?? .idle
    }

    private mutating func movedWindow(at point: CGPoint, windows: [WindowServerWindow]) -> WorkspaceWindowDrag? {
        for window in windows {
            guard let original = startWindows[window.id], original.processID == window.processID else { continue }
            if abs(window.frame.width - original.frame.width) > 2 ||
                abs(window.frame.height - original.frame.height) > 2 {
                resizedWindows.insert(window.id)
            }
            guard !resizedWindows.contains(window.id) else { continue }
            let drag = WorkspaceWindowDrag(window: window, originalFrame: original.frame, startPoint: startPoint)
            if drag.canDrop(at: point, actualFrame: window.frame, acceptsPoint: true) { return drag }
        }
        return nil
    }
}
