import AppKit
import WindowDockCore

/// Choosing a workspace from the Dock menu while two workspaces overlap. Uses real windows of a helper process
/// and changes the active application, so it runs in the `--activation-only` harness process.
@MainActor
enum WorkspaceActivationSmoke {
    static func runDockMenuSwitchChecks() -> [String] {
        guard let executable = Bundle.main.executableURL else { return ["Dock menu switch check could not find its executable"] }
        let helper = Process()
        let output = Pipe()
        let input = Pipe()
        helper.executableURL = executable
        helper.arguments = ["--activation-helper"]
        helper.standardOutput = output
        helper.standardInput = input
        do { try helper.run() } catch { return ["Dock menu switch helper failed to launch: \(error.localizedDescription)"] }
        defer {
            helper.terminate()
            helper.waitUntilExit()
        }
        let fields = (String(data: output.fileHandleForReading.availableData, encoding: .utf8) ?? "")
            .split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard fields.count == 4 else { return ["Dock menu switch helper did not report its windows"] }
        let helperPID = pid_t(fields[0])
        let otherAppWindow = fields[3]
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
        let first = WorkspaceController(name: "Smoke 1")
        let second = WorkspaceController(name: "Smoke 2")
        first.window.setFrame(NSRect(x: 160, y: 160, width: 720, height: 480), display: false)
        second.window.setFrame(NSRect(x: 260, y: 240, width: 720, height: 480), display: false)
        defer {
            first.window.orderOut(nil)
            second.window.orderOut(nil)
        }
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
            input.fileHandleForWriting.write(Data("yield \(ProcessInfo.processInfo.processIdentifier)\n".utf8))
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
            input.fileHandleForWriting.write(Data("raise 2\n".utf8))
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
            activation.show(first)
            wait(2) { NSApp.isActive }
            wait(0.5)
            var failures: [String] = []
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
            input.fileHandleForWriting.write(Data("activate \(ProcessInfo.processInfo.processIdentifier)\n".utf8))
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
}
