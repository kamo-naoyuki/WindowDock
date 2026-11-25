import AppKit
import SwiftUI
import WindowDockCore

@main
@MainActor
enum StartupRestoreSmoke {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let bundleID = NSRunningApplication.current.bundleIdentifier,
              bundleID.hasPrefix("local.WindowDock.RestoreSmoke.p")
        else { fatalError("Restore smoke must run in its disposable fixture bundle") }
        Task {
            var status: Int32 = 0
            do {
                try await run(bundleID)
                print("PASS: inline restore, matching/order, deferred registration, split/pins, dismissal, permission and empty startup")
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                status = 1
            }
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            exit(status)
        }
        app.run()
    }

    private struct Failure: Error, CustomStringConvertible { let description: String }

    private static func check(_ passed: Bool, _ failure: String) throws {
        if !passed { throw Failure(description: failure) }
    }

    private static func wait(_ check: () -> Bool, _ failure: String) async throws {
        for _ in 0 ..< 100 {
            if check() { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw Failure(description: failure)
    }

    private static func page(in controller: WorkspaceController) throws -> NewTabPage {
        guard let chrome = controller.window.contentView as? WorkspaceChromeView,
              let page = chrome.gridAreas.first?.subviews.compactMap({ $0 as? NSHostingView<NewTabPage> }).first,
              page.visibleRect.width > 200, page.visibleRect.height > 150
        else { throw Failure(description: "no visible inline page in \(controller.name)") }
        return page.rootView
    }

    // Give the thumbnail controls a fixed, accessibility-enabled viewport, like the normal multi-select smoke.
    private static func confirm(in controller: WorkspaceController, extra: WindowCandidate?, count: Int) async throws {
        let page = try page(in: controller)
        guard let saved = page.restoration?.workspace else { throw Failure(description: "not a restore page") }
        let choices = SavedLayout.restoreChoices(saved.windows,
                                                 among: page.access.scan().windows.filter(page.isAvailable),
                                                 frameOf: page.access.frame)
        let grid = WindowChoiceGrid(windows: choices.windows, previews: nil, restoring: choices.checked,
                                    choose: page.choose)
        let host = NSHostingView(rootView: grid.frame(width: 720, height: 360)
            .environment(\.accessibilityEnabled, true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 360), styleMask: .titled,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        func find(_ name: String, _ nodes: [Any]) -> AnyObject? {
            for node in nodes.map({ $0 as AnyObject }) {
                if node.accessibilityRole?() == .button,
                   node.accessibilityLabel?() == name || node.accessibilityTitle?() == name { return node }
                if let match = find(name, node.accessibilityChildren?() ?? []) { return match }
            }
            return nil
        }
        func press(_ name: String) async throws {
            try await wait({
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                guard let button = find(name, host.accessibilityChildren() ?? []),
                      button.isAccessibilityEnabled?() == true else { return false }
                return button.accessibilityPerformPress?() == true
            }, "missing or disabled restore control: \(name)")
        }
        if let extra { try await press(extra.label) }
        try await press(L("%d件を復元", count))
    }

    private static func run(_ bundleID: String) async throws {
        let candidates = ["A", "B", "C", "D"].enumerated().map { index, title in
            WindowCandidate(element: AXUIElementCreateApplication(pid_t(910_000 + index)),
                            application: .current, title: title)
        }
        var access = WindowAccessClient()
        var allowed = true
        var permissionRequests = 0
        access.isTrusted = { allowed }
        access.requestPermission = { permissionRequests += 1 }
        access.scan = { WindowScan(windows: candidates) }
        access.requireWritable = { _, _ in }
        let original = CGRect(x: 20, y: 30, width: 480, height: 300)
        var frames: [AXUIElement: CGRect] = [:]
        access.frame = { frames[$0] ?? original }
        access.setFrame = { frames[$0] = $1 }
        access.setPosition = { frames[$0, default: original].origin = $1 }
        access.isMinimized = { _ in false }
        access.minimize = { _, _ in false }
        access.isFullScreen = { _ in false }
        access.focus = { _, _ in }
        access.raise = { _ in }

        func saved(_ titles: [String]) -> [SavedWindow] {
            titles.map { SavedWindow(bundleID: bundleID, title: $0, frame: original) }
        }
        let first = SavedWorkspace(name: "First", windows: saved(["C", "A"]), columns: 2, rows: 1,
                                   pinnedPanes: [0], tabBarPosition: .right)
        let last = SavedWorkspace(name: "Last", windows: saved(["D"]),
                                  paneLayout: .grid(columnWeights: [1, 2], rowWeights: [1]), pinnedPanes: [1])
        try check(SavedLayout.suggest(first.windows, among: candidates, frameOf: access.frame) == [2, 0],
                  "restore suggestions lost saved tab order when scan order differed")
        SavedLayout.save([first, last])
        var controllers: [WorkspaceController] = []
        var registered: [String] = []
        var deleted: [String] = []
        func makeWorkspace(_ name: String?) -> WorkspaceController {
            let controller = WorkspaceController(name: name ?? "Fresh", access: access)
            controllers.append(controller)
            controller.isRegisteredElsewhere = { candidate in
                controllers.contains { $0 !== controller && $0.session.contains(candidate) }
            }
            controller.deletesWhenEmpty = true
            controller.onAutoDelete = { deleted.append($0.name) }
            controller.session.onAddedApplication = { _ in registered.append(controller.name) }
            controller.session.onFocusStartPage = {}
            controller.window.animationBehavior = .none
            controller.window.orderBack(nil)
            return controller
        }
        defer { for controller in controllers { controller.finishClosing() } }
        WorkspaceRestore.start([first, last], makeWorkspace: makeWorkspace)
        let one = controllers[0]
        try check(controllers.count == 1 && one.session.tabIDs.count == 1 && one.window.attachedSheet == nil,
                  "first restore did not open in a single inline tab")
        // Adjust a preselection without taking ownership of any window; leave the saved order intact.
        try await confirm(in: one, extra: candidates[1], count: 3)
        try await wait({ controllers.count == 2 }, "confirm did not advance to the second workspace")
        let two = controllers[1]
        let pageTwo = try page(in: two)
        try check(registered.isEmpty && one.session.tabIDs.isEmpty && two.window.attachedSheet == nil &&
            candidates.filter(pageTwo.isAvailable).map(\.title) == ["D"],
            "an earlier choice was registered too soon or offered again")
        try await confirm(in: two, extra: nil, count: 1)
        try await wait({ registered.count == 4 }, "restoration did not finish")
        try check(registered == ["Last", "First", "First", "First"] && one.session.windows.map(\.candidate.title) ==
            ["C", "A", "B"] && two.session.windows.map(\.candidate.title) == ["D"],
            "deferred registrations changed workspace or tab order")
        try check(one.session.tabIDs.count == 3 && one.session.gridSize.columns == 2
            && one.session.pinnedCells == [0] && one.session.cells.allSatisfy { $0 != nil }
            && one.tabBarPosition == .right && two.session.customLayout == last.paneLayout
            && two.session.pinnedCells == [1], "placeholder changed restored pane layout or pins")
        for controller in controllers { controller.finishClosing() }
        controllers.removeAll()

        // Explicit Skip, removing the temporary tab, and closing the workspace each advance once.
        WorkspaceRestore.start([first, last, first, last], makeWorkspace: makeWorkspace)
        try page(in: controllers[0]).restoration?.skip()
        try await wait({ controllers.count == 2 }, "Skip stalled restore")
        controllers[1].removeSelected()
        try await wait({ controllers.count == 3 }, "closing the temporary tab stalled restore")
        allowed = false
        controllers[2].finishClosing()
        try await wait({ controllers.count == 4 && permissionRequests == 1 }, "dismissal or denied AX stalled restore")
        try check(deleted.isEmpty && controllers.allSatisfy { $0.session.tabIDs.isEmpty }
            && SavedLayout.load().map { $0.windows.map(\.title) } == [["C", "A"], ["D"]],
            "a transient blank triggered automatic deletion or erased saved windows")
        allowed = true
        WorkspaceRestore.start([], makeWorkspace: makeWorkspace)
        let fresh = controllers.last!
        try check(fresh.name == "Fresh" && fresh.session.tabIDs.isEmpty && fresh.window.attachedSheet == nil,
                  "fresh startup unexpectedly prompted to restore")
        fresh.showPicker()
        try check(fresh.window.attachedSheet is NSPanel, "ordinary Add Window did not open the legacy sheet")
        if let sheet = fresh.window.attachedSheet { fresh.window.endSheet(sheet) }
        fresh.newTab()
        try check(try page(in: fresh).restoration == nil, "ordinary + didn't return to the normal new-tab launcher")
    }
}
