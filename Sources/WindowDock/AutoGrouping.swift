import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WindowDockCore
import os

/// Names and icons of apps that are identified by bundle ID, whether they're running or not.
enum AutoGroupApplication {
    static func url(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func name(_ bundleID: String) -> String {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .compactMap(\.localizedName).first
        {
            return running
        }
        guard let url = url(bundleID) else { return bundleID }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static func icon(_ bundleID: String, size: CGFloat) -> NSImage? {
        guard let url = url(bundleID), let icon = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage else {
            return nil
        }
        icon.size = NSSize(width: size, height: size)
        return icon
    }

    static func names(_ bundleIDs: [String]) -> String {
        ListFormatter.localizedString(byJoining: bundleIDs.map(name))
    }
}

/// What the user is asked before registering apps that move from another workspace or already have windows.
struct AutoGroupConfirmation {
    let workspace: String
    let applications: [String]
    let moves: [(application: String, from: String)]
    let existingWindowCount: Int
}

/// Collects new windows of registered apps into their workspace. Each app is collected by at most one workspace.
@MainActor
final class AutoGroupCoordinator {
    enum WindowIdentity: Hashable {
        case number(CGWindowID)
        case element(AXUIElement)
    }

    private enum WorkspaceKey: Hashable {
        case open(ObjectIdentifier)
        case closed(String)
    }

    @MainActor
    private final class Watch {
        let application: NSRunningApplication
        var ledger = AutoGroupWindowLedger<WindowIdentity>()
        var observer: AnyObject?
        var accepting = false
        var reading = false
        var baselineRequest = 0
        var listing = false
        var listAgain = false
        var launchTimers: [Timer] = []
        var creationTimers: [Timer] = []
        var reportedFailure = false

        init(application: NSRunningApplication) { self.application = application }

        func stop() {
            (launchTimers + creationTimers).forEach { $0.invalidate() }
            launchTimers = []
            creationTimers = []
            observer = nil
        }
    }

    private static let logger = Logger(subsystem: "WindowDock", category: "AutoGrouping")
    private let access: WindowAccessClient
    private let controllers: () -> [WorkspaceController]
    /// Saved workspaces; their rules wait while they're closed.
    var closedWorkspaces: () -> [SavedWorkspace] = { SavedLayout.load() }
    var updateClosedWorkspace: (String, [String])
        -> Void = { SavedLayout.setAutoGroupBundleIDs($1, forWorkspaceNamed: $0) }
    var save: (WorkspaceController) -> Void = { _ in }
    var runningApplications: () -> [NSRunningApplication] = {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }
    var bundleIdentifier: (NSRunningApplication) -> String? = { $0.bundleIdentifier }
    var recentApplications: () -> [String: Date] = { RecentApplications().dates }
    /// Reads AX window lists off the main thread so an unresponsive app doesn't stall the UI.
    var readsWindowsInBackground = true
    /// Returns nil when the user cancels, otherwise whether to add the windows that are already open.
    var confirm: (AutoGroupConfirmation) -> Bool? = AutoGroupCoordinator.confirmWithAlert
    private var watches: [pid_t: Watch] = [:]
    private var notificationObservers: [NSObjectProtocol] = []
    private var nextPoll = Date.distantPast

    init(access: WindowAccessClient = WindowAccessClient(), controllers: @escaping () -> [WorkspaceController]) {
        self.access = access
        self.controllers = controllers
    }

    func start() {
        guard notificationObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let handlers: [(Notification.Name, (AutoGroupCoordinator, NSRunningApplication) -> Void)] = [
            (NSWorkspace.didLaunchApplicationNotification, { $0.applicationLaunched($1) }),
            (NSWorkspace.didTerminateApplicationNotification, { $0.applicationTerminated($1) }),
            (NSWorkspace.didActivateApplicationNotification, { $0.applicationActivated($1) }),
        ]
        for (name, handler) in handlers {
            notificationObservers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                else { return }
                MainActor.assumeIsolated {
                    if let self { handler(self, app) }
                }
            })
        }
        refresh()
    }

    func stop() {
        notificationObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        notificationObservers = []
        watches.values.forEach { $0.stop() }
        watches = [:]
    }

    // MARK: Watching

    /// Follows rule and workspace changes: watches the running apps that an open workspace collects.
    func refresh() {
        for (pid, watch) in watches where watch.application.isTerminated || target(for: watch.application) == nil {
            watch.stop()
            watches.removeValue(forKey: pid)
        }
        for app in runningApplications() where !app.isTerminated {
            guard let target = target(for: app) else { continue }
            let watch = self.watch(app)
            let accepting = target.acceptsAutomaticWindows
            if !watch.ledger.isBaselined {
                if !watch.reading { baseline(watch, empty: !app.isFinishedLaunching) }
            } else if accepting, !watch.accepting {
                // Windows opened while the workspace was paused stay where they are.
                baseline(watch)
            }
            watch.accepting = accepting
        }
    }

    /// Rechecks watched apps now and then, in case an app didn't report a new window.
    func poll() {
        refresh()
        guard Date() >= nextPoll else { return }
        nextPoll = Date().addingTimeInterval(6)
        for watch in watches.values where watch.accepting { check(watch) }
    }

    /// Windows opened while an app launches are new, even if they appeared before the launch was reported.
    func applicationLaunched(_ app: NSRunningApplication) {
        guard target(for: app) != nil else { return }
        refresh()
        guard let watch = watches[app.processIdentifier] else { return }
        baseline(watch, empty: true)
        watch.launchTimers.forEach { $0.invalidate() }
        watch.launchTimers = [0.5, 1, 2, 4].map { schedule(watch, after: $0) }
    }

    func applicationTerminated(_ app: NSRunningApplication) {
        watches.removeValue(forKey: app.processIdentifier)?.stop()
    }

    private func applicationActivated(_ app: NSRunningApplication) {
        if let watch = watches[app.processIdentifier] { check(watch) }
    }

    /// A window that joined a workspace in any way, e.g. by hand, is no longer new.
    func remember(_ candidate: WindowCandidate) {
        watches[candidate.application.processIdentifier]?.ledger.remember(identity(of: candidate.element))
    }

    private func target(for app: NSRunningApplication) -> WorkspaceController? {
        guard let id = bundleIdentifier(app) else { return nil }
        return controllers().first { !$0.quitting && $0.autoGroupBundleIDs.contains(id) }
    }

    private func watch(_ app: NSRunningApplication) -> Watch {
        let pid = app.processIdentifier
        let watch = watches[pid] ?? Watch(application: app)
        watches[pid] = watch
        if watch.observer == nil {
            watch.observer = access.observeWindowCreation(app) { [weak self, weak watch] _ in
                MainActor.assumeIsolated {
                    guard let self, let watch else { return }
                    self.windowCreated(watch)
                }
            }
            if watch.observer == nil {
                Self.logger.debug("Watching \(self.bundleIdentifier(app) ?? "?", privacy: .public) by polling")
            }
        }
        return watch
    }

    /// New windows can report their role and size a little later, so look again a few times.
    private func windowCreated(_ watch: Watch) {
        guard watches[watch.application.processIdentifier] === watch else { return }
        watch.creationTimers.forEach { $0.invalidate() }
        watch.creationTimers = [0.05, 0.35, 1].map { schedule(watch, after: $0) }
    }

    private func schedule(_ watch: Watch, after delay: TimeInterval) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self, weak watch] _ in
            MainActor.assumeIsolated {
                guard let self, let watch else { return }
                self.check(watch)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func identity(of element: AXUIElement) -> WindowIdentity {
        access.windowID(element).map(WindowIdentity.number) ?? .element(element)
    }

    /// Takes the app's current windows as already seen. A failed listing is retried rather than treated as empty.
    private func baseline(_ watch: Watch, empty: Bool = false) {
        watch.ledger.invalidate()
        watch.baselineRequest += 1
        if empty {
            watch.reading = false
            watch.ledger.setBaseline([])
            return
        }
        let request = watch.baselineRequest
        let app = watch.application
        let elements = access.windowElements, numbers = access.allWindowIDs, number = access.windowID
        // AX lists only the current Space's windows; the WindowServer also knows the ones on other Spaces.
        let read = { () -> [WindowIdentity]? in
            guard let listed = elements(app) else { return nil }
            return listed.map { number($0).map(WindowIdentity.number) ?? .element($0) }
                + (numbers(app) ?? []).map(WindowIdentity.number)
        }
        guard readsWindowsInBackground else {
            watch.ledger.setBaseline(read())
            return
        }
        watch.reading = true
        Task { [weak self] in
            let windows = await Task.detached(operation: read).value
            guard let self, self.watches[app.processIdentifier] === watch, watch.baselineRequest == request else {
                return
            }
            watch.reading = false
            watch.ledger.setBaseline(windows)
        }
    }

    private func check(_ watch: Watch) {
        let app = watch.application
        guard watches[app.processIdentifier] === watch, !app.isTerminated else { return }
        guard watch.ledger.isBaselined else {
            if !watch.reading { baseline(watch) }
            return
        }
        let epoch = watch.ledger.epoch
        guard readsWindowsInBackground else {
            return admit(access.applicationWindows(app), to: watch, epoch: epoch)
        }
        guard !watch.listing else {
            watch.listAgain = true
            return
        }
        watch.listing = true
        let list = access.applicationWindows
        Task { [weak self] in
            let windows = await Task.detached { list(app) }.value
            watch.listing = false
            guard let self else { return }
            self.admit(windows, to: watch, epoch: epoch)
            if watch.listAgain {
                watch.listAgain = false
                self.check(watch)
            }
        }
    }

    /// Rechecks everything on the main actor: results read before a rule change or a new baseline are dropped.
    private func admit(_ listed: [WindowCandidate]?, to watch: Watch, epoch: Int) {
        let app = watch.application
        guard watches[app.processIdentifier] === watch, let listed else { return }
        let target = target(for: app)
        let accepting = target?.acceptsAutomaticWindows == true
        if accepting, !watch.accepting {
            watch.accepting = true
            return baseline(watch)
        }
        watch.accepting = accepting
        let windows = listed.map { (identity: identity(of: $0.element), candidate: $0) }
        let new = Set(watch.ledger.takeNew(from: windows.map(\.identity), epoch: epoch))
        // Windows opened while the workspace can't take them are skipped for good.
        guard let target, accepting, !new.isEmpty else { return }
        let all = controllers()
        let bundleID = bundleIdentifier(app)
        for window in windows where new.contains(window.identity) {
            let candidate = window.candidate
            // A launcher on a new-tab page is waiting for this app's window; the explicit request wins.
            guard !all.contains(where: { $0.session.isAwaitingWindow(pid: app.processIdentifier, bundleID: bundleID) }),
                  !all.contains(where: { $0.session.contains(candidate) }),
                  (try? access.isMinimized(candidate.element)) == false,
                  !access.isFullScreen(candidate.element)
            else { continue }
            do {
                try target.addAutomatically(candidate)
            } catch {
                Self.logger.error("Could not collect a new window: \(error.localizedDescription, privacy: .public)")
                guard !watch.reportedFailure else { continue }
                watch.reportedFailure = true
                target.showNotice(.attention(error.localizedDescription))
            }
        }
    }

    // MARK: Rules

    private func rules() -> AutoGroupRules<WorkspaceKey> {
        let open = controllers().filter { !$0.quitting }
        let names = Set(open.map(\.name))
        return AutoGroupRules(
            open.map { .init(workspace: .open(ObjectIdentifier($0)), bundleIDs: $0.autoGroupBundleIDs) }
                + closedWorkspaces().filter { !names.contains($0.name) }.map {
                    .init(workspace: .closed($0.name), bundleIDs: $0.autoGroupBundleIDs ?? [])
                })
    }

    private func name(of workspace: WorkspaceKey) -> String {
        switch workspace {
        case let .open(id): controllers().first { ObjectIdentifier($0) == id }?.name ?? ""
        case let .closed(name): name
        }
    }

    /// Windows of the apps that no workspace manages yet.
    private func existingWindows(of bundleIDs: [String]) -> [WindowCandidate] {
        let all = controllers()
        return runningApplications()
            .filter { app in !app.isTerminated && bundleIdentifier(app).map(bundleIDs.contains) == true }
            .flatMap { access.applicationWindows($0) ?? [] }
            .filter { candidate in !all.contains { $0.session.contains(candidate) } }
    }

    /// Registering doesn't launch apps. Moving an app from another workspace or adding its open windows is confirmed.
    /// Returns false when nothing was registered.
    @discardableResult
    func register(_ bundleIDs: [String], in controller: WorkspaceController) -> Bool {
        guard !controller.quitting, !controller.isRestoring else { return false }
        var ids: [String] = []
        for id in bundleIDs where !id.isEmpty && id != Bundle.main.bundleIdentifier
            && !controller.autoGroupBundleIDs.contains(id) && !ids.contains(id)
        {
            ids.append(id)
        }
        guard !ids.isEmpty else { return false }
        let rules = rules()
        let key = WorkspaceKey.open(ObjectIdentifier(controller))
        let moves = ids.compactMap { id -> (application: String, from: String)? in
            guard let owner = rules.workspace(for: id), owner != key else { return nil }
            return (AutoGroupApplication.name(id), name(of: owner))
        }
        let existing = existingWindows(of: ids).count
        var includeExisting = false
        if !moves.isEmpty || existing > 0 {
            let request = AutoGroupConfirmation(
                workspace: controller.name, applications: ids.map(AutoGroupApplication.name), moves: moves,
                existingWindowCount: existing)
            guard let answer = confirm(request) else { return false }
            includeExisting = answer
        }
        return apply(ids, to: controller, includingExisting: includeExisting)
    }

    /// Registers apps chosen by their bundle, telling the user about bundles without an identifier.
    @discardableResult
    func register(applicationsAt urls: [URL], in controller: WorkspaceController) -> Bool {
        let (ids, unidentified) = Self.bundleIdentifiers(of: urls)
        reportUnidentified(unidentified, in: controller)
        return register(ids, in: controller)
    }

    private static func bundleIdentifiers(of urls: [URL]) -> (ids: [String], unidentified: [String]) {
        var ids: [String] = []
        var unidentified: [String] = []
        for url in urls {
            if let id = Bundle(url: url)?.bundleIdentifier {
                ids.append(id)
            } else {
                unidentified.append(url.deletingPathExtension().lastPathComponent)
            }
        }
        return (ids, unidentified)
    }

    private func reportUnidentified(_ names: [String], in controller: WorkspaceController) {
        guard !names.isEmpty else { return }
        controller.showNotice(.attention(L(
            "%@ は識別できないため、新しいウィンドウを自動で追加できません。", ListFormatter.localizedString(byJoining: names))))
    }

    /// Makes the workspace collect exactly these apps; unchecked apps keep their tabs.
    /// Returns false when nothing changed or the user cancelled moving an app.
    @discardableResult
    func setApplications(_ bundleIDs: [String], for controller: WorkspaceController) -> Bool {
        guard !controller.quitting, !controller.isRestoring else { return false }
        let current = controller.autoGroupBundleIDs
        let removed = current.filter { !bundleIDs.contains($0) }
        let added = bundleIDs.filter { !current.contains($0) }
        if !added.isEmpty, !register(added, in: controller) { return false }
        guard !removed.isEmpty else { return !added.isEmpty }
        controller.autoGroupBundleIDs.removeAll(where: removed.contains)
        save(controller)
        if added.isEmpty {
            controller.showNotice(.information(L(
                "%@の自動追加を止めました。追加済みのタブは残ります。", AutoGroupApplication.names(removed))))
        }
        return true
    }

    private func apply(_ ids: [String], to controller: WorkspaceController, includingExisting: Bool) -> Bool {
        guard controllers().contains(where: { $0 === controller }), !controller.quitting, !controller.isRestoring
        else { return false }
        var rules = rules()
        let key = WorkspaceKey.open(ObjectIdentifier(controller))
        var changed: [WorkspaceKey] = []
        for id in ids {
            if let previous = rules.assign(id, to: key), !changed.contains(previous) { changed.append(previous) }
        }
        // Remove the apps from their old workspaces first, so no app is ever collected twice.
        for workspace in changed + [key] {
            let ids = rules.bundleIDs(in: workspace)
            switch workspace {
            case let .open(id):
                guard let owner = controllers().first(where: { ObjectIdentifier($0) == id }) else { continue }
                owner.autoGroupBundleIDs = ids
                save(owner)
            case let .closed(name):
                updateClosedWorkspace(name, ids)
            }
        }
        if includingExisting {
            let windows = existingWindows(of: ids)
            if !windows.isEmpty { controller.session.add(windows) }
        }
        if !access.isTrusted() {
            controller.showNotice(.attention(L("新しいウィンドウを自動で追加するにはアクセシビリティ権限が必要です。")))
        } else {
            controller.showNotice(.information(L(
                "%@で新しく開いたウィンドウを、このワークスペースに追加します。", AutoGroupApplication.names(ids))))
        }
        return true
    }

    /// Stops collecting the app. Its tabs stay in the workspace.
    func unregister(_ bundleID: String, from controller: WorkspaceController) {
        guard controller.autoGroupBundleIDs.contains(bundleID) else { return }
        controller.autoGroupBundleIDs.removeAll { $0 == bundleID }
        save(controller)
        controller.showNotice(.information(L(
            "%@の自動追加を止めました。追加済みのタブは残ります。", AutoGroupApplication.name(bundleID))))
    }

    // MARK: Choosing apps

    /// An app listed for choosing: whether this workspace collects it, and which other workspace does.
    struct ApplicationChoice: Equatable {
        let bundleID: String
        let selected: Bool
        let registeredIn: String?
    }

    /// This workspace's apps first, then recently used and running apps.
    func applicationChoices(for controller: WorkspaceController) -> [ApplicationChoice] {
        let rules = rules()
        let key = WorkspaceKey.open(ObjectIdentifier(controller))
        let own = Bundle.main.bundleIdentifier
        let registered = controller.autoGroupBundleIDs
        func listable(_ id: String) -> Bool {
            id != own && !registered.contains(id) && AutoGroupApplication.url(id) != nil
        }
        let recent = recentApplications().sorted { $0.value > $1.value }.map(\.key).filter(listable).prefix(12)
        var ids = registered + recent
        for id in runningApplications().filter({ !$0.isTerminated }).compactMap(bundleIdentifier)
            where listable(id) && !ids.contains(id)
        {
            ids.append(id)
        }
        return ids.map { id in
            let owner = rules.workspace(for: id).flatMap { $0 == key ? nil : name(of: $0) }
            return ApplicationChoice(bundleID: id, selected: registered.contains(id), registeredIn: owner)
        }
    }

    /// Lets the user check the apps whose new windows this workspace adds, changing several at once.
    func chooseApplications(for controller: WorkspaceController) {
        guard !controller.quitting, !controller.isRestoring, controller.window.attachedSheet == nil else { return }
        let choices = applicationChoices(for: controller)
        guard !choices.isEmpty else { return chooseOtherApplications(for: controller) }
        let list = AutoGroupApplicationList(choices: choices)
        var unidentified: [String] = []
        list.chooseOther = { [weak controller] in
            guard let controller, let urls = Self.chooseApplicationBundles(for: controller.name) else { return nil }
            let found = Self.bundleIdentifiers(of: urls)
            unidentified += found.unidentified
            return found.ids.filter { $0 != Bundle.main.bundleIdentifier }
        }
        let alert = NSAlert()
        alert.messageText = L("新しいウィンドウを自動で追加するアプリ")
        alert.informativeText = L(
            "チェックしたアプリで今後開いたウィンドウを「%@」に追加します。チェックを外しても、追加済みのタブは残ります。", controller.name)
        alert.accessoryView = list
        alert.addButton(withTitle: L("保存"))
        alert.addButton(withTitle: L("キャンセル"))
        if alert.runModal() == .alertFirstButtonReturn {
            setApplications(list.selectedBundleIDs, for: controller)
        }
        reportUnidentified(unidentified, in: controller)
    }

    private func chooseOtherApplications(for controller: WorkspaceController) {
        guard let urls = Self.chooseApplicationBundles(for: controller.name) else { return }
        register(applicationsAt: urls, in: controller)
    }

    private static func chooseApplicationBundles(for workspace: String) -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("登録")
        panel.message = L("選んだアプリで今後開いたウィンドウを「%@」に追加します。アプリは起動しません。", workspace)
        return panel.runModal() == .OK ? panel.urls : nil
    }

    private static func confirmWithAlert(_ request: AutoGroupConfirmation) -> Bool? {
        let alert = NSAlert()
        alert.messageText = L("新しいウィンドウを自動で「%@」に追加しますか？", request.workspace)
        var lines = request.moves.map { L("「%@」の追加先を「%@」から「%@」に変更します。", $0.application, $0.from, request.workspace) }
        if !request.moves.isEmpty { lines.append(L("追加済みのタブは移動しません。")) }
        if lines.isEmpty {
            lines.append(L("%@で今後開いたウィンドウを追加します。", ListFormatter.localizedString(byJoining: request.applications)))
        }
        alert.informativeText = lines.joined(separator: "\n")
        let existing = NSButton(
            checkboxWithTitle: L("今開いている%d件も追加", request.existingWindowCount), target: nil, action: nil)
        existing.state = .off
        if request.existingWindowCount > 0 {
            existing.frame = NSRect(origin: .zero, size: existing.fittingSize)
            alert.accessoryView = existing
        }
        alert.addButton(withTitle: L("登録"))
        alert.addButton(withTitle: L("キャンセル"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return request.existingWindowCount > 0 && existing.state == .on
    }
}

/// Checkboxes for the apps whose new windows a workspace adds, with a button to list any other app.
@MainActor
final class AutoGroupApplicationList: NSView {
    private final class Document: NSView {
        override var isFlipped: Bool { true }
    }

    private static let width: CGFloat = 400
    private(set) var bundleIDs: [String] = []
    private var checks: [String: NSButton] = [:]
    private let rows = NSStackView()
    private let document = Document()
    private let scroll = NSScrollView()
    /// Returns more apps to list checked, or nil when the user cancels.
    var chooseOther: () -> [String]? = { nil }

    init(choices: [AutoGroupCoordinator.ApplicationChoice]) {
        super.init(frame: .zero)
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        rows.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        for choice in choices {
            append(choice.bundleID, selected: choice.selected, registeredIn: choice.registeredIn)
        }
        document.addSubview(rows)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        let other = NSButton(title: L("その他のアプリを選ぶ…"), target: self, action: #selector(addOtherApplications))
        other.frame = NSRect(origin: .zero, size: other.fittingSize)
        let height = min(300, max(120, rows.fittingSize.height + 4))
        scroll.frame = NSRect(x: 0, y: other.frame.maxY + 8, width: Self.width, height: height)
        addSubview(scroll)
        addSubview(other)
        frame = NSRect(x: 0, y: 0, width: Self.width, height: scroll.frame.maxY)
        layoutRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var selectedBundleIDs: [String] { bundleIDs.filter { checks[$0]?.state == .on } }

    func checkbox(for bundleID: String) -> NSButton? { checks[bundleID] }

    /// Lists the apps checked; apps that are already listed are checked.
    func add(_ ids: [String]) {
        for id in ids {
            if let check = checks[id] {
                check.state = .on
            } else {
                append(id, selected: true, registeredIn: nil)
            }
        }
        layoutRows()
        if let last = ids.last.flatMap({ checks[$0] }) { last.scrollToVisible(last.bounds) }
    }

    private func append(_ id: String, selected: Bool, registeredIn: String?) {
        var name = AutoGroupApplication.name(id)
        if let registeredIn { name += L("（「%@」に登録済み）", registeredIn) }
        // An image would replace the checkbox itself, so the icon goes into the title.
        let title = NSMutableAttributedString()
        if let icon = AutoGroupApplication.icon(id, size: 16) {
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
            title.append(NSAttributedString(attachment: attachment))
            title.append(NSAttributedString(string: " "))
        }
        title.append(NSAttributedString(string: name))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        title.addAttributes([
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ], range: NSRange(location: 0, length: title.length))
        let check = NSButton(checkboxWithTitle: name, target: nil, action: nil)
        check.attributedTitle = title
        check.lineBreakMode = .byTruncatingTail
        check.toolTip = name
        check.setAccessibilityLabel(name)
        check.state = selected ? .on : .off
        // Leave room for the insets and an overlay scroller; longer names are truncated.
        check.widthAnchor.constraint(lessThanOrEqualToConstant: Self.width - 32).isActive = true
        bundleIDs.append(id)
        checks[id] = check
        rows.addArrangedSubview(check)
    }

    private func layoutRows() {
        let size = rows.fittingSize
        let visible = scroll.contentSize
        document.frame = NSRect(x: 0, y: 0, width: max(size.width, visible.width),
                                height: max(size.height, visible.height))
        rows.frame = NSRect(x: 0, y: 0, width: document.frame.width, height: size.height)
    }

    @objc private func addOtherApplications() {
        guard let ids = chooseOther(), !ids.isEmpty else { return }
        add(ids)
    }
}

/// The apps whose new windows a workspace adds automatically, shown on its new-tab page.
@MainActor
final class AutoGroupPageModel: ObservableObject {
    @Published var bundleIDs: [String] = []
    @Published var isAvailable = false
    /// Returns whether the apps were registered, false when the user cancels.
    var register: ([URL]) -> Bool = { _ in false }
    var remove: (String) -> Void = { _ in }
}

struct AutoGroupSection: View {
    @ObservedObject var model: AutoGroupPageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(L("新しいウィンドウを自動で追加するアプリ")).font(.headline)
            Text(L("これらのアプリで新しく開いたウィンドウは、自動的にこのワークスペースにタブとして追加されます。"))
                .foregroundStyle(.secondary)
            ForEach(model.bundleIDs, id: \.self) { id in
                HStack {
                    if let icon = AutoGroupApplication.icon(id, size: 20) {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    }
                    Text(AutoGroupApplication.name(id))
                    Spacer()
                    Button(L("登録を解除")) { model.remove(id) }.controlSize(.small).hoverGlow()
                }
            }
        }
    }
}
