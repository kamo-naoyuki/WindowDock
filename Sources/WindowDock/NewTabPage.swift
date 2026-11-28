import SwiftUI
import WindowDockCore

@MainActor
struct NewTabPage: View {
    struct Restoration {
        let workspace: SavedWorkspace
        let skip: () -> Void
    }

    var restoration: Restoration?
    var access = WindowAccessClient()
    var isAvailable: (WindowCandidate) -> Bool
    var launch: (URL) async throws -> [WindowCandidate]
    var choose: ([WindowCandidate]) -> Bool
    /// Chooses an item of an installed app's Dock menu and returns the new windows it opened.
    var chooseDockMenuItem: (DockMenuPath, [DockMenuItem], URL) async throws -> [WindowCandidate] = { _, _, _ in [] }
    var applications: () async -> [LauncherApplication] = InstalledApplications.load
    @ObservedObject var autoGroup = AutoGroupPageModel()

    private struct Request: Equatable {
        let id = UUID()
        var apps: [URL] = []
    }
    private struct DockMenuChoice: Equatable {
        let id = UUID()
        var path: DockMenuPath
        var items: [DockMenuItem]
        var url: URL
    }
    @State private var request = Request()
    @State private var dockMenuChoice: DockMenuChoice?
    @State private var choices: [WindowCandidate] = []
    /// Changes with each new list of windows, so the grid takes up its initial selection.
    @State private var listID = UUID()
    @State private var initialSelection: IndexSet?
    @State private var preselected: IndexSet?
    @State private var apps: [LauncherApplication]?
    @State private var message = ""
    @State private var loading = true
    @State private var needsPermission = false
    @State private var previews: WindowThumbnails?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(restoration.map { L("「%@」のタブを復元", $0.workspace.name) } ?? L("開いているウィンドウ")).font(.headline)
                    Spacer()
                    if let restoration {
                        Button(L("復元しない"), action: restoration.skip).keyboardShortcut(.cancelAction).hoverGlow()
                    }
                    Button { request = Request() } label: {
                        Image(systemName: "arrow.clockwise")
                    }.hoverGlow().help(L("一覧を更新")).accessibilityLabel(L("一覧を更新"))
                }
                if restoration != nil {
                    Text(L("前回のタブに一致するウィンドウが選択されています。復元するウィンドウを確認してください。"))
                        .foregroundStyle(.secondary)
                }
                if loading { ProgressView().controlSize(.small) }
                if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
                if needsPermission {
                    Button(L("権限設定")) { access.requestPermission() }.hoverGlow()
                }
                if !choices.isEmpty, previews == nil {
                    Button(L("画面収録を許可してプレビューを表示…")) {
                        if CGRequestScreenCaptureAccess() {
                            request = Request()
                        }
                        else if let url =
                            URL(
                                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                            ) {
                            NSWorkspace.shared.open(url)
                        }
                    }.controlSize(.small).hoverGlow()
                }
                if !choices.isEmpty {
                    WindowChoiceGrid(windows: choices, previews: previews, restoring: initialSelection,
                                     selected: preselected, choose: choose)
                        .id(listID)
                }
                if restoration == nil {
                    if autoGroup.isAvailable, !autoGroup.bundleIDs.isEmpty { AutoGroupSection(model: autoGroup) }
                    launchActions
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: request) { await load(request) }
        .task(id: dockMenuChoice) { await perform(dockMenuChoice) }
    }

    @ViewBuilder
    private var launchActions: some View {
        Divider()
        Text(L("インストール済みのアプリ")).font(.headline)
        Text(L("最近使った順に表示します。")).foregroundStyle(.secondary)
        Text(L("アプリを選ぶと新しいウィンドウを開いて、このタブに追加します。起動していないアプリは起動し、起動中のアプリでは「新規ウィンドウ」を実行します。"))
            .foregroundStyle(.secondary)
        if autoGroup.isAvailable {
            Text(L("複数選択すると、まとめて開くか、新しいウィンドウを自動でこのワークスペースに追加するように設定できます。"))
                .foregroundStyle(.secondary)
        }
        Text(L("右クリックすると Dock のようなメニューを表示します。")).foregroundStyle(.secondary)
        VStack(alignment: .leading) {
            if let apps, !apps.isEmpty {
                LauncherGrid(apps: apps, autoGroup: autoGroup, launch: { request = Request(apps: $0) },
                             access: access,
                             chooseDockMenuItem: { dockMenuChoice = DockMenuChoice(path: $0, items: $1, url: $2) })
            } else if apps == nil {
                ProgressView().controlSize(.small)
            } else {
                Text(L("起動できるアプリが見つかりませんでした。")).foregroundStyle(.secondary)
            }
        }.task(id: request.id) {
            guard request.apps.isEmpty else { return }
            let installed = await applications()
            if !Task.isCancelled { apps = installed }
        }
    }

    /// Opens a new window of each app at once and returns the windows with any launch problems.
    private func launchAll(_ urls: [URL]) async -> (windows: [WindowCandidate], problems: [String]) {
        let results = await withTaskGroup(of: (Int, Result<[WindowCandidate], Error>).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask { @MainActor in
                    do { return try await (index, .success(launch(url))) } catch { return (index, .failure(error)) }
                }
            }
            var results: [(Int, Result<[WindowCandidate], Error>)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var windows: [WindowCandidate] = []
        var problems: [String] = []
        for (url, result) in zip(urls, results) {
            switch result {
            case let .success(launched):
                windows += launched
                if launched.isEmpty {
                    problems
                        .append(L("%@は起動しましたが、追加できるウィンドウが見つかりませんでした。", url.deletingPathExtension().lastPathComponent))
                }
            case let .failure(error):
                if !(error is CancellationError) {
                    problems.append(L("%@を起動できませんでした: %@", url.lastPathComponent, error.localizedDescription))
                }
            }
        }
        return (windows, problems)
    }

    /// The open windows that can be added, and a note naming apps whose windows couldn't be read.
    private func scanWindows() async -> (windows: [WindowCandidate], note: String) {
        let scan = await Task.detached(priority: .userInitiated) { [scan = access.scan] in scan() }.value
        let note = scan.failedApplications.isEmpty
            ? "" : L("取得できなかったアプリ: %@", scan.failedApplications.joined(separator: L("、")))
        return (scan.windows.filter(isAvailable), note)
    }

    private func show(_ windows: [WindowCandidate]) {
        previews = CGPreflightScreenCaptureAccess() ? WindowThumbnails() : nil
        choices = windows
        listID = UUID()
    }

    private func load(_ request: Request) async {
        // A launch leaves the current windows on screen, so they stay available if it fails.
        if request.apps.isEmpty { choices = [] }
        initialSelection = nil
        preselected = nil
        message = ""
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        needsPermission = !access.isTrusted()
        guard !needsPermission else {
            choices = []
            message = L("追加にはアクセシビリティ権限が必要です。システム設定で現在の WindowDock を許可してください。")
            return
        }
        if !request.apps.isEmpty {
            let (launched, problems) = await launchAll(request.apps)
            guard !Task.isCancelled else { return }
            if problems.isEmpty, launched.count == request.apps.count, choose(launched) { return }
            // List the new windows first, then the other open windows in case a launch failed.
            let open = await scanWindows()
            guard !Task.isCancelled else { return }
            message = (problems + [open.note]).filter { !$0.isEmpty }.joined(separator: "\n")
            if request.apps.count > 1 { preselected = IndexSet(launched.indices) }
            show(launched + open.windows.filter { window in !launched.contains { $0.isSameWindow(as: window) } })
            return
        }
        let open = await scanWindows()
        guard !Task.isCancelled else { return }
        var candidates = open.windows
        if !open.note.isEmpty {
            message = open.note
        } else if candidates.isEmpty {
            message = L("追加できるウィンドウがありません。")
        }
        if let saved = restoration?.workspace.windows {
            let sorted = await Task.detached(priority: .userInitiated) { [candidates, frame = access.frame] in
                SavedLayout.restoreChoices(saved, among: candidates, frameOf: frame)
            }.value
            guard !Task.isCancelled else { return }
            candidates = sorted.windows
            initialSelection = sorted.checked
        }
        show(candidates)
    }

    /// Runs a Dock menu item without a progress indicator, as the Dock does, and adds any windows it opened.
    private func perform(_ choice: DockMenuChoice?) async {
        guard let choice else { return }
        do {
            let windows = try await chooseDockMenuItem(choice.path, choice.items, choice.url)
            if !Task.isCancelled, !windows.isEmpty { _ = choose(windows) }
        } catch {
            if !(error is CancellationError), !Task.isCancelled { message = error.localizedDescription }
        }
    }
}

struct WindowChoiceGrid: View {
    let windows: [WindowCandidate]
    let previews: WindowThumbnails?
    let choose: ([WindowCandidate]) -> Bool
    @State private var selection: GridSelection
    private let restoring: Bool

    /// `restoring` checks the windows of a restore prompt; `selected` only checks windows to add.
    init(windows: [WindowCandidate], previews: WindowThumbnails?, restoring: IndexSet? = nil,
         selected: IndexSet? = nil, choose: @escaping ([WindowCandidate]) -> Bool) {
        self.windows = windows
        self.previews = previews
        self.choose = choose
        self.restoring = restoring != nil
        _selection = State(initialValue: GridSelection(rows: restoring ?? selected))
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 200))], alignment: .leading,
                  pinnedViews: [.sectionHeaders]) {
            Section {
                ForEach(windows.indices, id: \.self) { index in
                    let window = windows[index]
                    let checked = selection.rows?.contains(index) == true
                    Button {
                        if selection.clickWithCurrentModifiers(index) { _ = choose([window]) }
                    } label: {
                        WindowCard(candidate: window, previews: previews)
                            .selectionMark(selection.isSelecting ? checked : nil)
                            .padding(6).hoverGlow()
                    }.buttonStyle(.plain).help(window.label)
                        .accessibilityLabel(window.label)
                        .accessibilityAddTraits(checked ? .isSelected : [])
                }
            } header: {
                SelectionHeader(rows: selection.rows, begin: L("複数選択")) { selection.begin() } actions: { rows in
                    Button(L("選択したアプリの全ウィンドウを選択")) {
                        selection.select(rows.includingWindowsOfSelectedApps(
                            in: windows.map(\.application.processIdentifier)
                        ))
                    }.hoverGlow().disabled(rows.isEmpty)
                    if !restoring {
                        Button(L("キャンセル")) { selection.cancel() }.hoverGlow()
                    }
                    Button(restoring ? L("%d件を復元", rows.count) : L("%d件を追加", rows.count)) {
                        _ = choose(rows.map { windows[$0] })
                    }.buttonStyle(.borderedProminent).hoverGlow().disabled(rows.isEmpty)
                }
            }
        }
    }
}

/// Installed apps. A click opens a new window of the app; several selected apps can be opened together or have
/// their new windows added to the workspace automatically. A right-click shows a menu like the app's Dock menu.
struct LauncherGrid: View {
    let apps: [LauncherApplication]
    @ObservedObject var autoGroup: AutoGroupPageModel
    let launch: ([URL]) -> Void
    var access = WindowAccessClient()
    var chooseDockMenuItem: (DockMenuPath, [DockMenuItem], URL) -> Void = { _, _, _ in }
    @State private var selection = GridSelection()
    @State private var menu = LauncherMenu()

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 6)], alignment: .leading,
                  spacing: 6, pinnedViews: [.sectionHeaders]) {
            Section {
                ForEach(apps.indices, id: \.self) { index in
                    let app = apps[index]
                    let checked = selection.rows?.contains(index) == true
                    let automatic = isAutomatic(app)
                    Button {
                        if selection.clickWithCurrentModifiers(index) { launch([app.url]) }
                    } label: {
                        VStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                .resizable().scaledToFit().frame(width: 40, height: 40)
                                .overlay(alignment: .bottomTrailing) {
                                    if automatic {
                                        Image(systemName: "rectangle.stack.badge.plus")
                                            .foregroundStyle(Color.accentColor)
                                            .background(Circle().fill(.background).padding(-2))
                                            .accessibilityHidden(true)
                                    }
                                }
                            Text(app.name).lineLimit(1)
                        }.frame(width: 84).selectionMark(selection.isSelecting ? checked : nil).padding(6).hoverGlow()
                    }.buttonStyle(.plain)
                        .background(SecondaryClick { view, point in showMenu(for: app.url, in: view, at: point) })
                        .help(automatic ? app.name + "\n" + L("新しいウィンドウを自動でこのワークスペースに追加します") : app.name)
                        .accessibilityLabel(app.name)
                        .accessibilityAddTraits(checked ? .isSelected : [])
                }
            } header: {
                SelectionHeader(rows: selection.rows, begin: L("アプリを複数選択")) { selection.begin() } actions: { rows in
                    let urls = rows.map { apps[$0].url }
                    Button(L("キャンセル")) { selection.cancel() }.hoverGlow()
                    Button(L("%d個のアプリで新しいウィンドウを開く", rows.count)) {
                        selection.cancel()
                        launch(urls)
                    }.buttonStyle(.borderedProminent).hoverGlow().disabled(rows.isEmpty)
                    if autoGroup.isAvailable {
                        Button(L("%d個のアプリの新しいウィンドウを自動でこのワークスペースに追加", rows.count)) {
                            if autoGroup.register(urls) { selection.cancel() }
                        }.hoverGlow().disabled(rows.allSatisfy { isAutomatic(apps[$0]) })
                            .help(L("選んだアプリで今後開いたウィンドウを、自動的にこのワークスペースに追加します。アプリは起動しません。"))
                    }
                }
            }
        }.onChange(of: apps.map(\.url)) { _ in selection.cancel() }
    }

    private func isAutomatic(_ app: LauncherApplication) -> Bool {
        autoGroup.isAvailable && Bundle(url: app.url)?.bundleIdentifier.map(autoGroup.bundleIDs.contains) == true
    }

    /// Shows a menu like the app's Dock menu without opening the Dock's, which would flash at the Dock. Its Show Dock
    /// Menu item reads the Dock's menu for app-specific items such as Chrome's profiles.
    private func showMenu(for url: URL, in view: NSView, at point: NSPoint) {
        guard !menu.isShowing else { return }
        menu.isShowing = true
        Task { @MainActor in
            defer { menu.isShowing = false }
            let (app, windows, inDock) = await Task.detached(priority: .userInitiated) { [access] in
                let app = access.runningApplication(url)
                return (app, app.flatMap(access.applicationWindows) ?? [], access.hasDockItem(url))
            }.value
            guard view.window != nil else { return }
            let focus = access.focus
            LauncherMenu.standard(
                for: url, running: app, windows: windows, open: { launch([url]) },
                focus: { window in Task.detached { try? focus(window.element, window.application) } },
                showDockMenu: inDock ? { Task { @MainActor in showDockMenu(for: url, in: view, at: point) } } : nil
            )
            .popUp(positioning: nil, at: point, in: view)
        }
    }

    /// Reads the app's Dock menu, which briefly opens it at the Dock, and shows the same items at the click.
    private func showDockMenu(for url: URL, in view: NSView, at point: NSPoint) {
        guard !menu.isShowing else { return }
        menu.isShowing = true
        Task { @MainActor in
            defer { menu.isShowing = false }
            let items = await Task.detached(priority: .userInitiated) { [access] in try? access.dockMenu(url) }.value
            guard view.window != nil else { return }
            guard let items, !items.isEmpty else { return NSSound.beep() }
            LauncherMenu.mirroring(items) { chooseDockMenuItem($0, items, url) }
                .popUp(positioning: nil, at: point, in: view)
        }
    }
}

/// The AppKit menu that stands in for an app's Dock menu.
@MainActor
final class LauncherMenu {
    /// Whether a menu is being read or shown, so another right-click waits for it.
    var isShowing = false

    static func mirroring(_ items: [DockMenuItem], choose: @escaping (DockMenuPath) -> Void) -> NSMenu {
        let menu = NSMenu()
        add(items, at: [], of: items, to: menu, choose: choose)
        return menu
    }

    /// The Dock's standard items for the app: its windows, then opening it, and Hide and Quit while it runs.
    static func standard(for url: URL, running app: NSRunningApplication?, windows: [WindowCandidate],
                         open: @escaping () -> Void, focus: @escaping (WindowCandidate) -> Void,
                         showDockMenu: (() -> Void)?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for window in windows {
            menu.addItem(item(window.title.isEmpty ? L("名称未設定") : window.title) { focus(window) })
        }
        if !windows.isEmpty { menu.addItem(.separator()) }
        menu.addItem(item(app == nil ? L("開く") : L("新規ウィンドウ"), action: open))
        menu.addItem(item(L("Finderに表示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        if let showDockMenu { menu.addItem(item(L("Dock のメニューを表示"), action: showDockMenu)) }
        guard let app else { return menu }
        menu.addItem(.separator())
        if app.isHidden {
            menu.addItem(item(L("非表示を解除")) { app.unhide() })
        } else {
            menu.addItem(item(L("非表示")) { app.hide() })
        }
        let quit = item(L("終了")) { app.terminate() }
        quit.keyEquivalentModifierMask = []
        menu.addItem(quit)
        // Like the Dock's, Force Quit replaces Quit while Option is held.
        let forceQuit = item(L("強制終了")) { app.forceTerminate() }
        forceQuit.keyEquivalentModifierMask = .option
        forceQuit.isAlternate = true
        menu.addItem(forceQuit)
        return menu
    }

    private static func add(_ items: [DockMenuItem], at parent: [Int], of root: [DockMenuItem], to menu: NSMenu,
                            choose: @escaping (DockMenuPath) -> Void) {
        menu.autoenablesItems = false
        for (index, item) in items.enumerated() {
            if item.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let entry: NSMenuItem
            if !item.submenu.isEmpty {
                entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: item.title)
                add(item.submenu, at: parent + [index], of: root, to: submenu, choose: choose)
                entry.submenu = submenu
            } else if item.performsAction, let path = DockMenuPath(indices: parent + [index], in: root) {
                entry = Self.item(item.title) { choose(path) }
                entry.isEnabled = item.isEnabled
            } else if #available(macOS 14, *) {
                entry = .sectionHeader(title: item.title)
            } else {
                entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                entry.isEnabled = false
            }
            entry.state = item.isChecked ? .on : .off
            // An alternate replaces the item above it while Option is held. Both need the same key equivalent.
            entry.keyEquivalentModifierMask = item.isAlternate ? .option : []
            entry.isAlternate = item.isAlternate
            menu.addItem(entry)
        }
    }

    private static func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let handler = MenuAction(action)
        let entry = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        entry.target = handler
        // A menu item holds its target weakly.
        entry.representedObject = handler
        return entry
    }

    private final class MenuAction: NSObject {
        private let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }
}

/// Calls `action` for a right-click or Control-click on the view it's the background of. It watches the window's
/// events instead of taking clicks, so a Control-click doesn't also press the button above it.
private struct SecondaryClick: NSViewRepresentable {
    let action: (NSView, NSPoint) -> Void

    func makeNSView(context: Context) -> SecondaryClickView { SecondaryClickView() }

    func updateNSView(_ view: SecondaryClickView, context: Context) { view.action = action }

    static func dismantleNSView(_ view: SecondaryClickView, coordinator: ()) { view.stopMonitoring() }
}

private final class SecondaryClickView: NSView {
    var action: ((NSView, NSPoint) -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMonitoring()
        } else if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] in
                // `handle` returns nil to consume the click, so it mustn't fall back to the event with `??`.
                guard let self else { return $0 }
                return handle($0)
            }
        }
    }

    func stopMonitoring() {
        monitor.map(NSEvent.removeMonitor)
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.type == .rightMouseDown || event.modifierFlags.contains(.control), let action, let window,
              event.window === window, !isHiddenOrHasHiddenAncestor,
              let content = window.contentView else { return event }
        let point = convert(event.locationInWindow, from: nil)
        // SwiftUI's view host reports a visibleRect wider than the view, so check the bounds, and skip clicks on
        // views that cover the page or a scrolled-away app, such as a scroller.
        guard bounds.contains(point),
              let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil)
                  ?? event.locationInWindow),
              isDescendant(of: hit) else { return event }
        action(self, point)
        return nil
    }
}

/// The pinned header of a selectable grid: how to select, then either the button that starts selecting or the
/// actions on the selection.
private struct SelectionHeader<Actions: View>: View {
    let rows: IndexSet?
    let begin: String
    let start: () -> Void
    @ViewBuilder let actions: (IndexSet) -> Actions

    init(rows: IndexSet?, begin: String, start: @escaping () -> Void,
         @ViewBuilder actions: @escaping (IndexSet) -> Actions) {
        self.rows = rows
        self.begin = begin
        self.start = start
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Command + クリックで複数選択 / Shift + クリックで範囲選択")).font(.caption).foregroundStyle(.secondary)
            if let rows {
                ViewThatFits(in: .horizontal) {
                    HStack { actions(rows) }
                    VStack(alignment: .leading) { actions(rows) }
                }
            } else {
                Button(begin, action: start).hoverGlow()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4).background(Color(nsColor: .windowBackgroundColor))
    }
}

private extension GridSelection {
    /// Returns true when a click without Command or Shift should act on the item.
    @MainActor
    mutating func clickWithCurrentModifiers(_ index: Int) -> Bool {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        return click(index, command: flags.contains(.command), shift: flags.contains(.shift))
    }
}

extension View {
    func hoverGlow() -> some View { modifier(HoverGlow()) }
}

private extension View {
    /// A check circle while selecting; nil hides it.
    func selectionMark(_ checked: Bool?) -> some View {
        overlay(alignment: .topTrailing) {
            if let checked {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(checked ? Color.accentColor : .secondary)
                    .background(Circle().fill(.background)).padding(5)
            }
        }
    }
}

private struct HoverGlow: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        let lit = hovering && enabled
        content
            .background(shape.fill(Color.accentColor.opacity(lit ? 0.14 : 0)))
            .overlay(shape.strokeBorder(Color.accentColor.opacity(lit ? 0.85 : 0), lineWidth: 1.5)
                .shadow(color: Color.accentColor.opacity(lit ? 0.6 : 0), radius: 5)
                .allowsHitTesting(false))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

private struct WindowCard: View {
    let candidate: WindowCandidate
    let previews: WindowThumbnails?
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                } else if let icon = candidate.application.icon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 36, height: 36)
                }
            }.frame(height: 84)
            HStack(spacing: 4) {
                if let icon = candidate.application.icon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                }
                Text(candidate.application.localizedName ?? L("対象アプリ")).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(candidate.title.isEmpty ? L("名称未設定") : candidate.title).lineLimit(1)
        }.contentShape(Rectangle()).accessibilityElement(children: .combine)
            .task {
                guard let previews, let id = WindowAccess.windowID(of: candidate.element) else { return }
                let preview = await previews.image(for: id)
                if !Task.isCancelled { image = preview }
            }
    }
}
