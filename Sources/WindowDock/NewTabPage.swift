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
    var browse: (@escaping (URL) -> Void) -> Void

    private struct Request: Equatable {
        let id = UUID()
        var app: URL?
    }
    @State private var request = Request()
    @State private var choices: [WindowCandidate] = []
    @State private var initialSelection: IndexSet?
    @State private var recent: [URL] = []
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
                        Button(L("復元しない"), action: restoration.skip).keyboardShortcut(.cancelAction)
                    }
                    Button { request = Request() } label: {
                        Image(systemName: "arrow.clockwise")
                    }.help(L("一覧を更新")).accessibilityLabel(L("一覧を更新"))
                }
                if restoration != nil {
                    Text(L("前回のタブに一致するウィンドウが選択されています。復元するウィンドウを確認してください。"))
                        .foregroundStyle(.secondary)
                }
                if loading { ProgressView().controlSize(.small) }
                if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
                if needsPermission {
                    Button(L("権限設定")) { access.requestPermission() }
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
                    }.controlSize(.small)
                }
                if !choices.isEmpty {
                    WindowChoiceGrid(windows: choices, previews: previews, restoring: initialSelection, choose: choose)
                        .id(request.id)
                }
                if restoration == nil { launchActions }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: request) { await load(request) }
    }

    @ViewBuilder
    private var launchActions: some View {
        Divider()
        Text(L("最近追加したアプリ")).font(.headline)
        if recent.isEmpty {
            Text(L("ウィンドウを追加すると、ここにアプリが表示されます。")).foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 96))], alignment: .leading) {
                ForEach(recent, id: \.self) { url in
                    Button { request = Request(app: url) } label: {
                        VStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable().scaledToFit().frame(width: 40, height: 40)
                            Text(FileManager.default.displayName(atPath: url.path)).lineLimit(1)
                        }.frame(maxWidth: .infinity).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
        Divider()
        Button(L("その他のアプリを選んで起動…")) { browse { request = Request(app: $0) } }
    }

    private func load(_ request: Request) async {
        if restoration == nil {
            recent = RecentApplications().identifiers
                .compactMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:))
        }
        choices = []
        initialSelection = nil
        message = ""
        loading = true
        previews = nil
        defer { if !Task.isCancelled { loading = false } }
        needsPermission = !access.isTrusted()
        guard !needsPermission else {
            message = L("追加にはアクセシビリティ権限が必要です。システム設定で現在の WindowDock を許可してください。")
            return
        }
        var candidates: [WindowCandidate]
        if let url = request.app {
            do {
                candidates = try await launch(url)
                try Task.checkCancellation()
                if candidates.count == 1, choose(candidates) { return }
                if candidates.isEmpty { message = L("アプリは起動しましたが、追加できるウィンドウが見つかりませんでした。") }
            } catch {
                if !Task
                    .isCancelled { message = L("%@を起動できませんでした: %@", url.lastPathComponent, error.localizedDescription) }
                return
            }
        } else {
            let scan = await Task.detached(priority: .userInitiated) { [scan = access.scan] in scan() }.value
            guard !Task.isCancelled else { return }
            candidates = scan.windows.filter(isAvailable)
            if !scan.failedApplications.isEmpty {
                message = L("取得できなかったアプリ: %@", scan.failedApplications.joined(separator: L("、")))
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
        }
        previews = CGPreflightScreenCaptureAccess() ? WindowThumbnails() : nil
        choices = candidates
    }

}

struct WindowChoiceGrid: View {
    let windows: [WindowCandidate]
    let previews: WindowThumbnails?
    let choose: ([WindowCandidate]) -> Bool
    // nil keeps the usual one-click add; an empty selection is still in multi-select mode.
    @State private var selection: IndexSet?
    @State private var rangeStart: (index: Int, checked: IndexSet)?
    private let restoring: Bool

    init(windows: [WindowCandidate], previews: WindowThumbnails?, restoring: IndexSet? = nil,
         choose: @escaping ([WindowCandidate]) -> Bool) {
        self.windows = windows
        self.previews = previews
        self.choose = choose
        self.restoring = restoring != nil
        _selection = State(initialValue: restoring)
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 200))], alignment: .leading,
                  pinnedViews: [.sectionHeaders]) {
            Section {
                ForEach(windows.indices, id: \.self) { index in
                    let window = windows[index]
                    let checked = selection?.contains(index) == true
                    Button {
                        click(index)
                    } label: {
                        WindowCard(candidate: window, previews: previews)
                            .overlay(alignment: .topTrailing) {
                                if selection != nil {
                                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(checked ? Color.accentColor : .secondary)
                                        .background(Circle().fill(.background)).padding(5)
                                }
                            }
                    }.buttonStyle(.plain).help(window.label)
                        .accessibilityLabel(window.label)
                        .accessibilityAddTraits(checked ? .isSelected : [])
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Command + クリックで複数選択 / Shift + クリックで範囲選択")).font(.caption).foregroundStyle(.secondary)
                    if let selection {
                        ViewThatFits(in: .horizontal) {
                            HStack { selectionActions(selection) }
                            VStack(alignment: .leading) { selectionActions(selection) }
                        }
                    } else {
                        Button(L("複数選択")) { selection = IndexSet() }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4).background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    private func click(_ index: Int) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        var rows = selection ?? IndexSet()
        if flags.contains(.shift) {
            let start = rangeStart ?? (index: rows.last ?? index, checked: rows)
            rangeStart = start
            rows = start.checked.union(IndexSet(integersIn: min(start.index, index) ... max(start.index, index)))
        } else if flags.contains(.command) || selection != nil {
            if rows.contains(index) { rows.remove(index) } else { rows.insert(index) }
            rangeStart = (index, rows)
        } else {
            _ = choose([windows[index]])
            return
        }
        selection = rows
    }

    @ViewBuilder
    private func selectionActions(_ rows: IndexSet) -> some View {
        Button(L("選択したアプリの全ウィンドウを選択")) {
            selection = rows.includingWindowsOfSelectedApps(in: windows.map(\.application.processIdentifier))
            rangeStart = nil
        }.disabled(rows.isEmpty)
        if !restoring {
            Button(L("キャンセル")) {
                selection = nil
                rangeStart = nil
            }
        }
        Button(restoring ? L("%d件を復元", rows.count) : L("%d件を追加", rows.count)) { _ = choose(rows.map { windows[$0] }) }
            .buttonStyle(.borderedProminent).disabled(rows.isEmpty)
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
