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

    init(
        onFocusChange: @escaping @Sendable () -> Void,
        onWindowChange: @escaping @Sendable (AXUIElement) -> Void) {
        self.onFocusChange = onFocusChange
        self.onWindowChange = onWindowChange
    }
}

private func windowObserverCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let context = Unmanaged<WindowNotificationContext>.fromOpaque(refcon).takeUnretainedValue()
    if notification as String == kAXFocusedWindowChangedNotification {
        context.onFocusChange()
    } else {
        context.onWindowChange(element)
    }
}

/// Watches an app's focused window and its windows being moved, resized or minimized.
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
        onWindowChange: @escaping @Sendable (AXUIElement) -> Void) {
        let pid = application.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var createdObserver: AXObserver?
        let createError = AXObserverCreate(pid, windowObserverCallback, &createdObserver)
        guard createError == .success, let createdObserver else {
            WindowAccess.logger.debug("Could not observe windows for PID \(pid): \(createError.rawValue)")
            return nil
        }
        let context = WindowNotificationContext(onFocusChange: onFocusChange, onWindowChange: onWindowChange)
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

    /// Apps report minimizing for each window rather than for the whole app.
    func observeMinimizing(of windows: [AXUIElement]) {
        let notification = kAXWindowMiniaturizedNotification as CFString
        for element in minimizableWindows where !windows.contains(where: { CFEqual($0, element) }) {
            AXObserverRemoveNotification(observer, element, notification)
        }
        minimizableWindows.removeAll { element in !windows.contains { CFEqual($0, element) } }
        for element in windows where !minimizableWindows.contains(where: { CFEqual($0, element) }) {
            let error = AXObserverAddNotification(
                observer, element, notification, Unmanaged.passUnretained(context).toOpaque())
            guard error == .success || error == .notificationAlreadyRegistered else {
                WindowAccess.logger.debug("Could not observe minimizing of a window: \(error.rawValue)")
                continue
            }
            minimizableWindows.append(element)
        }
    }

    deinit {
        for notification in applicationNotifications {
            AXObserverRemoveNotification(observer, applicationElement, notification as CFString)
        }
        for element in minimizableWindows {
            AXObserverRemoveNotification(observer, element, kAXWindowMiniaturizedNotification as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
}

struct WindowAccessClient {
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
        guard try value(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole else { return nil }
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
