import AppKit
import ApplicationServices
import OSLog
import WindowDockCore

struct WindowAccessError: LocalizedError {
    let operation: String
    let code: AXError

    var errorDescription: String? {
        L("%@に失敗しました（Accessibility: %d）。権限や対象アプリの状態を確認してください。", operation, Int(code.rawValue))
    }
}

enum WindowAccess {
    static let logger = Logger(subsystem: "local.WindowDock", category: "Accessibility")

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func value(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef {
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
        guard error == .success, let result else {
            throw WindowAccessError(operation: L("%@の取得", attribute), code: error == .success ? .noValue : error)
        }
        return result
    }

    static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) throws {
        let error = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        guard error == .success else {
            throw WindowAccessError(operation: L("%@の変更", attribute), code: error)
        }
    }

    static func requireWritable(_ element: AXUIElement, _ attribute: String) throws {
        var writable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &writable)
        guard error == .success, writable.boolValue else {
            throw WindowAccessError(
                operation: L("%@の操作（このウィンドウは非対応）", attribute), code: error == .success ? .attributeUnsupported : error)
        }
    }

    static func frame(_ element: AXUIElement) throws -> CGRect {
        let position = try value(element, kAXPositionAttribute)
        let size = try value(element, kAXSizeAttribute)
        guard CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID()
        else {
            throw WindowAccessError(operation: L("ウィンドウ位置の取得"), code: .illegalArgument)
        }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
        else {
            throw WindowAccessError(operation: L("ウィンドウ位置の変換"), code: .illegalArgument)
        }
        return CGRect(origin: point, size: dimensions)
    }

    static func setPosition(_ element: AXUIElement, _ position: CGPoint) throws {
        var point = position
        guard let positionValue = AXValueCreate(.cgPoint, &point) else {
            throw WindowAccessError(operation: L("ウィンドウ位置の変換"), code: .illegalArgument)
        }
        try set(element, kAXPositionAttribute, positionValue)
    }

    static func setFrame(_ element: AXUIElement, _ frame: CGRect) throws {
        let application = try applicationElement(for: element)
        let enhancedUIAttribute = "AXEnhancedUserInterface"
        let enhancedUI: Bool?
        do {
            guard let value = try value(application, enhancedUIAttribute) as? Bool else {
                throw WindowAccessError(operation: L("拡張UI状態の取得"), code: .illegalArgument)
            }
            enhancedUI = value
        } catch let error as WindowAccessError
            where error.code == .attributeUnsupported || error.code == .noValue
        {
            enhancedUI = nil
        }
        guard enhancedUI == true else {
            try setFrameAttributes(element, frame)
            return
        }

        do {
            try setEnhancedUI(false, on: application, attribute: enhancedUIAttribute)
            try setFrameAttributes(element, frame)
        } catch {
            let frameError = error
            do {
                try setEnhancedUI(true, on: application, attribute: enhancedUIAttribute)
            } catch {
                logger
                    .error(
                        "Could not restore Enhanced UI after a failed frame change: \(error.localizedDescription, privacy: .public)")
            }
            throw frameError
        }
        try setEnhancedUI(true, on: application, attribute: enhancedUIAttribute)
    }

    private static func applicationElement(for element: AXUIElement) throws -> AXUIElement {
        var processIdentifier: pid_t = 0
        let error = AXUIElementGetPid(element, &processIdentifier)
        guard error == .success else {
            throw WindowAccessError(operation: L("対象アプリの取得"), code: error)
        }
        return AXUIElementCreateApplication(processIdentifier)
    }

    private static func setEnhancedUI(_ enabled: Bool, on application: AXUIElement, attribute: String) throws {
        let result = AXUIElementSetAttributeValue(
            application, attribute as CFString, enabled ? kCFBooleanTrue : kCFBooleanFalse)
        guard let actual = try WindowAccess.value(application, attribute) as? Bool, actual == enabled else {
            throw WindowAccessError(
                operation: L("拡張UI状態の変更"),
                code: result == .success ? .cannotComplete : result)
        }
    }

    private static func setFrameAttributes(_ element: AXUIElement, _ frame: CGRect) throws {
        var size = frame.size
        guard let sizeValue = AXValueCreate(.cgSize, &size) else {
            throw WindowAccessError(operation: L("ウィンドウサイズの変換"), code: .illegalArgument)
        }
        try setPosition(element, frame.origin)
        try set(element, kAXSizeAttribute, sizeValue)
        // Some applications adjust the origin when resizing at a screen edge.
        try setPosition(element, frame.origin)
    }

    static func isMinimized(_ element: AXUIElement) throws -> Bool {
        guard let minimized = try value(element, kAXMinimizedAttribute) as? Bool else {
            throw WindowAccessError(operation: L("最小化状態の取得"), code: .illegalArgument)
        }
        return minimized
    }

    @discardableResult
    static func minimize(_ element: AXUIElement, _ minimized: Bool) throws -> Bool {
        guard try isMinimized(element) != minimized else { return false }
        try set(element, kAXMinimizedAttribute, minimized ? kCFBooleanTrue : kCFBooleanFalse)
        return true
    }

    private static let fullScreenAttribute = "AXFullScreen"

    static func isFullScreen(_ element: AXUIElement) -> Bool {
        (try? value(element, fullScreenAttribute)) as? Bool == true
    }

    static func setFullScreen(_ element: AXUIElement, _ fullScreen: Bool) throws {
        try set(element, fullScreenAttribute, fullScreen ? kCFBooleanTrue : kCFBooleanFalse)
    }

    static func raise(_ element: AXUIElement) throws {
        let error = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        guard error == .success else {
            throw WindowAccessError(operation: L("ウィンドウの前面表示"), code: error)
        }
    }

    static func close(_ element: AXUIElement) throws {
        let button = try value(element, kAXCloseButtonAttribute)
        guard CFGetTypeID(button) == AXUIElementGetTypeID() else {
            throw WindowAccessError(operation: L("ウィンドウを閉じる"), code: .illegalArgument)
        }
        let result = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        guard result == .success else {
            throw WindowAccessError(operation: L("ウィンドウを閉じる"), code: result)
        }
    }

    /// Makes the window the focused one of its application and brings that application to the front
    /// without bringing its other windows forward.
    static func focus(_ element: AXUIElement, application: NSRunningApplication) throws {
        try focus(
            element, applicationElement: AXUIElementCreateApplication(application.processIdentifier),
            setAttribute: set, raiseWindow: raise,
            activateFrontWindowOnly: { activateFrontWindowOnly(application.processIdentifier) })
    }

    static func focus(
        _ element: AXUIElement, applicationElement: AXUIElement,
        setAttribute: (AXUIElement, String, CFTypeRef) throws -> Void,
        raiseWindow: (AXUIElement) throws -> Void,
        activateFrontWindowOnly: () -> Bool) throws {
        try? setAttribute(element, kAXMainAttribute, kCFBooleanTrue)
        try? setAttribute(element, kAXFocusedAttribute, kCFBooleanTrue)
        // Front-window-only activation brings forward the app's frontmost window, so that must be the target.
        try raiseWindow(element)
        if !activateFrontWindowOnly() {
            // AXFrontmost also activates across apps, but brings every window of the app forward.
            try setAttribute(applicationElement, kAXFrontmostAttribute, kCFBooleanTrue)
        }
        try raiseWindow(element)
    }

    private typealias GetProcessForPIDFunction =
        @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcessWithOptionsFunction =
        @convention(c) (UnsafePointer<ProcessSerialNumber>, OptionBits) -> OSStatus

    // These Process Manager functions still ship in ApplicationServices but are unavailable to Swift.
    private static let processManager: (GetProcessForPIDFunction, SetFrontProcessWithOptionsFunction)? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let getProcess = dlsym(handle, "GetProcessForPID"),
              let setFront = dlsym(handle, "SetFrontProcessWithOptions")
        else { return nil }
        return (
            unsafeBitCast(getProcess, to: GetProcessForPIDFunction.self),
            unsafeBitCast(setFront, to: SetFrontProcessWithOptionsFunction.self))
    }()

    /// Activates an application like clicking one of its windows: only its frontmost window comes forward.
    static func activateFrontWindowOnly(_ processIdentifier: pid_t) -> Bool {
        guard let (getProcess, setFront) = processManager else { return false }
        var process = ProcessSerialNumber()
        guard getProcess(processIdentifier, &process) == noErr else { return false }
        let frontWindowOnly: OptionBits = 1  // kSetFrontProcessFrontWindowOnly
        return setFront(&process, frontWindowOnly) == noErr
    }

    private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    // Private but long-standing HIServices function that maps an AX window to its WindowServer number.
    private static let getWindow: GetWindowFunction? = {
        guard let handle = dlopen(nil, RTLD_LAZY), let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(symbol, to: GetWindowFunction.self)
    }()

    /// The WindowServer number of an AX window. Unlike frames, it stays exact while the window is being dragged.
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        return getWindow(element, &id) == .success && id != 0 ? id : nil
    }
}

private final class WindowNotificationContext {
    let onFocusChange: @Sendable () -> Void
    let onWindowChange: @Sendable (AXUIElement) -> Void
    let onWindowRestore: @Sendable (AXUIElement) -> Void

    init(
        onFocusChange: @escaping @Sendable () -> Void,
        onWindowChange: @escaping @Sendable (AXUIElement) -> Void,
        onWindowRestore: @escaping @Sendable (AXUIElement) -> Void) {
        self.onFocusChange = onFocusChange
        self.onWindowChange = onWindowChange
        self.onWindowRestore = onWindowRestore
    }
}

private func windowObserverCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let context = Unmanaged<WindowNotificationContext>.fromOpaque(refcon).takeUnretainedValue()
    if notification as String == kAXFocusedWindowChangedNotification {
        context.onFocusChange()
    } else if notification as String == kAXWindowDeminiaturizedNotification {
        context.onWindowRestore(element)
    } else {
        context.onWindowChange(element)
    }
}

/// Watches an app's focused window and its windows being moved, resized, minimized or restored.
final class WindowEventObserver {
    private static let applicationNotifications = [
        kAXFocusedWindowChangedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
    ]
    private let observer: AXObserver
    private let applicationElement: AXUIElement
    private let context: WindowNotificationContext
    private let runLoopSource: CFRunLoopSource
    private let applicationNotifications: [String]
    private var minimizableWindows: [AXUIElement] = []

    /// The handlers are called on the main thread.
    init?(
        application: NSRunningApplication, onFocusChange: @escaping @Sendable () -> Void,
        onWindowChange: @escaping @Sendable (AXUIElement) -> Void,
        onWindowRestore: @escaping @Sendable (AXUIElement) -> Void) {
        let pid = application.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var createdObserver: AXObserver?
        let createError = AXObserverCreate(pid, windowObserverCallback, &createdObserver)
        guard createError == .success, let createdObserver else {
            WindowAccess.logger.debug("Could not observe windows for PID \(pid): \(createError.rawValue)")
            return nil
        }
        let context = WindowNotificationContext(
            onFocusChange: onFocusChange, onWindowChange: onWindowChange, onWindowRestore: onWindowRestore)
        let registered = Self.applicationNotifications.filter { notification in
            let error = AXObserverAddNotification(
                createdObserver, appElement, notification as CFString, Unmanaged.passUnretained(context).toOpaque())
            if error != .success {
                WindowAccess.logger.debug(
                    "Could not register \(notification, privacy: .public) for PID \(pid): \(error.rawValue)")
            }
            return error == .success
        }
        guard !registered.isEmpty else { return nil }
        let source = AXObserverGetRunLoopSource(createdObserver)
        observer = createdObserver
        applicationElement = appElement
        self.context = context
        applicationNotifications = registered
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private static let windowNotifications = [kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]

    /// Apps report minimizing and restoring for each window rather than for the whole app.
    func observeMinimizing(of windows: [AXUIElement]) {
        for element in minimizableWindows where !windows.contains(where: { CFEqual($0, element) }) {
            for notification in Self.windowNotifications {
                AXObserverRemoveNotification(observer, element, notification as CFString)
            }
        }
        minimizableWindows.removeAll { element in !windows.contains { CFEqual($0, element) } }
        for element in windows where !minimizableWindows.contains(where: { CFEqual($0, element) }) {
            let errors = Self.windowNotifications.map {
                AXObserverAddNotification(
                    observer, element, $0 as CFString, Unmanaged.passUnretained(context).toOpaque())
            }
            for error in errors where error != .success && error != .notificationAlreadyRegistered {
                WindowAccess.logger.debug("Could not observe minimizing of a window: \(error.rawValue)")
            }
            guard errors.contains(where: { $0 == .success || $0 == .notificationAlreadyRegistered }) else { continue }
            minimizableWindows.append(element)
        }
    }

    deinit {
        for notification in applicationNotifications {
            AXObserverRemoveNotification(observer, applicationElement, notification as CFString)
        }
        for element in minimizableWindows {
            for notification in Self.windowNotifications {
                AXObserverRemoveNotification(observer, element, notification as CFString)
            }
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
}

private final class WindowCreationContext {
    let onCreate: @Sendable (AXUIElement) -> Void
    init(onCreate: @escaping @Sendable (AXUIElement) -> Void) { self.onCreate = onCreate }
}

private func windowCreationCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<WindowCreationContext>.fromOpaque(refcon).takeUnretainedValue().onCreate(element)
}

/// Reports windows an app opens. Some apps report them late or never, so callers also rescan.
final class WindowCreationObserver {
    private let observer: AXObserver
    private let applicationElement: AXUIElement
    private let context: WindowCreationContext
    private let runLoopSource: CFRunLoopSource

    /// The handler is called on the main thread.
    init?(application: NSRunningApplication, onCreate: @escaping @Sendable (AXUIElement) -> Void) {
        let pid = application.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var createdObserver: AXObserver?
        let createError = AXObserverCreate(pid, windowCreationCallback, &createdObserver)
        guard createError == .success, let createdObserver else {
            WindowAccess.logger.debug("Could not observe new windows for PID \(pid): \(createError.rawValue)")
            return nil
        }
        let context = WindowCreationContext(onCreate: onCreate)
        let error = AXObserverAddNotification(
            createdObserver, appElement, kAXWindowCreatedNotification as CFString,
            Unmanaged.passUnretained(context).toOpaque())
        guard error == .success || error == .notificationAlreadyRegistered else {
            WindowAccess.logger.debug("Could not register window creation for PID \(pid): \(error.rawValue)")
            return nil
        }
        observer = createdObserver
        applicationElement = appElement
        self.context = context
        runLoopSource = AXObserverGetRunLoopSource(createdObserver)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }

    deinit {
        AXObserverRemoveNotification(observer, applicationElement, kAXWindowCreatedNotification as CFString)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
}

/// A window's Chromium tab strip, as Accessibility shows it.
enum BrowserWindowTabs: Equatable {
    case tabs([BrowserTabAudio])
    /// Not a Chromium browser window: another app's, or a browser's popup, DevTools or picture-in-picture window.
    case noTabStrip
    case gone
    /// The app didn't answer.
    case unavailable
}

/// Reads browser tabs for `AudioPlaybackMonitor`; tests replace it.
struct BrowserTabSource {
    /// One result per window in order, or nil if a drag interrupted the read. Calls back on the main thread.
    var read: ([AXUIElement], @escaping @MainActor @Sendable ([BrowserWindowTabs]?) -> Void) -> Void
    /// Delivers a token on the main thread. Releasing it stops the title-change callbacks.
    var observe: (pid_t, @escaping @MainActor @Sendable () -> Void,
                  @escaping @MainActor @Sendable (AnyObject?) -> Void) -> Void
    /// Drops what's remembered about the windows.
    var forget: ([AXUIElement]) -> Void

    static func accessibility() -> BrowserTabSource {
        let reader = BrowserTabStripReader()
        return BrowserTabSource(read: reader.read, observe: reader.observe, forget: reader.forget)
    }
}

/// Reads Chromium browsers' tab strips off the main thread, as a busy browser answers slowly. Finding a window's
/// strip takes a few dozen calls, so it's remembered; reading the tabs then takes about one call per tab.
final class BrowserTabStripReader: @unchecked Sendable {
    private enum Strip {
        case found(AXUIElement)
        case missing(since: TimeInterval)
    }

    private enum Search {
        case found(AXUIElement)
        case missing
        case gone
        case unavailable
    }

    /// A window may get a strip later, such as when it leaves full screen.
    private static let missingStripRecheck: TimeInterval = 10
    private let queue = DispatchQueue(label: "WindowDock.BrowserTabStrips")
    /// Only used on `queue`.
    private var strips: [AXUIElement: Strip] = [:]

    static func mouseDown() -> Bool { CGEventSource.buttonState(.combinedSessionState, button: .left) }

    private enum Pause: Error { case dragging }

    /// A drag can start after a read has already been queued or halfway through a crowded tab strip.
    private static func yieldToDrag() throws {
        if mouseDown() { throw Pause.dragging }
    }

    func read(_ windows: [AXUIElement], completion: @escaping @MainActor @Sendable ([BrowserWindowTabs]?) -> Void) {
        queue.async { [self] in
            do {
                let tabs = try windows.map(tabs(of:))
                Self.onMain { completion(tabs) }
            } catch Pause.dragging {
                Self.onMain { completion(nil) }
            } catch {
                WindowAccess.logger.error("Could not read browser tabs: \(error.localizedDescription)")
                Self.onMain { completion(Array(repeating: .unavailable, count: windows.count)) }
            }
        }
    }

    func observe(
        _ pid: pid_t, onChange: @escaping @MainActor @Sendable () -> Void,
        completion: @escaping @MainActor @Sendable (AnyObject?) -> Void) {
        queue.async { [queue] in
            let context = BrowserTabContext(onChange: onChange)
            let registration = BrowserTabObserver.register(pid: pid, context: context)
            Self.onMain {
                completion(registration.map { BrowserTabObserver($0, context: context, queue: queue) })
            }
        }
    }

    private static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        let runLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated { work() }
        }
        CFRunLoopWakeUp(runLoop)
    }

    func forget(_ windows: [AXUIElement]) {
        queue.async { [self] in
            for window in windows {
                strips[window] = nil
            }
        }
    }

    private func tabs(of window: AXUIElement) throws -> BrowserWindowTabs {
        try Self.yieldToDrag()
        let now = ProcessInfo.processInfo.systemUptime
        switch strips[window] {
        case let .found(strip):
            if let tabs = try Self.tabs(in: strip), !tabs.isEmpty { return .tabs(tabs) }
        case let .missing(since) where now - since < Self.missingStripRecheck:
            return .noTabStrip
        default:
            break
        }
        strips[window] = nil
        switch try Self.findStrip(in: window) {
        case let .found(strip):
            guard let tabs = try Self.tabs(in: strip) else { return .unavailable }
            // Safari's tab strip, for one, has no Chromium tabs.
            guard !tabs.isEmpty else {
                strips[window] = .missing(since: now)
                return .noTabStrip
            }
            strips[window] = .found(strip)
            return .tabs(tabs)
        case .missing:
            strips[window] = .missing(since: now)
            return .noTabStrip
        case .gone:
            return .gone
        case .unavailable:
            return .unavailable
        }
    }

    /// Searches the window's groups for a tab group. Chrome names its views in AXDOMClassList; groups named after
    /// tabs are searched first, which reaches the strip in a few calls without listing the page's contents.
    private static func findStrip(in window: AXUIElement) throws -> Search {
        var frontier: [(element: AXUIElement, depth: Int, preferred: Bool)] = [(window, 0, true)]
        var calls = 0
        while calls < 200, let next = frontier.firstIndex(where: \.preferred) ?? frontier.indices.first {
            let node = frontier.remove(at: next)
            let (error, found) = values(of: node.element, [kAXChildrenAttribute])
            calls += 1
            if node.depth == 0, error == .invalidUIElement { return .gone }
            if error == .cannotComplete { return .unavailable }
            for child in found.first.flatMap({ $0 as? [AXUIElement] }) ?? [] {
                try yieldToDrag()
                let (error, info) = values(of: child, [kAXRoleAttribute, "AXDOMClassList"])
                calls += 1
                if error == .cannotComplete { return .unavailable }
                guard error == .success else { continue }
                let role = info[0] as? String
                if role == kAXTabGroupRole { return .found(child) }
                guard role == kAXGroupRole, node.depth < 12 else { continue }
                let classes = info[1] as? [String] ?? []
                frontier.append((child, node.depth + 1, classes.contains { $0.contains("Tab") }))
            }
        }
        return .missing
    }

    /// The Chromium tabs in a tab group, or nil if it can't be read.
    private static func tabs(in strip: AXUIElement) throws -> [BrowserTabAudio]? {
        let (error, found) = values(of: strip, [kAXChildrenAttribute])
        guard error == .success else { return nil }
        var tabs: [BrowserTabAudio] = []
        for element in found[0] as? [AXUIElement] ?? [] {
            try yieldToDrag()
            let (error, tab) = values(
                of: element,
                [
                    kAXSubroleAttribute,
                    "AXDOMClassList",
                    kAXTitleAttribute,
                    kAXDescriptionAttribute,
                    kAXChildrenAttribute
                ])
            if error == .cannotComplete { return nil }
            guard error == .success, tab[0] as? String == "AXTabButton",
                  (tab[1] as? [String])?.contains("Tab") == true
            else { continue }
            let title = tab[2] as? String ?? ""
            tabs.append(BrowserTabAudio(name: title.isEmpty ? tab[3] as? String ?? "" : title) {
                // Chrome shows this button only while the tab has an alert; narrow tabs may hide it.
                (tab[4] as? [AXUIElement] ?? []).contains { child in
                    let classes = values(of: child, ["AXDOMClassList"]).values.first.flatMap { $0 as? [String] }
                    return classes?.contains("AlertIndicatorButton") == true
                }
            })
        }
        return tabs
    }

    /// Reads attributes in one call; those the element lacks are nil. The error is the element's, such as
    /// `.invalidUIElement` once it's gone or `.cannotComplete` when the app doesn't answer.
    private static func values(
        of element: AXUIElement, _ attributes: [String]) -> (error: AXError, values: [CFTypeRef?]) {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var result: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &result)
        guard error == .success, let values = result as? [CFTypeRef], values.count == attributes.count else {
            return (error == .success ? .failure : error, [])
        }
        var elementError = AXError.success
        let found = values.map { value -> CFTypeRef? in
            guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError else {
                return value
            }
            var attributeError = AXError.success
            if AXValueGetValue(value as! AXValue, .axError, &attributeError),
               attributeError == .invalidUIElement || attributeError == .cannotComplete {
                elementError = attributeError
            }
            return nil
        }
        return (elementError, found)
    }
}

private final class BrowserTabContext {
    let onChange: @MainActor @Sendable () -> Void
    init(onChange: @escaping @MainActor @Sendable () -> Void) { self.onChange = onChange }
}

private func browserTabCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let context = Unmanaged<BrowserTabContext>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { context.onChange() }
}

/// Reports renamed elements of an app. Chrome renames a tab when it starts or stops playing or gets another alert, and
/// renames the window when its tabs change.
private final class BrowserTabObserver {
    typealias Registration = (observer: AXObserver, app: AXUIElement)
    private let observer: AXObserver
    private let applicationElement: AXUIElement
    private let context: BrowserTabContext
    private let queue: DispatchQueue

    static func register(pid: pid_t, context: BrowserTabContext) -> Registration? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var createdObserver: AXObserver?
        let createError = AXObserverCreate(pid, browserTabCallback, &createdObserver)
        guard createError == .success, let createdObserver else {
            WindowAccess.logger.debug("Could not observe tabs for PID \(pid): \(createError.rawValue)")
            return nil
        }
        let error = AXObserverAddNotification(
            createdObserver, appElement, kAXTitleChangedNotification as CFString,
            Unmanaged.passUnretained(context).toOpaque())
        guard error == .success || error == .notificationAlreadyRegistered else {
            WindowAccess.logger.debug("Could not register title changes for PID \(pid): \(error.rawValue)")
            return nil
        }
        return (createdObserver, appElement)
    }

    init(_ registration: Registration, context: BrowserTabContext, queue: DispatchQueue) {
        observer = registration.observer
        applicationElement = registration.app
        self.context = context
        self.queue = queue
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        queue.async { [observer, applicationElement, context] in
            withExtendedLifetime(context) {
                _ = AXObserverRemoveNotification(observer, applicationElement, kAXTitleChangedNotification as CFString)
            }
        }
    }
}

struct WindowAccessClient {
    var isTrusted: () -> Bool = { WindowAccess.isTrusted }
    var requestPermission: () -> Void = WindowAccess.requestPermission
    var scan: () -> WindowScan = WindowAccess.scan
    var requireWritable: (AXUIElement, String) throws -> Void = WindowAccess.requireWritable
    var frame: (AXUIElement) throws -> CGRect = WindowAccess.frame
    var setFrame: (AXUIElement, CGRect) throws -> Void = WindowAccess.setFrame
    var setPosition: (AXUIElement, CGPoint) throws -> Void = WindowAccess.setPosition
    var isMinimized: (AXUIElement) throws -> Bool = WindowAccess.isMinimized
    var minimize: (AXUIElement, Bool) throws -> Bool = WindowAccess.minimize
    var isFullScreen: (AXUIElement) -> Bool = WindowAccess.isFullScreen
    var setFullScreen: (AXUIElement, Bool) throws -> Void = WindowAccess.setFullScreen
    var raise: (AXUIElement) throws -> Void = WindowAccess.raise
    var close: (AXUIElement) throws -> Void = WindowAccess.close
    var windowID: (AXUIElement) -> CGWindowID? = WindowAccess.windowID(of:)
    var windowElements: (NSRunningApplication) -> [AXUIElement]? = WindowAccess.windowElements
    var focus: (AXUIElement, NSRunningApplication) throws -> Void = WindowAccess.focus
    /// Reads the title while checking whether the element is still available.
    var probe: (AXUIElement) -> WindowProbeResult = WindowAccess.probe
    var applicationWindows: (NSRunningApplication) -> [WindowCandidate]? = WindowAccess.applicationWindows
    var requestNewWindow: (NSRunningApplication) async throws -> Void = WindowAccess.requestNewWindow
    var allWindowIDs: (NSRunningApplication) -> [CGWindowID]? = WindowAccess.allWindowIDs(of:)
    /// Returns an object that keeps reporting the app's new windows until it's released, or nil if that failed.
    var observeWindowCreation: (NSRunningApplication, @escaping @Sendable (AXUIElement) -> Void) -> AnyObject? = {
        WindowCreationObserver(application: $0, onCreate: $1)
    }
}

struct WindowProbeResult {
    let error: AXError
    let title: String?
}

struct WindowCandidate {
    let element: AXUIElement
    let application: NSRunningApplication
    var title: String

    var label: String {
        "\(application.localizedName ?? "App") — \(title.isEmpty ? L("名称未設定") : title)"
    }

    func isSameWindow(as other: WindowCandidate) -> Bool {
        CFEqual(element, other.element)
    }
}

struct WindowScan {
    var windows: [WindowCandidate] = []
    var failedApplications: [String] = []
}

extension WindowAccess {
    static func windowServerWindows() throws -> [WindowServerWindow] {
        guard
            let entries = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            throw WindowAccessError(operation: L("移動中ウィンドウの検出"), code: .cannotComplete)
        }
        return entries.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  !frame.isEmpty, !frame.isInfinite
            else { return nil }
            return WindowServerWindow(id: id, processID: pid, frame: frame, layer: layer)
        }
    }

    /// Every normal-layer window the app owns, including minimized ones and ones on other Spaces that AX doesn't list.
    static func allWindowIDs(of application: NSRunningApplication) -> [CGWindowID]? {
        guard let entries = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let pid = application.processIdentifier
        return entries.compactMap { entry in
            guard entry[kCGWindowOwnerPID as String] as? pid_t == pid,
                  entry[kCGWindowLayer as String] as? Int == 0 else { return nil }
            return entry[kCGWindowNumber as String] as? CGWindowID
        }
    }

    /// The window a click at `point` (AppKit screen coordinates) would reach, skipping `excluded` windows. Unlike the
    /// WindowServer list, this passes through click-through overlays such as Accessibility Inspector's.
    static func windowReceivingClick(at point: NSPoint, excluding excluded: Set<CGWindowID>) -> CGWindowID? {
        var below = 0
        for _ in 0 ... excluded.count {
            let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: below)
            guard number > 0 else { return nil }
            if !excluded.contains(CGWindowID(number)) { return CGWindowID(number) }
            below = number
        }
        return nil
    }

    static func candidate(matching moved: WindowServerWindow) throws -> WindowCandidate {
        guard let app = NSRunningApplication(processIdentifier: moved.processID), !app.isTerminated else {
            throw WindowAccessError(operation: L("移動したウィンドウのアプリの取得"), code: .invalidUIElement)
        }
        let application = AXUIElementCreateApplication(moved.processID)
        AXUIElementSetMessagingTimeout(application, 0.3)
        guard let windows = try value(application, kAXWindowsAttribute) as? [AXUIElement] else {
            throw WindowAccessError(operation: L("移動したウィンドウの一覧取得"), code: .illegalArgument)
        }
        // Frames can lag behind the WindowServer, and same-sized windows of one app can share a frame.
        if let identified = windows.first(where: { windowID(of: $0) == moved.id }),
           let candidate = try? candidate(identified, application: app)
        {
            return candidate
        }
        var matches: [WindowCandidate] = []
        var failures: [WindowAccessError] = []
        for window in windows {
            do {
                guard let candidate = try candidate(window, application: app),
                      try !isMinimized(window),
                      WindowGeometry.fits(try frame(window), requested: moved.frame)
                else { continue }
                matches.append(candidate)
            } catch let error as WindowAccessError {
                logger.debug("Window drop candidate unavailable: \(error.localizedDescription, privacy: .public)")
                failures.append(error)
            }
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            let focused = try value(application, kAXFocusedWindowAttribute)
            if let match = matches.first(where: { CFEqual($0.element, focused) }) { return match }
        }
        if matches.isEmpty, let failure = failures.first { throw failure }
        throw WindowAccessError(operation: L("移動した通常ウィンドウの特定（「＋」から追加してください）"), code: .noValue)
    }

    static func probe(_ element: AXUIElement) -> WindowProbeResult {
        var title: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        let currentTitle =
            error == .success || error == .noValue || error == .attributeUnsupported
                ? title as? String ?? ""
                : nil
        return WindowProbeResult(error: error, title: currentTitle)
    }

    static func windowElements(_ application: NSRunningApplication) -> [AXUIElement]? {
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        return try? value(element, kAXWindowsAttribute) as? [AXUIElement]
    }

    static func focusedWindow(_ application: NSRunningApplication) -> AXUIElement? {
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard let focused = try? value(element, kAXFocusedWindowAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let window: AXUIElement = focused as! AXUIElement
        return window
    }

    /// The standard windows of an application, or nil when they cannot be listed.
    static func applicationWindows(_ application: NSRunningApplication) -> [WindowCandidate]? {
        windowElements(application)?.compactMap { try? candidate($0, application: application) }
    }

    /// Press the target process's menu item, without activating its previous window or sending a global keystroke.
    static func requestNewWindow(_ app: NSRunningApplication) async throws {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        let bar = try value(element, kAXMenuBarAttribute)
        guard CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let menus = try value(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]
        else { throw WindowAccessError(operation: L("新規ウィンドウの作成"), code: .noValue) }
        // The standard shortcut is language independent for these apps. Don't execute an unrelated ⌘N
        // (e.g. New Playlist) in an unknown app.
        let standardShortcut = ["com.apple.finder", "org.mozilla.firefox", "com.google.Chrome", "com.mitchellh.ghostty"]
            .contains(app.bundleIdentifier ?? "")
        let titles: Set<String> = [
            "New Window", "New Finder Window", "新規ウインドウ", "新規ウィンドウ", "新しいウィンドウ", "新規Finderウインドウ",
            "新建窗口", "新建访达窗口", "새로운 윈도우", "새 창", "Nueva ventana", "Nueva ventana del Finder",
        ]
        var shortcut: AXUIElement?
        var named: AXUIElement?
        search: for top in menus {
            try Task.checkCancellation()
            guard let submenus = try? value(top, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for submenu in submenus {
                guard let items = try? value(submenu, kAXChildrenAttribute) as? [AXUIElement] else { continue }
                for item in items {
                    if let title = try? value(item, kAXTitleAttribute) as? String, titles.contains(title) {
                        named = item
                        break search
                    }
                    if standardShortcut, shortcut == nil,
                       (try? value(item, kAXMenuItemCmdCharAttribute) as? String)?.lowercased() == "n",
                       (try? value(item, kAXMenuItemCmdModifiersAttribute) as? Int) == 0 {
                        shortcut = item
                    }
                }
            }
        }
        guard let item = named ?? shortcut, try value(item, kAXEnabledAttribute) as? Bool == true else {
            throw WindowAccessError(operation: L("「新規ウィンドウ」メニューの取得"), code: .actionUnsupported)
        }
        try Task.checkCancellation()
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        // Some apps time out after accepting the action; poll for the result rather than issuing it twice.
        guard result == .success || result == .cannotComplete else {
            throw WindowAccessError(operation: L("新規ウィンドウの作成"), code: result)
        }
    }

    /// Picks the live window for a cached element that went stale (e.g. after a login-window round trip).
    /// Windows that any workspace already manages are never taken, even when they are the app's only other window.
    static func reresolve(
        _ stale: WindowCandidate, among windows: [WindowCandidate],
        isClaimed: (WindowCandidate) -> Bool) -> WindowCandidate? {
        let unclaimed = windows.filter { !isClaimed($0) }
        let titled = unclaimed.filter { $0.title == stale.title }
        if titled.count == 1 { return titled[0] }
        return titled.isEmpty && unclaimed.count == 1 ? unclaimed[0] : nil
    }

    private static func candidate(_ window: AXUIElement, application: NSRunningApplication) throws -> WindowCandidate? {
        // Finder includes its desktop scroll area in AXWindows. No subrole means it isn't a standard window.
        do {
            guard try value(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole else { return nil }
        } catch let error as WindowAccessError where error.code == .noValue || error.code == .attributeUnsupported {
            return nil
        }
        var title: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        guard result == .success || result == .noValue || result == .attributeUnsupported else {
            throw WindowAccessError(operation: L("タイトルの取得"), code: result)
        }
        return WindowCandidate(element: window, application: application, title: title as? String ?? "")
    }

    static func scan() -> WindowScan {
        var scan = WindowScan()
        for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular && app.processIdentifier != ProcessInfo.processInfo
            .processIdentifier {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.3)
            do {
                guard let windows = try value(application, kAXWindowsAttribute) as? [AXUIElement] else {
                    throw WindowAccessError(operation: L("ウィンドウ一覧の変換"), code: .illegalArgument)
                }
                for window in windows {
                    if let candidate = try candidate(window, application: app) { scan.windows.append(candidate) }
                }
            } catch {
                logger.error(
                    "\(app.localizedName ?? "App", privacy: .public): \(error.localizedDescription, privacy: .public)")
                scan.failedApplications.append(app.localizedName ?? "App")
            }
        }
        scan.windows.sort { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        return scan
    }
}
