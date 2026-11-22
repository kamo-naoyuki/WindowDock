import AppKit
import WindowDockCore

/// Choosing a workspace from the Dock menu while two workspaces overlap. Uses real windows of a helper process
/// and changes the active application, so it runs in the `--activation-only` harness process.
@MainActor
enum WorkspaceActivationSmoke {
    /// A simulated managed window; the client intercepts every operation.
    private final class FocusProbe {
        let element = AXUIElementCreateApplication(pid_t(910_000))
        var frame = CGRect(x: 200, y: 200, width: 500, height: 400)
        var focusCount = 0

        var access: WindowAccessClient {
            var access = WindowAccessClient()
            access.requireWritable = { _, _ in }
            access.frame = { [unowned self] _ in frame }
            access.setFrame = { [unowned self] _, frame in self.frame = frame }
            access.setPosition = { [unowned self] _, position in frame.origin = position }
            access.isMinimized = { _ in false }
            access.minimize = { _, _ in false }
            access.raise = { _ in }
            access.focus = { [unowned self] _, _ in focusCount += 1 }
            return access
        }
    }

    static func runDockMenuSwitchChecks() -> [String] {
        let helper: WindowSessionSmoke.ActivationHelperProcess
        switch WindowSessionSmoke.ActivationHelperProcess.launch() {
        case .success(let launched): helper = launched
        case .failure(let failure): return ["Dock menu switch: \(failure.message)"]
        }
        defer { helper.terminate() }
        let helperPID = helper.pid
        let otherAppWindow = helper.windows[2]
        // App activation arrives as an event, so dispatch events while waiting.
        func wait(_ seconds: TimeInterval, until condition: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline {
                if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            }
        }
        func stackIndex(_ number: Int) -> Int {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            return list.firstIndex { $0[kCGWindowNumber as String] as? Int == number } ?? Int.max
        }

        // The helper's windows lie inside both workspaces, which overlap each other.
        let probe = FocusProbe()
        let first = WorkspaceController(name: "Smoke 1", access: probe.access)
        let second = WorkspaceController(name: "Smoke 2")
        first.window.setFrame(NSRect(x: 160, y: 160, width: 720, height: 480), display: false)
        second.window.setFrame(NSRect(x: 260, y: 240, width: 720, height: 480), display: false)
        defer {
            first.window.orderOut(nil)
            second.window.orderOut(nil)
        }
        first.session.add([WindowCandidate(element: probe.element, application: .current, title: "Focus probe")])
        wait(0.5)
        first.window.orderFrontRegardless()
        second.window.orderFrontRegardless()
        let firstNumber = first.window.windowNumber
        let secondNumber = second.window.windowNumber
        func stack() -> String {
            "other app \(stackIndex(otherAppWindow)), first \(stackIndex(firstNumber)), second \(stackIndex(secondNumber)), " +
                "active \(NSApp.isActive), second key \(second.window.isKeyWindow)"
        }

        let activation = WorkspaceActivation { [first, second] }
        // The Dock and its menus are not in the window list, so the click that chose the Dock menu item
        // may appear to land on a workspace under the menu.
        guard let screen = NSScreen.screens.first else { return ["Dock menu switch check found no screen"] }
        let overlap = first.window.frame.intersection(second.window.frame)
        let menuItem = CGPoint(x: overlap.maxX - 40, y: screen.frame.maxY - (overlap.minY + 40))
        activation.latestClick = { .init(point: menuItem, buttonDown: false, secondsSinceMouseDown: 0.1) }
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated { activation.applicationDidBecomeActive() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        // Stands in for the Dock, which lets the app whose Dock menu item was chosen activate itself.
        func letWindowDockActivate() {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != helperPID {
                _ = WindowAccess.activateFrontWindowOnly(helperPID)
                wait(2) { NSWorkspace.shared.frontmostApplication?.processIdentifier == helperPID }
                wait(0.3)
            }
            helper.send("yield \(ProcessInfo.processInfo.processIdentifier)")
            wait(0.3)
        }
        // The user works in the second workspace, e.g. by clicking it.
        func useSecond() -> Bool {
            letWindowDockActivate()
            NSApp.activate(ignoringOtherApps: true)
            wait(2) { NSApp.isActive }
            second.window.makeKeyAndOrderFront(nil)
            wait(1) { second.window.isKeyWindow && stackIndex(secondNumber) < stackIndex(otherAppWindow) }
            return NSApp.isActive && second.window.isKeyWindow && stackIndex(secondNumber) < stackIndex(otherAppWindow)
        }
        // Then in another app's window in front of both workspaces.
        func useSecondThenOtherApp() -> Bool {
            guard useSecond() else { return false }
            helper.send("raise 2")
            wait(0.3)
            _ = WindowAccess.activateFrontWindowOnly(helperPID)
            wait(2) {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == helperPID && !NSApp.isActive &&
                    stackIndex(otherAppWindow) < stackIndex(secondNumber)
            }
            return NSWorkspace.shared.frontmostApplication?.processIdentifier == helperPID && !NSApp.isActive &&
                stackIndex(otherAppWindow) < stackIndex(secondNumber)
        }
        func chooseFirst(_ situation: String) -> [String] {
            probe.focusCount = 0
            activation.show(first)
            wait(2) { NSApp.isActive }
            wait(0.5)
            wait(1) { probe.focusCount > 0 }
            var failures: [String] = []
            if probe.focusCount == 0 {
                failures.append("\(situation): only the chosen workspace's frame came forward; its window stayed behind")
            }
            if !NSApp.isActive {
                failures.append("\(situation): choosing a workspace from the Dock menu did not activate WindowDock")
            }
            if stackIndex(firstNumber) > stackIndex(secondNumber) {
                failures.append("\(situation): the chosen workspace did not come in front of the other workspace (\(stack()))")
            }
            if stackIndex(secondNumber) < stackIndex(otherAppWindow) {
                failures.append("\(situation): the other workspace's frame and tab bar stayed in front of another app (\(stack()))")
            }
            return failures
        }

        var failures: [String] = []
        // WindowDock is still active from using the second workspace, so no activation follows.
        if useSecond() {
            failures += chooseFirst("while active")
        } else {
            failures.append("Dock menu switch fixture could not make the second workspace key in front (\(stack()))")
        }

        // The Dock activates WindowDock, raising every workspace and restoring the second one as key, before
        // the menu item's action arrives.
        if useSecondThenOtherApp() {
            helper.send("activate \(ProcessInfo.processInfo.processIdentifier)")
            wait(2) { NSApp.isActive }
            wait(0.3)
            failures += chooseFirst("after the Dock activated WindowDock")
        } else {
            failures.append("Dock menu switch fixture did not start with another app in front of the second workspace (\(stack()))")
        }

        // The menu item's action arrives before WindowDock is active.
        if useSecondThenOtherApp() {
            letWindowDockActivate()
            failures += chooseFirst("before WindowDock was active")
        } else {
            failures.append("Dock menu switch fixture did not start with another app in front of the second workspace (\(stack()))")
        }
        return failures
    }

    /// The auto-hidden tab bar is a non-activating panel; a click on it must still activate WindowDock (and show
    /// its menu bar) with that workspace key, like a click on the embedded tab bar.
    static func runAutoHiddenToolbarActivationChecks() -> [String] {
        let helper: WindowSessionSmoke.ActivationHelperProcess
        switch WindowSessionSmoke.ActivationHelperProcess.launch() {
        case .success(let launched): helper = launched
        case .failure(let failure): return ["auto-hidden tab bar click: \(failure.message)"]
        }
        defer { helper.terminate() }
        func wait(_ seconds: TimeInterval, until condition: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline {
                if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            }
        }
        func stackIndex(_ number: Int) -> Int {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            return list.firstIndex { $0[kCGWindowNumber as String] as? Int == number } ?? Int.max
        }
        let probe = FocusProbe()
        let first = WorkspaceController(name: "Auto-hide click", access: probe.access)
        let second = WorkspaceController(name: "Other workspace")
        first.window.setFrame(NSRect(x: 160, y: 160, width: 720, height: 480), display: false)
        second.window.setFrame(NSRect(x: 260, y: 240, width: 720, height: 480), display: false)
        defer {
            first.quitting = true
            second.quitting = true
            first.window.orderOut(nil)
            second.window.orderOut(nil)
            first.setAutoHideTabs(false)
        }
        first.session.add([WindowCandidate(element: probe.element, application: .current, title: "Focus probe")])
        first.setAutoHideTabs(true)
        let activation = WorkspaceActivation { [first, second] }
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated { activation.applicationDidBecomeActive() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        first.window.orderFrontRegardless()
        second.bringToFront()
        wait(2) { NSApp.isActive && second.window.isKeyWindow }
        // The user then works in another app that covers the other workspace.
        helper.send("raise 2")
        wait(0.3)
        _ = WindowAccess.activateFrontWindowOnly(helper.pid)
        wait(2) { !NSApp.isActive }
        wait(0.3)
        guard !NSApp.isActive else { return ["auto-hidden tab bar click fixture could not deactivate WindowDock"] }
        let otherAppWindow = helper.windows[2]
        let secondBefore = stackIndex(second.window.windowNumber)
        first.revealAutoHiddenTabBarTemporarily()
        guard let chrome = first.window.contentView as? WorkspaceChromeView,
              let panel = chrome.autoHiddenToolbarPanel, panel.isVisible,
              let dragSpace = panel.contentView?.subviews.compactMap({ $0 as? NSStackView }).flatMap(\.arrangedSubviews)
                .first(where: { $0.toolTip == L("ドラッグして移動 / ダブルクリックで最大化") }),
              let screen = NSScreen.screens.first
        else { return ["auto-hidden tab bar click fixture could not show the tab bar"] }
        let point = dragSpace.convert(NSPoint(x: dragSpace.bounds.midX, y: dragSpace.bounds.midY), to: nil)
        let start = panel.convertPoint(toScreen: point)
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ), let up = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: CGPoint(x: start.x, y: screen.frame.maxY - start.y), mouseButton: .left
        ).flatMap(NSEvent.init(cgEvent:)) else { return ["auto-hidden tab bar click fixture could not create mouse events"] }
        probe.focusCount = 0
        NSApp.postEvent(up, atStart: false)
        panel.sendEvent(down)
        wait(2) { NSApp.isActive && first.window.isKeyWindow && probe.focusCount > 0 }
        var failures: [String] = []
        if !NSApp.isActive {
            failures.append("a click on the auto-hidden tab bar did not activate WindowDock, so its menu bar did not appear")
        }
        if !first.window.isKeyWindow {
            failures.append("a click on the auto-hidden tab bar did not make its workspace key (second key \(second.window.isKeyWindow), key \(String(describing: NSApp.keyWindow)), panel key \(panel.isKeyWindow))")
        }
        if probe.focusCount == 0 {
            failures.append("a click on the auto-hidden tab bar's empty area did not hand focus back to the selected window")
        }
        if secondBefore > stackIndex(otherAppWindow), stackIndex(second.window.windowNumber) < stackIndex(otherAppWindow) {
            failures.append("a click on the auto-hidden tab bar raised another workspace above another app")
        }
        return failures
    }
}
