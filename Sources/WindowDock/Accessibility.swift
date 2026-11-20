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
            throw WindowAccessError(operation: L("%@の操作（このウィンドウは非対応）", attribute), code: error == .success ? .attributeUnsupported : error)
        }
    }

    static func frame(_ element: AXUIElement) throws -> CGRect {
        let position = try value(element, kAXPositionAttribute)
        let size = try value(element, kAXSizeAttribute)
        guard CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else {
            throw WindowAccessError(operation: L("ウィンドウ位置の取得"), code: .illegalArgument)
        }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else {
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

    static func raise(_ element: AXUIElement) throws {
        let error = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        guard error == .success else {
            throw WindowAccessError(operation: L("ウィンドウの前面表示"), code: error)
        }
    }

    /// Makes the window the focused one of its application and brings that application to the front.
    static func focus(_ element: AXUIElement, application: NSRunningApplication) throws {
        try? set(element, kAXMainAttribute, kCFBooleanTrue)
        try? set(element, kAXFocusedAttribute, kCFBooleanTrue)
        try raise(element)
        application.activate(options: [.activateIgnoringOtherApps])
    }
}

struct WindowAccessClient {
    var requireWritable: (AXUIElement, String) throws -> Void = WindowAccess.requireWritable
    var frame: (AXUIElement) throws -> CGRect = WindowAccess.frame
    var setFrame: (AXUIElement, CGRect) throws -> Void = WindowAccess.setFrame
    var setPosition: (AXUIElement, CGPoint) throws -> Void = WindowAccess.setPosition
    var isMinimized: (AXUIElement) throws -> Bool = WindowAccess.isMinimized
    var minimize: (AXUIElement, Bool) throws -> Bool = WindowAccess.minimize
    var raise: (AXUIElement) throws -> Void = WindowAccess.raise
    var focus: (AXUIElement, NSRunningApplication) throws -> Void = WindowAccess.focus
}

struct WindowCandidate {
    let element: AXUIElement
    let application: NSRunningApplication
    let title: String

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
        guard let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            throw WindowAccessError(operation: L("移動中ウィンドウの検出"), code: .cannotComplete)
        }
        return entries.compactMap { entry in
            guard entry[kCGWindowLayer as String] as? Int == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  !frame.isEmpty, !frame.isInfinite else { return nil }
            return WindowServerWindow(id: id, processID: pid, frame: frame)
        }
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
        var matches: [WindowCandidate] = []
        var failures: [WindowAccessError] = []
        for window in windows {
            do {
                guard let candidate = try candidate(window, application: app),
                      try !isMinimized(window),
                      WindowGeometry.fits(try frame(window), requested: moved.frame) else { continue }
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
        where app.activationPolicy == .regular && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
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
                logger.error("\(app.localizedName ?? "App", privacy: .public): \(error.localizedDescription, privacy: .public)")
                scan.failedApplications.append(app.localizedName ?? "App")
            }
        }
        scan.windows.sort { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        return scan
    }
}
