import AppKit

@MainActor
final class WindowPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 650, height: 420),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    private let table = NSTableView()
    private let addButton = NSButton(title: L("追加"), target: nil, action: nil)
    private let selectAppButton = NSButton(title: L("選択したアプリの全ウィンドウを選択"), target: nil, action: nil)
    private let candidates: [WindowCandidate]
    private let onSelect: ([WindowCandidate]) -> Void

    init(candidates: [WindowCandidate], failedApplications: [String], suggested: [Int] = [], onSelect: @escaping ([WindowCandidate]) -> Void) {
        self.candidates = candidates
        self.onSelect = onSelect
        super.init()
        panel.title = L("タブに追加するウィンドウ")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("window"))
        column.title = L("アプリ / ウィンドウ")
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 34
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(add)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        addButton.target = self
        addButton.action = #selector(add)
        addButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: L("キャンセル"), target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        selectAppButton.target = self
        selectAppButton.action = #selector(selectAllOfApps)
        let buttons = NSStackView(views: [selectAppButton, cancelButton, addButton])
        buttons.spacing = 12
        var note: String
        if !failedApplications.isEmpty {
            note = L("取得できなかったアプリ: %@", failedApplications.joined(separator: L("、")))
        } else if candidates.isEmpty {
            note = L("追加できるウィンドウがありません。別のアプリで通常のウィンドウを開いてください。")
        } else {
            note = L("ウィンドウを選んで追加。フルスクリーンは事前に解除してください。")
        }
        if !candidates.isEmpty {
            note += L("\nCommand + クリックで複数選択 / Shift + クリックで範囲選択")
        }
        let label = NSTextField(wrappingLabelWithString: note)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        let content = NSStackView(views: [scroll, label, buttons])
        content.orientation = .vertical
        content.alignment = .trailing
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            label.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        if !suggested.isEmpty {
            table.selectRowIndexes(IndexSet(suggested), byExtendingSelection: false)
            table.scrollRowToVisible(suggested[0])
        } else if !candidates.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateAddButton()
    }

    func present(on window: NSWindow, completion: @escaping () -> Void) {
        window.beginSheet(panel) { _ in completion() }
        panel.makeFirstResponder(table)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateAddButton()
    }

    private func updateAddButton() {
        let count = table.selectedRowIndexes.count
        addButton.isEnabled = count > 0
        selectAppButton.isEnabled = count > 0
        addButton.title = count > 1 ? L("%d件を追加", count) : L("追加")
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: candidates[row].label)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = candidates[row].label
        return label
    }

    @objc private func selectAllOfApps() {
        let pids = Set(table.selectedRowIndexes.map { candidates[$0].application.processIdentifier })
        let rows = candidates.indices.filter { pids.contains(candidates[$0].application.processIdentifier) }
        table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    @objc private func add() {
        let selected = table.selectedRowIndexes.map { candidates[$0] }
        guard !selected.isEmpty else { return }
        onSelect(selected)
        panel.sheetParent?.endSheet(panel)
    }

    @objc private func cancel() {
        panel.sheetParent?.endSheet(panel)
    }
}
