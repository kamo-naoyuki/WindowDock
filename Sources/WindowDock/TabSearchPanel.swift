import AppKit

struct TabSearchItem {
    let title: String
    let workspaceName: String
    let select: () -> Void

    @MainActor
    static func entries(
        for session: WindowSession, workspaceName: String, onSelect: @escaping (UUID) -> Void
    ) -> [TabSearchItem] {
        let windows = session.tabIDs.compactMap { id -> TabSearchItem? in
            guard let window = session.managedByID[id] else { return nil }
            return TabSearchItem(title: window.candidate.label, workspaceName: workspaceName) {
                onSelect(id)
            }
        }
        let groups = session.tabEntries.compactMap { id -> TabSearchItem? in
            guard session.isPaneGroup(id) else { return nil }
            let titles = session.groupMembers(id).compactMap { session.managedByID[$0]?.candidate.label }
            guard !titles.isEmpty else { return nil }
            let title = L("まとめたタブ") + " · " + titles.joined(separator: " | ")
            return TabSearchItem(title: title, workspaceName: workspaceName) {
                onSelect(id)
            }
        }
        return windows + groups
    }
}

@MainActor
final class TabSearchPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let selectButton = NSButton(title: L("切り替え"), target: nil, action: nil)
    private let items: [TabSearchItem]
    private var filteredItems: [TabSearchItem]
    private var pendingSelection: TabSearchItem?

    var filteredResultCount: Int { filteredItems.count }

    init(items: [TabSearchItem]) {
        self.items = items
        filteredItems = items
        super.init()
        panel.title = L("ウィンドウを検索")
        searchField.placeholderString = L("アプリ名、ウィンドウ名、ワークスペース名で検索")
        searchField.target = self
        searchField.action = #selector(searchChanged)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("window"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 32
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(selectCurrent)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        selectButton.target = self
        selectButton.action = #selector(selectCurrent)
        selectButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: L("キャンセル"), target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancelButton, selectButton])
        buttons.spacing = 12
        let content = NSStackView(views: [searchField, scroll, buttons])
        content.orientation = .vertical
        content.alignment = .trailing
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 18),
            content.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -18),
            searchField.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        filterResults(for: "")
    }

    func present(on window: NSWindow, completion: @escaping (TabSearchItem?) -> Void) {
        pendingSelection = nil
        window.beginSheet(panel) { [weak self] _ in
            guard let self else { return }
            completion(self.pendingSelection)
            self.pendingSelection = nil
        }
        panel.makeFirstResponder(searchField)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredItems.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectButton.isEnabled = table.selectedRow >= 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = filteredItems[row]
        let title = "\(item.title)  —  \(item.workspaceName)"
        let label = NSTextField(labelWithString: title)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = title
        return label
    }

    func filterResults(for query: String) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        filteredItems = items.filter { item in
            guard !normalizedQuery.isEmpty else { return true }
            let searchableText = "\(item.title) \(item.workspaceName)"
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return searchableText.localizedStandardContains(normalizedQuery)
        }
        table.reloadData()
        if !filteredItems.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        selectButton.isEnabled = !filteredItems.isEmpty
    }

    @objc private func searchChanged() {
        filterResults(for: searchField.stringValue)
    }

    @objc private func selectCurrent() {
        guard filteredItems.indices.contains(table.selectedRow) else { return }
        pendingSelection = filteredItems[table.selectedRow]
        panel.sheetParent?.endSheet(panel, returnCode: .OK)
    }

    @objc private func cancel() {
        pendingSelection = nil
        panel.sheetParent?.endSheet(panel, returnCode: .cancel)
    }
}
