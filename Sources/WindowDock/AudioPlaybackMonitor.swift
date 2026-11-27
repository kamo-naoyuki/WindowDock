import ApplicationServices
import CoreAudio
import Darwin
import Foundation
import OSLog
import WindowDockCore

/// Tracks which applications are playing audio, for the speaker on their tabs. Core Audio reports audio per process,
/// so the windows of an application count as playing, except that a Chromium browser window plays only if one of its
/// tabs may be playing.
@MainActor
final class AudioPlaybackMonitor {
    static let shared = AudioPlaybackMonitor()
    static let didChange = Notification.Name("WindowDockAudioPlaybackDidChange")

    /// Applications playing audio, including those that stopped within the last moment.
    private(set) var audibleApplications: Set<pid_t> = []
    private var recent: RecentlyAudibleApplications
    private let playingApplications: () -> Set<pid_t>
    private let processes: CoreAudioProcesses?
    private let browserTabs: BrowserTabSource
    private let mouseDown: () -> Bool
    private static let tabReadDelay: TimeInterval = 0.25
    /// The windows asked about in each audible application.
    private var browsers: [pid_t: BrowserWindows] = [:]
    private var started = false
    private var refreshScheduled = false
    private var holdTimer: Timer?

    /// `playingApplications` replaces Core Audio in tests; call `refresh()` to report changes to its output.
    init(
        hold: TimeInterval = 2, playingApplications: (() -> Set<pid_t>)? = nil,
        browserTabs: BrowserTabSource? = nil,
        mouseDown: @escaping () -> Bool = BrowserTabStripReader.mouseDown) {
        recent = RecentlyAudibleApplications(hold: hold)
        if let playingApplications {
            processes = nil
            self.playingApplications = playingApplications
        } else {
            let processes = CoreAudioProcesses()
            self.processes = processes
            self.playingApplications = { processes.playingApplications() }
        }
        self.browserTabs = browserTabs ?? .accessibility()
        self.mouseDown = mouseDown
    }

    func start() {
        guard !started else { return }
        started = true
        processes?.observe { [weak self] in self?.scheduleRefresh() }
        refresh()
    }

    func refresh() {
        holdTimer?.invalidate()
        holdTimer = nil
        let now = ProcessInfo.processInfo.systemUptime
        let audible = recent.update(playing: playingApplications(), at: now)
        if let expiry = recent.nextExpiry {
            let timer = Timer(timeInterval: max(0.01, expiry - now), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
        }
        for (pid, browser) in browsers {
            if !audible.contains(pid) {
                untrack(pid)
            } else if case .unavailable = browser.observation {
                scheduleRead(of: pid, after: Self.tabReadDelay)
            } else if browser.tabs.values.contains(.unavailable) {
                scheduleRead(of: pid, after: Self.tabReadDelay)
            }
        }
        guard audible != audibleApplications else { return }
        audibleApplications = audible
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Whether the window may be playing audio: its application is, and if it's a Chromium browser window, one of its
    /// tabs is or shows another alert. A window doesn't count until its tabs have been read, so that the speaker
    /// doesn't appear on every window of a browser first.
    func isPlaying(_ window: WindowCandidate) -> Bool {
        let pid = window.application.processIdentifier
        guard audibleApplications.contains(pid) else { return false }
        let browser = browsers[pid] ?? track(pid)
        guard let tabs = browser.tabs[window.element] else {
            if browser.windows.insert(window.element).inserted { scheduleRead(of: pid, after: 0) }
            return false
        }
        return Self.plays(tabs)
    }

    fileprivate static func plays(_ tabs: BrowserWindowTabs) -> Bool {
        guard case let .tabs(tabs) = tabs else { return true }
        return tabs.contains { $0.mayBePlaying }
    }

    private func track(_ pid: pid_t) -> BrowserWindows {
        let browser = BrowserWindows()
        browsers[pid] = browser
        return browser
    }

    private func untrack(_ pid: pid_t) {
        guard let browser = browsers.removeValue(forKey: pid) else { return }
        browser.timer?.invalidate()
        browserTabs.forget(Array(browser.windows))
    }

    private func scheduleRead(of pid: pid_t, after delay: TimeInterval) {
        guard let browser = browsers[pid], !browser.windows.isEmpty else { return }
        guard !browser.reading else {
            browser.readAgain = true
            return
        }
        if let timer = browser.timer, timer.isValid, timer.fireDate.timeIntervalSinceNow <= delay { return }
        browser.timer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.read(pid) }
        }
        // Don't query a browser inside WindowDock's own event-tracking loop.
        RunLoop.main.add(timer, forMode: .default)
        browser.timer = timer
    }

    private func read(_ pid: pid_t) {
        guard let browser = browsers[pid] else { return }
        browser.timer = nil
        // A Chrome tab tear-off tracks the mouse in Chrome, not in our run loop.
        guard !mouseDown() else { return scheduleRead(of: pid, after: Self.tabReadDelay) }
        if case .notStarted = browser.observation {
            browser.observation = .pending
            browserTabs.observe(pid, { [weak self, weak browser] in
                guard let self, let browser, browsers[pid] === browser else { return }
                scheduleRead(of: pid, after: Self.tabReadDelay)
            }, { [weak browser] observer in
                browser?.observation = observer.map(BrowserWindows.Observation.active) ?? .unavailable
            })
        }
        browser.reading = true
        let windows = Array(browser.windows)
        browserTabs.read(windows) { [weak self, weak browser] tabs in
            guard let self, let browser, browsers[pid] === browser else { return }
            browser.reading = false
            guard let tabs, !mouseDown() else {
                browser.readAgain = false
                return scheduleRead(of: pid, after: Self.tabReadDelay)
            }
            apply(tabs, of: windows, to: browser, pid: pid)
        }
    }

    private func apply(_ tabs: [BrowserWindowTabs], of windows: [AXUIElement], to browser: BrowserWindows, pid: pid_t) {
        let playing = browser.playingWindows
        for (window, tabs) in zip(windows, tabs) {
            switch tabs {
            case .tabs, .noTabStrip:
                browser.tabs[window] = tabs
            case .gone:
                browser.windows.remove(window)
                browser.tabs[window] = nil
            case .unavailable:
                // Keep what was read before, or count the window as its application does.
                if browser.tabs[window] == nil { browser.tabs[window] = .unavailable }
            }
        }
        if browser.readAgain {
            browser.readAgain = false
            scheduleRead(of: pid, after: Self.tabReadDelay)
        } else if browser.tabs.values.contains(where: Self.showsOtherAlert) {
            // Chrome tells nothing when an alert icon finishes fading out.
            scheduleRead(of: pid, after: 1)
        }
        guard browser.playingWindows != playing else { return }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private static func showsOtherAlert(_ tabs: BrowserWindowTabs) -> Bool {
        guard case let .tabs(tabs) = tabs else { return false }
        return tabs.contains(.otherAlert)
    }

    /// Core Audio notifies several properties for one change; read them once.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

/// The windows asked about in an audible application, and their tabs once read.
@MainActor
private final class BrowserWindows {
    enum Observation {
        case notStarted, pending, active(AnyObject), unavailable
    }

    var windows = Set<AXUIElement>()
    var tabs: [AXUIElement: BrowserWindowTabs] = [:]
    var observation = Observation.notStarted
    var timer: Timer?
    var reading = false
    /// Tabs changed while they were being read.
    var readAgain = false

    var playingWindows: Set<AXUIElement> {
        Set(tabs.filter { AudioPlaybackMonitor.plays($0.value) }.keys)
    }
}

/// Core Audio's process objects, which older macOS versions lack; nothing counts as playing there. A process's output
/// state doesn't notify by itself, but its IsRunning and Devices properties do, so any notification from a process
/// triggers a full re-read.
@MainActor
private final class CoreAudioProcesses {
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private nonisolated static let logger = Logger(subsystem: "local.WindowDock", category: "AudioPlayback")
    private let queue = DispatchQueue(label: "WindowDock.CoreAudioProcesses")
    private var listener: AudioObjectPropertyListenerBlock?
    /// Process objects with a listener.
    private var observed = Set<AudioObjectID>()

    /// Calls `onChange` when a process connects to Core Audio, or starts or stops audio.
    func observe(_ onChange: @escaping @MainActor @Sendable () -> Void) {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        guard listener == nil, AudioObjectHasProperty(Self.system, &address) else { return }
        let listener = Self.listener(onChange)
        guard Self.succeeded(
            AudioObjectAddPropertyListenerBlock(Self.system, &address, queue, listener),
            operation: "observe process list", object: Self.system)
        else { return }
        self.listener = listener
    }

    /// Core Audio calls listeners on `queue`. Like AX observers, they deliver through the main run loop, which also
    /// runs inside nested event-tracking loops.
    private nonisolated static func listener(_ onChange: @escaping @MainActor @Sendable () -> Void)
        -> AudioObjectPropertyListenerBlock
    {
        { _, _ in
            let runLoop = CFRunLoopGetMain()
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { onChange() }
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    /// Applications with a process running audio output.
    func playingApplications() -> Set<pid_t> {
        let objects = processObjects()
        observed.formIntersection(objects)
        if let listener {
            var any = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertySelectorWildcard, mScope: kAudioObjectPropertyScopeWildcard,
                mElement: kAudioObjectPropertyElementWildcard)
            for object in objects.subtracting(observed) {
                if Self.succeeded(
                    AudioObjectAddPropertyListenerBlock(object, &any, queue, listener),
                    operation: "observe process", object: object)
                {
                    observed.insert(object)
                }
            }
        }
        // Read after the listeners are in place so that no change goes unnoticed; read the process identifier anew,
        // as an object may stand for another process later.
        var playing = Set<pid_t>()
        for object in objects where value(kAudioProcessPropertyIsRunningOutput, of: object, as: UInt32.self) == 1 {
            if let pid = value(kAudioProcessPropertyPID, of: object, as: pid_t.self) { playing.insert(pid) }
        }
        return AudioPlaybackAttribution.applications(
            of: playing, responsible: Self.responsibleProcess, parent: Self.parentProcess)
    }

    private func processObjects() -> Set<AudioObjectID> {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectHasProperty(Self.system, &address) else { return [] }
        guard Self.succeeded(
            AudioObjectGetPropertyDataSize(Self.system, &address, 0, nil, &size),
            operation: "read process list size", object: Self.system)
        else { return [] }
        guard size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard Self.succeeded(
            AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &objects),
            operation: "read process list", object: Self.system)
        else { return [] }
        return Set(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private func value<T>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID, as _: T.Type) -> T? {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard Self.succeeded(
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer),
            operation: "read property \(selector)", object: object)
        else { return nil }
        guard size == MemoryLayout<T>.size else {
            Self.logger.error("Unexpected size \(size) for Core Audio property \(selector) on object \(object)")
            return nil
        }
        return pointer.pointee
    }

    private nonisolated static func succeeded(_ status: OSStatus, operation: String, object: AudioObjectID) -> Bool {
        guard status != noErr else { return true }
        if status == kAudioHardwareBadObjectError {
            logger.debug("Core Audio object \(object) disappeared during \(operation, privacy: .public)")
        } else {
            logger.error("Could not \(operation, privacy: .public) on Core Audio object \(object): \(status)")
        }
        return false
    }

    private nonisolated static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private typealias ResponsibleProcessFunction = @convention(c) (pid_t) -> pid_t

    // Private but long-standing libquarantine function. It maps helpers that launchd started, such as Safari's
    // WebKit GPU process, to their application.
    private static let responsibleProcessFunction: ResponsibleProcessFunction? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else {
            logger.error("Could not open process symbols for audio attribution")
            return nil
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else {
            logger.notice("Responsible-process lookup is unavailable; audio attribution will use parent processes")
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleProcessFunction.self)
    }()

    private static func responsibleProcess(of pid: pid_t) -> pid_t? {
        guard let responsible = responsibleProcessFunction?(pid), responsible > 0 else { return nil }
        return responsible
    }

    private static func parentProcess(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else {
            logger.debug("Could not read parent of audio process \(pid): \(errno)")
            return nil
        }
        guard size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    deinit {
        guard let listener else { return }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        _ = Self.succeeded(
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener),
            operation: "remove process list observer", object: AudioObjectID(kAudioObjectSystemObject))
        var any = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertySelectorWildcard, mScope: kAudioObjectPropertyScopeWildcard,
            mElement: kAudioObjectPropertyElementWildcard)
        for object in observed {
            _ = Self.succeeded(
                AudioObjectRemovePropertyListenerBlock(object, &any, queue, listener),
                operation: "remove process observer", object: object)
        }
    }
}
