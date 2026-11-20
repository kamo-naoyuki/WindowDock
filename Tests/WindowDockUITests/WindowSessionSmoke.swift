import AppKit
import WindowDockCore

@MainActor
enum WindowSessionSmoke {
    private enum Operation: Equatable {
        case resize(Int)
        case move(Int)
        case minimize(Int, Bool)
        case raise(Int)
    }

    private struct InjectedFailure: LocalizedError {
        var errorDescription: String? { "Injected window operation failure" }
    }

    private final class WindowState {
        let element: AXUIElement
        let originalFrame: CGRect
        let originallyMinimized: Bool
        var frame: CGRect
        var minimized: Bool
        var minimumSize = CGSize.zero

        init(index: Int) {
            // These handles only identify simulated windows; the client intercepts every operation.
            element = AXUIElementCreateApplication(pid_t(900_000 + index))
            originalFrame = CGRect(x: 40 + index * 20, y: 80, width: 500, height: 400)
            originallyMinimized = index == 2
            frame = originalFrame
            minimized = originallyMinimized
        }
    }

    private final class Model {
        let windows: [WindowState]
        var target = CGRect(x: 200, y: 160, width: 900, height: 600)
        var operations: [Operation] = []
        var onMove: (() -> Void)?
        var failedMoves: Set<Int> = []
        var failedMinimizations: Set<Int> = []
        var failedRegistrations: Set<Int> = []
        var failedFocuses: Set<Int> = []
        var focusedWindows: [Int] = []
        var changeCount = 0
        var notices: [WorkspaceNotice] = []
        var presentedFrames: [CGRect?] = []
        var paneFrames: [UUID: CGRect] = [:]
        var rightTarget = CGRect(x: 650, y: 160, width: 450, height: 600)
        var gridTargets: [Int: CGRect]?

        init(windowCount: Int = 4) {
            windows = (0..<windowCount).map(WindowState.init)
        }

        func index(of element: AXUIElement) throws -> Int {
            guard let index = windows.firstIndex(where: { CFEqual($0.element, element) }) else {
                throw InjectedFailure()
            }
            return index
        }
    }

    private static func access(for model: Model) -> WindowAccessClient {
        var access = WindowAccessClient()
        access.requireWritable = { element, _ in
            let index = try model.index(of: element)
            if model.failedRegistrations.contains(index) { throw InjectedFailure() }
        }
        access.frame = { element in model.windows[try model.index(of: element)].frame }
        access.isMinimized = { element in model.windows[try model.index(of: element)].minimized }
        access.setFrame = { element, frame in
            let index = try model.index(of: element)
            model.operations.append(.resize(index))
            model.windows[index].frame = frame
            model.windows[index].frame.size.width = max(frame.width, model.windows[index].minimumSize.width)
            model.windows[index].frame.size.height = max(frame.height, model.windows[index].minimumSize.height)
        }
        access.setPosition = { element, position in
            let index = try model.index(of: element)
            model.onMove?()
            if model.failedMoves.contains(index) { throw InjectedFailure() }
            model.operations.append(.move(index))
            model.windows[index].frame.origin = position
        }
        access.minimize = { element, minimized in
            let index = try model.index(of: element)
            if model.failedMinimizations.contains(index) { throw InjectedFailure() }
            guard model.windows[index].minimized != minimized else { return false }
            model.operations.append(.minimize(index, minimized))
            model.windows[index].minimized = minimized
            return true
        }
        access.raise = { element in model.operations.append(.raise(try model.index(of: element))) }
        access.focus = { element, _ in
            let index = try model.index(of: element)
            if model.failedFocuses.contains(index) { throw InjectedFailure() }
            model.focusedWindows.append(index)
        }
        return access
    }

    private static func fixture(registering indexes: [Int] = [0, 1, 2], windowCount: Int = 4,
                                sharedModel: Model? = nil) -> (WindowSession, Model) {
        let model = sharedModel ?? Model(windowCount: windowCount)
        let session = WindowSession(access: access(for: model))
        session.targetFrame = { model.target }
        session.secondaryTargetFrame = { model.rightTarget }
        session.targetFrames = { model.gridTargets ?? [0: model.target, 1: model.rightTarget] }
        session.onMessage = { model.notices.append($0) }
        session.onPresentedFrame = { model.presentedFrames.append($0) }
        session.onPresentedFrames = { model.paneFrames = $0 }
        session.onChange = { model.changeCount += 1 }
        for index in indexes {
            session.add(WindowCandidate(
                element: model.windows[index].element,
                application: .current,
                title: "Test \(index)"
            ))
        }
        model.operations.removeAll()
        model.changeCount = 0
        return (session, model)
    }

    static func runTransferChecks() -> [String] {
        var failures: [String] = []
        let (source, model) = fixture()
        let (destination, _) = fixture(registering: [3], sharedModel: model)
        let transferred = source.windows[2]
        let target = CGRect(x: 1200, y: 120, width: 800, height: 600)
        destination.targetFrames = { [0: target] }
        var observedDuplicate = false
        source.onChange = {
            if source.contains(transferred.candidate) && destination.contains(transferred.candidate) {
                observedDuplicate = true
            }
        }
        if !source.transferWindow(transferred.id, to: destination, at: 0) ||
            source.contains(transferred.candidate) || destination.windows.first?.id != transferred.id ||
            destination.selectedID != transferred.id || observedDuplicate {
            failures.append("cross-workspace transfer lost identity, insertion position, selection, or unique ownership")
        }
        if model.windows[2].frame != target || model.windows[2].minimized ||
            destination.windows.first?.originalFrame != transferred.originalFrame ||
            destination.windows.first?.originallyMinimized != transferred.originallyMinimized {
            failures.append("transfer did not align the window or preserve its original restoration state")
        }
        let originalSourceIDs = source.windows.map(\.id)
        let originalDestinationIDs = destination.windows.map(\.id)
        if source.transferWindow(source.windows[0].id, to: destination, at: -1) ||
            source.windows.map(\.id) != originalSourceIDs || destination.windows.map(\.id) != originalDestinationIDs {
            failures.append("invalid transfer modified window ownership")
        }
        if !destination.remove(transferred.id) || model.windows[2].frame != transferred.originalFrame ||
            model.windows[2].minimized != transferred.originallyMinimized {
            failures.append("releasing a transferred tab did not restore its pre-registration state")
        }
        source.setSplit(true)
        destination.setSplit(true)
        destination.targetFrames = { [0: target, 1: target.offsetBy(dx: 800, dy: 0)] }
        let splitID = source.windows[0].id
        if !source.transferWindow(splitID, to: destination, cell: 1) ||
            source.cells.contains(splitID) || destination.cells[1] != splitID ||
            destination.activeCell != 1 || source.windows.count != 1 {
            failures.append("pane transfer failed to reconcile the source or select the destination pane")
        }
        let (empty, _) = fixture(registering: [], sharedModel: model)
        let lastID = source.windows[0].id
        if !source.transferWindow(lastID, to: empty) || !source.windows.isEmpty ||
            source.cells != [nil] || empty.selectedID != lastID {
            failures.append("detaching the last tab did not leave an empty source and a selected destination")
        }
        return failures
    }

    static func runRegisteredWindowDragChecks() -> [String] {
        var failures: [String] = []
        let (source, model) = fixture(registering: [0])
        let (other, _) = fixture(registering: [1], sharedModel: model)
        let registered = source.windows.map(\.candidate) + other.windows.map(\.candidate)
        let candidate = source.windows[0].candidate
        let pid = candidate.application.processIdentifier
        var registration = WorkspaceWindowDragRegistration()
        var resolutions = 0
        let resolve: (WindowServerWindow) throws -> WindowCandidate = { _ in
            resolutions += 1
            return candidate
        }
        do {
            for offset in [CGFloat(0), 100, 200] {
                let moved = WindowServerWindow(id: 80, processID: pid, frame: model.target.offsetBy(dx: offset, dy: 0))
                if try !registration.isRegistered(moved, among: registered, resolve: resolve) {
                    failures.append("a registered window was offered for ordinary dragging into a workspace")
                }
            }
            if resolutions != 1 {
                failures.append("registered-window drag identification repeated AX resolution while moving")
            }
            let sibling = WindowCandidate(element: model.windows[2].element, application: .current, title: "Unregistered sibling")
            let siblingWindow = WindowServerWindow(id: 81, processID: pid, frame: model.target)
            let resolveSibling: (WindowServerWindow) throws -> WindowCandidate = { _ in sibling }
            if try registration.isRegistered(siblingWindow, among: registered, resolve: resolveSibling) {
                failures.append("registration filtering suppressed an unregistered window from the same app")
            }
            if try !registration.isRegistered(siblingWindow, among: registered + [sibling], resolve: resolveSibling) {
                failures.append("cached drag identity did not notice newly registered ownership")
            }
            let unrelated = WindowServerWindow(id: 82, processID: pid + 1, frame: model.target)
            if try registration.isRegistered(unrelated, among: registered, resolve: { _ in throw InjectedFailure() }) {
                failures.append("an app with no registered windows was suppressed")
            }
            registration.reset()
            if try !registration.isRegistered(
                WindowServerWindow(id: 80, processID: pid, frame: model.target), among: registered, resolve: resolve
            ) || resolutions != 2 {
                failures.append("resetting the drag did not discard its cached window identity")
            }
            if try !registration.isRegistered(
                WindowServerWindow(id: 84, processID: pid, frame: model.target), among: registered,
                resolve: { _ in other.windows[0].candidate }
            ) {
                failures.append("a window registered in another workspace was not suppressed")
            }
            do {
                _ = try registration.isRegistered(
                    WindowServerWindow(id: 83, processID: pid, frame: model.target), among: registered,
                    resolve: { _ in throw InjectedFailure() }
                )
                failures.append("window identification failure silently allowed a drop")
            } catch is InjectedFailure {
            }
        } catch {
            failures.append("registered-window drag identification failed: \(error.localizedDescription)")
        }
        return failures
    }

    static func runKeyboardFocusChecks() -> [String] {
        var failures: [String] = []
        let (session, model) = fixture()
        let applications = [AXUIElementCreateApplication(800_001), AXUIElementCreateApplication(800_002)]
        var steps: [String] = []
        let setAttribute: (AXUIElement, String, CFTypeRef) throws -> Void = { element, attribute, _ in
            if attribute == kAXFrontmostAttribute {
                steps.append("all-windows \(applications.firstIndex { CFEqual($0, element) } ?? -1)")
            }
        }
        do {
            for index in [0, 1, 2, 0] {
                steps = []
                try WindowAccess.focus(
                    model.windows[index].element, applicationElement: applications[index == 2 ? 1 : 0],
                    setAttribute: setAttribute,
                    raiseWindow: { steps.append("raise \(try model.index(of: $0))") },
                    activateFrontWindowOnly: { steps.append("front-only"); return true }
                )
                // Activating the whole app would bring its unregistered windows above other apps too.
                if steps != ["raise \(index)", "front-only", "raise \(index)"] {
                    failures.append("tab focus did not bring only window \(index) forward: \(steps)")
                }
            }
            steps = []
            try WindowAccess.focus(
                model.windows[2].element, applicationElement: applications[1], setAttribute: setAttribute,
                raiseWindow: { steps.append("raise \(try model.index(of: $0))") },
                activateFrontWindowOnly: { steps.append("front-only"); return false }
            )
            if steps != ["raise 2", "front-only", "all-windows 1", "raise 2"] {
                failures.append("unavailable front-window-only activation did not fall back to AXFrontmost: \(steps)")
            }
            steps = []
            do {
                try WindowAccess.focus(
                    model.windows[2].element, applicationElement: applications[1],
                    setAttribute: { _, attribute, _ in
                        if attribute == kAXFrontmostAttribute { throw InjectedFailure() }
                    },
                    raiseWindow: { steps.append("raise \(try model.index(of: $0))") },
                    activateFrontWindowOnly: { false }
                )
                failures.append("application activation failure did not propagate")
            } catch is InjectedFailure {
            }
            if steps != ["raise 2"] { failures.append("failed application activation still raised after activation") }
        } catch {
            failures.append("keyboard focus operation failed: \(error.localizedDescription)")
        }
        session.cycle(1)
        session.cycle(1)
        session.cycle(-1)
        if model.focusedWindows != [0, 1, 0] {
            failures.append("forward and reverse keyboard cycling did not focus the selected tab")
        }
        model.failedFocuses.insert(1)
        session.cycle(1)
        if model.notices.last?.needsAttention != true {
            failures.append("keyboard focus failure was not reported to the user")
        }
        return failures
    }

    static func runWindowInsertionChecks() -> [String] {
        var failures: [String] = []
        for insertion in [0, 1, 3] {
            let (session, model) = fixture()
            let originals = session.windows.map(\.id)
            let candidate = WindowCandidate(element: model.windows[3].element, application: .current, title: "Inserted")
            session.add(candidate, originalFrame: model.windows[3].originalFrame, at: insertion)
            guard let inserted = session.windows.first(where: { $0.candidate.isSameWindow(as: candidate) }) else {
                failures.append("window addition at an insertion line failed")
                continue
            }
            var expected = originals
            expected.insert(inserted.id, at: insertion)
            if session.windows.map(\.id) != expected || session.selectedID != inserted.id {
                failures.append("a new window was not inserted and selected at the indicated position")
            }
            if !session.remove(inserted.id) || model.windows[3].frame != model.windows[3].originalFrame {
                failures.append("inserting a window changed its original restoration geometry")
            }
        }
        let (session, model) = fixture()
        let originals = session.windows.map(\.id)
        session.add(WindowCandidate(element: model.windows[3].element, application: .current, title: "Invalid"), at: -1)
        if session.windows.map(\.id) != originals || model.notices.last?.needsAttention != true {
            failures.append("an invalid insertion position changed the session or failed silently")
        }
        return failures
    }

    static func runTitlebarFocusChecks() -> [String] {
        let model = Model(windowCount: 2)
        let controller = WorkspaceController(name: "Titlebar focus", access: access(for: model))
        let window = controller.window
        defer {
            controller.quitting = true
            window.orderOut(nil)
        }
        guard let chrome = window.contentView as? WorkspaceChromeView,
              let screen = NSScreen.screens.first else { return ["titlebar focus fixture could not find its content or screen"] }
        func settle(_ seconds: TimeInterval = 0.5) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            }
        }
        window.setFrame(NSRect(x: 160, y: 180, width: 900, height: 600), display: true)
        controller.session.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        controller.session.add(model.windows.map {
            WindowCandidate(element: $0.element, application: .current, title: "Focus probe")
        })
        controller.bringToFront()
        settle()
        guard NSApp.isActive, window.isKeyWindow else { return ["titlebar focus fixture did not become active and key"] }
        guard let dragSpace = chrome.subviews.compactMap({ $0 as? NSStackView })
            .flatMap(\.arrangedSubviews).first(where: { $0.toolTip == L("ドラッグして移動 / ダブルクリックで最大化") })
        else { return ["titlebar focus fixture could not find the toolbar drag area"] }
        var failures: [String] = []
        if !model.focusedWindows.isEmpty {
            failures.append("making the workspace key stole focus before any titlebar gesture")
        }
        func gesture(at point: NSPoint, delta: NSSize) -> Bool {
            guard let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            ) else { return false }
            let start = window.convertPoint(toScreen: point)
            let types: [CGEventType] = delta == .zero ? [.leftMouseUp] : [.leftMouseDragged, .leftMouseUp]
            let events = types.compactMap { type -> NSEvent? in
                guard let event = CGEvent(
                    mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: CGPoint(x: start.x + delta.width, y: screen.frame.maxY - start.y - delta.height),
                    mouseButton: .left
                ) else { return nil }
                return NSEvent(cgEvent: event)
            }
            guard events.count == types.count else { return false }
            // Queue only in this app, without moving the system pointer or clicking another app.
            for event in events { NSApp.postEvent(event, atStart: false) }
            window.sendEvent(down)
            return true
        }
        let barPoint = dragSpace.convert(NSPoint(x: dragSpace.bounds.midX, y: dragSpace.bounds.midY), to: nil)
        let gestures: [(String, NSPoint, NSSize)] = [
            ("titlebar click", barPoint, .zero),
            ("titlebar click while already key", barPoint, .zero),
            ("titlebar drag", barPoint, NSSize(width: 20, height: 10)),
            ("resize grip", NSPoint(x: chrome.bounds.maxX - 12, y: 12), NSSize(width: 20, height: -10))
        ]
        for (label, point, delta) in gestures {
            model.focusedWindows.removeAll()
            guard gesture(at: point, delta: delta) else {
                failures.append("\(label): could not create mouse events")
                continue
            }
            if !model.focusedWindows.isEmpty {
                failures.append("\(label): handed off focus before mouse tracking returned")
            }
            settle()
            if model.focusedWindows != [1] {
                failures.append("\(label): selected pane was not focused on release; another activation click is needed: \(model.focusedWindows)")
            }
        }

        // A pending handoff must not steal focus from a window opened before it runs.
        model.focusedWindows.removeAll()
        if !gesture(at: barPoint, delta: .zero) { failures.append("could not create interrupted titlebar click") }
        let other = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        other.makeKeyAndOrderFront(nil)
        settle()
        window.makeKeyAndOrderFront(nil)
        settle()
        if !model.focusedWindows.isEmpty {
            failures.append("a stale titlebar handoff stole focus after another window became key")
        }
        return failures
    }

    static func runConstraintNoticeChecks() -> [String] {
        var failures: [String] = []
        let (session, model) = fixture()
        let ids = session.windows.map(\.id)
        model.windows[0].minimumSize.width = model.target.width + 100
        model.target.size.width -= 10
        session.sync()
        if model.notices.last?.needsAttention == true {
            failures.append("hidden constrained window showed a size warning")
        }
        session.select(ids[0])
        if model.notices.last?.needsAttention != true {
            failures.append("selected constrained window did not show a size warning")
        }
        let constrainedStart = Date()
        for _ in 0..<3 {
            model.target.origin.x += 1
            session.sync()
        }
        if Date().timeIntervalSince(constrainedStart) > 0.2 {
            failures.append("a window at its known minimum size stalled every workspace sync")
        }
        model.windows[0].minimumSize = .zero
        for _ in 0..<3 {
            model.target.origin.x += 1
            session.sync()
            if model.notices.last?.needsAttention != true {
                failures.append("repeated synchronization cleared the selected tab's warning")
                break
            }
        }
        session.select(ids[2])
        if model.notices.last?.needsAttention == true {
            failures.append("switching to an unconstrained tab did not clear the warning")
        }
        session.select(ids[0])
        if model.notices.last?.needsAttention != true {
            failures.append("returning to the constrained tab did not restore its warning")
        }
        return failures
    }

    static func runManyTabMoveChecks() -> [String] {
        var failures: [String] = []
        let (session, model) = fixture(registering: Array(0..<20), windowCount: 20)
        var clearedDuringMove = false
        session.onPresentedFrames = { model.paneFrames = $0 }
        let selectedID = session.selectedID!
        model.paneFrames = [selectedID: model.target]
        model.target.origin.x += 80
        session.targetFrames = { [0: model.target] }
        model.onMove = {
            if model.paneFrames.isEmpty { clearedDuringMove = true }
        }
        session.sync()
        if clearedDuringMove || model.paneFrames[selectedID] != model.target {
            failures.append("many-tab move blanked the entire pane or did not restore the selected window")
        }
        return failures
    }

    /// Child process for `runFrontWindowOnlyActivationChecks`: an inactive app with three windows.
    static func runActivationHelper(_ application: NSApplication) {
        // Regular apps activate themselves at launch; becoming regular afterwards keeps this one in the background.
        application.setActivationPolicy(.accessory)
        DispatchQueue.main.async { application.setActivationPolicy(.regular) }
        let windows = (0..<3).map { index in
            let window = NSWindow(contentRect: NSRect(x: 300 + index * 40, y: 300 + index * 40, width: 300, height: 200),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            return window
        }
        print(([ProcessInfo.processInfo.processIdentifier] + windows.map { Int32($0.windowNumber) })
            .map(String.init).joined(separator: " "))
        fflush(stdout)
        DispatchQueue.global().async {
            while let line = readLine() {
                if line.hasPrefix("raise "), let index = Int(line.dropFirst(6)) {
                    DispatchQueue.main.async { windows[index].orderFrontRegardless() }
                } else if line.hasPrefix("yield "), let pid = pid_t(line.dropFirst(6)) {
                    // Stands in for the Dock, which lets the app whose Dock menu item was chosen activate itself.
                    DispatchQueue.main.async {
                        if #available(macOS 14, *), let target = NSRunningApplication(processIdentifier: pid) {
                            application.yieldActivation(to: target)
                        }
                    }
                } else if line.hasPrefix("activate "), let pid = pid_t(line.dropFirst(9)) {
                    // Like the Dock, activates the app with all of its windows.
                    DispatchQueue.main.async {
                        if #available(macOS 14, *), let target = NSRunningApplication(processIdentifier: pid) {
                            _ = target.activate(from: .current, options: [.activateAllWindows])
                        }
                    }
                }
            }
            exit(0)
        }
    }

    /// Uses real windows of another process and changes the active application, so it runs in its own
    /// harness process (`--activation-only`) that is not the active app when it launches the helper.
    static func runFrontWindowOnlyActivationChecks() -> [String] {
        guard let executable = Bundle.main.executableURL else { return ["activation check could not find its executable"] }
        let helper = Process()
        let output = Pipe()
        let input = Pipe()
        helper.executableURL = executable
        helper.arguments = ["--activation-helper"]
        helper.standardOutput = output
        helper.standardInput = input
        do { try helper.run() } catch { return ["activation helper failed to launch: \(error.localizedDescription)"] }
        defer {
            helper.terminate()
            helper.waitUntilExit()
        }
        let fields = (String(data: output.fileHandleForReading.availableData, encoding: .utf8) ?? "")
            .split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard fields.count == 4 else { return ["activation helper did not report its windows"] }
        let helperPID = pid_t(fields[0])
        let helperWindows = Array(fields[1...])
        func wait(_ seconds: TimeInterval, until condition: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }
        func stackIndex(_ number: Int) -> Int {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            return list.firstIndex { $0[kCGWindowNumber as String] as? Int == number } ?? Int.max
        }
        wait(0.5)
        let otherApplication = NSWindow(contentRect: NSRect(x: 250, y: 250, width: 500, height: 400),
                                        styleMask: [.titled], backing: .buffered, defer: false)
        otherApplication.isReleasedWhenClosed = false
        otherApplication.orderFrontRegardless()
        defer { otherApplication.close() }
        let other = otherApplication.windowNumber
        wait(0.3)
        // The registered window is raised within its inactive app before the app is activated.
        input.fileHandleForWriting.write(Data("raise 2\n".utf8))
        wait(2) { stackIndex(helperWindows[2]) < stackIndex(other) }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == helperPID ||
            helperWindows[..<2].contains(where: { stackIndex($0) < stackIndex(other) }) {
            return ["activation fixture did not start with unregistered windows behind another app " +
                "(helper frontmost: \(NSWorkspace.shared.frontmostApplication?.processIdentifier == helperPID), " +
                "stack: \(helperWindows.map(stackIndex)) vs \(stackIndex(other)))"]
        }
        guard WindowAccess.activateFrontWindowOnly(helperPID) else {
            return ["front-window-only app activation is unavailable, so tab focus would raise every app window"]
        }
        wait(2) { NSWorkspace.shared.frontmostApplication?.processIdentifier == helperPID }
        wait(0.4)
        var failures: [String] = []
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != helperPID {
            failures.append("front-window-only activation did not make the window's app frontmost")
        }
        if stackIndex(helperWindows[2]) > stackIndex(other) {
            failures.append("front-window-only activation did not keep the registered window in front")
        }
        if helperWindows[..<2].contains(where: { stackIndex($0) < stackIndex(other) }) {
            failures.append("activating a tab's app brought its unregistered windows above other apps")
        }
        return failures
    }

    static func runChecks() -> [String] {
        var failures: [String] = []
        failures += runManyTabMoveChecks()
        failures += runConstraintNoticeChecks()
        failures += runTransferChecks()
        failures += runRegisteredWindowDragChecks()
        failures += runKeyboardFocusChecks()
        failures += runWindowInsertionChecks()
        let (orderingSession, orderingModel) = fixture()
        let originalOrder = orderingSession.windows.map(\.id)
        let originalCells = orderingSession.cells
        orderingSession.reorderWindows([originalOrder[2], originalOrder[1], originalOrder[0]])
        if orderingSession.windows.map(\.id) != [originalOrder[2], originalOrder[1], originalOrder[0]] ||
            orderingSession.cells != originalCells || orderingModel.changeCount != 1 ||
            !orderingModel.operations.isEmpty {
            failures.append("reordering tabs changed pane assignments or window state")
        }
        orderingSession.reorderWindows([originalOrder[0], originalOrder[0], originalOrder[2]])
        if orderingSession.windows.map(\.id) != [originalOrder[2], originalOrder[1], originalOrder[0]] ||
            orderingModel.changeCount != 1 {
            failures.append("invalid tab order changed the session")
        }

        let (session, model) = fixture()
        guard session.windows.count == 3 else { return ["stacked fixture could not register windows"] }
        let ids = session.windows.map(\.id)

        for _ in 0..<10 {
            for id in ids { session.select(id) }
        }

        let expectedRaises = (0..<10).flatMap { _ in (0..<3).map(Operation.raise) }
        if model.operations != expectedRaises {
            failures.append("stacked switching minimized/restored, moved or resized an already aligned window")
        }
        if model.windows.prefix(3).contains(where: { $0.minimized || $0.frame != model.target }) {
            failures.append("stacked tabs are not all visible at the same frame")
        }
        model.operations.removeAll()
        model.target.origin.x += 70
        session.sync()
        if model.operations != [.move(0), .move(1), .move(2), .raise(2)] ||
            model.windows.prefix(3).contains(where: { $0.frame != model.target }) {
            failures.append("moving the workspace did not move the entire stack without resizing")
        }
        model.operations.removeAll()
        model.target.size.width -= 100
        session.sync()
        if model.operations != [.resize(0), .resize(1), .resize(2), .raise(2)] ||
            model.windows.prefix(3).contains(where: { $0.frame != model.target }) {
            failures.append("resizing the workspace left background tabs behind or above the selected tab")
        }
        model.operations.removeAll()
        session.sync()
        if !model.operations.isEmpty { failures.append("unchanged workspace repeated frame writes") }

        model.windows[0].frame = model.windows[0].originalFrame
        session.select(ids[0])
        if model.windows[0].frame != model.target || model.operations != [.resize(0), .raise(0)] {
            failures.append("selecting a manually displaced tab did not realign it")
        }
        model.operations.removeAll()
        model.windows[1].minimized = true
        session.suspend()
        session.suspend()
        if model.windows.prefix(3).contains(where: { !$0.minimized }) ||
            model.operations != [.minimize(0, true), .minimize(2, true)] {
            failures.append("workspace suspension did not minimize all tabs exactly once")
        }
        model.target.origin.y += 40
        session.resume()
        if model.windows[0].minimized || model.windows[2].minimized || !model.windows[1].minimized ||
            model.windows[0].frame != model.target || model.windows[2].frame != model.target ||
            model.operations.last != .raise(0) {
            failures.append("resume did not restore the stack while preserving a manually minimized inactive tab")
        }
        if !session.remove(ids[0]) || session.selectedID != ids[1] ||
            model.windows[0].frame != model.windows[0].originalFrame || model.windows[0].minimized {
            failures.append("removing the selected tab did not restore it and present the next tab")
        }
        if !session.restoreAll().isEmpty ||
            model.windows.prefix(3).contains(where: {
                $0.frame != $0.originalFrame || $0.minimized != $0.originallyMinimized
            }) {
            failures.append("stacked tabs did not restore their original frames and minimized states")
        }
        if model.windows[3].frame != model.windows[3].originalFrame ||
            model.windows[3].minimized != model.windows[3].originallyMinimized {
            failures.append("unregistered sibling window was modified")
        }
        return failures + checkPartialFailures() + checkBatchAddition() +
            checkSplitSelection(layout: .sideBySide) + checkSplitSelection(layout: .stacked) +
            checkGrid() + checkGridConstraints() + checkInput()
    }

    private static func gridTargets(_ size: WorkspaceGridSize) -> [Int: CGRect] {
        let width = (1600 - CGFloat(size.columns - 1) * 32) / CGFloat(size.columns)
        let height = (1000 - CGFloat(size.rows - 1) * 32) / CGFloat(size.rows)
        return Dictionary(uniqueKeysWithValues: (0..<size.cellCount).map { index in
            (index, CGRect(
                x: 200 + CGFloat(index % size.columns) * (width + 32),
                y: 160 + CGFloat(index / size.columns) * (height + 32),
                width: width, height: height
            ))
        })
    }

    private static func configureGridFixture(_ session: WindowSession, _ model: Model) {
        session.onChange = { [weak session] in
            model.changeCount += 1
            if let session { model.gridTargets = gridTargets(session.gridSize) }
        }
        model.gridTargets = gridTargets(session.gridSize)
    }

    private static func checkGrid() -> [String] {
        var failures: [String] = []
        let (session, model) = fixture(registering: Array(0..<17), windowCount: 18)
        let ids = session.windows.map(\.id)
        configureGridFixture(session, model)
        session.setGrid(WorkspaceGridSize(columns: 4, rows: 4))
        if session.gridSize.cellCount != 16 || session.visibleWindows.count != 16 ||
            Set(session.cells.compactMap { $0 }).count != 16 || model.paneFrames.count != 16 {
            failures.append("4x4 grid did not display sixteen distinct windows")
        }
        let visibleFrames = Array(model.paneFrames.values)
        for index in visibleFrames.indices {
            for other in visibleFrames.indices where other > index {
                if visibleFrames[index].intersects(visibleFrames[other]) {
                    failures.append("4x4 grid published overlapping actual window frames")
                }
            }
        }
        let oldCells = session.cells
        model.operations.removeAll()
        session.activateCell(15)
        if session.activeCell != 15 || !model.operations.isEmpty {
            failures.append("activating a grid cell changed external windows")
        }
        guard let hidden = ids.first(where: { !oldCells.contains($0) }) else {
            return failures + ["4x4 fixture has no hidden window"]
        }
        if let source = session.cells[0], let destination = session.cells[15] {
            session.moveWindow(source, toCell: 15)
            if session.cells[15] != source || session.cells[0] != destination ||
                Array(session.cells[1..<15]) != Array(oldCells[1..<15]) ||
                session.selectedID != source || model.paneFrames[source] != model.gridTargets?[15] ||
                model.paneFrames[destination] != model.gridTargets?[0] {
                failures.append("pane exchange did not swap only the two displayed windows and their actual frames")
            }
        }
        let swapped = session.cells
        session.select(hidden)
        if session.cells[15] != hidden || Array(session.cells.prefix(15)) != Array(swapped.prefix(15)) {
            failures.append("selecting a hidden tab changed a cell other than the active one")
        }
        session.setGrid(WorkspaceGridSize(columns: 3, rows: 4))
        if session.gridSize.columns != 3 || session.gridSize.rows != 4 ||
            session.selectedID != hidden || Set(session.cells.compactMap { $0 }).count != 12 {
            failures.append("shrinking only the column count lost the active window or duplicated cells")
        }
        session.setGrid(.single)
        if session.selectedID != hidden || model.paneFrames.count != 1 ||
            model.windows.prefix(17).contains(where: { $0.frame != gridTargets(.single)[0] }) {
            failures.append("collapsing a grid did not reunite hidden stacks behind the active tab")
        }
        session.setGrid(WorkspaceGridSize(columns: 5, rows: 1))
        if session.gridSize != .single || model.notices.last?.needsAttention != true {
            failures.append("invalid grid dimensions were accepted or rejected silently")
        }
        if !session.restoreAll().isEmpty || model.windows.contains(where: {
            $0.frame != $0.originalFrame || $0.minimized != $0.originallyMinimized
        }) {
            failures.append("sixteen-cell lifecycle changed original states or an unregistered sibling")
        }

        let (emptySession, emptyModel) = fixture(registering: [], windowCount: 4)
        configureGridFixture(emptySession, emptyModel)
        emptySession.setGrid(WorkspaceGridSize(columns: 2, rows: 2))
        emptySession.activateCell(3)
        emptySession.add(Array(emptyModel.windows.prefix(3)).map {
            WindowCandidate(element: $0.element, application: .current, title: "Fill empty cells")
        })
        if emptySession.visibleWindows.count != 3 || Set(emptySession.cells.compactMap { $0 }).count != 3 ||
            emptySession.cells[3] != emptySession.windows.first?.id {
            failures.append("batch addition did not fill distinct empty grid cells starting at the active cell")
        }
        guard let emptyCell = emptySession.cells.firstIndex(where: { $0 == nil }) else {
            return failures + ["batch fixture has no remaining empty cell"]
        }
        let movedID = emptySession.windows.last!.id
        let previous = emptySession.cellIndex(for: movedID)!
        emptySession.moveWindow(movedID, toCell: emptyCell)
        if emptySession.cells[emptyCell] != movedID || emptySession.cells[previous] != nil ||
            emptySession.visibleWindows.count != 3 {
            failures.append("moving a displayed tab into an empty cell duplicated it or lost another pane")
        }
        emptySession.activateCell(previous)
        emptySession.cycle(1)
        if emptySession.selectedID != emptySession.windows.first?.id || emptySession.activeCell != 3 {
            failures.append("keyboard cycling from an empty cell did not select the first registered tab")
        }
        return failures
    }

    private static func checkGridConstraints() -> [String] {
        var failures: [String] = []
        let (session, model) = fixture(registering: [0, 1, 2, 3])
        configureGridFixture(session, model)
        model.windows[3].minimumSize.width = 900
        var learned: [Int: CGSize] = [:]
        session.fitMinimumSizes = { [weak session] sizes in
            learned = sizes
            guard let session else { return false }
            guard session.gridSize.columns == 2, session.gridSize.rows == 2 else { return true }
            if (sizes[0]?.width ?? 0) > 784 {
                model.gridTargets = [
                    0: CGRect(x: 200, y: 160, width: 900, height: 484),
                    1: CGRect(x: 1132, y: 160, width: 668, height: 484),
                    2: CGRect(x: 200, y: 676, width: 900, height: 484),
                    3: CGRect(x: 1132, y: 676, width: 668, height: 484)
                ]
            }
            return true
        }
        session.setGrid(WorkspaceGridSize(columns: 2, rows: 2))
        if session.gridSize.cellCount != 4 || learned[0] != CGSize(width: 900, height: 0) ||
            model.paneFrames.count != 4 || model.windows[3].frame != model.gridTargets?[0] {
            failures.append("actual minimum width was not learned and fitted without inventing a minimum height")
        }
        let frames = Array(model.paneFrames.values)
        for index in frames.indices {
            if frames.indices.contains(where: { $0 != index && frames[index].intersects(frames[$0]) }) {
                failures.append("minimum-size correction left overlapping windows")
                break
            }
        }
        let (blocked, blockedModel) = fixture()
        configureGridFixture(blocked, blockedModel)
        blockedModel.windows[1].minimumSize.width = 1500
        blocked.fitMinimumSizes = { sizes in sizes.values.allSatisfy { $0.width <= 1000 } }
        blocked.setGrid(WorkspaceGridSize(columns: 2, rows: 2))
        if blocked.gridSize != .single || blockedModel.paneFrames.count != 1 ||
            blockedModel.notices.last?.needsAttention != true ||
            blockedModel.notices.last?.text.contains("1×1") != true {
            failures.append("infeasible minimum sizes did not reject the overlapping grid explicitly")
        }
        return failures
    }

    private static func checkInput() -> [String] {
        var failures: [String] = []
        func key(_ flags: NSEvent.ModifierFlags = .control, code: UInt16 = 48) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: 0, context: nil, characters: "\t",
                             charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: code)!
        }
        var context = WorkspaceShortcutContext()
        if context.direction(for: key(), ownPID: 1, frontPID: 2, visiblePIDs: [2]) != 1 {
            failures.append("Control Tab was not accepted from a visible external window")
        }
        for _ in 0..<30 {
            if context.direction(for: key(), ownPID: 1, frontPID: 2, visiblePIDs: [3]) != 1 {
                failures.append("continuous Control Tab stopped after AXRaise left keyboard focus in the previous app")
                break
            }
        }
        if context.direction(for: key([.control, .shift, .capsLock]), ownPID: 1, frontPID: 2, visiblePIDs: [3]) != -1 {
            failures.append("reverse switching or Caps Lock support regressed")
        }
        context.reset()
        if context.direction(for: key(), ownPID: 1, frontPID: 2, visiblePIDs: [3]) != nil {
            failures.append("a mouse click did not end the retained shortcut focus context")
        }
        _ = context.direction(for: key(), ownPID: 1, frontPID: 2, visiblePIDs: [2])
        context.applicationDidActivate(9)
        if context.direction(for: key(), ownPID: 1, frontPID: 2, visiblePIDs: [3]) != nil ||
            context.direction(for: key([.control, .command]), ownPID: 1, frontPID: 1, visiblePIDs: []) != nil {
            failures.append("shortcut context survived an unrelated app activation or accepted a different shortcut")
        }
        _ = context.direction(for: key(), ownPID: 1, frontPID: 2, visiblePIDs: [2])
        _ = context.direction(for: key(.command, code: 50), ownPID: 1, frontPID: 2, visiblePIDs: [3])
        if context.direction(for: key(), ownPID: 1, frontPID: 2, visiblePIDs: [3]) != nil {
            failures.append("switching windows within the same application retained a stale shortcut context")
        }

        let (session, model) = fixture(registering: [])
        let candidate = WindowCandidate(element: model.windows[0].element, application: .current, title: "Dragged")
        let original = model.windows[0].originalFrame
        model.windows[0].frame.origin.x += 120
        session.add(candidate, originalFrame: original)
        session.add(candidate, originalFrame: original)
        if session.windows.count != 1 || !session.remove(session.windows[0].id) || model.windows[0].frame != original {
            failures.append("drag registration duplicated a tab or restored the post-drag rather than pre-drag frame")
        }
        return failures
    }

    private static func checkSplitSelection(layout: WorkspaceSplitLayout) -> [String] {
        var failures: [String] = []
        let (session, model) = fixture()
        let ids = session.windows.map(\.id)
        let full = model.target
        func configure(_ model: Model, for layout: WorkspaceSplitLayout) {
            model.target = full
            if layout == .sideBySide {
                model.target.size.width = 444
                model.rightTarget = CGRect(x: full.minX + 450, y: full.minY, width: 450, height: full.height)
            } else {
                model.target.size.height = 294
                model.rightTarget = CGRect(x: full.minX, y: full.minY + 300, width: full.width, height: 300)
            }
        }
        configure(model, for: layout)
        session.setSplit(true, layout: layout)
        if session.primaryID != ids[2] || session.secondaryID != ids[0] ||
            model.windows[2].frame != model.target || model.windows[0].frame != model.rightTarget ||
            Set(model.paneFrames.keys) != Set([ids[2], ids[0]]) {
            failures.append("split did not display two distinct windows in their pane frames")
        }
        model.operations.removeAll()
        session.focusVisibleWindow(ids[0])
        if session.selectedID != ids[0] || session.primaryID != ids[2] || !model.operations.isEmpty {
            failures.append("focusing the right pane moved windows or changed pane assignments")
        }
        session.select(ids[1])
        if session.primaryID != ids[2] || session.secondaryID != ids[1] ||
            model.windows[1].frame != model.rightTarget || model.windows[2].frame != model.target {
            failures.append("selecting a hidden tab did not replace only the active right pane")
        }
        let other: WorkspaceSplitLayout = layout == .sideBySide ? .stacked : .sideBySide
        configure(model, for: other)
        session.setSplit(true, layout: other)
        if session.primaryID != ids[2] || session.secondaryID != ids[1] || session.selectedID != ids[1] ||
            session.splitLayout != other || model.windows[2].frame != model.target ||
            model.windows[1].frame != model.rightTarget {
            failures.append("changing split orientation lost the displayed windows or the active pane")
        }
        configure(model, for: layout)
        session.setSplit(true, layout: layout)
        model.operations.removeAll()
        session.select(ids[2])
        if model.operations != [.raise(1), .raise(2)] || session.secondaryID != ids[1] {
            failures.append("selecting a displayed tab resized it or swapped the visible panes")
        }
        session.cycle(1)
        if session.primaryID != ids[0] || session.secondaryID != ids[1] ||
            model.windows[0].frame != model.target || model.windows[1].frame != model.rightTarget {
            failures.append("tab cycling did not replace the active left pane independently")
        }
        model.target.origin.y += 40
        model.rightTarget.origin.y += 40
        session.sync()
        if model.windows[0].frame != model.target || model.windows[1].frame != model.rightTarget ||
            model.windows[2].frame != model.target {
            failures.append("workspace movement did not preserve both pane stacks")
        }
        model.failedMoves.insert(1)
        model.target.origin.x += 20
        model.rightTarget.origin.x += 20
        session.sync()
        if Set(model.paneFrames.keys) != Set([ids[0]]) || model.notices.last?.needsAttention != true {
            failures.append("one failed pane movement did not mask only that pane and report its error")
        }
        model.failedMoves.remove(1)
        session.sync()
        if Set(model.paneFrames.keys) != Set([ids[0], ids[1]]) {
            failures.append("failed split pane did not recover independently")
        }
        session.suspend()
        session.resume()
        if model.windows.prefix(3).contains(where: { $0.minimized }) ||
            model.windows[0].frame != model.target || model.windows[1].frame != model.rightTarget {
            failures.append("split suspension/resume lost a visible pane or its geometry")
        }
        model.target = full
        session.focusVisibleWindow(ids[1])
        session.setSplit(false)
        if session.primaryID != ids[1] || session.isSplit ||
            model.windows.prefix(3).contains(where: { $0.frame != full }) ||
            Set(model.paneFrames.keys) != Set([ids[1]]) {
            failures.append("disabling split did not expand the active pane and reunite the stack")
        }
        configure(model, for: layout)
        session.setSplit(true, layout: layout)
        if !session.remove(ids[1]) || session.primaryID != ids[2] || session.secondaryID != ids[0] {
            failures.append("removing a visible pane did not fill it from a hidden tab")
        }
        model.target = full
        if !session.remove(ids[2]) || session.isSplit || session.primaryID != ids[0] ||
            model.windows[0].frame != full {
            failures.append("removing down to one tab did not automatically collapse split")
        }
        if !session.remove(ids[0]) || session.primaryID != nil || session.selectedID != nil ||
            !model.paneFrames.isEmpty {
            failures.append("removing the final split tab left a stale pane or aperture")
        }
        let (rightSession, rightModel) = fixture()
        let rightIDs = rightSession.windows.map(\.id)
        configure(rightModel, for: layout)
        rightSession.setSplit(true, layout: layout)
        if !rightSession.remove(rightIDs[0]) || rightSession.primaryID != rightIDs[2] ||
            rightSession.secondaryID != rightIDs[1] || rightSession.selectedID != rightIDs[2] {
            failures.append("removing the inactive right pane changed the active left pane")
        }
        rightSession.focusVisibleWindow(rightIDs[1])
        let addedCandidate = WindowCandidate(
            element: rightModel.windows[3].element, application: .current, title: "New right tab"
        )
        rightSession.add(addedCandidate)
        if rightSession.primaryID != rightIDs[2] ||
            rightSession.selected?.candidate.isSameWindow(as: addedCandidate) != true ||
            rightSession.secondaryID != rightSession.selectedID ||
            rightModel.windows[3].frame != rightModel.rightTarget ||
            rightModel.windows[2].frame != rightModel.target {
            failures.append("adding a tab to the active right pane displaced the left pane")
        }
        return failures.map { "\(layout): \($0)" }
    }

    private static func checkBatchAddition() -> [String] {
        var failures: [String] = []
        let (session, model) = fixture(registering: [])
        let candidates = model.windows.map {
            WindowCandidate(element: $0.element, application: .current, title: "Batch")
        }
        session.add([candidates[0], candidates[2], candidates[0], candidates[1]])
        if session.windows.count != 3 || session.selected?.candidate.isSameWindow(as: candidates[1]) != true ||
            model.changeCount != 1 || model.operations.filter({
                if case .raise = $0 { return true }
                return false
            }) != [.raise(1)] ||
            model.windows.prefix(3).contains(where: { $0.minimized || $0.frame != model.target }) {
            failures.append("batch addition did not register unique windows and present only the final tab")
        }
        if !session.restoreAll().isEmpty || model.windows.prefix(3).contains(where: {
            $0.frame != $0.originalFrame || $0.minimized != $0.originallyMinimized
        }) {
            failures.append("batch addition did not preserve original window states")
        }

        let (partial, partialModel) = fixture(registering: [])
        partialModel.failedRegistrations.insert(1)
        let partialCandidates = partialModel.windows.map {
            WindowCandidate(element: $0.element, application: .current, title: "Partial batch")
        }
        partial.add(Array(partialCandidates.prefix(3)))
        if partial.windows.count != 2 || partialModel.changeCount != 1 ||
            partial.selected?.candidate.isSameWindow(as: partialCandidates[2]) != true ||
            partialModel.notices.last?.needsAttention != true ||
            partialModel.windows[1].frame != partialModel.windows[1].originalFrame {
            failures.append("partial batch failure blocked valid windows, modified a rejected window or lost its error")
        }
        return failures
    }

    private static func checkPartialFailures() -> [String] {
        var failures: [String] = []
        let (session, model) = fixture()
        model.failedMoves.insert(1)
        model.target.origin.x += 50
        session.sync()
        if model.windows[0].frame != model.target || model.windows[2].frame != model.target ||
            model.notices.last?.needsAttention != true ||
            model.notices.last?.text.contains("Injected window operation failure") != true {
            failures.append("one failed background move blocked the other tabs or failed silently")
        }
        model.failedMoves.remove(1)
        session.sync()
        if model.windows[1].frame != model.target || model.operations.last != .raise(2) {
            failures.append("failed background alignment was not retried beneath the selected window")
        }
        model.failedMoves.insert(2)
        model.target.origin.y += 30
        session.sync()
        if model.presentedFrames.last != .some(nil) || model.notices.last?.needsAttention != true {
            failures.append("failed selected-window movement left a stale transparent aperture")
        }
        model.failedMoves.remove(2)
        session.sync()
        if model.presentedFrames.last != .some(model.target) {
            failures.append("selected-window alignment did not recover after an error")
        }
        model.failedMinimizations.insert(0)
        session.suspend()
        if !model.windows[1].minimized || !model.windows[2].minimized ||
            model.notices.last?.needsAttention != true {
            failures.append("one failed minimization blocked suspension of the remaining stack")
        }
        model.failedMinimizations.remove(0)
        session.resume()
        if model.windows.prefix(3).contains(where: { $0.minimized }) {
            failures.append("partial suspension could not be resumed")
        }
        return failures
    }
}
