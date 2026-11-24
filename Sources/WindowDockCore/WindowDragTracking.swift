import CoreGraphics
import Foundation

public struct WindowServerWindow: Equatable {
    public let id: CGWindowID
    public let processID: pid_t
    public let frame: CGRect
    public var layer: Int

    public init(id: CGWindowID, processID: pid_t, frame: CGRect, layer: Int = 0) {
        self.id = id
        self.processID = processID
        self.frame = frame
        self.layer = layer
    }
}

public struct WorkspaceWindowDrag {
    public let window: WindowServerWindow
    public let originalFrame: CGRect
    public let startPoint: CGPoint

    public init(window: WindowServerWindow, originalFrame: CGRect, startPoint: CGPoint) {
        self.window = window
        self.originalFrame = originalFrame
        self.startPoint = startPoint
    }

    public func canDrop(at point: CGPoint, actualFrame: CGRect, acceptsPoint: Bool) -> Bool {
        acceptsPoint && hypot(point.x - startPoint.x, point.y - startPoint.y) >= 8
            && hypot(actualFrame.minX - originalFrame.minX, actualFrame.minY - originalFrame.minY) >= 8
            && abs(actualFrame.width - originalFrame.width) <= 2 && abs(actualFrame.height - originalFrame.height) <= 2
    }
}

/// Detects another app's window being dragged by sampling WindowServer frames while the mouse button is down.
public struct WorkspaceWindowDragTracker {
    public enum Update {
        case idle
        case moving(WorkspaceWindowDrag)
        case released(WorkspaceWindowDrag)
    }

    public private(set) var isTrackingPress = false
    private var idleWindows: [CGWindowID: WindowServerWindow] = [:]
    private var startWindows: [CGWindowID: WindowServerWindow] = [:]
    private var resizedWindows: Set<CGWindowID> = []
    private var startPoint = CGPoint.zero
    private var suppressed = false
    private var pressedWorkspace: WindowServerWindow?

    public init() {}

    public mutating func cancel() {
        suppressed = true
        isTrackingPress = true
        idleWindows.removeAll()
        startWindows.removeAll()
        pressedWorkspace = nil
    }

    public mutating func update(buttonDown: Bool, point: CGPoint, windows: [WindowServerWindow], ownPID: pid_t)
        -> Update
    {
        if !buttonDown {
            let completed =
                isTrackingPress && !suppressed && !workspaceMoved(in: windows)
                    ? movedWindow(at: point, windows: windows) : nil
            idleWindows = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
            startWindows.removeAll()
            resizedWindows.removeAll()
            isTrackingPress = false
            suppressed = false
            pressedWorkspace = nil
            return completed.map(Update.released) ?? .idle
        }
        guard !suppressed else { return .idle }
        if !isTrackingPress {
            isTrackingPress = true
            startPoint = point
            if let top = windows.first(where: { $0.frame.contains(point) }), top.processID == ownPID {
                pressedWorkspace = idleWindows[top.id] ?? top
            }
            for window in windows where window.processID != ownPID && window.frame.contains(point) {
                let previous = idleWindows[window.id]
                startWindows[window.id] = previous?.processID == window.processID ? previous : window
            }
        }
        if workspaceMoved(in: windows) {
            suppressed = true
            return .idle
        }
        return movedWindow(at: point, windows: windows).map(Update.moving) ?? .idle
    }

    private func workspaceMoved(in windows: [WindowServerWindow]) -> Bool {
        guard let workspace = pressedWorkspace,
              let current = windows.first(where: { $0.id == workspace.id })
        else { return false }
        return current.frame != workspace.frame
    }

    private mutating func movedWindow(at point: CGPoint, windows: [WindowServerWindow]) -> WorkspaceWindowDrag? {
        for window in windows {
            guard let original = startWindows[window.id], original.processID == window.processID else { continue }
            if abs(window.frame.width - original.frame.width) > 2
                || abs(window.frame.height - original.frame.height) > 2
            {
                resizedWindows.insert(window.id)
            }
            guard !resizedWindows.contains(window.id) else { continue }
            let drag = WorkspaceWindowDrag(window: window, originalFrame: original.frame, startPoint: startPoint)
            if drag.canDrop(at: point, actualFrame: window.frame, acceptsPoint: true) { return drag }
        }
        return nil
    }
}
