import AppKit
import WindowDockCore

/// Decides which workspace comes forward when WindowDock is activated, and keeps the other workspaces' frames behind it.
@MainActor
final class WorkspaceActivation {
    /// The latest mouse press, in window-server coordinates (top-left origin).
    struct Click {
        var point: CGPoint
        var buttonDown: Bool
        var secondsSinceMouseDown: Double
    }

    private let controllers: () -> [WorkspaceController]
    var latestClick: () -> Click? = WorkspaceActivation.currentClick

    init(controllers: @escaping () -> [WorkspaceController]) {
        self.controllers = controllers
    }

    /// The workspace whose window is key, falling back to the main or first one.
    var activeController: WorkspaceController? {
        let controllers = controllers()
        return controllers.first { $0.window.isKeyWindow } ?? controllers.first { $0.window.isMainWindow }
            ?? controllers.first
    }

    /// Brings a workspace forward on request, e.g. from the Dock menu or the Workspace menu.
    func show(_ controller: WorkspaceController) {
        controller.present()
        // No activation may follow (the app is already active), or the Dock may already have activated the app,
        // raising every workspace and keying the last used one, before its menu item's action arrives.
        sendInactiveWorkspacesBack(behind: controller)
    }

    /// A Dock click brings back only the last used workspace.
    func reopen() {
        activeController?.present()
        sendInactiveWorkspacesBack()
    }

    func applicationDidBecomeActive() {
        // The auto-hidden tab bar is a non-activating panel, so its click activates WindowDock explicitly.
        // Like a click on the workspace itself, it leaves the other workspaces where they are.
        if let clicked = controllers().first(where: { $0.claimToolbarActivation() }) {
            clicked.window.makeKey()
            return
        }
        // A click raises only the clicked workspace, which is not key yet; guessing the active workspace now
        // would send the clicked one behind the others until the mouse is released.
        if let (clicked, point) = activatingClick() {
            if let controller = controllers().first(where: { CGWindowID($0.window.windowNumber) == clicked }) {
                // Like a titlebar click, the click returns focus to the selected window once released.
                controller.scheduleSelectedWindowRaise(activate: !controller.handlesActivatingClick(at: point))
            }
            return
        }
        activeController?.scheduleSelectedWindowRaise()
        sendInactiveWorkspacesBack()
    }

    private func activatingClick() -> (window: CGWindowID, point: CGPoint)? {
        guard let click = latestClick(), let windows = try? WindowAccess.windowServerWindows() else { return nil }
        return WindowHitTesting.activatingClick(
            at: click.point,
            windows: windows.map { ($0.id, $0.processID, $0.frame) },
            ownPID: ProcessInfo.processInfo.processIdentifier,
            buttonDown: click.buttonDown, secondsSinceMouseDown: click.secondsSinceMouseDown
        ).map { ($0, click.point) }
    }

    private static func currentClick() -> Click? {
        guard let screen = NSScreen.screens.first else { return nil }
        let point = NSEvent.mouseLocation
        let age =
            [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown].map {
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
            }.min() ?? .infinity
        return Click(
            point: CGPoint(x: point.x, y: screen.frame.maxY - point.y),
            buttonDown: NSEvent.pressedMouseButtons != 0, secondsSinceMouseDown: age
        )
    }

    /// Activating the app raises every workspace's backdrop; keep the other workspaces behind so their frames don't cover the active one.
    private func sendInactiveWorkspacesBack(behind active: WorkspaceController? = nil) {
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let active = active ?? self.activeController else { return }
                for controller in self.controllers()
                    where controller !== active && controller.window.isVisible && !controller.window.isMiniaturized {
                    controller.window.orderBack(nil)
                }
            }
        }
    }
}
