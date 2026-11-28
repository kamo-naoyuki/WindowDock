import AppKit
import PDFKit
import QuartzCore
import SwiftUI
import WindowDockCore

private final class TabLayoutDragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint

    init(board: NSPasteboard, source: NSButton, window: NSWindow, location: NSPoint) {
        draggingPasteboard = board
        draggingSource = source
        draggingDestinationWindow = window
        draggingLocation = location
    }

    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
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
        classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

private final class TitlebarControlProbe: NSButton {
    var mouseDownCount = 0

    override func mouseDown(with event: NSEvent) {
        mouseDownCount += 1
    }
}

private final class TabBarTrackingEvent: NSEvent {
    var area: NSTrackingArea?
    override var trackingArea: NSTrackingArea? { area }
}

private final class TabCloseProbe: NSObject {
    var remove: (Int) -> Void = { _ in }
    @objc func click(_ sender: NSButton) { remove(sender.tag) }
}

private final class PaneCellProbe: NSView {
    var mouseDownCount = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownCount += 1
    }
}

/// Lets a fixture reach above the menu bar so any item can be placed under the pointer.
private final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class FrameChangeProbe: WorkspaceBackgroundView {
    var onPrepare: ((NSRect, NSRect) -> Void)?
    var onPrepared: (() -> Void)?
    var finishedChanges = 0

    override func prepareForFrameChange(to frame: NSRect) {
        if let window { onPrepare?(window.frame, frame) }
        super.prepareForFrameChange(to: frame)
        onPrepared?()
    }

    override func finishFrameChange() {
        super.finishFrameChange()
        finishedChanges += 1
    }
}

/// Runs a check inside the next top-level menu's tracking loop and then closes the menu.
@MainActor
private final class MenuTrackingProbe: NSObject {
    private var during: ((NSMenu) -> Void)?
    private var menu: NSMenu?
    private var fallback: NSMenu?

    /// Returns whether the menu opened and the check ran while it was tracking.
    func run(fallback: NSMenu?, open: () -> Void, during: @escaping (NSMenu) -> Void) -> Bool {
        self.during = during
        self.fallback = fallback
        menu = nil
        NotificationCenter.default.addObserver(
            self, selector: #selector(began(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        defer { NotificationCenter.default.removeObserver(self) }
        // Never leave a menu open waiting for a person if tracking was not reported.
        let guardTimer = Timer(
            timeInterval: 3, target: self, selector: #selector(cancelFallback), userInfo: nil, repeats: false)
        RunLoop.main.add(guardTimer, forMode: .common)
        defer { guardTimer.invalidate() }
        open()
        let ran = self.during == nil
        self.during = nil
        return ran
    }

    @objc private func began(_ note: Notification) {
        guard menu == nil, let menu = note.object as? NSMenu, menu.supermenu == nil else { return }
        self.menu = menu
        let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(inspect), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func inspect() {
        guard let menu, let during else { return }
        self.during = nil
        during(menu)
        menu.cancelTracking()
    }

    @objc private func cancelFallback() {
        (menu ?? fallback)?.cancelTracking()
    }
}

@main
enum TabLayoutSmoke {
    /// Standalone smoke: leave the pointer still while each fixture places a control underneath it.
    @MainActor
    private static func checkBackgroundHoverHelp(detached: Bool, workspaceName: Bool) -> String? {
        let name = "Hover fixture workspace"
        let controller = WorkspaceController(name: name)
        guard let chrome = controller.window.contentView as? WorkspaceChromeView else { return "missing chrome" }
        let host = controller.window
        host.delegate = nil
        defer {
            controller.quitting = true
            chrome.setAutoHideTabBar(false)
            host.orderOut(nil)
        }
        let appAndTitle = "Fixture App — Hover document"
        let tab = chrome.appendTab(title: "Hover document", toolTip: appAndTitle, selected: true)
        func pump(for seconds: TimeInterval, until done: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(seconds)
            while !done(), Date() < deadline {
                if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.02),
                                               inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            }
        }
        host.orderFrontRegardless()
        pump(for: 0.15)
        chrome.setAutoHideTabBar(detached)
        let view = workspaceName ? chrome.workspaceButton : tab.select
        let expected = workspaceName ? name : appAndTitle
        guard let window = view.window else { return "missing toolbar window" }
        window.contentView?.layoutSubtreeIfNeeded()
        let center = window
            .convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
        let mouse = NSEvent.mouseLocation
        host.setFrameOrigin(NSPoint(x: host.frame.minX + mouse.x - center.x, y: host.frame.minY + mouse.y - center.y))
        chrome.updateToolbarPanelFrame()
        chrome.setAutoHiddenToolbarVisible(detached)
        var shown = false
        var lastTip = ""
        pump(for: 2.5) {
            shown = NSApp.windows.contains { tip in
                guard tip is NSPanel, tip !== window, tip.isVisible, let content = tip.contentView else { return false }
                // Native tooltips draw text without a text field; read what the visible panel actually painted.
                lastTip = PDFDocument(data: content.dataWithPDF(inside: content.bounds))?.string ?? ""
                return lastTip.contains(expected)
            }
            return shown
        }
        if shown, !NSApp.isActive { return nil }
        let hit = window.contentView?.superview?.hitTest(window.mouseLocationOutsideOfEventStream)
        return "Expected inactive tooltip ‘\(expected)’ (detached=\(detached), hit=\((hit as? NSButton)?.title ?? "-"), displayed=\(lastTip))"
    }

    /// Standalone smoke: like the hover-help check, moves each glowing item under the still pointer in turn.
    @MainActor
    private static func checkHoverGlow(_ root: some View, size: NSSize, items names: [String],
                                       disabled: Set<String> = []) -> [String] {
        let host = NSHostingView(rootView: root.frame(width: size.width, height: size.height)
            .environment(\.accessibilityEnabled, true))
        let window = UnconstrainedWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                                         backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = host
        defer { window.close() }
        func pump(for seconds: TimeInterval, until done: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(seconds)
            while !done(), Date() < deadline {
                if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.02),
                                               inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            }
        }
        // The glow's border runs along each item's edge; a neighbor's glow can reach its side edges.
        func edgeColor(_ frame: NSRect) -> NSColor? {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let point = host.convert(NSPoint(x: frame.midX, y: frame.maxY - 1), from: nil)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            let y = host.isFlipped ? point.y : host.bounds.height - point.y
            return bitmap.colorAt(x: Int(point.x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB)
        }
        func distance(_ a: NSColor?, _ b: NSColor?) -> CGFloat {
            guard let a, let b else { return 0 }
            return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                + abs(a.blueComponent - b.blueComponent)
        }
        func move(by offset: NSPoint) {
            window.setFrameOrigin(NSPoint(x: window.frame.minX + offset.x, y: window.frame.minY + offset.y))
        }
        // Each item is a button whose label carries the glow. SwiftUI doesn't list a ScrollView's content as
        // accessibility children, but hit-testing reaches it.
        func itemFrames() -> [NSRect] {
            host.layoutSubtreeIfNeeded()
            var found: [String: NSRect] = [:]
            for y in stride(from: 4.0, to: size.height, by: 12) {
                for x in stride(from: 4.0, to: size.width, by: 12) {
                    let point = window.convertPoint(toScreen: NSPoint(x: x, y: y))
                    let node = host.accessibilityHitTest(point) as AnyObject?
                    guard node?.accessibilityRole?() == .button,
                          let label = node?.accessibilityLabel?() ?? node?.accessibilityTitle?(),
                          let name = names.first(where: label.contains), let frame = node?.accessibilityFrame?()
                    else { continue }
                    found[name] = window.convertFromScreen(frame)
                }
            }
            return names.compactMap { found[$0] }
        }
        let away = NSPoint(x: NSEvent.mouseLocation.x + 2000, y: NSEvent.mouseLocation.y + 2000)
        window.setFrameOrigin(away)
        window.orderFrontRegardless()
        pump(for: 3) { itemFrames().count == names.count }
        pump(for: 0.3)
        let frames = itemFrames()
        guard frames.count == names.count else { return ["expected \(names) to glow, found \(frames.count) items"] }
        let visible = host.convert(host.bounds, to: nil)
        guard frames.allSatisfy({ visible.contains($0) }) else { return ["\(names) are clipped in the fixture"] }
        let resting = frames.map(edgeColor)
        func glowing() -> [Bool] { zip(frames, resting).map { distance(edgeColor($0), $1) > 0.3 } }
        var failures: [String] = []
        for (index, name) in names.enumerated() {
            let expected = frames.indices.map { $0 == index && !disabled.contains(name) }
            var hovered: [Bool] = []
            var left: [Bool] = []
            // Retry if the pointer was moved during the check.
            for _ in 0 ..< 3 {
                let mouse = NSEvent.mouseLocation
                let center = window.convertPoint(toScreen: NSPoint(x: frames[index].midX, y: frames[index].midY))
                move(by: NSPoint(x: mouse.x - center.x, y: mouse.y - center.y))
                guard window.convertToScreen(frames[index]).contains(mouse) else {
                    failures.append("couldn't place \(name) under the pointer")
                    break
                }
                pump(for: 2) {
                    hovered = glowing()
                    return hovered == expected
                }
                pump(for: 0.3)
                hovered = glowing()
                move(by: NSPoint(x: 600, y: 0))
                pump(for: 2) {
                    left = glowing()
                    return !left.contains(true)
                }
                window.setFrameOrigin(away)
                if (hovered == expected && !left.contains(true)) || NSEvent.mouseLocation == mouse { break }
            }
            if hovered != expected {
                failures.append("hovering \(name) made \(hovered) of \(names) glow (frame \(frames[index]))")
            }
            if left.contains(true) {
                failures.append("\(left) of \(names) kept glowing after the pointer left \(name)")
            }
        }
        if NSApp.isActive { failures.append("hover glow fixture should stay inactive") }
        return failures
    }

    /// The installed apps wrap into columns, scroll vertically with the page, and a plain click still opens one app.
    /// Selected apps open together, or are registered to add their new windows automatically. A right-click or
    /// Control-click shows a Dock-like menu at once without reading the Dock's; its Show Dock Menu item shows the
    /// app's own Dock menu.
    @MainActor
    private static func checkLauncherGrid() async -> [String] {
        /// Records what the page asks of Accessibility off the main thread.
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String] = []
            func record(_ value: String) {
                lock.lock()
                values.append(value)
                lock.unlock()
            }

            var recorded: [String] {
                lock.lock()
                defer { lock.unlock() }
                return values
            }
        }
        let apps = (1 ... 13).map {
            LauncherApplication(url: URL(fileURLWithPath: "/Fixture\($0).app"), name: "Fixture \($0)", lastUsed: nil)
        }
        var launched: [URL] = []
        var chosen: [[String]] = []
        var registered: [[URL]] = []
        var dockChoices: [(path: DockMenuPath, url: URL)] = []
        let offMain = Recorder()
        let existing = WindowCandidate(element: AXUIElementCreateApplication(930_000), application: .current,
                                       title: "Existing window")
        let runningWindow = WindowCandidate(element: AXUIElementCreateApplication(930_001), application: .current,
                                            title: "Window A")
        let dockItems: [DockMenuItem] = [
            DockMenuItem(title: "Window A", isChecked: true), .separator,
            DockMenuItem(title: "New Window"), DockMenuItem(title: "Profiles", performsAction: false),
            DockMenuItem(title: "Profile 1"), .separator,
            DockMenuItem(title: "Options", performsAction: false,
                         submenu: [DockMenuItem(title: "Keep in Dock"), DockMenuItem(title: "Show in Finder")]),
            .separator, DockMenuItem(title: "Quit"), DockMenuItem(title: "Force Quit", isAlternate: true),
        ]
        var access = WindowAccessClient()
        access.isTrusted = { true }
        access.scan = { WindowScan(windows: [existing]) }
        // Fixture 1 runs with one window and is in the Dock; the other fixtures are neither.
        access.runningApplication = { $0 == apps[0].url ? .current : nil }
        access.applicationWindows = { _ in [runningWindow] }
        access.hasDockItem = { $0 == apps[0].url }
        access.dockMenu = {
            offMain.record("read Dock menu")
            return $0 == apps[0].url ? dockItems : nil
        }
        access.focus = { element, _ in
            offMain.record(CFEqual(element, runningWindow.element) ? "focus Window A" : "focus another window")
        }
        let autoGroup = AutoGroupPageModel()
        autoGroup.isAvailable = true
        autoGroup.register = {
            registered.append($0)
            return true
        }
        let page = NewTabPage(
            access: access, isAvailable: { _ in true },
            launch: { url in
                launched.append(url)
                if url == apps[4].url { throw CocoaError(.executableLoad) }
                return [WindowCandidate(element: AXUIElementCreateApplication(pid_t(920_000 + launched.count)),
                                        application: .current, title: url.lastPathComponent)]
            },
            choose: {
                chosen.append($0.map(\.title).sorted())
                return true
            },
            chooseDockMenuItem: { path, _, url in
                dockChoices.append((path, url))
                return [WindowCandidate(element: AXUIElementCreateApplication(910_900), application: .current,
                                        title: "Dock window")]
            }, applications: { apps }, autoGroup: autoGroup)
        let size = NSSize(width: 420, height: 360)
        let host = NSHostingView(rootView: page.frame(width: size.width, height: size.height)
            .environment(\.accessibilityEnabled, true))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        func settle() async {
            try? await Task.sleep(nanoseconds: 60_000_000)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        // SwiftUI doesn't list a ScrollView's content as accessibility children, but hit-testing reaches it.
        func buttons() -> [String: (node: AnyObject, frame: NSRect)] {
            var found: [String: (node: AnyObject, frame: NSRect)] = [:]
            for y in stride(from: 3.0, to: size.height, by: 9) {
                for x in stride(from: 3.0, to: size.width, by: 9) {
                    let node = host.accessibilityHitTest(window.convertPoint(toScreen: NSPoint(x: x, y: y)))
                        as AnyObject?
                    guard let node, node.accessibilityRole?() == .button,
                          let label = node.accessibilityLabel?() ?? node.accessibilityTitle?(), !label.isEmpty,
                          found[label] == nil, let frame = node.accessibilityFrame?() else { continue }
                    found[label] = (node, window.convertFromScreen(frame))
                }
            }
            return found
        }
        func descendants(of view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants(of: $0) } }
        var scroll: NSScrollView?
        for _ in 0 ..< 60 where scroll == nil {
            await settle()
            scroll = descendants(of: host).compactMap { $0 as? NSScrollView }.first {
                ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height + 40
            }
        }
        guard let scroll, let document = scroll.documentView else {
            return ["the installed apps did not scroll vertically with the page"]
        }
        /// Scrolls the page from the top until the button is wholly visible.
        func reveal(_ label: String) async -> (node: AnyObject, frame: NSRect)? {
            let range = max(0, document.bounds.height - scroll.contentSize.height)
            for offset in Array(stride(from: 0, to: range, by: 40)) + [range] {
                document.scroll(NSPoint(x: 0, y: document.isFlipped ? offset : range - offset))
                await settle()
                if let button = buttons()[label], NSRect(origin: .zero, size: size).contains(button.frame) {
                    return button
                }
            }
            return nil
        }
        func press(_ label: String) async -> Bool {
            guard let button = await reveal(label) else { return false }
            return button.node.isAccessibilityEnabled?() == true && button.node.accessibilityPerformPress?() == true
        }
        func commandClick(_ label: String) async -> Bool {
            await click(label, down: .leftMouseDown, up: .leftMouseUp, modifiers: .command)
        }
        func click(_ label: String, down: NSEvent.EventType, up: NSEvent.EventType,
                   modifiers: NSEvent.ModifierFlags) async -> Bool {
            guard let frame = await reveal(label)?.frame else { return false }
            for type in [up, down] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: frame.midX, y: frame.midY), modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1) else { return false }
                NSApp.postEvent(event, atStart: true)
            }
            while let event = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp],
                                              until: .distantPast, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            return true
        }
        func waitFor(_ condition: () -> Bool) async -> Bool {
            for _ in 0 ..< 60 {
                if condition() { return true }
                await settle()
            }
            return condition()
        }

        var failures: [String] = []
        guard let one = await reveal("Fixture 1")?.frame, let two = buttons()["Fixture 2"]?.frame else {
            return ["the installed apps grid did not show its first apps"]
        }
        if abs(one.midY - two.midY) > 1 || two.minX <= one.maxX {
            failures.append("the first installed apps were not laid out side by side: \(one) \(two)")
        }
        guard await reveal("Fixture 13") != nil else { return failures + ["could not scroll to the thirteenth app"] }
        let wrapped = buttons().contains { label, button in
            label.hasPrefix("Fixture ") && label != "Fixture 1" && abs(button.frame.minX - one.minX) < 1
        }
        if !wrapped { failures.append("the installed apps did not wrap onto another row") }
        let pressedLast = await press("Fixture 13")
        let launchedLast = await waitFor { launched == [apps[12].url] && chosen == [["Fixture13.app"]] }
        if !pressedLast || !launchedLast {
            failures.append("could not launch the thirteenth app and add its window: \(launched) \(chosen)")
        }

        // A failed launch keeps the open windows to choose from instead.
        launched.removeAll()
        guard await press("Fixture 5"), await waitFor({ launched == [apps[4].url] }) else {
            return failures + ["could not try to open an app that fails to launch"]
        }
        for _ in 0 ..< 10 { await settle() }
        if await reveal(existing.label) == nil {
            failures.append("a failed launch removed the open windows from the new tab")
        }

        launched.removeAll()
        chosen.removeAll()
        let selectedOne = await commandClick("Fixture 1")
        guard selectedOne, launched.isEmpty, await press("Fixture 2"),
              await press(L("%d個のアプリで新しいウィンドウを開く", 2)),
              await waitFor({ chosen == [["Fixture1.app", "Fixture2.app"]] })
        else {
            return failures + ["Command-click didn't select apps, or the selected apps weren't opened together: "
                + "launched \(launched), added \(chosen)"]
        }
        if Set(launched) != [apps[0].url, apps[1].url] { failures.append("opened the wrong apps: \(launched)") }
        if await reveal(L("アプリを複数選択")) == nil {
            failures.append("opening the selected apps did not leave multi-select mode")
        }

        launched.removeAll()
        guard await press(L("アプリを複数選択")), await press("Fixture 3"), await press("Fixture 4"),
              await press(L("%d個のアプリの新しいウィンドウを自動でこのワークスペースに追加", 2))
        else { return failures + ["could not register the selected apps to add their new windows automatically"] }
        if registered != [[apps[2].url, apps[3].url]] || !launched.isEmpty {
            failures.append("registering selected apps did not pass them without launching: \(registered) \(launched)")
        }
        if await reveal(L("アプリを複数選択")) == nil {
            failures.append("registering the selected apps did not leave multi-select mode")
        }

        // A failed launch keeps the open windows to choose from instead.
        launched.removeAll()
        guard await press(L("アプリを複数選択")), await press("Fixture 5"), await press("Fixture 6"),
              await press(L("%d個のアプリで新しいウィンドウを開く", 2)),
              await waitFor({ Set(launched) == [apps[4].url, apps[5].url] })
        else { return failures + ["could not open a failing app together with another app"] }
        for _ in 0 ..< 10 { await settle() }
        let opened = "\(existing.application.localizedName ?? "App") — Fixture6.app"
        let keptExisting = await reveal(existing.label) != nil
        let showedOpened = await reveal(opened) != nil
        let selectedOpened = await reveal(L("%d件を追加", 1)) != nil
        if !keptExisting || !showedOpened || !selectedOpened {
            failures.append("after one of the selected apps failed to open, the new tab showed existing "
                + "\(keptExisting), opened \(showedOpened), opened selected \(selectedOpened)")
        }

        /// Right-clicks and Control-clicks apps, and chooses an item from the menu each shows.
        func checkDockMenus() async -> [String] {
            // Menu tracking notifications and its timers arrive on the main thread.
            final class Tracking: @unchecked Sendable {
                var menus: [NSMenu] = []
                var pick: (NSMenu) -> NSMenuItem? = { _ in nil }
            }
            let tracking = Tracking()
            let observer = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                    guard let menu = note.object as? NSMenu, menu.supermenu == nil else { return }
                    tracking.menus.append(menu)
                    // The menu tracks in a nested run loop, so choose from it with a timer that runs there.
                    let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                        if let item = tracking.pick(menu), let owner = item.menu {
                            owner.performActionForItem(at: owner.index(of: item))
                        }
                        menu.cancelTracking()
                    }
                    RunLoop.main.add(timer, forMode: .common)
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            func describe(_ menu: NSMenu) -> [String] {
                menu.items.map { item in
                    if item.isSeparatorItem { return "-" }
                    var inert = !item.isEnabled
                    if #available(macOS 14, *) { inert = inert || item.isSectionHeader }
                    return item.title + (inert ? " (inert)" : "") + (item.state == .on ? " ✓" : "")
                        + (item.isAlternate && item.keyEquivalentModifierMask == .option ? " (⌥)" : "")
                        + (item.submenu.map { " ▸ " + describe($0).joined(separator: ", ") } ?? "")
                }
            }

            var failures: [String] = []
            launched.removeAll()
            chosen.removeAll()
            // The test process stands in for Fixture 1, so never choose Hide, Quit or Force Quit.
            tracking.pick = { $0.items.first { $0.title == "Window A" } }
            guard await click("Fixture 1", down: .rightMouseDown, up: .rightMouseUp, modifiers: []),
                  await waitFor({ tracking.menus.count == 1 && offMain.recorded.contains("focus Window A") })
            else {
                return ["right-clicking a running app didn't show its windows or focus the chosen one: "
                    + "menus \(tracking.menus.map(describe)), recorded \(offMain.recorded)"]
            }
            let standard = ["Window A", "-", L("新規ウィンドウ"), L("Finderに表示"), L("Dock のメニューを表示"), "-",
                            L("非表示"), L("終了"), L("強制終了") + " (⌥)"]
            if describe(tracking.menus[0]) != standard {
                failures.append("a running app's menu was \(describe(tracking.menus[0])), not \(standard)")
            }
            for _ in 0 ..< 5 { await settle() }
            if offMain.recorded != ["focus Window A"] || !chosen.isEmpty || !launched.isEmpty {
                failures.append("the right-click menu read the Dock menu or opened a window: "
                    + "recorded \(offMain.recorded), added \(chosen), launched \(launched)")
            }

            tracking.pick = { menu in
                menu.items.first { $0.title == L("Dock のメニューを表示") } ?? menu.items.first { $0.title == "Profile 1" }
            }
            guard await click("Fixture 1", down: .leftMouseDown, up: .leftMouseUp, modifiers: .control),
                  await waitFor({ tracking.menus.count == 3 && chosen == [["Dock window"]] })
            else {
                return failures + ["Show Dock Menu after a Control-click didn't show the Dock menu or add the chosen "
                    + "item's window: menus \(tracking.menus.map(describe)), chose \(dockChoices), added \(chosen)"]
            }
            let mirrored = ["Window A ✓", "-", "New Window", "Profiles (inert)", "Profile 1", "-",
                            "Options ▸ Keep in Dock, Show in Finder", "-", "Quit", "Force Quit (⌥)"]
            if describe(tracking.menus[2]) != mirrored {
                failures.append("the Dock menu was mirrored as \(describe(tracking.menus[2])), not \(mirrored)")
            }
            if dockChoices.map(\.path) != [DockMenuPath(indices: [4], in: dockItems)]
                || dockChoices.map(\.url) != [apps[0].url] {
                failures.append("Show Dock Menu chose \(dockChoices) instead of Fixture 1's Profile 1")
            }

            dockChoices.removeAll()
            tracking.pick = { menu in
                menu.items.first { $0.title == L("Dock のメニューを表示") }
                    ?? menu.items.first { $0.title == "Options" }?.submenu?.items.last
            }
            guard await click("Fixture 1", down: .rightMouseDown, up: .rightMouseUp, modifiers: []),
                  await waitFor({ tracking.menus.count == 5 && !dockChoices.isEmpty })
            else { return failures + ["choosing from the Dock menu's submenu did nothing: \(dockChoices)"] }
            if dockChoices.map(\.path) != [DockMenuPath(indices: [6, 1], in: dockItems)] {
                failures.append("choosing from the Dock menu's submenu chose \(dockChoices)")
            }
            for _ in 0 ..< 5 { await settle() }
            if !launched.isEmpty { failures.append("a Control-click or Dock menu choice opened the app: \(launched)") }
            if offMain.recorded.filter({ $0 == "read Dock menu" }).count != 2 {
                failures.append("the Dock menu was read \(offMain.recorded) instead of once per Show Dock Menu")
            }

            tracking.pick = { $0.items.first }
            guard await click("Fixture 2", down: .rightMouseDown, up: .rightMouseUp, modifiers: []),
                  await waitFor({ tracking.menus.count == 6 && launched == [apps[1].url] })
            else {
                return failures + ["right-clicking an app that isn't running didn't offer to open it: "
                    + "menus \(tracking.menus.map(describe)), launched \(launched)"]
            }
            if describe(tracking.menus[5]) != [L("開く"), L("Finderに表示")] {
                failures.append("an app that isn't running or in the Dock showed \(describe(tracking.menus[5]))")
            }

            launched.removeAll()
            guard await click("Fixture 3", down: .leftMouseDown, up: .leftMouseUp, modifiers: []),
                  await waitFor({ launched == [apps[2].url] })
            else { return failures + ["a plain click no longer opened the app: \(launched)"] }
            if tracking.menus.count != 6 { failures.append("a plain click showed a menu") }
            return failures
        }
        return failures + (await checkDockMenus())
    }

    @MainActor
    private static func checkNewTabHoverGlow() -> [String] {
        var access = WindowAccessClient()
        access.isTrusted = { true }
        access.scan = { WindowScan() }
        let page = NewTabPage(access: access, isAvailable: { _ in true }, launch: { _ in [] },
                              choose: { _ in false }, applications: {
                                  ["com.apple.finder", "com.apple.TextEdit"].compactMap { id in
                                      guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                                      else { return nil }
                                      return LauncherApplication(
                                          url: url,
                                          name: FileManager.default.displayName(atPath: url.path),
                                          lastUsed: nil)
                                  }
                              })
        let windows = (0 ..< 2).map {
            WindowCandidate(element: AXUIElementCreateApplication(pid_t(910_100 + $0)), application: .current,
                            title: "Glow \($0)")
        }
        let restore = L("%d件を復元", 0)
        return checkToolbarHover()
            + checkHoverGlow(page, size: NSSize(width: 560, height: 380),
                             items: ["Finder", "TextEdit", L("一覧を更新"), L("アプリを複数選択")])
            + checkHoverGlow(WindowChoiceGrid(windows: windows, previews: nil, restoring: []) { _ in false },
                             size: NSSize(width: 560, height: 260), items: ["Glow 0", "Glow 1", restore],
                             disabled: [restore])
    }

    @MainActor
    private static func checkToolbarHover() -> [String] {
        let frame = NSRect(x: 0, y: 0, width: 780, height: 150)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let chrome = WorkspaceChromeView(frame: frame)
        window.contentView = chrome
        chrome.setWorkspaceName("Hover workspace")
        chrome.layoutSubtreeIfNeeded()
        defer { window.close() }
        func pixels(_ button: NSButton) -> Data? {
            guard let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return nil }
            button.cacheDisplay(in: button.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])
        }
        var failures: [String] = []
        for button in [chrome.addButton, chrome.workspaceButton, chrome.columnSelector, chrome.combineButton] {
            guard let owner = button.trackingAreas.first(where: {
                $0.options.contains([.mouseEnteredAndExited, .activeAlways, .inVisibleRect])
                    && ($0.owner as? NSView)?.superview === button
            })?.owner as? NSView else { return ["no hover tracking on \(button.title)"] }
            let event = TabBarTrackingEvent()
            owner.mouseExited(with: event)
            guard let initial = pixels(button) else { return ["could not render \(button.title)"] }
            owner.mouseEntered(with: event)
            if (pixels(button) != initial) != button.isEnabled {
                failures.append("hover did not respect enabled state on \(button.title)")
            }
            owner.mouseExited(with: event)
            if pixels(button) != initial { failures.append("leaving \(button.title) did not restore its appearance") }
        }
        return failures
    }

    @MainActor
    private static func checkCloseSlotsAndWrapping() -> [String] {
        let host = WorkspaceWindow(contentRect: NSRect(x: 100, y: 100, width: 930, height: 600),
                                   styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let chrome = WorkspaceChromeView(frame: .zero)
        host.contentView = chrome
        host.orderBack(nil)
        defer { host.close() }
        // A compressed name could otherwise grow back into space freed by closed tabs and shift the next ×.
        chrome.setWorkspaceName("A workspace name long enough to be compressed")
        var failures: [String] = []
        let click = TabCloseProbe()
        let tracking = TabBarTrackingEvent()
        tracking.area = chrome.addButton.superview?.trackingAreas.first { $0.owner === chrome }
        guard tracking.area != nil else { return ["missing tab bar pointer tracking"] }
        let all = (0 ..< 27).map {
            WorkspaceTabItem(id: UUID(), title: $0.isMultiple(of: 2) ? "A" : "A longer title", selected: $0 == 0)
        }
        var items = all
        var groups: [WorkspaceChromeView.Tab] = []
        func layout() {
            chrome.layoutSubtreeIfNeeded()
            chrome.tabs.window?.contentView?.layoutSubtreeIfNeeded()
        }
        func settle() {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.24))
            layout()
        }
        func render() {
            groups = chrome.setTabs(items)
            for (index, tab) in groups.enumerated() {
                tab.select.tag = index
                tab.close.tag = index
                tab.close.target = click
                tab.close.action = #selector(TabCloseProbe.click(_:))
            }
            if let first = groups.first { chrome.revealTab(first.view) }
            layout()
        }
        click.remove = { items.remove(at: $0); render() }
        defer { click.remove = { _ in } }
        func screenPoint(_ view: NSView, x: CGFloat? = nil) -> NSPoint {
            view.window!
                .convertPoint(toScreen: view.convert(NSPoint(x: x ?? view.bounds.midX, y: view.bounds.midY), to: nil))
        }
        func closeTwice(at slot: Int) {
            let point = screenPoint(groups[slot].close)
            let viewport = chrome.tabs.visibleRect
            chrome.mouseEntered(with: tracking)
            for _ in 0 ..< 2 {
                let next = groups[slot + 1].id
                let hit = chrome.hitTest(host.convertPoint(fromScreen: point))
                if hit !== groups[slot].close {
                    failures.append("slot \(slot): repeated click missed × at \(point)")
                    break
                }
                (hit as? NSButton)?.performClick(nil)
                let center = screenPoint(groups[slot].close)
                let visible = chrome.tabs.visibleRect
                if groups[slot].id != next || abs(center.x - point.x) > 1 || abs(center.y - point.y) > 1
                    || visible.origin != viewport.origin || visible.height != viewport.height {
                    failures
                        .append(
                            "slot \(slot): next × moved from \(point) to \(center), viewport \(viewport) → \(chrome.tabs.visibleRect)")
                }
            }
        }
        for (count, scroll) in [(7, false), (all.count, true)] {
            items = Array(all.prefix(count))
            render()
            settle()
            if scroll { chrome.revealTab(groups[count - 1].view) }
            let slot = scroll ? count - 4 : 2
            let width = groups[slot].view.bounds.width
            let plus = screenPoint(chrome.addButton).x
            closeTwice(at: slot)
            let pulled = plus - screenPoint(chrome.addButton).x
            if abs(pulled - 2 * (width + chrome.tabs.spacing)) > 1 {
                failures.append("slot \(slot): + moved \(pulled) pt instead of following the closed tabs")
            }
            chrome.mouseExited(with: tracking)
            layout()
            if !scroll, groups[slot].view.bounds.width <= width + 1 {
                failures.append("leaving the tab bar did not redistribute freed space")
            }
        }

        // Closing the rightmost tab resizes at once, so the new last × lands under the pointer.
        items = Array(all.prefix(7))
        render()
        settle()
        let lastClose = screenPoint(groups[groups.count - 1].close)
        let compressedWidth = groups[0].view.bounds.width
        chrome.mouseEntered(with: tracking)
        for _ in 0 ..< 2 {
            let hit = chrome.hitTest(host.convertPoint(fromScreen: lastClose))
            guard hit === groups.last?.close else {
                failures.append("closing the rightmost tab moved the next × away from \(lastClose)")
                break
            }
            (hit as? NSButton)?.performClick(nil)
        }
        if groups[0].view.bounds.width <= compressedWidth + 1 {
            failures.append("closing the rightmost tab under the pointer did not resize the remaining tabs")
        }
        chrome.mouseExited(with: tracking)

        chrome.wrapsCrowdedTabs = true
        for position: TabBarPosition in [.top, .bottom] {
            chrome.setTabBarPosition(position)
            items = all
            render()
            settle()
            guard let split = chrome.tabs.secondRow, split < groups.count else {
                failures.append("\(position): overflow did not wrap")
                continue
            }
            let second = groups[split]
            let topFrame = groups[0].view.frame, lower = second.view.frame
            if lower.maxY > topFrame.minY || lower.minX != topFrame.minX || abs(lower.width - topFrame.width) > 1
                || chrome.tabs.visibleRect.width >= chrome.tabs.bounds.width {
                failures.append("\(position): crowded rows did not align or scroll together: \(topFrame), \(lower)")
            }
            let point = screenPoint(second.view, x: 1)
            if chrome.tabInsertionIndex(at: point) != split || chrome
                .hitTest(host.convertPoint(fromScreen: screenPoint(second.close))) !== second.close {
                failures.append("\(position): could not target the first tab in the second row")
            }
            chrome.showWindowDropTarget(at: point, requiresPermission: false)
            if let preview = chrome.windowDropPreview as? WorkspaceTabGroup,
               chrome.tabs.arrangedSubviews.firstIndex(of: preview) == split,
               let title = preview.arrangedSubviews.first as? NSButton, title.alignment == .left {
                if abs(preview.frame.width - second.view.frame.width) >
                    1 { failures.append("drop preview width differs") }
            } else { failures.append("\(position): window preview did not follow the target row") }
            chrome.hideWindowDropTarget()
            layout()
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.setString("across-rows", forType: workspaceTabDragType)
            let source = groups[0].select, destination = screenPoint(groups[split + 1].select)
            var reordered: [Int]?
            chrome.onReorderTabs = { reordered = $0 }
            chrome.beginTabDrag(source: source, token: "across-rows")
            if !chrome.performTabReorder(pasteboard: board, source: source, screenPoint: destination)
                || reordered?[split + 1] != 0 { failures.append("\(position): drag failed to reorder across rows") }
            chrome.setAutoHideTabBar(true)
            chrome.setAutoHiddenToolbarVisible(true)
            layout()
            if (chrome.autoHiddenToolbarPanel?.frame.height ?? 0) < chrome.tabs.bounds.height {
                failures.append("\(position): auto-hidden bar clipped its second row")
            }
            chrome.setAutoHideTabBar(false)
            chrome.mouseExited(with: tracking)
            let capacity =
                Int((chrome.tabs.visibleRect.width + chrome.tabs.spacing) / (topFrame.width + chrome.tabs.spacing))
            items = Array(all.prefix(capacity + 2))
            render()
            settle()
            guard let boundary = chrome.tabs.secondRow, boundary >= 1, boundary + 1 < groups.count else {
                failures.append("\(position): second row was not available for repeated closes")
                continue
            }
            closeTwice(at: boundary - 1)
            if chrome.tabs.secondRow != boundary { failures.append("\(position): row collapsed under the pointer") }
            chrome.mouseExited(with: tracking)
            settle()
            if chrome.tabs.secondRow != nil || chrome.tabs.visibleRect.height >= 64 {
                failures
                    .append(
                        "\(position): wrapping did not collapse: split=\(String(describing: chrome.tabs.secondRow)), strip=\(chrome.tabs.bounds), visible=\(chrome.tabs.visibleRect), widths=\(groups.map { $0.view.frame.width })")
            }
        }
        return failures
    }

    /// Icon-only tabs hide window names but keep them for help and accessibility, and stay narrow in a wide bar.
    @MainActor
    private static func checkIconOnlyTabs() -> [String] {
        let host = WorkspaceWindow(contentRect: NSRect(x: 100, y: 100, width: 930, height: 600),
                                   styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let chrome = WorkspaceChromeView(frame: .zero)
        host.contentView = chrome
        host.orderBack(nil)
        defer { host.close() }
        func layout() {
            chrome.layoutSubtreeIfNeeded()
            chrome.tabs.window?.contentView?.layoutSubtreeIfNeeded()
        }
        let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/TextEdit.app")
        var items = [
            WorkspaceTabItem(id: UUID(), title: "Quarterly report draft", icon: icon, selected: true),
            WorkspaceTabItem(id: UUID(), title: "Meeting notes", icon: icon, selected: false),
            WorkspaceTabItem(id: UUID(), title: "New Tab", selected: false),
        ]
        var tabs = chrome.setTabs(items)
        layout()
        let titledWidth = tabs[0].view.frame.width
        var failures: [String] = []
        chrome.showsTabIconsOnly = true
        layout()
        for (tab, item) in zip(tabs, items) {
            if !tab.select.title.isEmpty || tab.select.image == nil || tab.select.imagePosition != .imageOnly {
                failures.append("icon-only tab ‘\(item.title)’ still showed its title or lost its icon")
            }
            if tab.select.accessibilityLabel() != item.title || tab.select.toolTip != item.title {
                failures.append("icon-only tab ‘\(item.title)’ lost its name for help or accessibility")
            }
            let width = tab.view.frame.width
            if width > WindowGeometry.iconOnlyTabContentWidth + 34 + 1 || width >= titledWidth {
                failures.append("icon-only tab ‘\(item.title)’ was \(width) wide (titled \(titledWidth))")
            }
        }
        items[1] = WorkspaceTabItem(id: items[1].id, title: "Renamed notes", icon: icon, selected: false)
        items[0].shortcutNumber = 1
        items[2].shortcutNumber = 9
        chrome.updateTabs(items)
        if !tabs[1].select.title.isEmpty || tabs[1].select.accessibilityLabel() != "Renamed notes" {
            failures.append("updating an icon-only tab showed its title or kept its old name")
        }
        if tabs[0].select.shortcutNumberBadge?.number != 1
            || tabs[2].select.shortcutNumberBadge?.number != 9
            || (tabs[0].select.cell as? WorkspaceTabButtonCell)?.trailingInset == 0
        {
            failures.append("Control+Shift shortcut numbers were not shown on their tabs")
        }
        items[0].shortcutNumber = nil
        chrome.updateTabs(items)
        if tabs[0].select.shortcutNumberBadge?.isHidden != true {
            failures.append("shortcut number stayed visible after the modifier hint was dismissed")
        }
        chrome.setTabBarPosition(.left)
        layout()
        if !tabs[0].select.title.isEmpty || tabs[0].select.imagePosition != .imageLeading {
            failures.append("icon-only tabs in a vertical bar showed titles or moved their icons off the leading edge")
        }
        chrome.setTabBarPosition(.top)
        chrome.showsTabIconsOnly = false
        tabs = chrome.setTabs(items)
        layout()
        if tabs[0].select.title != items[0].title || tabs[2].select.image != nil
            || abs(tabs[0].view.frame.width - titledWidth) > 1 {
            failures.append("turning icon-only tabs off did not restore titles and widths")
        }
        return failures
    }

    /// The compact tab bar trims the tabs and hides the workspace name; its other controls wait behind a handle at
    /// the end of the bar and cover the tabs only while the handle or they are hovered.
    @MainActor
    private static func checkCompactTabBar() -> [String] {
        let host = WorkspaceWindow(contentRect: NSRect(x: 100, y: 100, width: 930, height: 600),
                                   styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let chrome = WorkspaceChromeView(frame: .zero)
        host.contentView = chrome
        chrome.setWorkspaceName("Workspace")
        host.orderBack(nil)
        defer {
            chrome.compactTabBar = false
            chrome.setAutoHideTabBar(false)
            host.close()
        }
        func layout() {
            chrome.layoutSubtreeIfNeeded()
            chrome.tabs.window?.contentView?.layoutSubtreeIfNeeded()
        }
        func center(_ view: NSView) -> NSPoint {
            let frame = view.window!.convertToScreen(view.convert(view.bounds, to: nil))
            return NSPoint(x: frame.midX, y: frame.midY)
        }
        let items = (0 ..< 12).map {
            WorkspaceTabItem(id: UUID(), title: "Document \($0) with a long title", selected: $0 == 0)
        }
        let tabs = chrome.setTabs(items)
        layout()
        let regularTab = tabs[0].view.frame
        let regularPadding = regularTab.width - tabs[0].select.frame.width
        let regularViewport = chrome.tabs.visibleRect.width
        var failures: [String] = []

        chrome.compactTabBar = true
        layout()
        let tucked: [NSView] = [
            chrome.workspaceButton, chrome.workspaceMenuButton, chrome.combineButton, chrome.columnSelector,
            chrome.rowSelector, chrome.permissionButton,
        ]
        if tucked.contains(where: { !$0.isHiddenOrHasHiddenAncestor }) {
            failures.append("compact tab bar still showed the workspace name or the controls after the tabs")
        }
        if chrome.addButton.isHiddenOrHasHiddenAncestor { failures.append("compact tab bar hid the + button") }
        let compactTab = tabs[0].view.frame
        let compactPadding = compactTab.width - tabs[0].select.frame.width
        if compactTab.height >= regularTab.height || compactPadding >= regularPadding {
            failures.append(
                "compact tabs kept their size: height \(compactTab.height) (was \(regularTab.height)), padding \(compactPadding) (was \(regularPadding))")
        }
        if chrome.tabs.visibleRect.width <= regularViewport + 100 {
            failures.append(
                "compact tab bar did not give the tabs the name's and controls' room: \(chrome.tabs.visibleRect.width) (was \(regularViewport))")
        }
        guard let handle = chrome.compactControlsHandleScreenFrame else {
            return failures + ["compact tab bar had no handle for its controls"]
        }
        if handle.maxX < host.frame.maxX - 8 {
            failures.append("compact tab bar handle was not at the end of the bar: \(handle) in \(host.frame)")
        }
        let tabFrames = tabs.map(\.view.frame)
        chrome.updateCompactControlsHover(at: NSPoint(x: handle.midX, y: handle.midY))
        layout()
        if !chrome.compactControlsRevealed || chrome.columnSelector.isHiddenOrHasHiddenAncestor
            || chrome.workspaceMenuButton.isHiddenOrHasHiddenAncestor {
            failures.append("hovering the compact tab bar handle did not show its controls")
        }
        if let tray = chrome.compactControlsScreenFrame {
            if tray.maxX > handle.minX || !host.frame.contains(tray) {
                failures.append("compact tab bar controls were not beside the handle: \(tray), handle \(handle)")
            }
        } else {
            failures.append("compact tab bar controls had no frame after hovering the handle")
        }
        if tabs.map(\.view.frame) != tabFrames {
            failures.append("showing the compact tab bar controls moved the tabs")
        }
        let selectorPoint = chrome.convert(
            chrome.convert(chrome.columnSelector.bounds, from: chrome.columnSelector), to: chrome.superview)
        if let hit = chrome.hitTest(NSPoint(x: selectorPoint.midX, y: selectorPoint.midY)),
           hit === chrome.columnSelector || hit.isDescendant(of: chrome.columnSelector) {
        } else {
            failures.append("the shown compact tab bar controls did not receive clicks above the tabs")
        }
        let start = Date()
        chrome.updateCompactControlsHover(
            at: center(chrome.columnSelector),
            now: start.addingTimeInterval(WorkspaceChromeView.compactControlsHideDelay * 2))
        let away = NSPoint(x: host.frame.minX + 20, y: host.frame.minY + 20)
        chrome.updateCompactControlsHover(at: away, now: start)
        if !chrome.compactControlsRevealed {
            failures.append("compact tab bar controls hid while the pointer was on them or right after it left")
        }
        chrome.updateCompactControlsHover(
            at: away, now: start.addingTimeInterval(WorkspaceChromeView.compactControlsHideDelay + 0.05))
        if chrome.compactControlsRevealed || !chrome.columnSelector.isHiddenOrHasHiddenAncestor {
            failures.append("compact tab bar controls stayed after the pointer left them")
        }

        chrome.setAutoHideTabBar(true)
        chrome.setAutoHiddenToolbarVisible(true)
        layout()
        if let panel = chrome.autoHiddenToolbarPanel, let panelHandle = chrome.compactControlsHandleScreenFrame {
            if !panel.frame.insetBy(dx: -1, dy: -1).contains(panelHandle) {
                failures.append("auto-hidden compact tab bar put its handle outside the bar")
            }
            chrome.updateCompactControlsHover(at: NSPoint(x: panelHandle.midX, y: panelHandle.midY))
            if !chrome.compactControlsRevealed {
                failures.append("hovering the auto-hidden compact tab bar handle did not show its controls")
            }
            chrome.setAutoHiddenToolbarVisible(false)
            if chrome.compactControlsRevealed {
                failures.append("hiding the auto-hidden compact tab bar left its controls shown")
            }
        } else {
            failures.append("auto-hidden compact tab bar had no handle")
        }
        chrome.setAutoHideTabBar(false)

        chrome.setTabBarPosition(.left)
        layout()
        if let verticalHandle = chrome.compactControlsHandleScreenFrame {
            chrome.updateCompactControlsHover(at: NSPoint(x: verticalHandle.midX, y: verticalHandle.midY))
            layout()
            if let tray = chrome.compactControlsScreenFrame, tray.minY >= verticalHandle.maxY,
               host.frame.contains(tray) {
            } else {
                failures.append("vertical compact tab bar did not show its controls above the handle")
            }
            chrome.updateCompactControlsHover(at: away, now: Date().addingTimeInterval(-1))
            chrome.updateCompactControlsHover(at: away)
        } else {
            failures.append("vertical compact tab bar had no handle")
        }
        chrome.setTabBarPosition(.top)

        chrome.compactTabBar = false
        layout()
        if tucked.dropFirst(2)
            .contains(where: { $0.isHiddenOrHasHiddenAncestor || $0.superview !== chrome.addButton.superview })
            || chrome.workspaceButton.isHiddenOrHasHiddenAncestor || chrome.workspaceMenuButton.window != nil
            || chrome.compactControlsHandleScreenFrame != nil {
            failures.append("turning the compact tab bar off did not put the name and controls back in the bar")
        }
        if abs(tabs[0].view.frame.height - regularTab.height) > 0.5
            || abs(tabs[0].view.frame.width - tabs[0].select.frame.width - regularPadding) > 0.5
            || abs(chrome.tabs.visibleRect.width - regularViewport) > 1 {
            failures.append(
                "turning the compact tab bar off did not restore the tabs: \(tabs[0].view.frame), viewport \(chrome.tabs.visibleRect.width) (was \(regularTab), \(regularViewport))")
        }
        return failures
    }

    /// An auto-hidden tab bar draws its tabs like the regular bar, not grayed out.
    @MainActor
    private static func checkAutoHiddenTabAppearance() -> [String] {
        let host = WorkspaceWindow(contentRect: NSRect(x: 100, y: 100, width: 930, height: 600),
                                   styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let chrome = WorkspaceChromeView(frame: .zero)
        host.contentView = chrome
        host.orderBack(nil)
        defer {
            chrome.setAutoHideTabBar(false)
            host.close()
        }
        let tabs = chrome.setTabs([
            WorkspaceTabItem(id: UUID(), title: "Selected document", selected: true),
            WorkspaceTabItem(id: UUID(), title: "Other document", selected: false),
        ])
        let tab = tabs[1]
        // The unselected tab's translucent background and its title's contrast against it.
        func sample(in root: NSView) -> (background: NSColor, contrast: CGFloat)? {
            root.layoutSubtreeIfNeeded()
            root.window?.displayIfNeeded()
            guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return nil }
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / root.bounds.width
            func color(_ point: NSPoint) -> NSColor? {
                let y = root.isFlipped ? point.y : root.bounds.height - point.y
                return bitmap.colorAt(x: Int(point.x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB)
            }
            func luminance(_ color: NSColor) -> CGFloat {
                0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
            }
            let group = tab.view.convert(tab.view.bounds, to: root)
            guard let background = color(NSPoint(x: group.minX + 3, y: group.midY)) else { return nil }
            let title = tab.select.convert(tab.select.bounds, to: root).insetBy(dx: 2, dy: 4)
            var contrast: CGFloat = 0
            for y in stride(from: title.minY, to: title.maxY, by: 0.5) {
                for x in stride(from: title.minX, to: min(title.maxX, title.minX + 80), by: 0.5) {
                    if let pixel = color(NSPoint(x: x, y: y)) {
                        contrast = max(contrast, abs(luminance(pixel) - luminance(background)))
                    }
                }
            }
            return (background, contrast)
        }
        guard let regular = sample(in: chrome) else { return ["couldn't render the regular tab bar"] }
        chrome.setAutoHideTabBar(true)
        chrome.setAutoHiddenToolbarVisible(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        guard let panel = chrome.autoHiddenToolbarPanel?.contentView, let hidden = sample(in: panel) else {
            return ["couldn't render the auto-hidden tab bar"]
        }
        let difference = abs(regular.background.redComponent - hidden.background.redComponent)
            + abs(regular.background.greenComponent - hidden.background.greenComponent)
            + abs(regular.background.blueComponent - hidden.background.blueComponent)
        if difference > 0.1 || hidden.contrast < regular.contrast * 0.8 {
            return ["auto-hidden tabs looked grayed out: background \(hidden.background) vs \(regular.background), "
                + "title contrast \(hidden.contrast) vs \(regular.contrast)"]
        }
        return []
    }

    @MainActor
    private static func checkTabStripFeedback() -> [String] {
        let host = WorkspaceWindow(contentRect: NSRect(x: 100, y: 100, width: 960, height: 640),
                                   styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let chrome = WorkspaceChromeView(frame: .zero)
        host.contentView = chrome
        host.orderBack(nil)
        defer { host.close() }
        var failures: [String] = []
        let first = WorkspaceTabItem(
            id: UUID(), title: "First", toolTip: "Safari — First", selected: true, displayed: true, pinned: true,
            tabSwitchTarget: true)
        let middle = WorkspaceTabItem(id: UUID(), title: "Middle", selected: false)
        let last = WorkspaceTabItem(id: UUID(), title: "Last", selected: false)
        func settle() {
            chrome.layoutSubtreeIfNeeded()
            CATransaction.flush()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.24))
        }
        for vertical in [false, true] {
            chrome.setTabBarPosition(vertical ? .left : .top)
            let existing = chrome.setTabs([first, last])
            if existing[0].select.toolTip != "Safari — First" || existing[0].view.toolTip != "Safari — First" {
                failures.append("hovering anywhere over the tab did not expose its app name and full title")
            }
            chrome.setWorkspaceName("Research workspace")
            if chrome.workspaceButton.toolTip != "Research workspace" {
                failures.append("hovering over the workspace name did not show its full name")
            }
            settle()
            for adding in [true, false] {
                let neighbor = existing[1].view
                func position(_ view: NSView, presented: Bool) -> CGFloat {
                    guard let layer = view.layer, let root = chrome.addButton.superview?.layer else { return .nan }
                    let current = presented ? layer.presentation() ?? layer : layer
                    let target = presented ? root.presentation() ?? root : root
                    let frame = current.convert(current.bounds, to: target)
                    return vertical ? frame.midY : frame.midX
                }
                let before = position(neighbor, presented: false)
                let firstBefore = position(existing[0].view, presented: false)
                let plusBefore = position(chrome.addButton, presented: false)
                let next = chrome.setTabs(adding ? [first, middle, last] : [first, last])
                chrome.revealTab(next[0].view)
                func between(_ value: CGFloat, _ a: CGFloat, _ b: CGFloat) -> Bool {
                    value.isFinite && value > min(a, b) + 1 && value < max(a, b) - 1
                }
                var samples: [(first: CGFloat, last: CGFloat, plus: CGFloat)] = []
                var entry: [(center: CGFloat, width: CGFloat)] = []
                let end = Date(timeIntervalSinceNow: 0.24)
                repeat {
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.009))
                    samples.append((position(existing[0].view, presented: true), position(neighbor, presented: true),
                                    position(chrome.addButton, presented: true)))
                    if adding, let layer = next[1].view.layer?.presentation(), layer.opacity > 0.05 {
                        entry.append((position(next[1].view, presented: true), layer.frame.width))
                    }
                } while Date() < end
                let after = position(neighbor, presented: false)
                let firstAfter = position(existing[0].view, presented: false)
                let plusAfter = position(chrome.addButton, presented: false)
                let sawSlide = samples
                    .contains { between($0.last, before, after) || between($0.first, firstBefore, firstAfter) }
                let sawPlus = samples.contains { between($0.plus, plusBefore, plusAfter) }
                let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                if adding {
                    let center = position(next[1].view, presented: false)
                    let width = next[1].view.frame.width
                    if entry.isEmpty || entry.contains(where: { abs($0.center - center) > 1.5 })
                        || entry.contains(where: { $0.width < width - 1 }) == reduce {
                        failures
                            .append(
                                "vertical=\(vertical): new tab should pop at \(center), not fly in: \(entry.prefix(4))")
                    }
                }
                if next.last?.view !== neighbor || max(abs(before - after), abs(firstBefore - firstAfter)) < 25
                    || sawSlide == reduce || (!vertical && (sawPlus == reduce || abs(plusBefore - plusAfter) < 25)) {
                    failures
                        .append(
                            "vertical=\(vertical) add=\(adding): first \(firstBefore)→\(firstAfter), last \(before)→\(after), slide=\(sawSlide); + \(plusBefore)→\(plusAfter), slide=\(sawPlus); reduce=\(reduce), samples=\(samples.prefix(4))")
                }
            }
        }
        let groups = chrome.setTabs([first, last]).map(\.view)
        for group in groups {
            guard group.trackingAreas.contains(where: {
                $0.owner === group && $0.options.contains([.mouseEnteredAndExited, .inVisibleRect])
            }), let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: host.windowNumber,
                                                   context: nil, eventNumber: 1, trackingNumber: 0, userData: nil),
                let exit = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
                                                  timestamp: 0, windowNumber: host.windowNumber,
                                                  context: nil, eventNumber: 2, trackingNumber: 0, userData: nil)
            else { return failures + ["missing tab-wide mouse tracking"] }
            group.mouseExited(with: exit)
            let base = group.layer?.backgroundColor
            let border = group.layer?.borderColor
            group.mouseEntered(with: enter)
            if group.layer?.backgroundColor == base || group.layer?.borderColor != border {
                failures.append("hover did not change the tab fill independently of the selection border")
            }
            guard let close = group.arrangedSubviews.last as? NSButton,
                  close.trackingAreas.contains(where: { $0.options.contains(.mouseEnteredAndExited) })
            else { return failures + ["the close button does not track its own hover"] }
            let tabFill = group.layer?.backgroundColor
            close.mouseEntered(with: enter)
            if (close.layer?.backgroundColor?.alpha ?? 0) < 0.22 || group.layer?.backgroundColor != tabFill {
                failures.append("the × did not gain a stronger local highlight over the hovered tab")
            }
            close.mouseExited(with: exit)
            if (close.layer?.backgroundColor?.alpha ?? 0) != 0 || group.layer?.backgroundColor != tabFill {
                failures.append("leaving × did not clear just its highlight")
            }
            group.mouseExited(with: exit)
            if group.layer?.backgroundColor != base { failures.append("tab remained highlighted after mouse exit") }
        }
        for closesWindow in [false, true] {
            chrome.closesWindowsOnRelease = closesWindow
            let close = chrome.setTabs([first, last])[0].close
            chrome.layoutSubtreeIfNeeded()
            let label = closesWindow ? L("ウィンドウを閉じる") : L("元の位置に戻してタブから解除")
            guard let cell = close.cell else { return failures + ["missing close button cell"] }
            if close.image == nil || cell.imageRect(forBounds: close.bounds).intersection(close.bounds).isEmpty
                || !cell.titleRect(forBounds: close.bounds).isEmpty {
                failures.append("the tab close button did not draw just its × for \(label)")
            }
            if close.toolTip != label || close.accessibilityLabel() != label {
                failures.append("the tab close button lost its action description for \(label)")
            }
        }
        return failures
    }

    @MainActor
    static func main() {
        let hoverOnly = CommandLine.arguments.contains("--hover-help-only")
        if hoverOnly {
            UserDefaults.standard
                .setVolatileDomain(["NSInitialToolTipDelay": 100], forName: UserDefaults.argumentDomain) }
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--new-tab-only") {
            app.setActivationPolicy(.prohibited)
            Task {
                let failures = await checkLauncherGrid()
                for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
                if failures.isEmpty {
                    print("PASS: installed apps grid, launching one or several apps, registering automatic adds, "
                        + "and Dock menus")
                }
                exit(failures.isEmpty ? 0 : 1)
            }
            app.run()
            return
        }
        app.setActivationPolicy(hoverOnly ? .prohibited : .accessory)
        if hoverOnly {
            app.finishLaunching()
            let failures = [false, true].flatMap { detached in
                [true, false].compactMap { checkBackgroundHoverHelp(detached: detached, workspaceName: $0) }
            } + checkNewTabHoverGlow()
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            if failures.isEmpty {
                print("PASS: visible tab and workspace help, and new tab hover glow, while another app stays active")
            }
            exit(failures.isEmpty ? 0 : 1)
        }
        let host = WorkspaceWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1120, height: 760),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let chrome = WorkspaceChromeView(frame: .zero)
        host.contentView = chrome
        chrome.workspaceButton.title = "Workspace"
        var failures = checkTabStripFeedback() + checkCloseSlotsAndWrapping() + checkIconOnlyTabs()
            + checkCompactTabBar() + checkAutoHiddenTabAppearance()

        func settle() {
            for _ in 0 ..< 4 {
                chrome.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }
        func checkVisible(_ label: String) {
            settle()
            let visible = chrome.tabs.visibleRect
            print("\(label): strip=\(chrome.tabs.frame), visible=\(visible)")
            if visible.width < 80 || visible.height < 28 {
                failures.append("\(label): tab viewport collapsed")
            }
            for control in [chrome.addButton, chrome.columnSelector, chrome.rowSelector, chrome.permissionButton] {
                let frame = chrome.convert(control.bounds, from: control)
                if frame.isEmpty || !chrome.bounds.contains(frame) {
                    failures.append("\(label): toolbar control is clipped")
                }
            }
            let nameWidth = chrome.workspaceButton.frame.width
            if nameWidth > ceil(chrome.workspaceButton.intrinsicContentSize.width) + 0.5 {
                failures.append("\(label): workspace name is wider than its text (\(nameWidth))")
            }
            for group in chrome.tabs.arrangedSubviews {
                guard let tab = (group as? WorkspaceTabGroup)?.arrangedSubviews.first as? NSButton else {
                    failures.append("\(label): tab button missing")
                    continue
                }
                if group.isHidden || tab.isHidden || tab.bounds.width < 21.5 || tab.bounds.height < 28 {
                    failures.append("\(label): tab has no usable size")
                }
            }
        }
        settle()
        let shortTitle = chrome.appendTab(title: "Tools", selected: false)
        let iconTitle = chrome.appendTab(
            title: "Tools", icon: NSImage(size: NSSize(width: 16, height: 16)), selected: false)
        let longTitle = chrome.appendTab(
            title: String(repeating: "Long application window title ", count: 4), selected: true)
        checkVisible("mixed title lengths")
        let shortWidth = shortTitle.select.bounds.width
        let longWidth = longTitle.select.bounds.width
        if abs(shortWidth - longWidth) > 1 || abs(iconTitle.select.bounds.width - longWidth) > 1
            || [shortTitle, iconTitle, longTitle].contains(where: { $0.select.alignment != .left }) {
            failures.append("titles with and without icons did not share equal-width, left-aligned slots")
        }
        for _ in 0 ..< 5 {
            chrome.appendTab(title: String(repeating: "Another long window ", count: 4), selected: false)
        }
        checkVisible("mixed title lengths when crowded")
        if longTitle.select.bounds
            .width >= longWidth || abs(shortTitle.select.bounds.width - longTitle.select.bounds.width) > 1 {
            failures.append("crowded tabs did not shrink together")
        }
        chrome.clearTabs()
        settle()
        let single = chrome.appendTab(title: "First application window", selected: true)
        checkVisible("first tab after empty layout")
        let singleWidth = single.select.bounds.width
        for index in 1 ..< 7 {
            chrome.appendTab(title: "Application \(index)", selected: false)
        }
        checkVisible("seven tabs")
        if single.select.bounds.width >= singleWidth {
            failures.append("tabs did not shrink as more were added")
        }
        let wideWidth = single.select.bounds.width
        _ = chrome.showNotice(.attention("Constraint warning"))
        settle()
        let warningStageHeight = chrome.stage.frame.height
        if chrome.showNotice(.attention("Constraint warning")) {
            failures.append("repeating the warning changed the notice bar height")
        }
        _ = chrome.showNotice(.information("Normal tab"))
        settle()
        if abs(chrome.stage.frame.height - warningStageHeight - 22) > 0.5 {
            failures.append("switching to a normal tab did not immediately remove the warning bar")
        }
        host.setFrame(NSRect(x: 100, y: 100, width: 720, height: 480), display: false)
        checkVisible("seven tabs in narrow window")
        if single.select.bounds.width > wideWidth + 0.5 {
            failures.append("tabs grew when the window narrowed")
        }
        for index in 7 ..< 20 {
            chrome.appendTab(title: "Application \(index)", selected: false)
        }
        checkVisible("twenty tabs")
        if single.view.frame.width > 56.5 || single.close.frame.width < 18 {
            failures.append("crowded tabs did not compact to 56 points while keeping the close button")
        }
        chrome.workspaceButton.title = String(repeating: "Long workspace name ", count: 6)
        checkVisible("long workspace name with crowded tabs")
        if chrome.workspaceButton.frame.width > 49 {
            failures.append("crowded tabs did not take space from the workspace name")
        }
        chrome.workspaceButton.title = "Workspace"
        if chrome.tabs.bounds.width <= chrome.tabs.visibleRect.width {
            failures.append("minimum-width tabs did not scroll")
        }
        if let last = chrome.tabs.arrangedSubviews.last {
            chrome.revealTab(last)
            if !chrome.tabs.visibleRect.contains(last.frame) {
                failures.append("last tab could not be revealed")
            }
            let divider = chrome.workspaceButton.superview?.subviews.compactMap { $0 as? NSBox }.first {
                $0.boxType == .separator
            }
            guard let scroll = chrome.tabs.enclosingScrollView else { fatalError("missing tab scroll view") }
            if divider?.isHidden != false || abs((divider?.frame.midX ?? 0) - scroll.frame.minX) > 4 {
                failures.append("scrolling hid the leading tabs without marking the workspace-name boundary")
            }
            chrome.revealTab(single.view)
            if divider?.isHidden != true {
                failures.append("returning to the first tab left a spurious clipping divider")
            }
        }
        chrome.clearTabs()
        settle()
        let releaseIDs = (0 ..< 4).map { _ in UUID() }
        for (id, title) in zip(releaseIDs, ["Release first", "Release target", "Release third", "Release fourth"]) {
            chrome.appendTab(id: id, title: title, selected: false)
        }
        for (tag, group) in chrome.tabs.arrangedSubviews.enumerated() {
            ((group as! WorkspaceTabGroup).arrangedSubviews.first as! NSButton).tag = tag
        }
        var released: [TabReleaseRequest] = []
        chrome.onReleaseTabs = { released.append($0) }
        let rightClick = NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: host.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let targetTab = (chrome.tabs.arrangedSubviews[1] as! WorkspaceTabGroup).arrangedSubviews.first as! NSButton
        let releaseMenu = targetTab.menu(for: rightClick)
        chrome.closesWindowsOnRelease = true
        let closeMenu = targetTab.menu(for: rightClick)
        // An open menu still targets the windows and the action it originally offered.
        chrome.clearTabs()
        chrome.appendTab(title: "New tab", selected: true)
        for (menu, bulkClose) in [(releaseMenu, false), (closeMenu, true)] {
            let expectations: [(String, [Int], Bool)] = [
                ("タブを解除", [1], false), ("ウィンドウを閉じる", [1], true),
                (bulkClose ? "他のタブのウィンドウをすべて閉じる" : "他のタブをすべて解除", [0, 2, 3], bulkClose),
                (bulkClose ? "右側のタブのウィンドウを閉じる" : "右側のタブを解除", [2, 3], bulkClose),
                (bulkClose ? "左側のタブのウィンドウを閉じる" : "左側のタブを解除", [0], bulkClose),
                (bulkClose ? "すべてのタブのウィンドウを閉じる" : "すべてのタブを解除", [0, 1, 2, 3], bulkClose),
            ]
            for (title, indexes, closeWindows) in expectations {
                guard let item = menu?.item(withTitle: L(title)), let action = item.action else {
                    failures.append("tab context menu did not offer \(title)")
                    continue
                }
                released.removeAll()
                _ = NSApp.sendAction(action, to: item.target, from: item)
                if released != [TabReleaseRequest(ids: indexes.map { releaseIDs[$0] }, closeWindows: closeWindows)] {
                    failures
                        .append(
                            "tab context menu performed the wrong action or targeted the wrong windows for \(title)")
                }
            }
        }
        chrome.closesWindowsOnRelease = false
        chrome.clearTabs()
        settle()
        let pinID = UUID()
        chrome.setTabs([
            WorkspaceTabItem(
                id: pinID, title: "Pin target", toolTip: nil, icon: nil, selected: false,
                canPinTab: true),
        ])
        let pinButton = (chrome.tabs.arrangedSubviews[0] as! WorkspaceTabGroup).arrangedSubviews.first as! NSButton
        pinButton.tag = 0
        var pinRequest: (UUID, Bool)?
        chrome.onSetTabPinned = { pinRequest = ($0, $1) }
        let pinMenu = pinButton.menu(for: rightClick)
        if let pin = pinMenu?.item(withTitle: L("タブを固定")), let action = pin.action {
            NSApp.sendAction(action, to: pin.target, from: pin)
        }
        if pinRequest?.0 != pinID || pinRequest?.1 != true {
            failures.append("tab context menu did not request pinning the selected tab")
        }
        if pinMenu?.items
            .contains(where: { $0.submenu?.item(withTitle: "Control+Shift+Option+Command+3") != nil }) == true {
            failures.append("a pinnable tab still offered per-tab number assignments")
        }
        chrome.setTabs([
            WorkspaceTabItem(
                id: UUID(), title: "Pane pin", toolTip: nil, icon: nil, selected: false, pinned: true),
            WorkspaceTabItem(
                id: UUID(), title: "Tab pin", toolTip: nil, icon: nil, selected: false, tabPinned: true),
        ])
        func pinIndicator(_ index: Int) -> NSImageView? {
            (chrome.tabs.arrangedSubviews[index] as? WorkspaceTabGroup)?.subviews.compactMap { $0 as? NSImageView }
                .first
        }
        let panePinIndicator = pinIndicator(0)
        let tabPinIndicator = pinIndicator(1)
        settle()
        let paneTab = chrome.tabs.arrangedSubviews[0] as? WorkspaceTabGroup
        let pinnedTab = chrome.tabs.arrangedSubviews[1] as? WorkspaceTabGroup
        let pinnedSelect = pinnedTab?.arrangedSubviews.first as? NSButton
        let pinnedClose = pinnedTab?.arrangedSubviews.dropFirst().first
        if panePinIndicator?.isHidden != false
            || panePinIndicator?.accessibilityLabel() != L("固定中")
            || panePinIndicator?.contentTintColor?.isEqual(NSColor.controlAccentColor) != true
            || tabPinIndicator?.isHidden != true
            || pinnedClose?.isHidden != true
            || pinnedSelect?.title != ""
            || pinnedSelect?.image == nil
            || (pinnedTab?.frame.width ?? .greatestFiniteMagnitude) >= (paneTab?.frame.width ?? 0)
            || pinnedTab?.isTabPinned != true
        {
            failures.append("tab pin did not use a compact icon-only style distinct from pane pins")
        }
        chrome.clearTabs()
        settle()
        let regularStageTop = chrome.stage.frame.maxY
        chrome.setAutoHideTabBar(true)
        settle()
        if !chrome.autoHideTabBar || chrome.stage.frame.maxY < regularStageTop + 24 {
            failures.append("auto-hide mode did not expand the managed window area")
        }
        if chrome.autoHiddenToolbarPanel?.isVisible == true {
            failures.append("auto-hidden toolbar panel was visible before hover")
        }
        chrome.setAutoHiddenToolbarVisible(true)
        settle()
        if chrome.autoHiddenToolbarPanel?.isVisible != true
            || chrome.autoHiddenToolbarPanel?.frame.width != host.frame.width - 64
            || chrome.autoHiddenToolbarPanel?.frame.minX != host.frame.minX + 64
            || chrome.autoHiddenToolbarPanel?.frame.maxY != host.frame.maxY
            || chrome.autoHiddenToolbarPanel?.frame.height != 34
        {
            failures.append(
                "auto-hidden toolbar panel did not cover the workspace's top edge: \(String(describing: chrome.autoHiddenToolbarPanel?.frame)) host=\(host.frame)")
        }
        // Like the embedded tab bar, dragging empty space in the auto-hidden bar moves the workspace.
        if let panel = chrome.autoHiddenToolbarPanel, let content = panel.contentView,
           let screen = NSScreen.screens.first
        {
            let emptyPoint = stride(from: content.bounds.minX + 2, to: content.bounds.maxX, by: 4)
                .map { NSPoint(x: $0, y: content.bounds.midY) }
                .first { point in
                    guard let hit = content.hitTest(point), hit !== content,
                          !String(describing: type(of: hit)).contains("DragSpace")
                    else { return false }
                    var view: NSView? = hit
                    while let current = view, current !== content {
                        if current is NSControl { return false }
                        view = current.superview
                    }
                    return true
                }
            let hostFrame = host.frame
            if let emptyPoint,
               let down = NSEvent.mouseEvent(
                   with: .leftMouseDown, location: emptyPoint, modifierFlags: [],
                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                   context: nil, eventNumber: 30, clickCount: 1, pressure: 1)
            {
                let start = panel.convertPoint(toScreen: emptyPoint)
                let queued = [CGEventType.leftMouseDragged, .leftMouseUp].compactMap { type in
                    CGEvent(
                        mouseEventSource: nil, mouseType: type,
                        mouseCursorPosition: CGPoint(x: start.x + 60, y: screen.frame.maxY - (start.y - 40)),
                        mouseButton: .left)
                        .flatMap { NSEvent(cgEvent: $0) }
                }
                queued.forEach { NSApp.postEvent($0, atStart: false) }
                panel.sendEvent(down)
                while NSApp.nextEvent(
                    matching: [.leftMouseDragged, .leftMouseUp],
                    until: Date(),
                    inMode: .default,
                    dequeue: true) != nil {}
                if host.frame != hostFrame.offsetBy(dx: 60, dy: -40) {
                    failures.append(
                        "dragging empty space in the auto-hidden tab bar did not move the workspace: \(host.frame) from \(hostFrame)")
                }
                host.setFrame(hostFrame, display: false)
                chrome.updateToolbarPanelFrame()
            } else {
                failures.append("could not find empty space in the auto-hidden tab bar to drag")
            }
        }
        chrome.setAutoHideTabBar(false)
        settle()
        if chrome.autoHideTabBar || chrome.autoHiddenToolbarPanel?.isVisible == true
            || abs(chrome.stage.frame.maxY - regularStageTop) > 0.5
        {
            failures.append("disabling auto-hide did not restore the embedded toolbar layout")
        }
        chrome.clearTabs()
        settle()
        chrome.appendTab(title: "First application window", selected: true)
        checkVisible("first tab after clear")
        if let tab = (chrome.tabs.arrangedSubviews.first as? WorkspaceTabGroup)?.arrangedSubviews.first,
           tab.bounds.width <= wideWidth
        {
            failures.append("tab did not expand again after removing other tabs")
        }
        let target = chrome.appendTab(title: "Drag target", selected: false)
        let board = NSPasteboard(name: NSPasteboard.Name("TabLayoutSmoke-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        chrome.setGrid(WorkspaceGridSize(columns: 2, rows: 1), activeCell: 0)
        for frame in [
            NSRect(x: 0, y: 0, width: 1400, height: 900),
            NSRect(x: 260, y: 190, width: 900, height: 600),
        ] {
            host.setFrame(frame, display: false)
            settle()
            let source = (chrome.tabs.arrangedSubviews.first as! WorkspaceTabGroup).arrangedSubviews.first as! NSButton
            let group = source.superview!
            let anchor = NSPoint(x: 15, y: source.bounds.midY)
            let anchorInGroup = source.convert(anchor, to: group)
            chrome.beginTabDrag(source: source, token: "geometry", anchor: anchor)
            board.setString("geometry", forType: workspaceTabDragType)
            let destination = target.select.convert(
                NSPoint(x: target.select.bounds.midX, y: target.select.bounds.midY), to: nil)
            let info = TabLayoutDragInfo(board: board, source: source, window: host, location: destination)
            _ = target.select.draggingUpdated(info)
            let actualAnchor = group.convert(anchorInGroup, to: nil)
            if abs(actualAnchor.x - destination.x) > 1 || chrome.tabDragPreviewPanel?.isVisible == true {
                failures.append("resized window: reordered tab is not under the pointer")
            }
            let panePoint = chrome.gridAreas[0].convert(NSPoint(x: 100, y: 100), to: nil)
            let paneInfo = TabLayoutDragInfo(board: board, source: source, window: host, location: panePoint)
            _ = chrome.draggingUpdated(paneInfo)
            let paneScreenPoint = host.convertPoint(toScreen: panePoint)
            let previewAligned =
                chrome.tabDragPreviewPanel.map {
                    $0.isVisible && abs($0.frame.minX + anchorInGroup.x - paneScreenPoint.x) <= 1
                        && abs($0.frame.minY + anchorInGroup.y - paneScreenPoint.y) <= 1
                } ?? false
            if !previewAligned {
                failures.append("resized window: pane preview is not under the pointer")
            }
            chrome.endTabDrag()
        }
        chrome.setGrid(.single, activeCell: 0)
        settle()
        do {
            let source = (chrome.tabs.arrangedSubviews.first as! WorkspaceTabGroup).arrangedSubviews.first as! NSButton
            chrome.beginTabDrag(source: source, token: "single-pane")
            board.setString("single-pane", forType: workspaceTabDragType)
            let pane = chrome.gridAreas[0]
            let panePoint = host.convertPoint(
                toScreen: pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil))
            _ = chrome.updateFloatingTab(pasteboard: board, source: source, screenPoint: panePoint)
            if pane.subviews.contains(where: { $0 is WorkspaceTabDropOverlay })
                || chrome.tabDragPreviewPanel?.isVisible != true
            {
                failures.append("a single pane did not show the detached-tab preview without a pane target")
            }
            chrome.endTabDrag()
        }
        settle()
        chrome.showManagedWindows(true)
        let area = chrome.gridAreas[0]
        let areaScreenFrame = host.convertToScreen(area.convert(area.bounds, to: nil))
        let oldRenderedFrame = areaScreenFrame.offsetBy(dx: -80, dy: 0)
        if let coverage = WindowGeometry.confirmedCoverage(for: areaScreenFrame, renderedFrames: [oldRenderedFrame]) {
            chrome.presentFrames([0: coverage])
        } else {
            failures.append("moving pane lost its overlapping coverage")
        }
        if let bitmap = chrome.bitmapImageRepForCachingDisplay(in: chrome.bounds) {
            chrome.cacheDisplay(in: chrome.bounds, to: bitmap)
            for (localPoint, transparent) in [
                (NSPoint(x: area.bounds.midX, y: area.bounds.midY), true),
                (NSPoint(x: area.bounds.maxX - 10, y: area.bounds.midY), false),
            ] {
                let point = chrome.convert(localPoint, from: area)
                let color = bitmap.colorAt(
                    x: Int(point.x * CGFloat(bitmap.pixelsWide) / chrome.bounds.width),
                    y: Int((chrome.bounds.height - point.y) * CGFloat(bitmap.pixelsHigh) / chrome.bounds.height))
                if let alpha = color?.alphaComponent {
                    if transparent ? alpha > 0.01 : alpha < 0.99 {
                        failures.append("moving pane blanked safe overlap or exposed its uncovered edge")
                    }
                } else {
                    failures.append("could not sample moving pane coverage")
                }
            }
        } else {
            failures.append("could not render moving pane coverage")
        }
        let probeHost = WorkspaceWindow(
            contentRect: NSRect(x: 150, y: 150, width: 500, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        probeHost.isReleasedWhenClosed = false
        let probe = FrameChangeProbe(frame: .zero)
        probeHost.contentView = probe
        let probeArea = NSView(frame: NSRect(x: 10, y: 10, width: 480, height: 380))
        probe.addSubview(probeArea)
        probe.contentArea = probeArea
        probe.revealsWindow = true
        var preparedChanges = 0
        for iteration in 0 ..< 30 {
            let oldFrame = probeHost.frame
            let nextFrame = oldFrame.offsetBy(dx: iteration.isMultiple(of: 2) ? 100 : -100, dy: 15)
            probe.coveredScreenRect = probeHost.convertToScreen(probeArea.frame)
            probe.onPrepare = { old, proposed in
                preparedChanges += 1
                if old != oldFrame || proposed != nextFrame {
                    failures.append("fast native move prepared coverage after changing the frame")
                }
            }
            probe.onPrepared = {
                guard let bitmap = probe.bitmapImageRepForCachingDisplay(in: probe.bounds) else {
                    failures.append("could not render the pre-move mask")
                    return
                }
                probe.cacheDisplay(in: probe.bounds, to: bitmap)
                let x = iteration.isMultiple(of: 2) ? probeArea.frame.maxX - 5 : probeArea.frame.minX + 5
                let y = probeArea.frame.midY
                let color = bitmap.colorAt(
                    x: Int(x * CGFloat(bitmap.pixelsWide) / probe.bounds.width),
                    y: Int((probe.bounds.height - y) * CGFloat(bitmap.pixelsHigh) / probe.bounds.height))
                if (color?.alphaComponent ?? 0) < 0.99 {
                    failures.append("fast native move left its exposed edge transparent before moving")
                }
            }
            if iteration.isMultiple(of: 2) {
                probeHost.setFrame(nextFrame, display: true)
            } else {
                probeHost.setFrameOrigin(nextFrame.origin)
            }
        }
        if preparedChanges != 30 || probe.finishedChanges != 30 {
            failures.append("native frame changes bypassed the pre-move coverage update")
        }
        probeHost.close()
        if WorkspaceController(name: "Smoke").window.isMovable {
            failures.append(
                "workspace windows use server-side titlebar dragging, which skips the pre-move transparency mask")
        }
        let titleHost = WorkspaceWindow(
            contentRect: NSRect(x: 150, y: 150, width: 500, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        titleHost.isReleasedWhenClosed = false
        titleHost.isMovable = false
        titleHost.titlebarAppearsTransparent = true
        titleHost.titleVisibility = .hidden
        let titleProbe = FrameChangeProbe(frame: .zero)
        titleHost.contentView = titleProbe
        titleHost.orderFront(nil)
        let titleFrame = titleHost.frame
        let pressPoint = NSPoint(x: 250, y: titleHost.contentLayoutRect.maxY + 8)
        let pressScreen = titleHost.convertPoint(toScreen: pressPoint)
        if let screen = NSScreen.screens.first,
           let down = NSEvent.mouseEvent(
               with: .leftMouseDown, location: pressPoint, modifierFlags: [],
               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: titleHost.windowNumber,
               context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
        {
            var queuedEvents: [NSEvent] = []
            for (offset, type) in [
                (CGFloat(120), CGEventType.leftMouseDragged),
                (CGFloat(-80), CGEventType.leftMouseDragged),
                (CGFloat(180), CGEventType.leftMouseDragged),
                (CGFloat(180), CGEventType.leftMouseUp),
            ] {
                let screenPoint = CGPoint(x: pressScreen.x + offset, y: screen.frame.maxY - pressScreen.y)
                if let cgEvent = CGEvent(
                    mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: screenPoint, mouseButton: .left),
                    let event = NSEvent(cgEvent: cgEvent)
                {
                    queuedEvents.append(event)
                }
            }
            if queuedEvents.count == 4 {
                // These events stay in this test application's queue; they do not move the system pointer.
                for event in queuedEvents { NSApp.postEvent(event, atStart: false) }
                titleHost.sendEvent(down)
                if titleProbe.finishedChanges != 3 || titleHost.frame != titleFrame.offsetBy(dx: 180, dy: 0) {
                    failures.append("titlebar mouse tracking bypassed application-controlled frame changes")
                }
            } else {
                failures.append("could not create titlebar tracking events")
            }
        } else {
            failures.append("could not prepare titlebar mouse tracking")
        }
        let control = TitlebarControlProbe(
            frame: NSRect(
                x: 320, y: titleHost.contentLayoutRect.maxY + 1, width: 100, height: 20))
        titleProbe.addSubview(control)
        if let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: control.frame.midX, y: control.frame.midY),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: titleHost.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1) {
            titleHost.sendEvent(event)
            if control.mouseDownCount != 1 || titleProbe.finishedChanges != 3 {
                failures.append(
                    "titlebar control clicks=\(control.mouseDownCount), frame changes=\(titleProbe.finishedChanges)")
            }
        } else {
            failures.append("could not create a titlebar control click")
        }
        control.removeFromSuperview()
        let paneCell = PaneCellProbe(frame: titleProbe.bounds.insetBy(dx: 3, dy: 3))
        titleProbe.addSubview(paneCell)
        var resizeEventNumber = 10
        func dragTitleHost(from point: NSPoint, by delta: NSSize) -> NSRect? {
            resizeEventNumber += 1
            guard let screen = NSScreen.screens.first,
                  let down = NSEvent.mouseEvent(
                      with: .leftMouseDown, location: point, modifierFlags: [],
                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: titleHost.windowNumber,
                      context: nil, eventNumber: resizeEventNumber, clickCount: 1, pressure: 1)
            else { return nil }
            let start = titleHost.convertPoint(toScreen: point)
            var queued: [NSEvent] = []
            for type in [CGEventType.leftMouseDragged, .leftMouseUp] {
                let location = CGPoint(x: start.x + delta.width, y: screen.frame.maxY - (start.y + delta.height))
                if let cgEvent = CGEvent(
                    mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: location, mouseButton: .left),
                    let event = NSEvent(cgEvent: cgEvent)
                {
                    queued.append(event)
                }
            }
            guard queued.count == 2 else { return nil }
            for event in queued { NSApp.postEvent(event, atStart: false) }
            titleHost.sendEvent(down)
            return titleHost.frame
        }
        let resizeChecks: [(String, (NSRect) -> NSPoint, NSSize, (NSRect) -> NSRect)] = [
            (
                "top edge", { NSPoint(x: $0.midX, y: $0.maxY - 2) }, NSSize(width: 0, height: 30),
                { NSRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height + 30) }),
            (
                "top-right corner", { NSPoint(x: $0.maxX - 2, y: $0.maxY - 2) }, NSSize(width: 20, height: 20),
                { NSRect(x: $0.minX, y: $0.minY, width: $0.width + 20, height: $0.height + 20) }),
            (
                "right edge over a pane cell", { NSPoint(x: $0.maxX - 6, y: $0.midY) }, NSSize(width: 25, height: 0),
                { NSRect(x: $0.minX, y: $0.minY, width: $0.width + 25, height: $0.height) }),
            (
                "bottom-right grip", { NSPoint(x: $0.maxX - 12, y: 12) }, NSSize(width: 30, height: -20),
                { NSRect(x: $0.minX, y: $0.minY - 20, width: $0.width + 30, height: $0.height + 20) }),
        ]
        for (label, point, delta, expected) in resizeChecks {
            let before = titleHost.frame
            paneCell.frame = titleProbe.bounds.insetBy(dx: 3, dy: 3)
            let after = dragTitleHost(from: point(titleProbe.bounds), by: delta)
            if after != expected(before) || paneCell.mouseDownCount != 0 {
                failures.append(
                    "\(label) moved or was swallowed instead of resizing: \(before) -> \(String(describing: after))")
            }
        }
        let beforeCenterClick = titleHost.frame
        paneCell.frame = titleProbe.bounds.insetBy(dx: 3, dy: 3)
        if let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: titleProbe.bounds.midX, y: titleProbe.bounds.midY),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: titleHost.windowNumber, context: nil, eventNumber: 30, clickCount: 1, pressure: 1) {
            titleHost.sendEvent(event)
            if paneCell.mouseDownCount != 1 || titleHost.frame != beforeCenterClick {
                failures.append(
                    "a click inside a pane was taken by workspace resizing: clicks=\(paneCell.mouseDownCount) \(beforeCenterClick) -> \(titleHost.frame)")
            }
        }
        titleHost.close()
        let otherHost = WorkspaceWindow(
            contentRect: NSRect(x: 1400, y: 120, width: 900, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        otherHost.isReleasedWhenClosed = false
        let otherChrome = WorkspaceChromeView(frame: .zero)
        otherHost.contentView = otherChrome
        for index in 0 ..< 3 {
            let tab = otherChrome.appendTab(title: "Destination \(index)", selected: index == 0)
            tab.select.tag = index
        }
        otherChrome.setGrid(WorkspaceGridSize(columns: 2, rows: 1), activeCell: 0)
        otherChrome.layoutSubtreeIfNeeded()
        let source =
            (chrome.tabs.arrangedSubviews.first as! WorkspaceTabGroup).arrangedSubviews.first as! WorkspaceTabButton
        let transferToken = "cross-workspace"
        board.setString(transferToken, forType: workspaceTabDragType)
        chrome.beginTabDrag(source: source, token: transferToken)
        otherChrome.acceptsExternalTab = { token, button in token == transferToken && button === source }
        let destinationGroup = otherChrome.tabs.arrangedSubviews[1] as! WorkspaceTabGroup
        let destinationButton = destinationGroup.arrangedSubviews.first as! WorkspaceTabButton
        var received: (String, Int?, Int?)?
        otherChrome.onExternalTabDrop = { token, button, index, cell in
            guard button === source else { return false }
            received = (token, index, cell)
            return true
        }
        let tabPoint = destinationButton.convert(NSPoint(x: 1, y: destinationButton.bounds.midY), to: nil)
        let tabInfo = TabLayoutDragInfo(board: board, source: source, window: otherHost, location: tabPoint)
        let entered = destinationButton.draggingEntered(tabInfo)
        let tabMarkerFrame = otherChrome.windowDropPanel?.frame
        let previousKey = NSApp.keyWindow
        if let marker = otherChrome.windowDropPanel {
            if marker.frame != tabMarkerFrame || marker.frame.width != 3 || marker.frame.height != 28
                || !marker.isVisible || !marker.ignoresMouseEvents || marker.isKeyWindow
                || NSApp.keyWindow !== previousKey
                || marker.contentView?.subviews.contains(where: { $0 is NSTextField }) == true
            {
                failures.append("tab transfers did not retain their thin, nonactivating insertion line")
            }
            let expectedX = otherHost.convertPoint(toScreen: destinationGroup.convert(.zero, to: nil)).x
            if abs(marker.frame.minX - expectedX) > 1
                || otherChrome.tabInsertionIndex(at: otherHost.convertPoint(toScreen: tabPoint)) != 1
            {
                failures.append("the insertion line did not match its actual tab insertion position")
            }
        } else {
            failures.append("the tab insertion line was not created")
        }
        otherChrome.showWindowDropTarget(
            at: otherHost.convertPoint(toScreen: tabPoint), requiresPermission: false,
            application: .current, title: "Dragged window")
        if let preview = otherChrome.windowDropPreview {
            if otherChrome.tabs.arrangedSubviews.firstIndex(of: preview) != 1
                || preview.alphaValue >= 1 || otherChrome.windowDropPanel?.isVisible != true
                || otherChrome.windowDropPanel?.ignoresMouseEvents != true
                || (otherChrome.windowDropPanel?.frame.width ?? 0) <= preview.frame.width
                || (otherChrome.windowDropPanel?.level ?? .normal) <= .normal
                || (preview as? NSStackView)?.arrangedSubviews.compactMap({ $0 as? NSButton })
                .first?.title != "Dragged window"
                || NSApp.keyWindow !== previousKey
            {
                failures.append("ordinary window addition did not show the tab bar and insertion preview in front")
            }
            otherChrome.layoutSubtreeIfNeeded()
            let previewPoint = otherHost.convertPoint(
                toScreen: preview.convert(NSPoint(x: preview.bounds.midX, y: preview.bounds.midY), to: nil))
            if otherChrome.tabInsertionIndex(at: previewPoint) != 1 {
                failures.append("the preview did not preserve the insertion index under the pointer")
            }
            let last = otherChrome.tabs.arrangedSubviews.last!
            let endPoint = otherHost.convertPoint(
                toScreen: last.convert(NSPoint(x: last.bounds.maxX - 1, y: last.bounds.midY), to: nil))
            otherChrome.showWindowDropTarget(at: endPoint, requiresPermission: false)
            if otherChrome.tabs.arrangedSubviews.last !== preview
                || otherChrome.tabInsertionIndex(at: endPoint) != 3
            {
                failures.append("the translucent preview did not follow the insertion position")
            }
        } else {
            failures.append("the ordinary window-addition preview was not created")
        }
        _ = destinationButton.draggingUpdated(tabInfo)
        if otherChrome.windowDropPanel?.frame != tabMarkerFrame
            || otherChrome.windowDropPanel?.contentView?.subviews.contains(where: { !$0.isHidden && $0 is NSTextField })
            == true || otherChrome.windowDropPreview != nil
        {
            failures.append("switching from window addition to tab transfer retained a wide bar or visible label")
        }
        if entered != .move || chrome.tabDragPreviewPanel?.isVisible != true
            || !destinationButton.performDragOperation(tabInfo) || received?.1 != 1 || received?.2 != nil
        {
            failures.append("another workspace rejected the tab, lost its preview, or chose the wrong insertion index")
        }
        received = nil
        let cell = otherChrome.gridAreas[0]
        let cellPoint = cell.convert(NSPoint(x: 100, y: 100), to: nil)
        let cellInfo = TabLayoutDragInfo(board: board, source: source, window: otherHost, location: cellPoint)
        func highlightedPanes() -> [Int] {
            otherChrome.gridAreas.indices.filter { index in
                otherChrome.gridAreas[index].subviews.contains { $0 is WorkspaceTabDropOverlay && !$0.isHidden }
            }
        }
        _ = otherChrome.draggingUpdated(cellInfo)
        if highlightedPanes() != [0] {
            failures.append("a cross-workspace pane hover did not highlight just the receiving pane")
        }
        _ = destinationButton.draggingUpdated(tabInfo)
        if !highlightedPanes().isEmpty || otherChrome.windowDropPanel?.isVisible != true {
            failures.append(
                "returning to the destination tab strip did not replace the pane highlight with the insertion line")
        }
        if !otherChrome.performDragOperation(cellInfo) || received?.2 != 0 || received?.1 != nil {
            failures.append("cross-workspace pane drop did not select the destination pane")
        }
        otherChrome.hideExternalTabTargets()
        otherChrome.setGrid(.single, activeCell: 0)
        otherChrome.layoutSubtreeIfNeeded()
        received = nil
        let singlePane = otherChrome.gridAreas[0]
        let singlePanePoint = singlePane.convert(NSPoint(x: singlePane.bounds.midX, y: singlePane.bounds.midY), to: nil)
        let singlePaneInfo = TabLayoutDragInfo(
            board: board, source: source, window: otherHost, location: singlePanePoint)
        let expectedIndex = otherChrome.tabInsertionIndex(at: otherHost.convertPoint(toScreen: singlePanePoint))
        if singlePane.subviews.contains(where: { $0 is WorkspaceTabDropOverlay })
            || otherChrome.draggingUpdated(singlePaneInfo) != .move || otherChrome.windowDropPanel?.isVisible != true
            || otherChrome.windowDropPanel?.frame.width != 3 || !otherChrome.performDragOperation(singlePaneInfo)
            || received?.1 != expectedIndex || received?.2 != nil
        {
            failures.append("a single-pane workspace did not treat its pane as the tab bar for cross-workspace drops")
        }
        board.setString("stale-token", forType: workspaceTabDragType)
        if destinationButton.draggingEntered(tabInfo) != [] || destinationButton.performDragOperation(tabInfo) {
            failures.append("another workspace accepted a stale tab drag")
        }
        otherChrome.clearTabs()
        otherChrome.layoutSubtreeIfNeeded()
        board.setString(transferToken, forType: workspaceTabDragType)
        received = nil
        let emptyInfo = TabLayoutDragInfo(
            board: board, source: source, window: otherHost,
            location: NSPoint(x: 150, y: otherChrome.bounds.maxY - 16))
        if otherChrome.draggingEntered(emptyInfo) != .move || !otherChrome.performDragOperation(emptyInfo)
            || received?.1 != 0 || received?.2 != nil
        {
            failures.append("an empty workspace could not receive its first tab")
        }
        otherChrome.hideExternalTabTargets()
        if cell.subviews.contains(where: { $0 is WorkspaceTabDropOverlay })
            || otherChrome.windowDropPanel?.isVisible == true
        {
            failures.append("cross-workspace target cleanup left pane overlays behind")
        }
        chrome.endTabDrag()
        var ended: (String, Bool)?
        chrome.onTabDragEnd = { token, _, _, cancelled in ended = (token, cancelled) }
        source.onDragBegin?(source, transferToken, NSPoint(x: 10, y: 10), NSImage(size: NSSize(width: 100, height: 32)))
        chrome.endTabDrag()
        source.onDragEnd?(board, NSPoint(x: 1800, y: 100), true)
        if ended?.0 != transferToken || ended?.1 != true {
            failures.append("ending a cancelled or already-cleaned drag lost its transfer token")
        }
        otherHost.close()
        var mouseCompletions: [(NSPoint, Bool)] = []
        chrome.onTabDragEnd = { token, board, point, cancelled in
            if board.string(forType: workspaceTabDragType) != token {
                failures.append("mouse tracking lost its transfer token before completion")
            }
            mouseCompletions.append((point, cancelled))
            if !cancelled, host.frame.contains(point), chrome.tabRowContains(point) || chrome.gridAreas.count > 1 {
                _ = chrome.completeTabDrop(pasteboard: board, source: source, screenPoint: point)
            }
        }
        func replayTabDrag(to destination: NSPoint, escape: Bool, completes: Bool = true) {
            guard let screen = NSScreen.screens.first else {
                failures.append("could not find a screen for mouse tracking")
                return
            }
            let press = source.convert(NSPoint(x: 15, y: source.bounds.midY), to: nil)
            let start = host.convertPoint(toScreen: press)
            var events: [NSEvent] = []
            for (point, type) in [
                (NSPoint(x: start.x + 6, y: start.y), CGEventType.leftMouseDragged),
                (destination, CGEventType.leftMouseDragged),
            ] {
                if let cg = CGEvent(
                    mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: CGPoint(x: point.x, y: screen.frame.maxY - point.y), mouseButton: .left),
                    let event = NSEvent(
                        cgEvent: cg) {
                    events.append(event)
                }
            }
            let completion: NSEvent?
            if escape {
                completion = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53)
            } else {
                completion = CGEvent(
                    mouseEventSource: nil, mouseType: .leftMouseUp,
                    mouseCursorPosition: CGPoint(x: destination.x, y: screen.frame.maxY - destination.y),
                    mouseButton: .left).flatMap { NSEvent(cgEvent: $0) }
            }
            guard events.count == 2, let completion,
                  let down = NSEvent.mouseEvent(
                      with: .leftMouseDown, location: press, modifierFlags: [],
                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber,
                      context: nil, eventNumber: 3, clickCount: 1, pressure: 1)
            else {
                failures.append("could not create tab mouse tracking events")
                return
            }
            if completes { events.append(completion) }
            for event in events { NSApp.postEvent(event, atStart: false) }
            source.mouseDown(with: down)
        }
        let outside = NSPoint(x: host.frame.maxX + 300, y: host.frame.midY)
        let originalViews = chrome.tabs.arrangedSubviews.map { ObjectIdentifier($0) }
        replayTabDrag(to: outside, escape: false)
        if mouseCompletions.count != 1 || mouseCompletions.first?.0 != outside || mouseCompletions.first?.1 != false
            || chrome.tabs.arrangedSubviews.map({ ObjectIdentifier($0) }) != originalViews
            || chrome.tabDragPreviewPanel?.isVisible == true
        {
            failures.append("releasing a tab outside was lost or classified as cancellation")
        }
        replayTabDrag(to: outside, escape: true)
        if mouseCompletions.count != 2 || mouseCompletions.last?.1 != true
            || chrome.tabDragPreviewPanel?.isVisible == true
        {
            failures.append("Escape did not cancel tab tracking and remove its preview")
        }
        for (index, group) in chrome.tabs.arrangedSubviews.enumerated() {
            (group as! WorkspaceTabGroup).arrangedSubviews.compactMap { $0 as? WorkspaceTabButton }.first?.tag = index
        }
        var committedOrder: [Int]?
        chrome.onReorderTabs = { committedOrder = $0 }
        let neighbor = chrome.tabs.arrangedSubviews[1]
        let neighborPoint = host.convertPoint(
            toScreen: neighbor.convert(
                NSPoint(x: neighbor.bounds.maxX - 5, y: neighbor.bounds.midY), to: nil))
        replayTabDrag(to: neighborPoint, escape: false)
        if committedOrder != [1, 0] {
            failures.append("application-controlled mouse tracking no longer committed local tab reordering")
        }
        var movedCell: Int?
        chrome.onMoveTab = { _, cell in movedCell = cell }
        chrome.setGrid(WorkspaceGridSize(columns: 2, rows: 1), activeCell: 0)
        settle()
        let ownPane = chrome.gridAreas[0]
        replayTabDrag(
            to: host.convertPoint(
                toScreen: ownPane.convert(
                    NSPoint(x: ownPane.bounds.midX, y: ownPane.bounds.midY), to: nil)), escape: false)
        if movedCell != 0 {
            failures.append("application-controlled mouse tracking no longer committed local pane moves")
        }
        chrome.setGrid(.single, activeCell: 0)
        settle()
        for (index, group) in chrome.tabs.arrangedSubviews.enumerated() {
            (group as! WorkspaceTabGroup).arrangedSubviews.compactMap { $0 as? WorkspaceTabButton }.first?.tag = index
        }
        movedCell = nil
        committedOrder = nil
        let tabViews = chrome.tabs.arrangedSubviews
        let sourceGroup = source.superview!
        let sourceIndex = tabViews.firstIndex(of: sourceGroup)!
        let neighborIndex = sourceIndex + 1 < tabViews.count ? sourceIndex + 1 : sourceIndex - 1
        let neighborFrame = chrome.tabs.convert(tabViews[neighborIndex].frame, to: nil)
        let floatingCenter = neighborIndex > sourceIndex ? neighborFrame.maxX - 2 : neighborFrame.minX + 2
        let pressOffset = source.convert(NSPoint(x: 15, y: 0), to: sourceGroup).x
        let destinationX = floatingCenter - sourceGroup.frame.width / 2 + pressOffset
        let onlyPane = chrome.gridAreas[0]
        let onlyPaneY = onlyPane.convert(NSPoint(x: 0, y: onlyPane.bounds.midY), to: nil).y
        replayTabDrag(to: host.convertPoint(toScreen: NSPoint(x: destinationX, y: onlyPaneY)), escape: false)
        if movedCell != nil || committedOrder != nil {
            failures.append(
                "releasing a tab over the only pane unexpectedly reordered or moved it: moved=\(String(describing: movedCell)) order=\(String(describing: committedOrder))")
        }
        // Another app activated during the drag may receive its mouse-up; tracking must end once the button is up.
        let completionsBeforeLostRelease = mouseCompletions.count
        var trackingHung = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard mouseCompletions.count == completionsBeforeLostRelease, let screen = NSScreen.screens.first else {
                return
            }
            trackingHung = true
            let point = CGPoint(x: outside.x, y: screen.frame.maxY - outside.y)
            if let up = CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
                .flatMap({ NSEvent(cgEvent: $0) }) {
                NSApp.postEvent(up, atStart: false)
            }
        }
        replayTabDrag(to: outside, escape: false, completes: false)
        if trackingHung || mouseCompletions.count != completionsBeforeLostRelease + 1
            || mouseCompletions.last?.1 != false || chrome.tabDragPreviewPanel?.isVisible == true
        {
            failures.append("a tab drag whose mouse-up went to another app kept tracking after the button was released")
        }
        host.close()
        let autoHideController = WorkspaceController(name: "Auto-hide smoke")
        autoHideController.window.orderFrontRegardless()
        autoHideController.setAutoHideTabs(true)
        let revealPoint = NSPoint(
            x: autoHideController.autoHideHoverFrame.midX,
            y: autoHideController.autoHideHoverFrame.midY)
        let outsidePoint = NSPoint(
            x: autoHideController.window.frame.maxX + 80,
            y: autoHideController.window.frame.maxY - 2)
        let hoverStart = ProcessInfo.processInfo.systemUptime
        autoHideController.updateAutoHiddenTabBar(at: revealPoint, now: hoverStart)
        if autoHideController.isAutoHiddenToolbarVisible {
            failures.append("auto-hidden toolbar appeared without the hover delay")
        }
        autoHideController.updateAutoHiddenTabBar(at: revealPoint, now: hoverStart + 0.1)
        if !autoHideController.isAutoHiddenToolbarVisible {
            failures.append("hovering at the top edge did not reveal the auto-hidden toolbar within 0.1 s")
        }
        autoHideController.updateAutoHiddenTabBar(at: outsidePoint, now: hoverStart + 0.4)
        autoHideController.updateAutoHiddenTabBar(at: outsidePoint, now: hoverStart + 1.3)
        if autoHideController.isAutoHiddenToolbarVisible {
            failures.append("auto-hidden toolbar remained visible after leaving it")
        }
        if let autoHideChrome = autoHideController.window.contentView as? WorkspaceChromeView {
            let probe = MenuTrackingProbe()
            func checkMenuKeepsToolbar(_ label: String, fallback: NSMenu?, open: () -> Void) {
                let start = ProcessInfo.processInfo.systemUptime
                autoHideController.updateAutoHiddenTabBar(at: revealPoint, now: start)
                autoHideController.updateAutoHiddenTabBar(at: revealPoint, now: start + 0.1)
                guard autoHideController.isAutoHiddenToolbarVisible else {
                    failures.append("\(label): could not reveal the auto-hidden toolbar")
                    return
                }
                var visibleWhileOpen = false
                // Input from the person at the Mac can close a menu before the check runs; try once more.
                let tracked = (0 ..< 2).contains { _ in
                    probe.run(fallback: fallback, open: open) { menu in
                        // AppKit reports a submenu opening and closing while the pointer passes over its item.
                        for submenu in menu.items.compactMap(\.submenu) {
                            submenu.delegate?.menuWillOpen?(submenu)
                            submenu.delegate?.menuDidClose?(submenu)
                        }
                        let now = ProcessInfo.processInfo.systemUptime
                        autoHideController.updateAutoHiddenTabBar(at: outsidePoint, now: now + 0.4)
                        autoHideController.updateAutoHiddenTabBar(at: outsidePoint, now: now + 1.3)
                        visibleWhileOpen = autoHideController.isAutoHiddenToolbarVisible
                    }
                }
                if !tracked {
                    failures.append("\(label): the menu did not open")
                } else if !visibleWhileOpen {
                    failures.append("\(label): the auto-hidden toolbar hid while its menu was still open")
                }
                let closed = ProcessInfo.processInfo.systemUptime
                autoHideController.updateAutoHiddenTabBar(at: outsidePoint, now: closed + 0.4)
                autoHideController.updateAutoHiddenTabBar(at: outsidePoint, now: closed + 1.3)
                if autoHideController.isAutoHiddenToolbarVisible {
                    failures.append("\(label): the auto-hidden toolbar stayed after its menu closed")
                    autoHideChrome.hideAutoHiddenToolbar()
                }
            }
            let workspaceMenu = autoHideChrome.workspaceMenu?()
            checkMenuKeepsToolbar("workspace menu with a pane submenu", fallback: workspaceMenu) {
                workspaceMenu?.popUp(
                    positioning: nil, at: NSPoint(x: 0, y: autoHideChrome.workspaceButton.bounds.height),
                    in: autoHideChrome.workspaceButton)
            }
            checkMenuKeepsToolbar("column selector", fallback: autoHideChrome.columnSelector.menu) {
                autoHideChrome.columnSelector.performClick(nil)
            }
        } else {
            failures.append("auto-hide smoke workspace has no tab bar")
        }
        if let screen = autoHideController.window.screen {
            let frontController = WorkspaceController(name: "Menu bar front smoke")
            defer {
                frontController.quitting = true
                frontController.window.orderOut(nil)
            }
            frontController.window.orderFrontRegardless()
            let activation = WorkspaceActivation(controllers: { [frontController, autoHideController] })
            let menuBarPoint = NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 1)
            activation.orderedWindows = { [frontController.window, autoHideController.window] }
            if activation.menuBarRevealTarget(at: menuBarPoint, screens: [screen]) != nil {
                failures.append("the menu bar revealed a workspace behind the front workspace on its display")
            }
            activation.orderedWindows = { [autoHideController.window, frontController.window] }
            if activation.menuBarRevealTarget(at: menuBarPoint, screens: [screen]) !== autoHideController {
                failures.append("the menu bar did not target the front auto-hidden workspace on its display")
            }
            let belowMenuBar = NSPoint(x: screen.frame.midX, y: screen.visibleFrame.maxY - 20)
            if activation.menuBarRevealTarget(at: belowMenuBar, screens: [screen]) != nil {
                failures.append("a point below the menu bar targeted a workspace")
            }
            let menuStart = ProcessInfo.processInfo.systemUptime
            autoHideController.updateAutoHiddenTabBar(at: menuBarPoint, now: menuStart)
            autoHideController.updateAutoHiddenTabBar(at: menuBarPoint, now: menuStart + 0.1)
            if autoHideController.isAutoHiddenToolbarVisible {
                failures.append("the menu bar revealed the auto-hidden toolbar while the option was off")
            }
            autoHideController.updateAutoHiddenTabBar(at: menuBarPoint, hoveringMenuBar: true, now: menuStart + 0.2)
            autoHideController.updateAutoHiddenTabBar(at: menuBarPoint, hoveringMenuBar: true, now: menuStart + 0.3)
            if !autoHideController.isAutoHiddenToolbarVisible {
                failures.append("hovering the menu bar did not reveal the auto-hidden toolbar")
            }
            autoHideController.updateAutoHiddenTabBar(at: belowMenuBar, now: menuStart + 0.5)
            autoHideController.updateAutoHiddenTabBar(at: belowMenuBar, now: menuStart + 1.4)
            if autoHideController.isAutoHiddenToolbarVisible {
                failures.append("the toolbar revealed from the menu bar stayed visible after the pointer left")
            }
            autoHideController.setAutoHideTabs(false)
            if activation.menuBarRevealTarget(at: menuBarPoint, screens: [screen]) != nil {
                failures.append("the menu bar targeted a workspace whose tab bar is not hidden")
            }
        } else {
            failures.append("auto-hide smoke workspace has no screen")
        }
        autoHideController.window.orderOut(nil)
        failures += positionChecks()
        if failures.isEmpty {
            print(
                "PASS: tab layout, icon-only tabs, cross-workspace drops, actual tab mouse release/Escape, and movement masks")
            exit(0)
        }
        failures.forEach { fputs("FAIL: \($0)\n", stderr) }
        exit(1)
    }

    @MainActor
    private static func positionChecks() -> [String] {
        var failures: [String] = []
        let host = WorkspaceWindow(
            contentRect: NSRect(x: 100, y: 100, width: 720, height: 480),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let chrome = WorkspaceChromeView(frame: .zero)
        host.contentView = chrome
        chrome.workspaceButton.title = "Workspace"
        for index in 0 ..< 20 {
            let tab = chrome.appendTab(title: "Window \(index)", selected: index == 0)
            tab.select.tag = index
        }
        host.orderFrontRegardless()
        defer { host.close() }
        func settle() {
            for _ in 0 ..< 4 {
                chrome.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }
        for position in TabBarPosition.allCases {
            chrome.setTabBarPosition(position)
            settle()
            let stage = chrome.stage.frame
            switch position {
            case .top:
                if stage.maxY > chrome.bounds.maxY - 33 { failures.append("top tab bar did not reserve space") }
            case .bottom:
                if stage.minY < chrome.bounds.minY + 36 { failures.append("bottom tab bar did not reserve space") }
            case .left:
                if stage.minX < chrome.bounds.minX + 190 { failures.append("left tab bar did not reserve space") }
            case .right:
                if stage.maxX > chrome.bounds.maxX - 190 { failures.append("right tab bar did not reserve space") }
            }
            if position.isVertical {
                if chrome.tabs.orientation != .vertical || chrome.tabs.visibleRect.width < 175
                    || chrome.tabs.visibleRect.height < 50 || chrome.tabs.bounds.height <= chrome.tabs.visibleRect
                    .height
                {
                    failures.append("\(position): vertical tabs did not have a scrollable viewport")
                }
            } else if chrome.tabs.orientation != .horizontal || chrome.tabs.visibleRect.height < 28 {
                failures.append("\(position): horizontal tabs did not have a usable viewport")
            }
            for control in [chrome.addButton, chrome.columnSelector, chrome.rowSelector, chrome.permissionButton] {
                let frame = chrome.convert(control.bounds, from: control)
                if frame.isEmpty || !chrome.bounds.contains(frame) {
                    failures.append("\(position): toolbar control was clipped")
                }
            }
            guard let last = chrome.tabs.arrangedSubviews.last else {
                failures.append("\(position): tabs disappeared")
                continue
            }
            chrome.revealTab(last)
            settle()
            if !chrome.tabs.visibleRect.contains(last.frame) {
                failures.append("\(position): last tab could not be revealed")
            }
            let point = position.isVertical
                ? NSPoint(x: last.bounds.midX, y: last.bounds.maxY - 1)
                : NSPoint(x: last.bounds.minX + 1, y: last.bounds.midY)
            let screenPoint = host.convertPoint(toScreen: last.convert(point, to: nil))
            if chrome.tabInsertionIndex(at: screenPoint) != 19 {
                failures.append("\(position): insertion index did not follow tab order")
            }
            chrome.showWindowDropTarget(at: screenPoint, requiresPermission: false)
            if chrome.windowDropPreview == nil || chrome.windowDropPanel?.isVisible != true
                || chrome.tabInsertionIndex(at: screenPoint) != 19
            {
                failures.append("\(position): window drop preview was missing or misplaced")
            }
            chrome.hideWindowDropTarget()
            if position.isVertical {
                let sourceGroup = chrome.tabs.arrangedSubviews[18] as! WorkspaceTabGroup
                let source = sourceGroup.arrangedSubviews.first as! WorkspaceTabButton
                let originalOrder = chrome.tabs.arrangedSubviews.compactMap {
                    ($0 as? WorkspaceTabGroup)?.arrangedSubviews.first as? WorkspaceTabButton
                }.map(\.tag)
                var committed: [Int]?
                chrome.onReorderTabs = { committed = $0 }
                let board = NSPasteboard.withUniqueName()
                board.setString("vertical-reorder", forType: workspaceTabDragType)
                chrome.beginTabDrag(source: source, token: "vertical-reorder")
                let destination = host.convertPoint(
                    toScreen: last.convert(NSPoint(x: last.bounds.midX, y: last.bounds.minY + 1), to: nil))
                _ = chrome.updateFloatingTab(pasteboard: board, source: source, screenPoint: destination)
                let dropped = chrome.performTabReorder(
                    pasteboard: board, source: source, screenPoint: destination)
                var expected = originalOrder
                expected.append(expected.remove(at: 18))
                if !dropped || committed != expected {
                    failures.append("\(position): vertical tab reorder did not follow the pointer")
                }
                board.releaseGlobally()

                let incoming = NSButton(title: "Incoming", target: nil, action: nil)
                let incomingBoard = NSPasteboard.withUniqueName()
                incomingBoard.setString("incoming", forType: workspaceTabDragType)
                chrome.acceptsExternalTab = { token, button in token == "incoming" && button === incoming }
                var receivedIndex: Int?
                chrome.onExternalTabDrop = { _, _, index, _ in
                    receivedIndex = index
                    return true
                }
                let target = chrome.tabs.arrangedSubviews[18]
                chrome.revealTab(target)
                settle()
                let incomingPoint = host.convertPoint(
                    toScreen: target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.maxY - 1), to: nil))
                let expectedIndex = chrome.tabInsertionIndex(at: incomingPoint)
                _ = chrome.updateFloatingTab(pasteboard: incomingBoard, source: incoming, screenPoint: incomingPoint)
                if chrome.windowDropPanel?.frame.height != 3 || (chrome.windowDropPanel?.frame.width ?? 0) < 40
                    || !chrome.completeTabDrop(
                        pasteboard: incomingBoard, source: incoming, screenPoint: incomingPoint)
                    || receivedIndex != expectedIndex
                {
                    failures.append("\(position): incoming tab marker or insertion index was incorrect")
                }
                incomingBoard.releaseGlobally()
                chrome.acceptsExternalTab = nil
                chrome.onExternalTabDrop = nil
            }
            chrome.setAutoHideTabBar(true)
            chrome.setAutoHiddenToolbarVisible(true)
            settle()
            let expanded = chrome.stage.frame
            if position.isVertical ? expanded.width < stage.width + 180 : expanded.height < stage.height + 24 {
                failures.append("\(position): auto-hide did not reclaim the tab bar area")
            }
            let handle = chrome.toolbarHoverFrame
            let stageOnScreen = host.convertToScreen(chrome.stage.convert(chrome.stage.bounds, to: nil))
            if !chrome.isAutoHideHandleVisible || min(handle.width, handle.height) < 5
                || stageOnScreen.intersects(handle)
            {
                failures
                    .append("\(position): auto-hidden tab bar left no visible edge handle outside the panes: \(handle)")
            }
            if chrome.autoHiddenToolbarPanel?.isVisible != true
                || !host.frame.contains(chrome.toolbarHoverFrame)
            {
                failures.append("\(position): auto-hidden toolbar or edge hover area was missing")
            }
            if let panel = chrome.autoHiddenToolbarPanel {
                chrome.showWindowDropTarget(
                    at: NSPoint(x: panel.frame.midX, y: panel.frame.midY), requiresPermission: false)
                if chrome.windowDropPreview == nil || chrome.windowDropPanel?.frame != panel.frame {
                    failures.append("\(position): auto-hidden window drop preview was not shown on its bar")
                }
                chrome.hideWindowDropTarget()
            }
            chrome.setAutoHideTabBar(false)
            settle()
            if chrome.isAutoHideHandleVisible {
                failures.append("\(position): the auto-hide edge handle stayed after showing the tab bar again")
            }
        }
        do {
            let old = try JSONDecoder().decode(SavedWorkspace.self, from: Data(#"{"name":"old","windows":[]}"#.utf8))
            if old.tabBarPosition != nil { failures.append("old layouts did not preserve the default tab position") }
            let saved = SavedWorkspace(name: "Saved", windows: [], tabBarPosition: .right)
            let restored = try JSONDecoder().decode(SavedWorkspace.self, from: JSONEncoder().encode(saved))
            let controller = WorkspaceController(name: "Position")
            controller.restoreLayout(restored)
            if controller.tabBarPosition != .right {
                failures.append("tab bar position did not survive restoring a saved workspace")
            }
            let menu = controller.tabBarPositionMenu()
            menu.update()
            if menu.items.count != 4 || menu.items[3].state != .on {
                failures.append("tab bar position menu did not reflect the restored position")
            } else if let action = menu.items[1].action {
                _ = NSApp.sendAction(action, to: menu.items[1].target, from: menu.items[1])
                if controller.tabBarPosition != .bottom {
                    failures.append("tab bar position menu did not change the workspace")
                }
            } else {
                failures.append("tab bar position menu did not offer an action")
            }
            controller.quitting = true
            controller.window.orderOut(nil)
        } catch {
            failures.append("tab bar position persistence failed: \(error)")
        }
        chrome.clearTabs()
        let sortableIDs = (0 ..< 3).map { _ in UUID() }
        for id in sortableIDs {
            chrome.appendTab(id: id, title: "Sortable", selected: false)
        }
        var reordered: [Int]?
        chrome.onReorderTabs = { reordered = $0 }
        if !chrome.reorderTab(sortableIDs[0], by: 1) || reordered != [1, 0, 2]
            || chrome.reorderTab(sortableIDs[0], by: -1)
        {
            failures.append("wheel reordering did not request one adjacent tab move or respect an edge")
        }
        return failures
    }
}
