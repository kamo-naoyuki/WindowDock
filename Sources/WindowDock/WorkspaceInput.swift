import AppKit
import WindowDockCore

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

struct WorkspaceWindowDragRegistration {
    private var resolved: (id: CGWindowID, processID: pid_t, candidate: WindowCandidate)?

    mutating func reset() { resolved = nil }

    mutating func isRegistered(
        _ window: WindowServerWindow,
        among registered: [WindowCandidate],
        resolve: (WindowServerWindow) throws -> WindowCandidate = WindowAccess.candidate(matching:)
    ) throws -> Bool {
        let candidates = registered.filter { $0.application.processIdentifier == window.processID }
        guard !candidates.isEmpty else { return false }
        if let resolved, resolved.id == window.id, resolved.processID == window.processID {
            return candidates.contains { $0.isSameWindow(as: resolved.candidate) }
        }
        let candidate = try resolve(window)
        resolved = (window.id, window.processID, candidate)
        return candidates.contains { $0.isSameWindow(as: candidate) }
    }
}
