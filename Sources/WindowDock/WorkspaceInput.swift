import AppKit
import WindowDockCore

struct WorkspaceShortcutContext {
    private var originPID: pid_t?

    mutating func reset() { originPID = nil }

    static func showsNumberedTabHints(for event: NSEvent) -> Bool {
        guard event.type == .flagsChanged else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        return flags == [.control, .shift]
    }

    static func previouslyUsedTab(
        for event: NSEvent, ownPID: pid_t, frontPID: pid_t?, visiblePIDs: Set<pid_t>) -> Bool {
        guard event.type == .keyDown,
              frontPID == ownPID || frontPID.map(visiblePIDs.contains) == true
        else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        return flags == [.control, .shift] && event.keyCode == 29
    }

    static func numberedTab(for event: NSEvent, ownPID: pid_t, frontPID: pid_t?, visiblePIDs: Set<pid_t>) -> Int? {
        guard event.type == .keyDown else { return nil }
        guard frontPID == ownPID || frontPID.map(visiblePIDs.contains) == true else { return nil }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags == [.control, .shift] else { return nil }
        let number: Int
        switch event.keyCode {
        case 18: number = 1
        case 19: number = 2
        case 20: number = 3
        case 21: number = 4
        case 23: number = 5
        case 22: number = 6
        case 26: number = 7
        case 28: number = 8
        case 25: number = 9
        default: return nil
        }
        return number
    }

    static func paneDirection(
        for event: NSEvent, ownPID: pid_t, frontPID: pid_t?, visiblePIDs: Set<pid_t>) -> Int? {
        guard event.type == .keyDown,
              frontPID == ownPID || frontPID.map(visiblePIDs.contains) == true
        else { return nil }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags == [.command, .control, .option, .shift] else { return nil }
        switch event.keyCode {
        case 123: return -1
        case 124: return 1
        default: return nil
        }
    }

    mutating func applicationDidActivate(_ pid: pid_t) {
        if pid != originPID { reset() }
    }

    mutating func direction(
        for event: NSEvent, ownPID: pid_t, frontPID: pid_t?, visiblePIDs: Set<pid_t>, enabled: Bool = true) -> Int? {
        guard enabled else { return nil }
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.contains(.command), event.keyCode == 48 || event.keyCode == 50 { reset() }
        guard event.keyCode == 48, let frontPID else { return nil }
        guard flags == [.control] || flags == [.control, .shift],
              frontPID == ownPID || visiblePIDs.contains(frontPID) || frontPID == originPID
        else { return nil }
        // AXRaise need not transfer keyboard focus. Keep a shortcut sequence usable until focus or a click changes.
        originPID = frontPID == ownPID ? nil : frontPID
        return flags.contains(.shift) ? -1 : 1
    }
    /// ⌃⌥Tab / ⌃⌥⇧Tab switch workspaces while WindowDock or a window shown in a workspace is in front.
    static func workspaceDirection(for event: NSEvent, ownPID: pid_t, frontPID: pid_t?, managedPIDs: Set<pid_t>)
        -> Int?
    {
        guard event.type == .keyDown, event.keyCode == 48, let frontPID,
              frontPID == ownPID || managedPIDs.contains(frontPID)
        else { return nil }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags == [.control, .option] || flags == [.control, .option, .shift] else { return nil }
        return flags.contains(.shift) ? -1 : 1
    }
}

/// Whether a workspace already manages a window being dragged. Registered windows must not be offered for a drop,
/// but other windows of the same app must stay droppable while they move.
struct WorkspaceWindowDragRegistration {
    private var knownIDs: [(element: AXUIElement, id: CGWindowID?)] = []
    private var resolved: (id: CGWindowID, processID: pid_t, candidate: WindowCandidate?)?

    mutating func reset() {
        knownIDs.removeAll()
        resolved = nil
    }

    mutating func isRegistered(
        _ window: WindowServerWindow,
        among registered: [WindowCandidate],
        windowID: (AXUIElement) -> CGWindowID? = WindowAccess.windowID(of:),
        resolve: (WindowServerWindow) throws -> WindowCandidate = WindowAccess.candidate(matching:)) -> Bool {
        let candidates = registered.filter { $0.application.processIdentifier == window.processID }
        guard !candidates.isEmpty else { return false }
        let ids = candidates.map { id(of: $0.element, using: windowID) }
        if ids.contains(window.id) { return true }
        guard ids.contains(nil) else { return false }
        // Without window numbers, match frames. A moving window's AX frame lags behind the WindowServer, so an
        // unidentified window stays droppable; the drop itself checks ownership again once the window has stopped.
        if resolved?.id != window.id || resolved?.processID != window.processID {
            resolved = (window.id, window.processID, try? resolve(window))
        }
        guard let candidate = resolved?.candidate else { return false }
        return candidates.contains { $0.isSameWindow(as: candidate) }
    }

    private mutating func id(of element: AXUIElement, using windowID: (AXUIElement) -> CGWindowID?) -> CGWindowID? {
        if let known = knownIDs.first(where: { CFEqual($0.element, element) }) { return known.id }
        let id = windowID(element)
        knownIDs.append((element, id))
        return id
    }
}

/// Starts following a shown window when a left-button press reaches it, so dragging or resizing the window moves or
/// resizes its workspace.
@MainActor
struct ManagedWindowPress {
    var windowReceivingClick: (NSPoint, Set<CGWindowID>) -> CGWindowID? = WindowAccess.windowReceivingClick
    var windows: () throws -> [WindowServerWindow] = WindowAccess.windowServerWindows

    /// `reachedWindowDock` is set for presses that one of WindowDock's own windows received, such as the auto-hidden
    /// tab bar in front of a pane's window; the window behind it is not pressed.
    func begin(at point: NSPoint, reachedWindowDock: Bool, controllers: [WorkspaceController]) {
        guard !reachedWindowDock else { return }
        let excluded = Set(controllers.flatMap { controller in
            [controller.window.windowNumber, controller.toolbarPanelNumber ?? 0, controller.windowDropPanelNumber ?? 0]
                .filter { $0 > 0 }.map { CGWindowID($0) }
        })
        guard let windowID = windowReceivingClick(point, excluded) else { return }
        guard let controller = controllers.first(where: { controller in
            controller.session.windows.contains {
                controller.session.access.windowID($0.candidate.element) == windowID
            }
        })
        else { return }
        do {
            guard let window = try windows().first(where: { $0.id == windowID }) else { return }
            _ = controller.beginManagedWindowDrag(windowServerWindow: window)
        } catch {
            WindowAccess.logger
                .error("Could not begin managed-window sampling: \(error.localizedDescription, privacy: .public)")
            controller.showNotice(.attention(error.localizedDescription))
        }
    }
}

/// Adds another app's window to a workspace when it is dragged onto the workspace's tab bar. AppKit receives no
/// events for other apps' drags, so this samples WindowServer frames while the mouse button is down.
@MainActor
final class WorkspaceWindowDrop {
    struct Pointer {
        var location: NSPoint
        var buttonDown: Bool
    }

    private let controllers: () -> [WorkspaceController]
    var isEnabled = true {
        didSet { if !isEnabled { cancel() } }
    }
    var pointer: () -> Pointer = {
        Pointer(location: NSEvent.mouseLocation, buttonDown: NSEvent.pressedMouseButtons & 1 != 0)
    }
    var windows: () throws -> [WindowServerWindow] = WindowAccess.windowServerWindows
    var ownPID = ProcessInfo.processInfo.processIdentifier
    var isRegularApplication: (pid_t) -> Bool = {
        NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular
    }
    var windowID: (AXUIElement) -> CGWindowID? = WindowAccess.windowID(of:)
    var resolve: (WindowServerWindow) throws -> WindowCandidate = WindowAccess.candidate(matching:)
    var finish: (WorkspaceController, WorkspaceWindowDrag, CGPoint, Int) -> Void = {
        controller, drag, axPoint, index in
        controller.finishWindowDrag(drag, accessibilityPoint: axPoint, insertionIndex: index)
    }
    var onSamplingFailure: (Error) -> Void = { _ in }

    private var tracker = WorkspaceWindowDragTracker()
    private var registration = WorkspaceWindowDragRegistration()
    private var lastSnapshot: TimeInterval = 0
    private var samplingFailed = false
    private var previewTitle: (id: CGWindowID, processID: pid_t, title: String?)?

    init(controllers: @escaping () -> [WorkspaceController]) {
        self.controllers = controllers
    }

    func poll(sampledWindows: [WindowServerWindow]? = nil) {
        guard isEnabled else {
            cancel()
            return
        }
        let controllers = controllers()
        guard controllers.contains(where: \.acceptsWindowDrag), let screen = NSScreen.screens.first else {
            cancel()
            return
        }
        let pointer = pointer()
        let now = ProcessInfo.processInfo.systemUptime
        guard pointer.buttonDown || tracker.isTrackingPress || now - lastSnapshot >= 0.2 else { return }
        lastSnapshot = now
        let point = pointer.location
        let axPoint = CGPoint(x: point.x, y: screen.frame.maxY - point.y)
        let windows: [WindowServerWindow]
        if let sampledWindows {
            windows = sampledWindows
        } else {
            do {
                windows = try self.windows()
            } catch {
                cancel()
                if !samplingFailed {
                    samplingFailed = true
                    WindowAccess.logger.error("\(error.localizedDescription, privacy: .public)")
                    onSamplingFailure(error)
                }
                return
            }
        }
        samplingFailed = false
        switch tracker.update(
            buttonDown: pointer.buttonDown, point: axPoint,
            windows: windows.filter { $0.layer == 0 }, ownPID: ownPID)
        {
        case .idle:
            registration.reset()
            previewTitle = nil
            controllers.forEach { $0.hideWindowDropTarget() }
        case .moving(let drag):
            let target =
                isRegularApplication(drag.window.processID)
                    ? self.target(at: point, drag: drag, among: controllers)
                    : nil
            for controller in controllers {
                if controller === target {
                    if WindowAccess.isTrusted,
                       previewTitle?.id != drag.window.id || previewTitle?.processID != drag.window.processID
                    {
                        do {
                            previewTitle = (drag.window.id, drag.window.processID, try resolve(drag.window).title)
                        } catch {
                            WindowAccess.logger
                                .debug(
                                    "Could not read dragged window title: \(error.localizedDescription, privacy: .public)")
                            previewTitle = (drag.window.id, drag.window.processID, nil)
                        }
                    }
                    controller.showWindowDropTarget(
                        at: point, application: NSRunningApplication(processIdentifier: drag.window.processID),
                        title: previewTitle?.title)
                } else {
                    controller.hideWindowDropTarget()
                }
            }
        case .released(let drag):
            defer {
                registration.reset()
                previewTitle = nil
            }
            let target = self.target(at: point, drag: drag, among: controllers)
            let insertionIndex = target?.windowDropInsertionIndex(at: point)
            controllers.forEach { $0.hideWindowDropTarget() }
            if let target, let insertionIndex, isRegularApplication(drag.window.processID) {
                finish(target, drag, axPoint, insertionIndex)
            }
        }
    }

    func cancel() {
        tracker.cancel()
        registration.reset()
        previewTitle = nil
        controllers().forEach { $0.hideWindowDropTarget() }
    }

    private func target(
        at point: NSPoint, drag: WorkspaceWindowDrag,
        among controllers: [WorkspaceController]) -> WorkspaceController? {
        var excluded: Set<CGWindowID> = [drag.window.id]
        for controller in controllers {
            if let number = controller.windowDropPanelNumber, number > 0 {
                excluded.insert(CGWindowID(number))
            }
        }
        guard let frontmost = WindowAccess.windowReceivingClick(at: point, excluding: excluded) else { return nil }
        guard
            let target = controllers.first(where: {
                let isWorkspace = $0.window.windowNumber > 0 && CGWindowID($0.window.windowNumber) == frontmost
                let isToolbar = $0.toolbarPanelNumber.map { $0 > 0 && CGWindowID($0) == frontmost } ?? false
                return (isWorkspace || isToolbar) && $0.acceptsWindowDrop(at: point)
            })
        else { return nil }
        let registered = controllers.flatMap { $0.session.windows.map(\.candidate) }
        return registration.isRegistered(drag.window, among: registered, windowID: windowID, resolve: resolve)
            ? nil : target
    }
}
