import AppKit
import QuartzCore
import SwiftUI
import WindowDockCore

private final class TabDragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?
    init(pasteboard: NSPasteboard, source: Any?, window: NSWindow? = nil, location: NSPoint = .zero) {
        draggingPasteboard = pasteboard
        draggingSource = source
        draggingDestinationWindow = window
        draggingLocation = location
    }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

private final class TabClickTarget: NSObject {
    var clicks = 0
    @objc func clicked(_ sender: Any?) { clicks += 1 }
}

@main
enum WorkspaceBackgroundSmoke {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        if CommandLine.arguments.contains("--activation-helper") || CommandLine.arguments
            .contains("--resizable-helper") {
            WindowSessionSmoke.runActivationHelper(
                application, resizable: CommandLine.arguments.contains("--resizable-helper"))
            application.run()
            return
        }
        let previous = NSWorkspace.shared.frontmostApplication
        application.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--finder-scan-only") {
            // Finder also publishes its desktop scroll area in AXWindows. Never move or open a user's window here.
            guard WindowAccess.isTrusted,
                  let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
                  let elements = WindowAccess.windowElements(finder)
            else { fputs("FAIL: Finder scan needs Accessibility permission and a running Finder\n", stderr); exit(1) }
            let expected = elements.filter {
                (try? WindowAccess.value($0, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole
            }
            let scan = WindowAccess.scan()
            let found = scan.windows.filter { $0.application.processIdentifier == finder.processIdentifier }
            guard !scan.failedApplications.contains(finder.localizedName ?? "App"),
                  found.count == expected.count,
                  expected.allSatisfy({ element in found.contains { CFEqual(element, $0.element) } })
            else { fputs("FAIL: Finder scan warned or lost an ordinary folder window\n", stderr); exit(1) }
            print("PASS: Finder scan returned \(found.count) ordinary windows without a false warning")
            return
        }
        if CommandLine.arguments.contains("--new-window-only") {
            Task { @MainActor in
                let failures = await WindowSessionSmoke.runNewWindowLaunchCheck()
                for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
                if failures
                    .isEmpty { print("PASS: launch creates a fresh window without switching to an existing tab") }
                exit(failures.isEmpty ? 0 : 1)
            }
            application.run()
            return
        }
        if CommandLine.arguments.contains("--stage-manager-only") {
            DispatchQueue.main.async {
                let failures = WorkspaceActivationSmoke.runStageManagerChecks()
                if let previous { _ = previous.activate(options: []) }
                for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
                if failures.isEmpty { print("PASS: workspaces and their windows share the Stage Manager stage") }
                exit(failures.isEmpty ? 0 : 1)
            }
            application.run()
            return
        }
        DispatchQueue.main.async {
            let focused = CommandLine.arguments.contains("--tab-move-only")
            let dropOnly = CommandLine.arguments.contains("--window-drop-only")
            let activationOnly = CommandLine.arguments.contains("--activation-only")
            let shortcutOnly = CommandLine.arguments.contains("--shortcut-only")
            let nestedOnly = CommandLine.arguments.contains("--nested-split-only")
            let focusOnly = CommandLine.arguments.contains("--focus-sync-only")
            let refitOnly = CommandLine.arguments.contains("--window-refit-only")
            let windowFollowOnly = CommandLine.arguments.contains("--window-follow-only")
            let constraintOnly = CommandLine.arguments.contains("--constraint-notice-only")
            let enhancedUIOnly = CommandLine.arguments.contains("--enhanced-ui-only")
            let emptyWorkspaceOnly = CommandLine.arguments.contains("--empty-workspace-only")
            let audioOnly = CommandLine.arguments.contains("--audio-indicator-only")
            let autoGroupOnly = CommandLine.arguments.contains("--auto-group-only")
            let failures: [String]
            if CommandLine.arguments.contains("--new-tab-only") {
                failures = WindowSessionSmoke.runNewTabChecks() + checkThumbnailSelection()
            } else if windowFollowOnly {
                failures = WindowSessionSmoke.runManagedWindowFollowChecks()
                    + WindowSessionSmoke.runManagedWindowSettledFollowChecks()
                    + WindowSessionSmoke.runManagedWindowLiveResizeChecks()
                    + WindowSessionSmoke.runManagedWindowDragConcealmentChecks()
                    + WindowSessionSmoke.runManagedWindowMinimizeFollowChecks()
            } else if autoGroupOnly {
                failures = WindowSessionSmoke.runAutoGroupChecks()
            } else if audioOnly {
                failures = checkAudioIndicatorLayout() + WindowSessionSmoke.runAudioIndicatorChecks()
                    + checkAudioPlaybackDetection()
            } else if emptyWorkspaceOnly {
                failures = WindowSessionSmoke.runEmptyWorkspaceDeletionChecks() + checkWindowPicker()
            } else if enhancedUIOnly {
                failures = WindowSessionSmoke.runEnhancedUIFrameChecks()
            } else if constraintOnly {
                failures = WindowSessionSmoke.runConstraintNoticeChecks()
            } else if refitOnly {
                failures = WindowSessionSmoke.runDisplacedWindowChecks() + WindowSessionSmoke
                    .runWindowEventRefitChecks() + WindowSessionSmoke.runWindowEventReturnPolicyChecks()
                    + WindowSessionSmoke.runActivationRefitChecks()
            } else if focusOnly {
                failures = WindowSessionSmoke.runExternalFocusChecks()
            } else if nestedOnly {
                failures =
                    WindowSessionSmoke.runNestedPaneChecks() + WindowSessionSmoke.runPanePinChecks()
                        + WindowSessionSmoke.runTabSelectionFeedbackChecks()
                        + WindowSessionSmoke.runNestedPaneUIChecks() + WindowSessionSmoke.runNestedPaneLimitChecks()
                        + WindowSessionSmoke.runNestedPaneMinimumChecks() + checkGridLayout() + checkTabMoveRouting()
            } else if dropOnly {
                failures = WindowSessionSmoke.runExternalWindowDropChecks() + checkNativeWindowDrops()
            } else if shortcutOnly {
                failures = WindowSessionSmoke.runShortcutChecks()
            } else if focused {
                failures = checkTabMoveRouting() + WindowSessionSmoke.runTabTransferRevealChecks()
                    + WindowSessionSmoke.runOutsideTabDropChecks() + WindowSessionSmoke.runWorkspaceMergeChecks()
            } else if activationOnly {
                failures =
                    WindowSessionSmoke.runFrontWindowOnlyActivationChecks()
                        + WorkspaceActivationSmoke.runDockMenuSwitchChecks() + WindowSessionSmoke
                        .runTitlebarFocusChecks()
                        + WorkspaceActivationSmoke.runAutoHiddenToolbarActivationChecks()
                        + WindowSessionSmoke.runTabTransferKeyChecks() + WindowSessionSmoke.runActivationRefitChecks()
            } else {
                failures =
                    WindowSessionSmoke
                        .runChecks() + checkWindowPicker() + checkThumbnailSelection() + runChecks() +
                        checkCompactLayout()
                        + checkGridLayout() + checkTabMoveRouting() + checkNativeWindowDrops()
                        + checkAudioIndicatorLayout() + WindowSessionSmoke.runAudioIndicatorChecks()
                        + checkAudioPlaybackDetection()
            }
            if let previous {
                if #available(macOS 14, *) { application.yieldActivation(to: previous) }
                _ = previous.activate(options: [])
            }
            if failures.isEmpty {
                print(
                    CommandLine.arguments.contains("--new-tab-only")
                        ? "PASS: inline start pages, selection, replacement, failure and closing"
                        : autoGroupOnly
                        ? "PASS: automatic app grouping"
                        : audioOnly
                        ? "PASS: tab speakers for applications playing audio"
                        : emptyWorkspaceOnly
                        ? "PASS: empty-workspace deletion, last-tab transfer and deferred cleanup"
                        : nestedOnly
                        ? "PASS: nested pane menus, layout, resizing, persistence, tab reflow and routing"
                        : constraintOnly
                        ? "PASS: window constraint notices"
                        : enhancedUIOnly
                        ? "PASS: Enhanced UI frame alignment"
                        : dropOnly
                        ? "PASS: native WindowServer move/release sampling and nonactivating drop feedback"
                        : focused
                        ? "PASS: tab move routing, context menu and drag overlay cleanup"
                        : focusOnly
                        ? "PASS: external focus updates tabs without raising managed windows"
                        : refitOnly
                        ? "PASS: displaced windows return to their panes without raising other windows"
                        : activationOnly
                        ?
                        "PASS: front-window-only app activation, Dock menu workspace switch, titlebar focus, auto-hidden tab bar click, tab drop key and activation refit"
                        :
                        "PASS: window drop feedback, 2D grid, tab moves, picker, lifecycle, compact layout, masking, resize and tab speakers")
                exit(0)
            }
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
        application.run()
    }

    @MainActor
    private static func checkNativeWindowDrops() -> [String] {
        var failures: [String] = []
        let disabledDrop = WorkspaceWindowDrop { [] }
        var sampledWhileDisabled = false
        disabledDrop.windows = {
            sampledWhileDisabled = true
            return []
        }
        disabledDrop.isEnabled = false
        disabledDrop.poll()
        if sampledWhileDisabled {
            failures.append("disabled window dragging still sampled foreign windows")
        }
        let host = WorkspaceWindow(
            contentRect: NSRect(x: 120, y: 120, width: 900, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let chrome = WorkspaceChromeView(frame: host.contentLayoutRect)
        host.contentView = chrome
        let target = NSWindow(
            contentRect: NSRect(x: 50, y: 80, width: 400, height: 300),
            styleMask: .titled, backing: .buffered, defer: false)
        target.isReleasedWhenClosed = false
        // The open animation scales the window, so early WindowServer samples would look like a resize.
        target.animationBehavior = .none
        defer {
            chrome.hideWindowDropTarget()
            chrome.windowDropPanel?.close()
            target.close()
            host.close()
        }
        func flush() {
            host.displayIfNeeded()
            target.displayIfNeeded()
            CATransaction.flush()
            let deadline = Date().addingTimeInterval(0.05)
            repeat {
                if let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            } while Date() < deadline
        }
        host.orderFrontRegardless()
        target.orderFrontRegardless()
        chrome.layoutSubtreeIfNeeded()
        flush()
        do {
            let before = try WindowAccess.windowServerWindows().filter { $0.id == CGWindowID(target.windowNumber) }
            guard let initial = before.first else { return ["native window was missing from WindowServer sampling"] }
            let start = CGPoint(x: initial.frame.minX + 40, y: initial.frame.minY + 15)
            var tracker = WorkspaceWindowDragTracker()
            _ = tracker.update(buttonDown: false, point: start, windows: before, ownPID: -1)
            _ = tracker.update(buttonDown: true, point: start, windows: before, ownPID: -1)
            target.setFrameOrigin(NSPoint(x: target.frame.minX + 120, y: target.frame.minY + 60))
            flush()
            let after = try WindowAccess.windowServerWindows().filter { $0.id == initial.id }
            guard let moved = after.first else { return ["native moving window lost its WindowServer identity"] }
            let end = CGPoint(x: moved.frame.minX + 40, y: moved.frame.minY + 15)
            if case .moving(let drag) = tracker.update(buttonDown: true, point: end, windows: after, ownPID: -1) {
                if drag.originalFrame != initial.frame
                    || drag.window.processID != ProcessInfo.processInfo.processIdentifier
                {
                    failures.append("native sampling lost the original geometry or owning process")
                }
            } else {
                failures.append(
                    "actual WindowServer geometry changes were not detected without NSEvent delivery (\(initial.frame) -> \(moved.frame))")
            }
            if case .released = tracker.update(buttonDown: false, point: end, windows: after, ownPID: -1) {
            } else {
                failures.append("native sampling did not finish on the first released-button sample")
            }
            let previousKey = NSApp.keyWindow
            let dropPoint = host.convertPoint(
                toScreen: chrome.addButton.convert(
                    NSPoint(x: chrome.addButton.bounds.midX, y: chrome.addButton.bounds.midY), to: nil))
            chrome.showWindowDropTarget(at: dropPoint, requiresPermission: false)
            flush()
            if chrome.windowDropPreview == nil || NSApp.keyWindow !== previousKey {
                failures.append("drop preview was hidden or stole focus")
            }
            chrome.showWindowDropTarget(at: dropPoint, requiresPermission: true)
            guard let panel = chrome.windowDropPanel else { return failures + ["permission feedback was not created"] }
            let messages = panel.contentView?.subviews.compactMap { ($0 as? NSTextField)?.stringValue } ?? []
            if !messages.contains(L("追加にはアクセシビリティの許可が必要です")) || chrome.windowDropPreview != nil
                || !panel.ignoresMouseEvents || panel.isKeyWindow
            {
                failures.append("unauthorized drops showed no permission explanation")
            }
            chrome.hideWindowDropTarget()
            if panel.isVisible || chrome.windowDropPreview != nil {
                failures.append("drop feedback persisted after completion/cancellation")
            }
            chrome.setAutoHideTabBar(true)
            chrome.setAutoHiddenToolbarVisible(true)
            if let toolbar = chrome.autoHiddenToolbarPanel {
                let point = NSPoint(x: toolbar.frame.midX, y: toolbar.frame.midY)
                chrome.showWindowDropTarget(at: point, requiresPermission: false)
                if !panel.isVisible || panel.frame != toolbar.frame || !panel.ignoresMouseEvents
                    || panel.isKeyWindow || NSApp.keyWindow !== previousKey
                {
                    failures.append("auto-hidden tab bar was not shown in front without intercepting the drag")
                }
                chrome.hideWindowDropTarget()
            } else {
                failures.append("auto-hidden toolbar was not created")
            }
            chrome.setAutoHideTabBar(false)
        } catch {
            failures.append("native window drop check failed: \(error.localizedDescription)")
        }
        return failures
    }

    @MainActor
    private static func checkThumbnailSelection() -> [String] {
        let candidates = (0 ..< 3).map {
            WindowCandidate(
                element: AXUIElementCreateApplication(pid_t(910_000 + $0)),
                application: .current,
                title: "Choice \($0)")
        }
        var submitted: [[String]] = []
        let grid = WindowChoiceGrid(windows: candidates, previews: nil) {
            submitted.append($0.map(\.title))
            return true
        }
        let host = NSHostingView(rootView: grid.frame(width: 640, height: 400)
            .environment(\.accessibilityEnabled, true))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 640, height: 400),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }

        // SwiftUI's lazy grid exposes the AX selectors without adopting NSAccessibilityProtocol.
        func findButton(_ name: String, in nodes: [Any]) -> AnyObject? {
            for node in nodes.map({ $0 as AnyObject }) {
                if node.accessibilityRole?() == .button,
                   node.accessibilityLabel?() == name || node.accessibilityTitle?() == name { return node }
                if let match = findButton(name, in: node.accessibilityChildren?() ?? []) { return match }
            }
            return nil
        }
        func button(_ name: String) -> AnyObject? {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return findButton(name, in: host.accessibilityChildren() ?? [])
        }
        func press(_ name: String) -> Bool {
            guard let button = button(name), button.isAccessibilityEnabled?() == true else { return false }
            return button.accessibilityPerformPress?() == true
        }
        func click(_ index: Int, with flags: NSEvent.ModifierFlags) -> Bool {
            guard let frame = button(candidates[index].label)?.accessibilityFrame?(),
                  !frame.isEmpty else { return false }
            let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            // Send these only through the fixture's own AppKit queue, not to the system pointer.
            for type in [NSEvent.EventType.leftMouseUp, .leftMouseDown] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 1, clickCount: 1, pressure: 1) else { return false }
                NSApp.postEvent(event, atStart: true)
            }
            while let event = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp], until: .distantPast,
                                              inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            return true
        }
        guard press(L("複数選択")), button(L("%d件を追加", 0))?.isAccessibilityEnabled?() == false, press(candidates[1].label),
              press(L("選択したアプリの全ウィンドウを選択")), press(candidates[1].label),
              submitted.isEmpty, press(L("%d件を追加", 2)), submitted == [["Choice 0", "Choice 2"]]
        else {
            return ["thumbnail controls didn't select an app, deselect a card and submit the checked windows in order"]
        }
        guard press(L("キャンセル")), press(candidates[1].label), submitted.last == ["Choice 1"], submitted.count == 2
        else { return ["cancelling thumbnail selection didn't restore one-click add"] }
        guard click(2, with: .shift), button(L("%d件を追加", 1)) != nil, click(0, with: .shift),
              button(L("%d件を追加", 3)) != nil, click(1, with: .shift), button(L("%d件を追加", 2)) != nil,
              click(2, with: .command), press(L("%d件を追加", 1)), submitted.last == ["Choice 1"], submitted.count == 3
        else { return ["Shift-click did not select/shrink a range, or Command-click didn't toggle a thumbnail"] }
        return []
    }

    @MainActor
    private static func checkWindowPicker() -> [String] {
        var failures: [String] = []
        let candidates = (0 ..< 3).map {
            WindowCandidate(
                element: AXUIElementCreateApplication(pid_t(910_000 + $0)),
                application: .current,
                title: "Picker \($0)")
        }
        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        for scenario in 0 ..< 4 {
            let host = NSWindow(
                contentRect: NSRect(x: 120, y: 120, width: 720, height: 480),
                styleMask: .titled, backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            var received: [[WindowCandidate]] = []
            let available = scenario == 3 ? [] : candidates
            let picker = WindowPicker(candidates: available, failedApplications: []) { received.append($0) }
            picker.present(on: host) {}
            defer {
                if let sheet = host.attachedSheet { host.endSheet(sheet) }
                host.close()
                withExtendedLifetime(picker) {}
            }
            guard let content = host.attachedSheet?.contentView else {
                failures.append("picker sheet was not presented")
                continue
            }
            content.layoutSubtreeIfNeeded()
            let views = descendants(of: content)
            guard let table = views.compactMap({ $0 as? NSTableView }).first,
                  let add = views.compactMap({ $0 as? NSButton }).first(where: {
                      $0.action == NSSelectorFromString("add")
                  }),
                  let cancel = views.compactMap({ $0 as? NSButton }).first(where: { $0.keyEquivalent == "\u{1b}" })
            else {
                let buttons = views.compactMap { $0 as? NSButton }.map {
                    "\($0.title):\($0.keyEquivalent.debugDescription)"
                }
                failures.append(
                    "picker controls were not found: tables=\(views.compactMap { $0 as? NSTableView }.count), buttons=\(buttons)")
                continue
            }
            if scenario == 3 {
                if add.isEnabled { failures.append("empty picker enabled the add button") }
                add.performClick(nil)
                cancel.performClick(nil)
                if !received.isEmpty { failures.append("empty picker submitted windows") }
                continue
            }
            table.deselectAll(nil)
            if add.isEnabled { failures.append("clearing picker selection did not disable add") }
            table.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
            if !add.isEnabled || add.title != "2件を追加" {
                failures.append("picker did not display the multiple-selection count")
            }
            if scenario == 1 {
                cancel.performClick(nil)
                if !received.isEmpty { failures.append("cancel submitted selected windows") }
                continue
            }
            if scenario == 2 {
                table.selectAll(nil)
                guard let action = table.doubleAction else {
                    failures.append("picker has no double-click action")
                    continue
                }
                _ = NSApp.sendAction(action, to: table.target, from: table)
            } else {
                add.performClick(nil)
            }
            let expected = scenario == 2 ? candidates : [candidates[0], candidates[2]]
            if received.count != 1 || received.first?.count != expected.count
                || zip(received.first ?? [], expected).contains(where: { !$0.0.isSameWindow(as: $0.1) })
            {
                failures.append("picker did not submit all selected windows once in row order")
            }
        }
        return failures
    }

    @MainActor
    private static func runChecks() -> [String] {
        var failures: [String] = []
        let host = WorkspaceWindow(
            contentRect: NSRect(x: 120, y: 120, width: 420, height: 360),
            styleMask: [.borderless, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        host.title = "WindowDock rendering test"
        host.isReleasedWhenClosed = false
        host.isOpaque = false
        host.backgroundColor = .clear
        let workspace = WorkspaceBackgroundView(frame: NSRect(origin: .zero, size: host.contentLayoutRect.size))
        let stage = NSView(frame: NSRect(x: 8, y: 8, width: 404, height: 260))
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor.clear.cgColor
        workspace.addSubview(stage)
        workspace.contentArea = stage
        host.contentView = workspace
        let target = NSWindow(
            contentRect: host.convertToScreen(stage.frame),
            styleMask: .titled,
            backing: .buffered,
            defer: false)
        target.isReleasedWhenClosed = false
        target.backgroundColor = .systemGreen
        let backgroundTarget = NSWindow(
            contentRect: host.convertToScreen(stage.frame),
            styleMask: .titled,
            backing: .buffered,
            defer: false)
        backgroundTarget.isReleasedWhenClosed = false
        backgroundTarget.backgroundColor = .systemBlue
        // Keep unrelated desktop windows from occluding the fixture's native hit tests.
        host.level = .floating
        target.level = .floating
        backgroundTarget.level = .floating
        target.setFrame(host.convertToScreen(stage.frame), display: false)
        backgroundTarget.setFrame(target.frame, display: false)
        workspace.coveredScreenRect = target.frame
        defer {
            host.onWorkspaceFrameChange = nil
            host.close()
            target.close()
            backgroundTarget.close()
        }
        backgroundTarget.orderFrontRegardless()
        target.orderFrontRegardless()
        host.makeKeyAndOrderFront(nil)
        host.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        func flush() {
            workspace.displayIfNeeded()
            host.displayIfNeeded()
            CATransaction.flush()
            let deadline = Date().addingTimeInterval(0.05)
            repeat {
                if let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            } while Date() < deadline
        }

        func checkAlpha(_ point: NSPoint, transparent: Bool, label: String) {
            guard let bitmap = workspace.bitmapImageRepForCachingDisplay(in: workspace.bounds) else {
                failures.append("\(label): could not allocate view bitmap")
                return
            }
            workspace.cacheDisplay(in: workspace.bounds, to: bitmap)
            let x = Int(point.x * CGFloat(bitmap.pixelsWide) / workspace.bounds.width)
            let y = Int((workspace.bounds.height - point.y) * CGFloat(bitmap.pixelsHigh) / workspace.bounds.height)
            guard let color = bitmap.colorAt(x: x, y: y) else {
                failures.append("\(label): could not sample view bitmap")
                return
            }
            let alpha = color.alphaComponent
            if transparent ? alpha > 0.01 : alpha < 0.99 {
                failures.append("\(label): expected \(transparent ? "transparent" : "opaque"), alpha=\(alpha)")
            }
        }

        func contentCenter() -> NSPoint {
            NSPoint(x: stage.frame.midX, y: stage.frame.midY)
        }

        func checkHit(_ point: NSPoint, expected: NSWindow, label: String) {
            let screenPoint = host.convertToScreen(NSRect(origin: point, size: .zero)).origin
            let hit = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
            if hit != expected.windowNumber {
                failures.append("\(label): hit window \(hit), expected \(expected.windowNumber)")
            }
        }

        let activationDeadline = Date().addingTimeInterval(2)
        while !NSApp.isActive && Date() < activationDeadline { flush() }
        host.makeKeyAndOrderFront(nil)
        host.orderFrontRegardless()
        flush()
        checkAlpha(contentCenter(), transparent: false, label: "empty workspace")
        workspace.revealsWindow = true
        flush()
        checkAlpha(contentCenter(), transparent: true, label: "selected content")
        checkAlpha(NSPoint(x: 100, y: 320), transparent: false, label: "tab controls")
        checkAlpha(NSPoint(x: 4, y: 100), transparent: false, label: "resize border")
        checkHit(NSPoint(x: 100, y: 320), expected: host, label: "tab controls")
        checkHit(NSPoint(x: 4, y: 100), expected: host, label: "resize border")
        checkHit(NSPoint(x: workspace.bounds.maxX - 12, y: 12), expected: host, label: "resize grip")

        for iteration in 1 ... 20 {
            let selected = iteration.isMultiple(of: 2) ? backgroundTarget : target
            selected.makeKeyAndOrderFront(nil)
            selected.orderFrontRegardless()
            host.makeKeyAndOrderFront(nil)
            host.orderFrontRegardless()
            flush()
            if !host.isKeyWindow {
                failures.append("host refocus \(iteration): host did not become the key window")
                break
            }
            checkAlpha(contentCenter(), transparent: true, label: "host refocus \(iteration)")
            checkHit(contentCenter(), expected: selected, label: "stacked selection / host refocus \(iteration)")
        }
        target.orderFrontRegardless()
        host.makeKeyAndOrderFront(nil)
        flush()

        let originalFrame = host.frame
        let movedFrame = originalFrame.offsetBy(dx: 100, dy: 0)
        let exposedPoint = NSPoint(x: stage.frame.maxX - 10, y: stage.frame.midY)
        workspace.prepareForFrameChange(to: movedFrame)
        flush()
        checkAlpha(exposedPoint, transparent: false, label: "gap masked before parent moves")
        checkHit(exposedPoint, expected: host, label: "gap masked before parent moves")
        workspace.finishFrameChange()

        host.setWorkspaceFrame(movedFrame)
        flush()
        checkAlpha(exposedPoint, transparent: false, label: "delayed target exposes no background")
        checkHit(exposedPoint, expected: host, label: "delayed target exposes no background")
        let overlap = NSPoint(x: stage.frame.minX + 20, y: stage.frame.midY)
        checkAlpha(overlap, transparent: true, label: "overlapping target remains visible during delay")
        checkHit(overlap, expected: target, label: "overlapping target remains interactive during delay")
        target.setFrame(host.convertToScreen(stage.frame), display: true)
        backgroundTarget.setFrame(target.frame, display: true)
        target.orderFrontRegardless()
        host.orderFrontRegardless()
        workspace.coveredScreenRect = target.frame
        workspace.refreshCoverage()
        flush()
        checkAlpha(exposedPoint, transparent: true, label: "target caught up")
        checkHit(exposedPoint, expected: target, label: "target caught up")

        host.onWorkspaceFrameChange = {
            stage.frame = NSRect(x: 8, y: 8, width: workspace.bounds.width - 16, height: workspace.bounds.height - 100)
            backgroundTarget.setFrame(host.convertToScreen(stage.frame), display: true)
            target.setFrame(host.convertToScreen(stage.frame), display: true)
            workspace.coveredScreenRect = target.frame
            workspace.refreshCoverage()
        }
        host.toggleMaximize()
        flush()
        if host.frame != host.screen?.visibleFrame {
            failures.append("maximize did not use the available screen area")
        }
        host.toggleMaximize()
        flush()
        if host.frame != movedFrame {
            failures.append("maximize did not restore the previous frame")
        }
        checkHit(contentCenter(), expected: target, label: "content after maximize and restore")

        let minimum = NSSize(width: 240, height: 180)
        let expanded = WorkspaceResize.resizedFrame(
            from: movedFrame,
            delta: NSSize(width: 80, height: -40),
            edges: [.right, .bottom],
            minimumSize: minimum)
        host.setWorkspaceFrame(expanded)
        flush()
        if host.frame.size != NSSize(width: movedFrame.width + 80, height: movedFrame.height + 40)
            || host.frame.minX != movedFrame.minX || host.frame.maxY != movedFrame.maxY
        {
            failures.append("resize grip did not grow the window while preserving its top-left corner")
        }
        host.setWorkspaceFrame(movedFrame)
        flush()

        stage.frame = NSRect(x: 8, y: 8, width: 300, height: 200)
        workspace.needsLayout = true
        workspace.layoutSubtreeIfNeeded()
        flush()
        checkAlpha(contentCenter(), transparent: true, label: "resized content")
        checkAlpha(NSPoint(x: 350, y: 240), transparent: false, label: "old content cleared after resize")
        checkHit(contentCenter(), expected: target, label: "resized content")
        checkHit(NSPoint(x: 350, y: 240), expected: host, label: "old content cleared after resize")

        workspace.revealsWindow = false
        flush()
        checkAlpha(contentCenter(), transparent: false, label: "last tab removed")
        checkHit(contentCenter(), expected: host, label: "last tab removed")
        return failures
    }

    @MainActor
    private static func checkGridLayout() -> [String] {
        var failures: [String] = []
        let host = WorkspaceWindow(
            contentRect: NSRect(x: 120, y: 120, width: 1120, height: 760),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.isOpaque = false
        host.backgroundColor = .clear
        host.level = .floating
        let chrome = WorkspaceChromeView(frame: .zero)
        host.contentView = chrome
        let targets = (0 ..< 16).map { _ -> NSWindow in
            let target = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            target.isReleasedWhenClosed = false
            target.level = .floating
            target.backgroundColor = .systemGreen
            return target
        }
        defer {
            host.close()
            targets.forEach { $0.close() }
        }
        func flush() {
            chrome.displayIfNeeded()
            host.displayIfNeeded()
            CATransaction.flush()
            let deadline = Date().addingTimeInterval(0.05)
            repeat {
                if let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            } while Date() < deadline
        }
        func screenRect(_ area: NSView) -> NSRect {
            host.convertToScreen(area.convert(area.bounds, to: nil))
        }
        func hit(_ point: NSPoint, expected: NSWindow, label: String) {
            let screen = host.convertToScreen(NSRect(origin: point, size: .zero)).origin
            let actual = NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0)
            if actual != expected.windowNumber {
                failures.append("\(label): hit \(actual), expected \(expected.windowNumber)")
            }
        }
        func synchronize() {
            var frames: [Int: CGRect] = [:]
            for (index, area) in chrome.gridAreas.enumerated() {
                targets[index].setFrame(screenRect(area), display: true)
                frames[index] = targets[index].frame
            }
            chrome.presentFrames(frames)
        }
        var gridChanges = 0
        chrome.onGridChange = { _ in gridChanges += 1 }
        for size in [
            WorkspaceGridSize.single, WorkspaceGridSize(columns: 2, rows: 1),
            WorkspaceGridSize(columns: 1, rows: 2), WorkspaceGridSize(columns: 4, rows: 4),
        ] {
            chrome.setGrid(size, activeCell: 0)
            chrome.layoutSubtreeIfNeeded()
            let areas = chrome.gridAreas.map { chrome.stage.convert($0.bounds, from: $0) }
            if chrome.gridSize != size || areas.count != size.cellCount {
                failures.append("grid \(size): wrong cell count")
            }
            let divider = chrome.stage.dividerThickness
            let expectedArea =
                (chrome.stage.bounds.width - CGFloat(size.columns - 1) * divider)
                    * (chrome.stage.bounds.height - CGFloat(size.rows - 1) * divider)
            if abs(areas.reduce(CGFloat(0), { $0 + $1.width * $1.height }) - expectedArea) > 0.1 {
                failures.append("grid \(size): areas do not exactly partition stage")
            }
            for i in areas.indices {
                if !chrome.stage.bounds.contains(areas[i]) { failures.append("grid cell extends outside stage") }
                for j in areas.indices where j > i {
                    if areas[i].intersects(areas[j]) { failures.append("grid \(size): cells overlap") }
                }
                if i % size.columns > 0 && areas[i].minX <= areas[i - 1].maxX {
                    failures.append("grid columns out of order")
                }
                if i >= size.columns && areas[i].maxY >= areas[i - size.columns].minY {
                    failures.append("grid rows out of order")
                }
            }
            chrome.showManagedWindows(true)
            synchronize()
            for target in targets.prefix(size.cellCount) { target.orderFrontRegardless() }
            host.makeKeyAndOrderFront(nil)
            host.orderFrontRegardless()
            flush()
            for (index, area) in chrome.gridAreas.enumerated() {
                let rect = chrome.convert(area.bounds, from: area)
                hit(NSPoint(x: rect.midX, y: rect.midY), expected: targets[index], label: "grid cell \(index)")
            }
            if size.columns > 1 {
                let left = chrome.convert(chrome.gridAreas[0].bounds, from: chrome.gridAreas[0])
                let right = chrome.convert(chrome.gridAreas[1].bounds, from: chrome.gridAreas[1])
                hit(NSPoint(x: (left.maxX + right.minX) / 2, y: left.midY), expected: host, label: "column divider")
            }
            if size.rows > 1 {
                let top = chrome.convert(chrome.gridAreas[0].bounds, from: chrome.gridAreas[0])
                let bottom = chrome.convert(chrome.gridAreas[size.columns].bounds, from: chrome.gridAreas[size.columns])
                hit(NSPoint(x: top.midX, y: (top.minY + bottom.maxY) / 2), expected: host, label: "row divider")
            }
        }
        if gridChanges != 0 { failures.append("programmatic grid update sent a user callback") }
        chrome.columnSelector.selectItem(at: 1)
        _ = NSApp.sendAction(
            chrome.columnSelector.action!, to: chrome.columnSelector.target, from: chrome.columnSelector)
        if gridChanges != 1 || chrome.gridSize != WorkspaceGridSize(columns: 4, rows: 4) {
            failures.append("user selector did not request exactly one grid change")
        }
        synchronize()
        chrome.prepareForFrameChange(to: host.frame.offsetBy(dx: 30, dy: 0))
        flush()
        for area in chrome.gridAreas {
            let rect = chrome.convert(area.bounds, from: area)
            hit(NSPoint(x: rect.maxX - 10, y: rect.midY), expected: host, label: "grid delayed move mask")
        }
        chrome.finishFrameChange()
        chrome.setGrid(WorkspaceGridSize(columns: 2, rows: 2), activeCell: 0)
        chrome.layoutSubtreeIfNeeded()
        let minimums: [Int: CGSize] = [0: CGSize(width: 650, height: 400), 3: CGSize(width: 200, height: 150)]
        if !chrome.fitPanesToMinimumSizes(minimums) { failures.append("feasible grid minimums were rejected") }
        let before = chrome.gridAreas.map(\.frame)
        if before[0].width < 650 || before[0].height < 400 || before[3].width < 200 || before[3].height < 150 {
            failures.append("grid fitting did not honor per-column/row minimums")
        }
        if chrome.fitPanesToMinimumSizes([0: CGSize(width: 5000, height: 100)])
            || chrome.gridAreas.map(\.frame) != before
        {
            failures.append("infeasible grid fitting mutated geometry")
        }
        var changes = 0
        chrome.onPaneLayoutChange = { changes += 1 }
        func drag(from start: NSPoint, to end: NSPoint) {
            let startWindow = chrome.stage.convert(start, to: nil)
            let endWindow = chrome.stage.convert(end, to: nil)
            func event(_ type: NSEvent.EventType, _ location: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: host.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1)!
            }
            NSApp.postEvent(event(.leftMouseDragged, endWindow), atStart: false)
            NSApp.postEvent(event(.leftMouseUp, endWindow), atStart: false)
            chrome.stage.mouseDown(with: event(.leftMouseDown, startWindow))
        }
        let first = chrome.gridAreas[0].frame
        drag(
            from: NSPoint(x: first.maxX + chrome.stage.dividerThickness / 2, y: first.midY),
            to: NSPoint(x: first.maxX - 100, y: first.midY))
        if chrome.gridAreas[0].frame.width < 650 || chrome.gridAreas[1].frame.width < 200 {
            failures.append("column divider bypassed learned minimums")
        }
        let afterColumn = chrome.gridAreas[0].frame
        drag(
            from: NSPoint(x: afterColumn.midX, y: afterColumn.minY - chrome.stage.dividerThickness / 2),
            to: NSPoint(x: afterColumn.midX, y: afterColumn.minY - 80))
        if chrome.gridAreas[0].frame.height < 400 || chrome.gridAreas[2].frame.height < 150
            || chrome.gridAreas[0].frame.height <= afterColumn.height || changes == 0
        {
            failures.append("row divider did not independently resize within learned minimums")
        }
        chrome.onPaneLayoutChange = nil
        host.setFrame(NSRect(origin: host.frame.origin, size: NSSize(width: 1000, height: 700)), display: false)
        chrome.layoutSubtreeIfNeeded()
        if chrome.gridAreas[0].frame.width < 650 || chrome.gridAreas[0].frame.height < 400
            || chrome.gridAreas[3].frame.width < 200 || chrome.gridAreas[3].frame.height < 150
        {
            failures.append("host resize forgot learned minimums")
        }
        if !chrome.fitPanesToMinimumSizes([0: CGSize(width: 100, height: 100)]) {
            failures.append("replacement minimums were rejected")
        }
        let resized = chrome.gridAreas[0].frame
        drag(
            from: NSPoint(x: resized.maxX + chrome.stage.dividerThickness / 2, y: resized.midY),
            to: NSPoint(x: 0, y: resized.midY))
        if chrome.gridAreas[0].frame.width > 101 {
            failures.append("replacement minimums retained a stale column constraint")
        }
        chrome.showManagedWindows(false)
        let firstRect = screenRect(chrome.gridAreas[0])
        let center = NSPoint(x: firstRect.midX, y: firstRect.midY)
        if !chrome.acceptsWindowDrop(at: center) { failures.append("empty stage did not accept a drop") }
        var activated: Int?
        chrome.onActivateCell = { activated = $0 }
        let area = chrome.gridAreas[3]
        let click = NSEvent.mouseEvent(
            with: .leftMouseDown, location: area.convert(NSPoint(x: 10, y: 10), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        area.mouseDown(with: click)
        if activated != 3 { failures.append("empty cell click did not select its row-major index") }
        chrome.showManagedWindows(true)
        if chrome.acceptsWindowDrop(at: center) { failures.append("occupied stage accepted a drop") }
        guard
            let nested = PaneLayout.pane.splittingPane(at: 0, axis: .horizontal)?
            .splittingPane(at: 1, axis: .vertical)
        else { return failures + ["could not construct nested layout fixture"] }
        chrome.setCustomLayout(nested, activeCell: 1)
        chrome.layoutSubtreeIfNeeded()
        let nestedMinimums = [
            0: CGSize(width: 400, height: 600), 1: CGSize(width: 200, height: 120),
            2: CGSize(width: 200, height: 200),
        ]
        if !chrome.fitPanesToMinimumSizes(nestedMinimums) {
            failures.append("nested minimums were incorrectly shared across the unsplit left pane")
        }
        let nestedFrames = chrome.gridAreas.map(\.frame)
        if nestedFrames.count != 3 || abs(nestedFrames[0].height - chrome.stage.bounds.height) > 0.5
            || nestedFrames[1].minX != nestedFrames[2].minX || nestedFrames[1].maxY != nestedFrames[0].maxY
            || nestedFrames[2].minY != nestedFrames[0].minY
        {
            failures.append("nested geometry was not one full-height left pane with two stacked right panes")
        }
        targets.dropFirst(3).forEach { $0.orderOut(nil) }
        synchronize()
        targets.prefix(3).forEach { $0.orderFrontRegardless() }
        host.orderFrontRegardless()
        flush()
        for (index, area) in chrome.gridAreas.enumerated() {
            let rect = chrome.convert(area.bounds, from: area)
            hit(NSPoint(x: rect.midX, y: rect.midY), expected: targets[index], label: "nested aperture \(index)")
        }
        let dividerY = nestedFrames[1].minY - chrome.stage.dividerThickness / 2
        hit(
            chrome.stage.convert(NSPoint(x: nestedFrames[0].midX, y: dividerY), to: chrome),
            expected: targets[0], label: "no divider across the unsplit left pane")
        hit(
            chrome.stage.convert(NSPoint(x: nestedFrames[1].midX, y: dividerY), to: chrome),
            expected: host, label: "nested right divider")
        drag(
            from: NSPoint(x: nestedFrames[1].midX, y: dividerY),
            to: NSPoint(x: nestedFrames[1].midX, y: dividerY - 1000))
        if chrome.gridAreas[0].frame != nestedFrames[0] || abs(chrome.gridAreas[2].frame.height - 200) > 0.5 {
            failures.append("nested divider drag changed the left pane or bypassed its child's minimum size")
        }
        return failures
    }

    @MainActor
    private static func checkTabMoveRouting() -> [String] {
        var failures: [String] = []
        let host = WorkspaceWindow(
            contentRect: NSRect(x: 120, y: 120, width: 900, height: 600),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.isOpaque = false
        host.backgroundColor = .clear
        host.level = .floating
        let chrome = WorkspaceChromeView(frame: .zero)
        host.contentView = chrome
        chrome.setGrid(WorkspaceGridSize(columns: 2, rows: 1), activeCell: 0)
        chrome.showManagedWindows(true)
        let tab = chrome.appendTab(title: "Move source", selected: true)
        let targetTab = chrome.appendTab(title: "Swap target", selected: false)
        tab.select.tag = 77
        targetTab.select.tag = 78
        chrome.layoutSubtreeIfNeeded()
        let targets = chrome.gridAreas.map { area -> WorkspaceWindow in
            let rect = host.convertToScreen(area.convert(area.bounds, to: nil))
            let target = WorkspaceWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            target.isReleasedWhenClosed = false
            target.level = .floating
            target.backgroundColor = .systemGreen
            target.setFrame(rect, display: true)
            return target
        }
        let board = NSPasteboard(name: NSPasteboard.Name("WindowDockSmoke-\(UUID().uuidString)"))
        defer {
            board.releaseGlobally()
            host.close()
            targets.forEach { $0.close() }
        }
        chrome.presentFrames(
            Dictionary(uniqueKeysWithValues: targets.enumerated().map { ($0.offset, $0.element.frame) }))
        targets.forEach { $0.orderFrontRegardless() }
        targets[0].makeKeyAndOrderFront(nil)
        host.orderFront(nil)
        func flush() {
            host.displayIfNeeded()
            CATransaction.flush()
            let deadline = Date().addingTimeInterval(0.05)
            repeat {
                if let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            } while Date() < deadline
        }
        func hit(_ index: Int, expected: NSWindow, label: String) {
            let area = chrome.gridAreas[index]
            let point = area.convert(NSPoint(x: area.bounds.midX, y: area.bounds.midY), to: nil)
            let screen = host.convertToScreen(NSRect(origin: point, size: .zero)).origin
            let actual = NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0)
            if actual != expected.windowNumber {
                failures.append("\(label): hit \(actual), expected \(expected.windowNumber)")
            }
        }
        flush()
        let clickTarget = TabClickTarget()
        tab.select.target = clickTarget
        tab.select.action = #selector(TabClickTarget.clicked(_:))
        let location = tab.select.convert(NSPoint(x: 10, y: 10), to: nil)
        func mouse(_ type: NSEvent.EventType, _ location: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: host.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(mouse(.leftMouseUp, location), atStart: false)
        tab.select.mouseDown(with: mouse(.leftMouseDown, location))
        if clickTarget.clicks != 1 { failures.append("normal tab click was not preserved") }

        var moves: [(Int, Int)] = []
        chrome.onMoveTab = { moves.append(($0, $1)) }
        let menu = tab.select.menu(for: mouse(.rightMouseDown, location))
        if let root = menu?.items.first, root.title == "配置を入れ替え",
           let items = root.submenu?.items, items.count == 2, let action = items[1].action
        {
            _ = NSApp.sendAction(action, to: items[1].target, from: items[1])
        } else {
            failures.append("tab move context menu did not offer each cell")
        }
        if moves.count != 1 || moves[0].0 != 77 || moves[0].1 != 1 {
            failures.append("context menu did not report source tag and destination cell")
        }
        moves.removeAll()
        flush()
        let keyBefore = NSApp.keyWindow
        let activeBefore = NSApp.isActive
        let paneSourceGroup = tab.select.superview!
        let paneSourceFrame = paneSourceGroup.frame
        chrome.beginTabDrag(source: tab.select, token: "internal-token")
        flush()
        if NSApp.keyWindow !== keyBefore || NSApp.isActive != activeBefore {
            failures.append("tab drag overlay activated the host")
        }
        let type = NSPasteboard.PasteboardType("local.windowdock.tab-move")
        board.clearContents()
        board.setString("internal-token", forType: type)
        func checkHighlight(_ cell: Int?, _ label: String) {
            flush()
            for index in targets.indices {
                hit(index, expected: index == cell ? host : targets[index], label: "\(label), pane \(index)")
            }
        }
        func hover(_ location: NSPoint) {
            _ = chrome.updateFloatingTab(
                pasteboard: board, source: tab.select,
                screenPoint: host.convertPoint(toScreen: location))
        }
        checkHighlight(nil, "starting a tab drag")
        for (index, area) in chrome.gridAreas.enumerated() {
            hover(area.convert(NSPoint(x: 30, y: 30), to: nil))
            checkHighlight(index, "hovering over pane \(index)")
        }
        let paneArea = chrome.gridAreas[1]
        let panePoint = paneArea.convert(NSPoint(x: 30, y: 30), to: nil)
        let valid = TabDragInfo(pasteboard: board, source: tab.select, window: host, location: panePoint)
        let external = TabDragInfo(pasteboard: board, source: nil)
        let wrongSource = TabDragInfo(pasteboard: board, source: NSButton())
        guard let overlay = chrome.gridAreas[1].subviews.last else {
            failures.append("tab drag did not install a cell overlay")
            return failures
        }
        if overlay.draggingEntered(external) != [] || overlay.draggingEntered(wrongSource) != []
            || overlay.prepareForDragOperation(external)
        {
            failures.append("drag overlay accepted an external drag")
        }
        board.setString("incorrect", forType: type)
        if overlay.draggingEntered(valid) != [] { failures.append("drag overlay accepted an incorrect token") }
        board.setString("internal-token", forType: type)
        if chrome.performTabDrop(pasteboard: board, source: tab.select, cell: 2) {
            failures.append("drag accepted an invalid destination")
        }
        if overlay.draggingEntered(valid) != .move {
            failures.append("drag overlay did not route an internal move")
        }
        if paneSourceGroup.alphaValue != 0.4 || chrome.tabDragPreviewPanel?.isVisible != true
            || !chrome.tabs.arrangedSubviews.contains(paneSourceGroup) || paneSourceGroup.frame != paneSourceFrame
        {
            failures.append(
                "dragging below the tab row did not pin the source and show the floating preview (alpha=\(paneSourceGroup.alphaValue), preview=\(String(describing: chrome.tabDragPreviewPanel?.isVisible)), inTabs=\(chrome.tabs.arrangedSubviews.contains(paneSourceGroup)), frame=\(paneSourceGroup.frame) vs \(paneSourceFrame))")
        }
        hover(location)
        checkHighlight(nil, "returning to the tab bar")
        hover(panePoint)
        guard let dropTarget = paneArea.subviews.last else {
            return failures + ["returning to the pane lost its drop target"]
        }
        if !dropTarget.prepareForDragOperation(valid) || !dropTarget.performDragOperation(valid) {
            failures.append("drag overlay did not route an internal move")
        }
        if chrome.tabDragPreviewPanel?.isVisible == true {
            failures.append("pane drag left the floating preview visible after drop")
        }
        if moves.count != 1 || moves[0].0 != 77 || moves[0].1 != 1 {
            failures.append("drag did not report source tag and destination cell")
        }
        var reordered: [[Int]] = []
        chrome.onReorderTabs = { reordered.append($0) }
        let floatingGroup = tab.select.superview!
        let initialX = floatingGroup.frame.minX
        let targetGroup = targetTab.select.superview!
        let targetInitialX = targetGroup.frame.minX
        chrome.beginTabDrag(source: tab.select, token: "swap-token")
        board.setString("swap-token", forType: type)
        let targetPoint = targetTab.select.convert(
            NSPoint(x: targetTab.select.bounds.maxX - 1, y: targetTab.select.bounds.midY), to: nil)
        let swap = TabDragInfo(pasteboard: board, source: tab.select, window: host, location: targetPoint)
        if targetTab.select.draggingEntered(swap) != .move || targetTab.select.draggingUpdated(swap) != .move
            || floatingGroup.frame.minX == initialX || reordered.count != 0
            || chrome.tabDragPreviewPanel?.isVisible == true || targetGroup.frame.minX >= targetInitialX
            || chrome.tabs.arrangedSubviews.count != 2
        {
            failures.append("the dragged tab and neighboring tab did not move before the drop")
        }
        if !targetTab.select.prepareForDragOperation(swap) || !targetTab.select.performDragOperation(swap) {
            failures.append("tab drop did not finish an internal tab reorder")
        }
        if reordered != [[78, 77]] {
            failures.append("tab drop did not persist the reordered tab position")
        }
        flush()
        for index in 0 ..< 2 {
            if !chrome.gridAreas[index].subviews.isEmpty { failures.append("completed drag left an overlay") }
            hit(index, expected: targets[index], label: "coverage after drop \(index)")
        }
        moves.removeAll()
        chrome.beginTabDrag(source: tab.select, token: "cancelled")
        chrome.endTabDrag()
        flush()
        if !moves.isEmpty || chrome.gridAreas.contains(where: { !$0.subviews.isEmpty }) {
            failures.append("cancelled drag did not clean up without moving")
        }
        for index in 0 ..< 2 { hit(index, expected: targets[index], label: "coverage after cancellation \(index)") }
        chrome.beginTabDrag(source: tab.select, token: "removed")
        chrome.clearTabs()
        if chrome.gridAreas.contains(where: { !$0.subviews.isEmpty }) || !moves.isEmpty {
            failures.append("removing tabs during a drag did not clean up")
        }
        guard
            let nested = PaneLayout.pane.splittingPane(at: 0, axis: .horizontal)?
            .splittingPane(at: 1, axis: .vertical)
        else { return failures + ["could not construct nested drop fixture"] }
        chrome.setCustomLayout(nested, activeCell: 0)
        let nestedTab = chrome.appendTab(title: "Nested drop", selected: true).select
        nestedTab.tag = 99
        chrome.layoutSubtreeIfNeeded()
        let nestedMenu = nestedTab.menu(for: mouse(.rightMouseDown, .zero))
        if let items = nestedMenu?.items.first?.submenu?.items, items.count == 3, let action = items[2].action {
            _ = NSApp.sendAction(action, to: items[2].target, from: items[2])
        } else {
            failures.append("nested tab menu did not expose every leaf pane as a destination")
        }
        if moves.count != 1 || moves[0].0 != 99 || moves[0].1 != 2 {
            failures.append("nested tab menu did not address the bottom-right pane")
        }
        moves.removeAll()
        chrome.beginTabDrag(source: nestedTab, token: "nested-drop")
        board.setString("nested-drop", forType: type)
        let bottomRight = chrome.gridAreas[2]
        let nestedPoint = bottomRight.convert(NSPoint(x: bottomRight.bounds.midX, y: bottomRight.bounds.midY), to: nil)
        let nestedDrop = TabDragInfo(pasteboard: board, source: nestedTab, window: host, location: nestedPoint)
        _ = chrome.draggingUpdated(nestedDrop)
        if bottomRight.subviews.last?.performDragOperation(nestedDrop) != true || moves.count != 1 || moves[0].0 != 99
            || moves[0].1 != 2 || chrome.gridAreas.contains(where: { !$0.subviews.isEmpty })
        {
            failures.append("tab drop into a nested pane failed to route or clean up all leaf overlays")
        }
        return failures
    }

    /// Speakers on the tabs of applications playing audio: placement beside the close button and the pin badge, the
    /// title kept clear of them, crowded tabs, and updates during a tab drag.
    @MainActor
    private static func checkAudioIndicatorLayout() -> [String] {
        var failures: [String] = []
        let host = WorkspaceWindow(
            contentRect: NSRect(x: 120, y: 120, width: 960, height: 640),
            styleMask: [.borderless, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        host.isReleasedWhenClosed = false
        host.isOpaque = false
        host.backgroundColor = .clear
        let chrome = WorkspaceChromeView(frame: .zero)
        chrome.workspaceButton.title = "Workspace 1"
        host.contentView = chrome
        defer { host.close() }
        /// Pixels the button draws between `minX` and `maxX`, leaving out its speaker.
        func ink(_ button: WorkspaceTabButton, from minX: CGFloat, to maxX: CGFloat) -> Int {
            let indicator = button.audioIndicator
            let hidden = indicator?.isHidden ?? true
            indicator?.isHidden = true
            defer { indicator?.isHidden = hidden }
            guard let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return -1 }
            button.cacheDisplay(in: button.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / button.bounds.width
            let columns = max(0, Int(minX * scale)) ..< min(bitmap.pixelsWide, Int((maxX * scale).rounded(.up)))
            var count = 0
            for y in 0 ..< bitmap.pixelsHigh {
                for x in columns where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { count += 1 }
            }
            return count
        }
        let icon = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        let title = "Application — A window title long enough to be truncated in its tab"
        var items = [
            WorkspaceTabItem(id: UUID(), title: title, icon: icon, selected: true),
            WorkspaceTabItem(id: UUID(), title: title, icon: icon, selected: false, playingAudio: true),
            WorkspaceTabItem(id: UUID(), title: title, icon: icon, selected: false, pinned: true, playingAudio: true),
        ]
        let tabs = chrome.setTabs(items)
        chrome.layoutSubtreeIfNeeded()
        let widths = tabs.map(\.view.frame.width)
        if widths.contains(where: { abs($0 - widths[0]) > 0.5 }) {
            failures.append("speakers changed tab widths: \(widths)")
        }
        if tabs[0].select.audioIndicator?.isHidden == false {
            failures.append("a silent tab shows a speaker")
        }
        for (index, tab) in tabs.enumerated().dropFirst() {
            let select = tab.select
            guard let indicator = select.audioIndicator, !indicator.isHidden, indicator.superview === select else {
                failures.append("tab \(index) playing audio shows no speaker")
                continue
            }
            let frame = indicator.frame
            let pin = tab.view.subviews.compactMap { $0 as? NSImageView }.first { !$0.isHidden }
                .map { tab.view.convert($0.frame, to: select) }
            let trailing = pin?.minX ?? select.bounds.maxX
            if !select.bounds.contains(frame) || trailing - frame.maxX < 0 || trailing - frame.maxX > 4
                || abs(frame.midY - select.bounds.midY) > 0.5
            {
                failures.append("tab \(index): speaker \(frame) is not centered before \(trailing) in \(select.bounds)")
            }
            if let pin, pin.intersects(frame) {
                failures.append("tab \(index): speaker \(frame) overlaps the pin badge \(pin)")
            }
            if ink(select, from: frame.minX, to: select.bounds.maxX) != 0 {
                failures.append("tab \(index): the title runs under the speaker")
            }
            if ink(select, from: 18, to: frame.minX) == 0 {
                failures.append("tab \(index): the title disappeared beside the speaker")
            }
        }
        if let speaker = tabs[1].select.audioIndicator?.frame,
           ink(tabs[0].select, from: speaker.minX, to: tabs[0].select.bounds.maxX) <= 0
        {
            failures.append("a silent tab's title stops short of the speaker's place")
        }

        chrome.beginTabDrag(source: tabs[1].select, token: "audio-indicator-probe")
        items[0].playingAudio = true
        items[1].playingAudio = false
        chrome.updateTabs(items)
        if !tabs[1].view.isFloating || chrome.tabs.arrangedSubviews.contains(tabs[1].view) {
            failures.append("updating speakers ended a tab drag")
        }
        if tabs[0].select.audioIndicator?.isHidden != false || tabs[1].select.audioIndicator?.isHidden == false {
            failures.append("speakers did not follow playback during a tab drag")
        }
        chrome.endTabDrag()

        let crowded = chrome.setTabs((0 ..< 25).map { _ in
            WorkspaceTabItem(id: UUID(), title: title, icon: icon, selected: false, playingAudio: true)
        })
        chrome.layoutSubtreeIfNeeded()
        if let tab = crowded.first(where: {
            $0.select.audioIndicator?.isHidden == false
                || ($0.select.cell as? WorkspaceTabButtonCell)?.trailingInset != 0
        }) {
            failures.append("a crowded \(tab.select.frame.width)pt tab gave its app icon's place to a speaker")
        }

        // Narrow tabs have room for the speaker but not for an ellipsis; no sliver of the title may remain.
        let smallIcon = icon.copy() as? NSImage
        smallIcon?.size = NSSize(width: 16, height: 16)
        for width: CGFloat in [40, 44] {
            let button = WorkspaceTabButton(title: title, target: nil, action: nil)
            button.isBordered = false
            button.alignment = .left
            button.imageHugsTitle = true
            button.lineBreakMode = .byTruncatingTail
            button.font = .systemFont(ofSize: 12, weight: .semibold)
            button.image = smallIcon
            button.imagePosition = .imageLeading
            button.frame = NSRect(x: 20, y: 60, width: width, height: 28)
            chrome.addSubview(button)
            button.showsAudioIndicator = true
            if button.audioIndicator?.isHidden != false || ink(button, from: 0, to: 18) == 0 {
                failures.append("a \(width)pt tab did not show both its app icon and speaker")
            }
            if ink(button, from: 18, to: width) != 0 {
                failures.append("a \(width)pt tab left a sliver of its title beside the speaker")
            }
            button.removeFromSuperview()
        }
        return failures
    }

    /// A child process's silent output counts as this application's playback, through Core Audio notifications alone.
    @MainActor
    private static func checkAudioPlaybackDetection() -> [String] {
        guard #available(macOS 14.4, *) else {
            print("Skipping audio playback detection: Core Audio process objects need macOS 14.4")
            return []
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WindowDockSilence-\(getpid()).wav")
        let player = Process()
        defer {
            if player.isRunning { player.terminate() }
            try? FileManager.default.removeItem(at: url)
        }
        // Six seconds of 16-bit mono silence at 44.1 kHz, which outlasts the wait for an output device to start.
        let samples = 44100 * 6
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        // A PCM WAVE header: format 1, one channel, 44.1 kHz, 2-byte frames of 16-bit samples.
        wav.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + samples * 2))
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(44100))
        append(UInt32(44100 * 2))
        append(UInt16(2))
        append(UInt16(16))
        wav.append(contentsOf: Array("data".utf8))
        append(UInt32(samples * 2))
        wav.append(Data(count: samples * 2))
        do { try wav.write(to: url) } catch { return ["could not write a silent sound: \(error)"] }

        let monitor = AudioPlaybackMonitor(hold: 0.3)
        monitor.start()
        func wait(until condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            return condition()
        }
        if monitor.audibleApplications.contains(getpid()) {
            return ["this application counted as playing audio before it played any"]
        }
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0", url.path]
        do { try player.run() } catch { return ["could not start afplay: \(error)"] }
        var failures: [String] = []
        if !wait(until: { monitor.audibleApplications.contains(getpid()) }) {
            failures.append(
                "a child process playing audio did not mark this application as playing"
                    + (player.isRunning ? "" : " (afplay exited with \(player.terminationStatus))"))
        }
        player.terminate()
        player.waitUntilExit()
        if !wait(until: { !monitor.audibleApplications.contains(getpid()) }) {
            failures.append("this application still counted as playing after its child process stopped")
        }
        return failures
    }

    @MainActor
    private static func checkCompactLayout() -> [String] {
        var failures: [String] = []
        let host = WorkspaceWindow(
            contentRect: NSRect(x: 120, y: 120, width: 1120, height: 760),
            styleMask: [.borderless, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        host.isReleasedWhenClosed = false
        host.isOpaque = false
        host.backgroundColor = .clear
        let chrome = WorkspaceChromeView(frame: .zero)
        chrome.workspaceButton.title = "Workspace 1"
        host.contentView = chrome
        defer { host.close() }
        chrome.layoutSubtreeIfNeeded()
        let initialAddFrame = chrome.convert(chrome.addButton.bounds, from: chrome.addButton)
        let controlsFrame = chrome.convert(chrome.workspaceButton.bounds, from: chrome.workspaceButton)
        let initialGap = initialAddFrame.minX - controlsFrame.maxX
        if controlsFrame.minX < 64 || initialGap < 0 || initialGap > 8 {
            failures.append(
                "empty tabs: add button is not beside the workspace name after the traffic lights, gap=\(initialGap)")
        }
        for index in 1 ... 3 {
            let tab = chrome.appendTab(title: "Application \(index) — A longer window title", selected: index == 1).view
            chrome.layoutSubtreeIfNeeded()
            let lastFrame = chrome.convert(tab.bounds, from: tab)
            let addFrame = chrome.convert(chrome.addButton.bounds, from: chrome.addButton)
            let gap = addFrame.minX - lastFrame.maxX
            if gap < 0 || gap > 8 {
                failures.append("\(index) tabs: add button is not immediately after the last tab, gap=\(gap)")
            }
        }
        let threeTabWidth =
            (chrome.tabs.arrangedSubviews.first as? WorkspaceTabGroup)?.arrangedSubviews.first?.frame.width ?? 0
        chrome.layoutSubtreeIfNeeded()
        let settingsFrame = chrome.convert(chrome.permissionButton.bounds, from: chrome.permissionButton)
        let trailingGap = chrome.bounds.maxX - settingsFrame.maxX
        if trailingGap < 0 || trailingGap > 8 {
            failures.append("compact layout: settings button is not at the trailing edge, gap=\(trailingGap)")
        }
        if let first = chrome.tabs.arrangedSubviews.first {
            let firstFrame = chrome.convert(first.bounds, from: first)
            let gap = firstFrame.minX - controlsFrame.maxX
            if gap < 0 || gap > 8 {
                failures.append("compact layout: unnecessary space precedes the tab strip, gap=\(gap)")
            }
        }
        chrome.clearTabs()
        var lastTab: NSView?
        for index in 1 ... 12 {
            lastTab =
                chrome.appendTab(title: "Application \(index) — A longer window title", selected: index == 12).view
        }
        chrome.layoutSubtreeIfNeeded()
        let twelveTabWidth =
            (chrome.tabs.arrangedSubviews.first as? WorkspaceTabGroup)?.arrangedSubviews.first?.frame.width ?? 0
        if twelveTabWidth >= threeTabWidth {
            failures.append("tabs did not shrink as the tab count increased")
        }
        for size in [NSSize(width: 1120, height: 760), NSSize(width: 720, height: 480)] {
            host.setFrame(NSRect(origin: host.frame.origin, size: size), display: false)
            chrome.layoutSubtreeIfNeeded()
            let stage = chrome.stage.frame
            if chrome.bounds.size != size || abs(stage.width - (size.width - 6)) > 0.1 {
                failures.append("compact \(size): tab overflow changed the window width")
            }
            let topInset = chrome.bounds.maxY - stage.maxY
            if topInset > 35 || stage.height < size.height - 38 {
                failures.append("compact \(size): content area is too short, stage=\(stage)")
            }
            if stage.minX != 3 || chrome.bounds.maxX - stage.maxX != 3 || stage.minY != 3 {
                failures.append("compact \(size): viewport margins exceed 3 points, stage=\(stage)")
            }
            guard let first = chrome.tabs.arrangedSubviews.first, let lastTab else {
                failures.append("compact layout did not create tabs")
                continue
            }
            let firstFrame = chrome.convert(first.bounds, from: first)
            let addFrame = chrome.convert(chrome.addButton.bounds, from: chrome.addButton)
            let visibleTabs = chrome.convert(chrome.tabs.visibleRect, from: chrome.tabs)
            let addGap = addFrame.minX - visibleTabs.maxX
            if addGap < 0 || addGap > 8 {
                failures.append(
                    "compact \(size): add button is not beside the right edge of overflowing tabs, gap=\(addGap)")
            }
            let tabTop = chrome.bounds.maxY - firstFrame.maxY
            if tabTop < 0 || tabTop > 2 {
                failures.append("compact \(size): tabs are not within 2 points of the top, gap=\(tabTop)")
            }
            for button in [
                chrome.workspaceButton, chrome.addButton, chrome.columnSelector, chrome.rowSelector,
                chrome.permissionButton,
            ] {
                let rect = chrome.convert(button.bounds, from: button)
                if rect.isEmpty || !chrome.bounds.contains(rect) || rect.intersects(stage) {
                    failures.append("compact \(size): a window control is clipped or overlaps the viewport")
                }
            }
            if chrome.tabs.bounds.width <= chrome.tabs.visibleRect.width {
                failures.append("compact \(size): many tabs did not overflow horizontally")
            }
            chrome.revealTab(lastTab)
            if !chrome.tabs.visibleRect.contains(lastTab.frame) {
                failures.append("compact \(size): selected tab could not scroll fully into view")
            }
            let lastFrame = chrome.convert(lastTab.bounds, from: lastTab)
            let lastGap = addFrame.minX - lastFrame.maxX
            if lastGap < 0 || lastGap > 8 {
                failures.append("compact \(size): add button is not beside the revealed last tab, gap=\(lastGap)")
            }
            chrome.showNotice(.attention("Test error: accessibility permission is required"))
            chrome.layoutSubtreeIfNeeded()
            if abs(stage.height - chrome.stage.frame.height - 22) > 0.1
                || !chrome.subviews.contains(where: {
                    guard let text = $0 as? NSTextField else { return false }
                    return !text.isHidden && text.stringValue.contains("Test error:")
                })
            {
                failures.append("compact \(size): attention message is not visibly presented")
            }
            chrome.showNotice(.information("Keyboard shortcut help"))
            chrome.layoutSubtreeIfNeeded()
            let attentionFrame = chrome.stage.frame
            chrome.showNotice(.attention("Test error: again"))
            chrome.showNotice(.information("Keyboard shortcut help"))
            chrome.layoutSubtreeIfNeeded()
            if chrome.stage.frame != attentionFrame {
                failures.append("compact \(size): notice toggling resizes the stage (sync feedback loop)")
            }
            print(
                "Compact \(Int(size.width))×\(Int(size.height)): viewport \(Int(stage.width))×\(Int(stage.height)), tabs \(tabTop)pt from top")
        }
        chrome.clearTabs()
        chrome.layoutSubtreeIfNeeded()
        let clearedGap =
            chrome.convert(chrome.addButton.bounds, from: chrome.addButton).minX
                - chrome.convert(chrome.workspaceButton.bounds, from: chrome.workspaceButton).maxX
        if clearedGap < 0 || clearedGap > 8 {
            failures.append(
                "add button did not return beside the workspace name after all tabs were removed, gap=\(clearedGap)")
        }
        return failures
    }
}
