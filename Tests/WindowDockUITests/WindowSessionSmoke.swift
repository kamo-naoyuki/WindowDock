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
        /// In native full screen, the window ignores frame changes.
        var fullScreen = false

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
        /// Called before a window's frame is set, with its index and the new frame.
        var onSetFrame: ((Int, CGRect) -> Void)?
        var failedMoves: Set<Int> = []
        var failedMinimizations: Set<Int> = []
        var failedRegistrations: Set<Int> = []
        var failedFocuses: Set<Int> = []
        var focusedWindows: [Int] = []
        /// Windows asked to leave full screen, by index.
        var fullScreenExits: [Int] = []
        var probeErrors: [Int: AXError] = [:]
        var titles: [Int: String] = [:]
        /// The windows that their app lists, by index.
        var listedWindows: [Int] = []
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
            model.onSetFrame?(index, frame)
            model.operations.append(.resize(index))
            guard !model.windows[index].fullScreen else { return }
            model.windows[index].frame = frame
            model.windows[index].frame.size.width = max(frame.width, model.windows[index].minimumSize.width)
            model.windows[index].frame.size.height = max(frame.height, model.windows[index].minimumSize.height)
        }
        access.setPosition = { element, position in
            let index = try model.index(of: element)
            model.onMove?()
            if model.failedMoves.contains(index) { throw InjectedFailure() }
            model.operations.append(.move(index))
            guard !model.windows[index].fullScreen else { return }
            model.windows[index].frame.origin = position
        }
        access.isFullScreen = { element in
            (try? model.index(of: element)).map { model.windows[$0].fullScreen } ?? false
        }
        // Leaving full screen animates; a check ends it by clearing `fullScreen`.
        access.setFullScreen = { element, fullScreen in
            let index = try model.index(of: element)
            if !fullScreen { model.fullScreenExits.append(index) }
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
        access.probe = { element in
            guard let index = try? model.index(of: element) else {
                return WindowProbeResult(error: .invalidUIElement, title: nil)
            }
            let error = model.probeErrors[index] ?? .success
            let title = [.success, .noValue, .attributeUnsupported].contains(error)
                ? model.titles[index] ?? "Test \(index)"
                : nil
            return WindowProbeResult(error: error, title: title)
        }
        access.applicationWindows = { _ in
            model.listedWindows.map { WindowCandidate(element: model.windows[$0].element, application: .current, title: "Live \($0)") }
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
        let windowNumbers: [CGWindowID] = [80, 84, 81]
        var lookups = 0
        let windowID: (AXUIElement) -> CGWindowID? = { element in
            lookups += 1
            return (try? model.index(of: element)).map { windowNumbers[$0] }
        }
        // A moving window's AX frame lags behind the WindowServer, so frame matching cannot identify it.
        var resolutions = 0
        let laggingFrame: (WindowServerWindow) throws -> WindowCandidate = { _ in
            resolutions += 1
            throw InjectedFailure()
        }
        var registration = WorkspaceWindowDragRegistration()
        for offset in [CGFloat(0), 100, 200] {
            let moved = WindowServerWindow(id: 80, processID: pid, frame: model.target.offsetBy(dx: offset, dy: 0))
            if !registration.isRegistered(moved, among: registered, windowID: windowID, resolve: laggingFrame) {
                failures.append("a registered window was offered for ordinary dragging into a workspace")
            }
        }
        if !registration.isRegistered(WindowServerWindow(id: 84, processID: pid, frame: model.target),
                                      among: registered, windowID: windowID, resolve: laggingFrame) {
            failures.append("a window registered in another workspace was not suppressed")
        }
        for offset in [CGFloat(0), 100, 200] {
            let sibling = WindowServerWindow(id: 90, processID: pid, frame: model.target.offsetBy(dx: offset, dy: 40))
            if registration.isRegistered(sibling, among: registered, windowID: windowID, resolve: laggingFrame) {
                failures.append("an unregistered window was not droppable while another window of its app was registered")
                break
            }
        }
        if resolutions != 0 {
            failures.append("drag identification fell back to frame matching although window numbers were available")
        }
        if lookups != registered.count {
            failures.append("registered window numbers were looked up again during one drag: \(lookups)")
        }
        let sibling = WindowCandidate(element: model.windows[2].element, application: .current, title: "Newly registered")
        if !registration.isRegistered(WindowServerWindow(id: 81, processID: pid, frame: model.target),
                                      among: registered + [sibling], windowID: windowID, resolve: laggingFrame) {
            failures.append("drag identification did not notice newly registered ownership")
        }
        let unrelated = WindowServerWindow(id: 82, processID: pid + 1, frame: model.target)
        if registration.isRegistered(unrelated, among: registered, windowID: windowID, resolve: laggingFrame) {
            failures.append("an app with no registered windows was suppressed")
        }
        registration.reset()
        lookups = 0
        _ = registration.isRegistered(WindowServerWindow(id: 90, processID: pid, frame: model.target),
                                      among: registered, windowID: windowID, resolve: laggingFrame)
        if lookups != registered.count {
            failures.append("resetting the drag did not discard cached window numbers")
        }

        // Without window numbers, frames identify the window once it can be matched.
        let unavailable: (AXUIElement) -> CGWindowID? = { _ in nil }
        registration.reset()
        resolutions = 0
        let resolve: (WindowServerWindow) throws -> WindowCandidate = { _ in
            resolutions += 1
            return candidate
        }
        for offset in [CGFloat(0), 100, 200] {
            let moved = WindowServerWindow(id: 80, processID: pid, frame: model.target.offsetBy(dx: offset, dy: 0))
            if !registration.isRegistered(moved, among: registered, windowID: unavailable, resolve: resolve) {
                failures.append("frame fallback did not suppress a registered window")
            }
        }
        if resolutions != 1 {
            failures.append("frame fallback repeated AX resolution while moving: \(resolutions)")
        }
        registration.reset()
        resolutions = 0
        for offset in [CGFloat(0), 100, 200] {
            let moved = WindowServerWindow(id: 90, processID: pid, frame: model.target.offsetBy(dx: offset, dy: 40))
            if registration.isRegistered(moved, among: registered, windowID: unavailable, resolve: laggingFrame) {
                failures.append("a window whose moving frame could not be matched was not droppable")
            }
        }
        if resolutions != 1 {
            failures.append("an unmatched moving frame was resolved again on every sample: \(resolutions)")
        }
        return failures
    }

    /// Drags an unregistered window of an app whose other window is already in a workspace onto the tab bar.
    static func runExternalWindowDropChecks() -> [String] {
        let model = Model(windowCount: 2)
        let controller = WorkspaceController(name: "Window drop", access: access(for: model))
        let window = controller.window
        defer {
            controller.hideWindowDropTarget()
            controller.quitting = true
            window.orderOut(nil)
        }
        guard let chrome = window.contentView as? WorkspaceChromeView,
              let screen = NSScreen.screens.first else { return ["window drop fixture could not find its content or screen"] }
        window.setFrame(NSRect(x: 200, y: 160, width: 900, height: 600), display: true)
        controller.session.add(WindowCandidate(element: model.windows[0].element, application: .current, title: "Registered"))
        window.orderFrontRegardless()
        chrome.layoutSubtreeIfNeeded()
        let pid = ProcessInfo.processInfo.processIdentifier
        let registeredNumber: CGWindowID = 9_000_001
        let draggedNumber: CGWindowID = 9_000_002
        let workspace = WindowServerWindow(
            id: CGWindowID(window.windowNumber), processID: pid,
            frame: WindowGeometry.accessibilityRect(from: window.frame, primaryScreenTop: screen.frame.maxY)
        )
        let drop = window.convertPoint(toScreen: chrome.addButton.convert(
            NSPoint(x: chrome.addButton.bounds.midX, y: chrome.addButton.bounds.midY), to: nil
        ))
        guard controller.acceptsWindowDrop(at: drop) else { return ["window drop fixture's tab bar did not accept drops"] }
        let axDrop = CGPoint(x: drop.x, y: screen.frame.maxY - drop.y)
        // The dragged window starts outside the workspace and is grabbed 40 points into its titlebar.
        let start = CGRect(x: workspace.frame.maxX + 60, y: workspace.frame.minY + 40, width: 500, height: 400)
        let grab = CGPoint(x: start.minX + 40, y: start.minY + 10)
        let moved = start.offsetBy(dx: axDrop.x - grab.x, dy: axDrop.y - grab.y)

        func run(dragging number: CGWindowID, windowID: @escaping (AXUIElement) -> CGWindowID?) -> (shown: Bool, finished: Bool) {
            let coordinator = WorkspaceWindowDrop { [controller] }
            var pointer = WorkspaceWindowDrop.Pointer(location: .zero, buttonDown: false)
            var frame = start
            var finished: [WorkspaceController] = []
            coordinator.pointer = { pointer }
            coordinator.windows = { [WindowServerWindow(id: number, processID: pid, frame: frame), workspace] }
            // The harness owns both fake windows, so only the workspace must not count as its own app.
            coordinator.ownPID = -1
            coordinator.isRegularApplication = { _ in true }
            coordinator.windowID = windowID
            coordinator.resolve = { _ in throw InjectedFailure() }
            coordinator.finish = { target, _, _, _ in finished.append(target) }
            func sample(_ point: CGPoint, down: Bool) {
                pointer = .init(location: NSPoint(x: point.x, y: screen.frame.maxY - point.y), buttonDown: down)
                coordinator.poll()
            }
            sample(grab, down: false)
            sample(grab, down: true)
            frame = moved
            sample(axDrop, down: true)
            let shown = chrome.windowDropPanel?.isVisible == true
            sample(axDrop, down: false)
            return (shown, finished.count == 1 && finished.first === controller)
        }

        var failures: [String] = []
        let numbers: (AXUIElement) -> CGWindowID? = { element in
            CFEqual(element, model.windows[0].element) ? registeredNumber : nil
        }
        let sibling = run(dragging: draggedNumber, windowID: numbers)
        if !sibling.shown {
            failures.append("dragging an unregistered window over the tab bar showed no drop target when another window of its app was registered")
        }
        if !sibling.finished {
            failures.append("releasing an unregistered window on the tab bar did not add it when another window of its app was registered")
        }
        if chrome.windowDropPanel?.isVisible == true { failures.append("the drop target stayed visible after release") }
        let fallback = run(dragging: draggedNumber, windowID: { _ in nil })
        if !fallback.shown || !fallback.finished {
            failures.append("a window whose moving frame could not be matched was not added: \(fallback)")
        }
        let registered = run(dragging: registeredNumber, windowID: numbers)
        if registered.shown || registered.finished {
            failures.append("dragging an already registered window offered it for addition: \(registered)")
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
        func settle(_ seconds: TimeInterval = 0.5, until condition: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline {
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
        guard let dragSpace = chrome.subviews.flatMap(\.subviews).compactMap({ $0 as? NSStackView })
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
            // Each visible pane's window comes above other apps, and the selected one keeps focus.
            if model.focusedWindows != [0, 1] {
                failures.append("\(label): selected pane was not focused on release; another activation click is needed: " +
                    "\(model.focusedWindows) (active \(NSApp.isActive), key \(window.isKeyWindow), " +
                    "frontmost \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"))")
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

        // Clicks on an inactive workspace. The click is handled before WindowDock's activation arrives.
        let helper: ActivationHelperProcess
        switch ActivationHelperProcess.launch() {
        case .success(let launched): helper = launched
        case .failure(let failure): return failures + [failure.message]
        }
        defer { helper.terminate() }
        settle(0.5)
        // NSApp.deactivate() does not give up activation, so another app takes it.
        func deactivate() -> Bool {
            if NSApp.isActive {
                _ = WindowAccess.activateFrontWindowOnly(helper.pid)
                settle(2) { !NSApp.isActive }
            }
            return !NSApp.isActive
        }
        if deactivate() {
            model.focusedWindows.removeAll()
            if !gesture(at: barPoint, delta: .zero) { failures.append("could not create inactive titlebar click") }
            settle(0.3)
            if !model.focusedWindows.isEmpty {
                failures.append("inactive titlebar click handed off focus before WindowDock was active")
            }
            // Stands in for the click, which lets WindowDock activate itself.
            helper.send("yield \(ProcessInfo.processInfo.processIdentifier)")
            settle(0.3)
            controller.bringToFront()
            settle(2) { NSApp.isActive && window.isKeyWindow && !model.focusedWindows.isEmpty }
            settle(0.2)
            if model.focusedWindows != [0, 1] {
                failures.append("titlebar click on an inactive workspace left only the frame in front once WindowDock became active; another click is needed: \(model.focusedWindows)")
            }
        } else {
            failures.append("titlebar focus fixture could not deactivate WindowDock")
        }
        let paneArea = chrome.gridAreas[0]
        let panePoint = paneArea.convert(NSPoint(x: paneArea.bounds.midX, y: paneArea.bounds.midY), to: nil)
        let tabButtons = chrome.tabs.arrangedSubviews.compactMap {
            ($0 as? WorkspaceTabGroup)?.arrangedSubviews.compactMap { $0 as? WorkspaceTabButton }.first
        }
        if let tab = tabButtons.first(where: { $0.tag == 0 }) {
            let tabPoint = tab.convert(NSPoint(x: tab.bounds.midX, y: tab.bounds.midY), to: nil)
            for (label, point) in [("pane", panePoint), ("tab", tabPoint)] {
                controller.session.select(controller.session.windows[1].id)
                guard deactivate() else {
                    failures.append("titlebar focus fixture could not deactivate WindowDock before a \(label) click")
                    continue
                }
                model.focusedWindows.removeAll()
                if !gesture(at: point, delta: .zero) { failures.append("could not create inactive \(label) click") }
                settle(1) { !model.focusedWindows.isEmpty }
                // A pane does not track the mouse; deliver its queued mouse-up before the next click.
                settle(0.3)
                if model.focusedWindows != [0] {
                    failures.append("the first click on a \(label) of an inactive workspace did not focus its window: \(model.focusedWindows)")
                }
            }
        } else {
            failures.append("titlebar focus fixture could not find its first tab")
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

    /// A running `runActivationHelper` process, which can take activation away from the harness.
    final class ActivationHelperProcess {
        let pid: pid_t
        let windows: [Int]
        private let process: Process
        private let input: Pipe

        /// Fails with a description when the helper cannot be launched.
        static func launch() -> Result<ActivationHelperProcess, SmokeFailure> {
            guard let executable = Bundle.main.executableURL else { return .failure(.init("activation helper could not find its executable")) }
            let process = Process()
            let output = Pipe()
            let input = Pipe()
            process.executableURL = executable
            process.arguments = ["--activation-helper"]
            process.standardOutput = output
            process.standardInput = input
            do { try process.run() } catch { return .failure(.init("activation helper failed to launch: \(error.localizedDescription)")) }
            let fields = (String(data: output.fileHandleForReading.availableData, encoding: .utf8) ?? "")
                .split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            guard fields.count == 4 else {
                process.terminate()
                process.waitUntilExit()
                return .failure(.init("activation helper did not report its windows"))
            }
            return .success(ActivationHelperProcess(process: process, input: input, pid: pid_t(fields[0]), windows: Array(fields[1...])))
        }

        private init(process: Process, input: Pipe, pid: pid_t, windows: [Int]) {
            self.process = process
            self.input = input
            self.pid = pid
            self.windows = windows
        }

        func send(_ command: String) { input.fileHandleForWriting.write(Data("\(command)\n".utf8)) }

        func terminate() {
            process.terminate()
            process.waitUntilExit()
        }
    }

    struct SmokeFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Uses real windows of another process and changes the active application, so it runs in its own
    /// harness process (`--activation-only`) that is not the active app when it launches the helper.
    static func runFrontWindowOnlyActivationChecks() -> [String] {
        let helper: ActivationHelperProcess
        switch ActivationHelperProcess.launch() {
        case .success(let launched): helper = launched
        case .failure(let failure): return [failure.message]
        }
        defer { helper.terminate() }
        let helperPID = helper.pid
        let helperWindows = helper.windows
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
        helper.send("raise 2")
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

    /// A tab whose window stops answering must not take over another workspace's window of the same app,
    /// which would leave both workspaces managing it and make it impossible to move.
    static func runReresolveChecks() -> [String] {
        var failures: [String] = []
        let (renamed, renameModel) = fixture(registering: [0], windowCount: 1)
        renameModel.titles[0] = "Updated title"
        renamed.pruneClosedWindows()
        if renamed.windows[0].candidate.title != "Updated title" || renameModel.changeCount != 1 {
            failures.append("a changed window title was not reflected in the session")
        }
        renamed.pruneClosedWindows()
        if renameModel.changeCount != 1 {
            failures.append("an unchanged window title triggered another session update")
        }
        renameModel.titles[0] = ""
        renamed.pruneClosedWindows()
        if !renamed.windows[0].candidate.title.isEmpty || renameModel.changeCount != 2 {
            failures.append("a removed window title was not reflected in the session")
        }

        let model = Model(windowCount: 3)
        let (first, _) = fixture(registering: [0], sharedModel: model)
        let (second, _) = fixture(registering: [1], sharedModel: model)
        first.isClaimedElsewhere = { second.contains($0) }
        second.isClaimedElsewhere = { first.contains($0) }
        func manages(_ session: WindowSession, _ index: Int) -> Bool {
            session.windows.contains { CFEqual($0.candidate.element, model.windows[index].element) }
        }

        // A busy app (e.g. VS Code timing out) still owns the window.
        model.listedWindows = [1, 2]
        model.probeErrors = [0: .cannotComplete]
        first.pruneClosedWindows()
        first.pruneClosedWindows()
        if !manages(first, 0) || first.windows.count != 1 {
            failures.append("a tab whose window was busy was re-bound or dropped")
        }

        // The window closed while the app's only other window belongs to another workspace.
        model.listedWindows = [1]
        model.probeErrors = [0: .invalidUIElement]
        first.pruneClosedWindows()
        if manages(first, 1) {
            failures.append("a tab whose window closed took over another workspace's window")
        }
        first.pruneClosedWindows()
        if !first.windows.isEmpty {
            failures.append("a tab whose window closed was not removed")
        }
        if !second.transferWindow(second.windows[0].id, to: first) || !manages(first, 1) || !second.windows.isEmpty {
            failures.append("a window could not be moved to a workspace whose closed tab had the same app")
        }

        // A stale element of a window that still exists is found again among unclaimed windows.
        let (third, _) = fixture(registering: [0], sharedModel: model)
        third.isClaimedElsewhere = { first.contains($0) }
        model.listedWindows = [1, 2]
        third.pruneClosedWindows()
        if !manages(third, 2) || third.windows.count != 1 {
            failures.append("a tab with a stale element was not re-resolved to its app's unclaimed window")
        }
        return failures
    }

    static func runTabTransferRevealChecks() -> [String] {
        let model = Model(windowCount: 3)
        let source = WorkspaceController(name: "Reveal source", access: access(for: model))
        let destination = WorkspaceController(name: "Reveal destination", access: access(for: model))
        defer {
            for controller in [source, destination] {
                controller.hideTabTransferTargets()
                controller.quitting = true
                controller.window.orderOut(nil)
            }
        }
        guard let visible = NSScreen.main?.visibleFrame,
              let chrome = source.window.contentView as? WorkspaceChromeView,
              let destinationChrome = destination.window.contentView as? WorkspaceChromeView else {
            return ["tab reveal fixture could not find its screen or content"]
        }
        source.window.setFrame(NSRect(x: visible.minX + 40, y: visible.minY + 40, width: 700, height: 500), display: true)
        destination.window.setFrame(source.window.frame.offsetBy(dx: 400, dy: 100), display: true)
        source.session.add(WindowCandidate(element: model.windows[0].element, application: .current, title: "Moved"))
        source.session.add(WindowCandidate(element: model.windows[1].element, application: .current, title: "Stays"))
        destination.session.add(WindowCandidate(element: model.windows[2].element, application: .current, title: "Destination"))
        destination.window.orderFrontRegardless()
        source.window.orderFrontRegardless()
        chrome.layoutSubtreeIfNeeded()
        destinationChrome.layoutSubtreeIfNeeded()
        let sourceFrame = source.window.frame
        let destinationFrame = destination.window.frame
        let sourceOnly = NSPoint(x: sourceFrame.minX + 60, y: sourceFrame.minY + 60)
        let destinationOnly = NSPoint(x: destinationFrame.maxX - 60, y: destinationFrame.midY)
        let overlap = NSPoint(x: destinationFrame.minX + 60, y: destinationFrame.minY + 60)
        guard !destinationFrame.contains(sourceOnly), !sourceFrame.contains(destinationOnly),
              sourceFrame.contains(overlap), destinationFrame.contains(overlap), !source.tabRowContains(overlap) else {
            return ["tab reveal fixture could not place overlapping workspaces: \(sourceFrame) \(destinationFrame)"]
        }

        let transfer = WorkspaceTabTransfer { [source, destination] }
        var transfers: [(WorkspaceController, WorkspaceController)] = []
        transfer.onTransfer = { transfers.append(($0, $1)) }
        transfer.attach(source)
        transfer.attach(destination)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var button: WorkspaceTabButton?
        func begin() {
            chrome.layoutSubtreeIfNeeded()
            button = (chrome.tabs.arrangedSubviews.first as? WorkspaceTabGroup)?.arrangedSubviews.first as? WorkspaceTabButton
            let token = UUID().uuidString
            board.clearContents()
            board.setString(token, forType: workspaceTabDragType)
            button?.onDragBegin?(button!, token, NSPoint(x: 10, y: 10), NSImage(size: NSSize(width: 100, height: 28)))
        }
        func move(_ point: NSPoint) { button?.onDragMove?(board, point) }
        func end(_ point: NSPoint, cancelled: Bool) { button?.onDragEnd?(board, point, cancelled) }
        func inFront(_ front: WorkspaceController, of back: WorkspaceController) -> Bool {
            let order = NSApp.orderedWindows
            guard let first = order.firstIndex(where: { $0 === front.window }),
                  let second = order.firstIndex(where: { $0 === back.window }) else { return false }
            return first < second
        }
        func modelIndex(of id: UUID?, in session: WindowSession) -> Int? {
            guard let window = session.windows.first(where: { $0.id == id }) else { return nil }
            return model.windows.firstIndex { CFEqual($0.element, window.candidate.element) }
        }
        let sourceSelected = modelIndex(of: source.session.selectedID, in: source.session)
        var failures: [String] = []

        begin()
        guard button != nil, transfer.isActive else { return ["tab reveal fixture could not start a tab drag"] }
        move(overlap)
        if !model.focusedWindows.isEmpty || !inFront(source, of: destination) ||
            destinationChrome.windowDropPanel?.isVisible == true {
            failures.append("a workspace hidden behind the tab's own workspace took the tab where they overlap: " +
                "focused \(model.focusedWindows), source front \(inFront(source, of: destination)), " +
                "marker \(destinationChrome.windowDropPanel?.isVisible == true)")
        }
        move(destinationOnly)
        if !inFront(destination, of: source) || model.focusedWindows != [2] ||
            destinationChrome.windowDropPanel?.isVisible != true {
            failures.append("a tab dragged over a workspace behind did not bring it and its windows forward: " +
                "front \(inFront(destination, of: source)), focused \(model.focusedWindows)")
        }
        move(overlap)
        if !inFront(destination, of: source) || model.focusedWindows != [2] ||
            destinationChrome.windowDropPanel?.isVisible != true {
            failures.append("the workspace brought forward lost the overlap to the one behind it: \(model.focusedWindows)")
        }
        move(sourceOnly)
        if !inFront(source, of: destination) || model.focusedWindows.count < 2 || model.focusedWindows.last != sourceSelected {
            failures.append("moving the tab back did not bring its own workspace forward: \(model.focusedWindows)")
        }
        move(destinationOnly)
        model.focusedWindows.removeAll()
        end(destinationOnly, cancelled: true)
        if transfer.isActive || !inFront(source, of: destination) || model.focusedWindows.last != sourceSelected ||
            !transfers.isEmpty || source.session.windows.count != 2 || destinationChrome.windowDropPanel?.isVisible == true {
            failures.append("a cancelled tab drag left the workspace it passed over in front: \(model.focusedWindows)")
        }

        model.focusedWindows.removeAll()
        begin()
        move(destinationOnly)
        end(destinationOnly, cancelled: false)
        if transfer.isActive || transfers.count != 1 || transfers.first?.0 !== source || transfers.first?.1 !== destination ||
            modelIndex(of: destination.session.selectedID, in: destination.session) != 0 || source.session.windows.count != 1 {
            failures.append("dropping a tab on another workspace did not move it there")
        }
        if !inFront(destination, of: source) || model.focusedWindows.last != 0 {
            failures.append("the workspace that received a tab was not left in front with the moved window: \(model.focusedWindows)")
        }
        return failures
    }

    /// A drop does not activate WindowDock, which would bring every workspace forward; it only makes the destination
    /// key. Whether or not WindowDock was active at the drop, the destination must be the workspace that comes back
    /// when WindowDock is activated again, e.g. with Cmd+Tab. Changes the active application, so it runs in the
    /// `--activation-only` harness.
    static func runTabTransferKeyChecks() -> [String] {
        let model = Model(windowCount: 4)
        let source = WorkspaceController(name: "Key source", access: access(for: model))
        let destination = WorkspaceController(name: "Key destination", access: access(for: model))
        defer {
            for controller in [source, destination] {
                controller.hideTabTransferTargets()
                controller.quitting = true
                controller.window.orderOut(nil)
            }
        }
        func settle(_ seconds: TimeInterval = 0.5, until condition: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline {
                if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            }
        }
        guard let visible = NSScreen.main?.visibleFrame,
              let chrome = source.window.contentView as? WorkspaceChromeView else {
            return ["tab drop key fixture could not find its screen or content"]
        }
        source.window.setFrame(NSRect(x: visible.minX + 40, y: visible.minY + 40, width: 500, height: 400), display: true)
        destination.window.setFrame(source.window.frame.offsetBy(dx: 560, dy: 0), display: true)
        source.session.add((0..<3).map {
            WindowCandidate(element: model.windows[$0].element, application: .current, title: "Moved \($0)")
        })
        destination.session.add(WindowCandidate(element: model.windows[3].element, application: .current, title: "Destination"))
        let dropPoint = NSPoint(x: destination.window.frame.midX, y: destination.window.frame.midY)
        let transfer = WorkspaceTabTransfer { [source, destination] }
        transfer.attach(source)
        transfer.attach(destination)
        let activation = WorkspaceActivation { [source, destination] }
        activation.latestClick = { nil }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let helper: ActivationHelperProcess
        switch ActivationHelperProcess.launch() {
        case .success(let launched): helper = launched
        case .failure(let failure): return [failure.message]
        }
        defer { helper.terminate() }
        settle(0.5)
        let pid = ProcessInfo.processInfo.processIdentifier
        // NSApp.deactivate() does not give up activation, so the helper takes it.
        func setActive(_ active: Bool) -> Bool {
            if active, !NSApp.isActive {
                helper.send("yield \(pid)")
                settle(0.3)
                NSApp.activate(ignoringOtherApps: true)
                settle(2) { NSApp.isActive }
            } else if !active, NSApp.isActive {
                _ = WindowAccess.activateFrontWindowOnly(helper.pid)
                settle(2) { !NSApp.isActive }
            }
            return NSApp.isActive == active
        }
        func inFront(_ front: WorkspaceController, of back: WorkspaceController) -> Bool {
            let order = NSApp.orderedWindows
            guard let first = order.firstIndex(where: { $0 === front.window }),
                  let second = order.firstIndex(where: { $0 === back.window }) else { return false }
            return first < second
        }

        var failures: [String] = []
        for activeAtDrop in [true, false] {
            let state = activeAtDrop ? "active" : "inactive"
            guard setActive(true) else {
                failures.append("tab drop key fixture could not activate WindowDock")
                continue
            }
            destination.window.orderFrontRegardless()
            source.window.makeKeyAndOrderFront(nil)
            settle(2) { source.window.isKeyWindow }
            guard source.window.isKeyWindow, setActive(activeAtDrop) else {
                failures.append("tab drop key fixture could not make the source key while WindowDock was \(state)")
                continue
            }
            settle(0.3)
            chrome.layoutSubtreeIfNeeded()
            guard let button = (chrome.tabs.arrangedSubviews.first as? WorkspaceTabGroup)?
                .arrangedSubviews.first as? WorkspaceTabButton else {
                failures.append("tab drop key fixture could not find a tab to drag")
                continue
            }
            let count = source.session.windows.count
            let token = UUID().uuidString
            board.clearContents()
            board.setString(token, forType: workspaceTabDragType)
            button.onDragBegin?(button, token, NSPoint(x: 10, y: 10), NSImage(size: NSSize(width: 100, height: 28)))
            button.onDragMove?(board, dropPoint)
            button.onDragEnd?(board, dropPoint, false)
            guard source.session.windows.count == count - 1 else {
                failures.append("tab drop key fixture could not drop a tab while WindowDock was \(state)")
                continue
            }
            let operations = model.operations.count
            settle()
            if model.operations.dropFirst(operations).contains(where: { if case .raise = $0 { true } else { false } }) {
                failures.append("a tab dropped while WindowDock was \(state) raised the workspace again after its windows " +
                    "were handed focus, which can order the frame above them")
            }
            guard setActive(false), setActive(true) else {
                failures.append("tab drop key fixture could not switch WindowDock away and back")
                continue
            }
            activation.applicationDidBecomeActive()
            settle()
            if activation.activeController !== destination || !inFront(destination, of: source) {
                failures.append("after a tab was dropped while WindowDock was \(state), activating WindowDock again " +
                    "brought back the workspace the tab came from")
            }
        }
        return failures
    }

    /// Releasing a tab moves its window back to where it was. Its pane must stop showing through the workspace first,
    /// or what is behind the workspace shows there until the tab is gone; the other panes stay shown.
    private static func runRemovalApertureChecks() -> [String] {
        var failures: [String] = []
        func shownWhileRestoring(_ index: Int, in session: WindowSession, _ model: Model) -> (Bool, Set<UUID>?) {
            guard let id = session.windows.first(where: {
                CFEqual($0.candidate.element, model.windows[index].element)
            })?.id else { return (false, nil) }
            var shown: Set<UUID>?
            model.onSetFrame = { moved, frame in
                if moved == index, frame == model.windows[index].originalFrame { shown = Set(model.paneFrames.keys) }
            }
            defer { model.onSetFrame = nil }
            return (session.remove(id), shown)
        }

        let (single, singleModel) = fixture(registering: [0])
        guard singleModel.paneFrames.count == 1 else { return ["removal aperture fixture did not show its tab"] }
        let (removedLast, shownForLast) = shownWhileRestoring(0, in: single, singleModel)
        if !removedLast || shownForLast != [] || !singleModel.paneFrames.isEmpty {
            failures.append("removing the last tab moved its window away while the workspace still showed through to it: " +
                "\(shownForLast.map { "\($0.count) panes" } ?? "not restored")")
        }

        let (split, splitModel) = fixture(registering: [0, 1, 3])
        split.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        guard let left = split.cells[0], let right = split.cells[1], splitModel.paneFrames.count == 2,
              let leftIndex = splitModel.windows.firstIndex(where: { window in
                  split.windows.contains { $0.id == left && CFEqual($0.candidate.element, window.element) }
              }) else { return failures + ["removal aperture fixture could not show two panes"] }
        let (removedPane, shownForPane) = shownWhileRestoring(leftIndex, in: split, splitModel)
        if !removedPane || shownForPane != [right] {
            failures.append("removing a split pane's tab did not stop showing only that pane before moving its window: " +
                "\(shownForPane.map { $0.contains(left) ? "still shown" : "\($0.count) panes shown" } ?? "not restored")")
        }

        let (failing, failingModel) = fixture(registering: [0])
        failingModel.failedMinimizations.insert(0)
        let (removedFailing, _) = shownWhileRestoring(0, in: failing, failingModel)
        if removedFailing || failing.windows.count != 1 ||
            failing.selectedID.map({ failingModel.paneFrames[$0] }) != .some(failingModel.target) {
            failures.append("a tab whose window could not be restored was not shown in its pane again")
        }
        return failures
    }

    private static func runDisplacedWindowChecks() -> [String] {
        let (session, model) = fixture(registering: [0, 1, 3])
        session.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        func modelIndex(_ id: UUID?) -> Int? {
            guard let window = session.windows.first(where: { $0.id == id }) else { return nil }
            return model.windows.firstIndex { CFEqual($0.element, window.candidate.element) }
        }
        guard let left = modelIndex(session.cells[0]), let right = modelIndex(session.cells[1]),
              let hidden = [0, 1, 3].first(where: { $0 != left && $0 != right }),
              model.windows[left].frame == model.target, model.windows[right].frame == model.rightTarget
        else { return ["displaced window fixture could not show two panes"] }
        let fitted = model.windows.map(\.frame)
        var failures: [String] = []

        model.operations.removeAll()
        session.refitDisplacedWindows()
        if !model.operations.isEmpty {
            failures.append("refitting moved or raised windows although none had left its pane: \(model.operations)")
        }

        model.windows[left].frame = CGRect(x: 0, y: 25, width: 1440, height: 875)
        model.windows[hidden].frame.origin.x += 300
        model.operations.removeAll()
        session.refitDisplacedWindows()
        if model.windows[left].frame != fitted[left] || session.cells[0].flatMap({ model.paneFrames[$0] }) != fitted[left] {
            failures.append("a window maximized outside WindowDock was not fitted back into its pane: \(model.windows[left].frame)")
        }
        if model.windows[hidden].frame != fitted[hidden] {
            failures.append("a background tab's window moved outside WindowDock was not fitted back: \(model.windows[hidden].frame)")
        }
        if model.operations.contains(.resize(right)) || model.operations.contains(.move(right)) {
            failures.append("refitting moved a window that had stayed in its pane")
        }
        return failures
    }

    /// Windows maximized or made full screen while another app was active return to their panes once WindowDock is active.
    static func runActivationRefitChecks() -> [String] {
        let model = Model(windowCount: 2)
        let controller = WorkspaceController(name: "Activation refit", access: access(for: model))
        let window = controller.window
        defer {
            controller.quitting = true
            window.orderOut(nil)
        }
        func settle(_ seconds: TimeInterval = 0.5, until condition: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline {
                if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            }
        }
        window.setFrame(NSRect(x: 160, y: 180, width: 900, height: 600), display: true)
        controller.session.setGrid(WorkspaceGridSize(columns: 2, rows: 1))
        controller.session.add(model.windows.map {
            WindowCandidate(element: $0.element, application: .current, title: "Refit probe")
        })
        controller.bringToFront()
        settle()
        guard NSApp.isActive, window.isKeyWindow else { return ["activation refit fixture did not become active and key"] }
        let fitted = model.windows.map(\.frame)
        let grid = controller.session.gridSize
        let activation = WorkspaceActivation(controllers: { [controller] })
        activation.latestClick = { nil }
        func raised(_ index: Int? = nil) -> Bool {
            model.operations.contains { operation in
                if case .raise(let raised) = operation { return index.map { $0 == raised } ?? true }
                return false
            }
        }
        var failures: [String] = []

        model.windows[0].frame = CGRect(x: 0, y: 25, width: 1440, height: 875)
        model.operations.removeAll()
        activation.applicationDidBecomeActive()
        settle { raised(0) }
        if model.windows[0].frame != fitted[0] {
            failures.append("a window maximized while another app was active stayed maximized when WindowDock became active: \(model.windows[0].frame)")
        }
        if model.operations.contains(.resize(1)) || model.operations.contains(.move(1)) {
            failures.append("activation moved a window that had stayed in its pane")
        }

        model.windows[1].fullScreen = true
        model.windows[1].frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        model.operations.removeAll()
        activation.applicationDidBecomeActive()
        settle(0.4)
        if model.fullScreenExits != [1] {
            failures.append("activation did not take a full-screen window out of full screen: \(model.fullScreenExits)")
        }
        if raised() {
            // Raising a full-screen window switches to its Space instead of showing it in its pane.
            failures.append("activation raised windows before the full-screen window had left full screen")
        }
        model.windows[1].fullScreen = false
        model.windows[1].frame = fitted[1].offsetBy(dx: 0, dy: 40)
        settle(2) { raised(1) }
        if model.windows[1].frame != fitted[1] || controller.session.gridSize != grid {
            failures.append("a window that left full screen was not fitted back into its pane: " +
                "\(model.windows[1].frame), grid \(controller.session.gridSize.columns)×\(controller.session.gridSize.rows)")
        }
        if !raised(1) {
            failures.append("the workspace's windows were not raised once the window had left full screen")
        }
        return failures
    }

    static func runChecks() -> [String] {
        var failures: [String] = []
        failures += runManyTabMoveChecks()
        failures += runRemovalApertureChecks()
        failures += runDisplacedWindowChecks()
        failures += runReresolveChecks()
        failures += runTabTransferRevealChecks()
        failures += runConstraintNoticeChecks()
        failures += runTransferChecks()
        failures += runRegisteredWindowDragChecks()
        failures += runExternalWindowDropChecks()
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
