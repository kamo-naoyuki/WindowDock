import AppKit
import WindowDockCore

struct WorkspaceGridSize: Equatable {
    let columns: Int
    let rows: Int
    var cellCount: Int { columns * rows }
    var isValid: Bool { (1...4).contains(columns) && (1...4).contains(rows) }
    static let single = WorkspaceGridSize(columns: 1, rows: 1)
}

private final class WorkspaceGridCell: NSView {
    var onClick: (() -> Void)?
    // The click that activates WindowDock must already hand focus to the pane's window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class WorkspaceGridView: NSView {
    private(set) var gridSize = WorkspaceGridSize.single
    private(set) var areas: [NSView] = []
    var onActivate: ((Int) -> Void)?
    var onGeometryChange: (() -> Void)?
    let dividerThickness: CGFloat = 8
    private var columnWeights: [CGFloat] = [1]
    private var rowWeights: [CGFloat] = [1]
    private var columnMinimums: [CGFloat] = [0]
    private var rowMinimums: [CGFloat] = [0]
    private var activeCell = 0
    private var lastBoundsSize = NSSize.zero
    private var layingOut = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        rebuild()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        rebuild()
    }

    func setGrid(_ size: WorkspaceGridSize, activeCell: Int) {
        guard size.isValid else { return }
        if size != gridSize {
            gridSize = size
            columnWeights = Array(repeating: 1 / CGFloat(size.columns), count: size.columns)
            rowWeights = Array(repeating: 1 / CGFloat(size.rows), count: size.rows)
            columnMinimums = Array(repeating: 0, count: size.columns)
            rowMinimums = Array(repeating: 0, count: size.rows)
            rebuild()
        }
        setActiveCell(activeCell)
        layoutCells()
    }

    func setActiveCell(_ index: Int) {
        activeCell = min(max(0, index), max(0, areas.count - 1))
        for (i, area) in areas.enumerated() {
            area.layer?.borderWidth = i == activeCell ? 2 : 0
            area.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    private func rebuild() {
        areas.forEach { $0.removeFromSuperview() }
        areas = (0..<gridSize.cellCount).map { index in
            let cell = WorkspaceGridCell()
            cell.wantsLayer = true
            cell.translatesAutoresizingMaskIntoConstraints = false
            cell.onClick = { [weak self] in self?.onActivate?(index) }
            addSubview(cell)
            return cell
        }
        setActiveCell(activeCell)
        needsLayout = true
    }

    private func lengths(_ weights: [CGFloat], minimums: [CGFloat], available: CGFloat) -> [CGFloat] {
        WindowGeometry.lengths(weights, minimums: minimums, available: available)
    }

    @discardableResult
    func fitMinimumSizes(_ sizes: [Int: CGSize]) -> Bool {
        guard let (columns, rows) = WindowGeometry.trackMinimums(sizes, columns: gridSize.columns, rows: gridSize.rows) else { return false }
        let width = bounds.width - CGFloat(gridSize.columns - 1) * dividerThickness
        let height = bounds.height - CGFloat(gridSize.rows - 1) * dividerThickness
        guard columns.reduce(0, +) <= width, rows.reduce(0, +) <= height else { return false }
        columnMinimums = columns
        rowMinimums = rows
        layoutCells()
        return true
    }

    override func layout() {
        super.layout()
        layoutCells()
    }

    private func layoutCells() {
        guard !layingOut, areas.count == gridSize.cellCount else { return }
        layingOut = true
        defer { layingOut = false }
        let widths = lengths(columnWeights, minimums: columnMinimums, available: max(0, bounds.width - CGFloat(gridSize.columns - 1) * dividerThickness))
        let heights = lengths(rowWeights, minimums: rowMinimums, available: max(0, bounds.height - CGFloat(gridSize.rows - 1) * dividerThickness))
        var y = bounds.maxY
        var changed = lastBoundsSize != bounds.size
        lastBoundsSize = bounds.size
        for row in 0..<gridSize.rows {
            y -= heights[row]
            var x = bounds.minX
            for column in 0..<gridSize.columns {
                let area = areas[row * gridSize.columns + column]
                let frame = NSRect(x: x, y: y, width: widths[column], height: heights[row])
                if area.frame != frame { area.frame = frame; changed = true }
                x += widths[column] + dividerThickness
            }
            y -= dividerThickness
        }
        if changed {
            window?.invalidateCursorRects(for: self)
            onGeometryChange?()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for column in 0..<(gridSize.columns - 1) {
            let edge = areas[column].frame.maxX
            addCursorRect(NSRect(x: edge, y: bounds.minY, width: dividerThickness, height: bounds.height), cursor: .resizeLeftRight)
        }
        for row in 0..<(gridSize.rows - 1) {
            let edge = areas[row * gridSize.columns].frame.minY
            addCursorRect(NSRect(x: bounds.minX, y: edge - dividerThickness, width: bounds.width, height: dividerThickness), cursor: .resizeUpDown)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let column = (0..<(gridSize.columns - 1)).first { abs(point.x - (areas[$0].frame.maxX + dividerThickness / 2)) <= dividerThickness / 2 }
        let row = (0..<(gridSize.rows - 1)).first { abs(point.y - (areas[$0 * gridSize.columns].frame.minY - dividerThickness / 2)) <= dividerThickness / 2 }
        guard column != nil || row != nil else { return }
        let initialWidths = (0..<gridSize.columns).map { areas[$0].frame.width }
        let initialHeights = (0..<gridSize.rows).map { areas[$0 * gridSize.columns].frame.height }
        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            let current = convert(next.locationInWindow, from: nil)
            if let column {
                let total = initialWidths[column] + initialWidths[column + 1]
                if total >= columnMinimums[column] + columnMinimums[column + 1] {
                    let first = min(max(initialWidths[column] + current.x - point.x, columnMinimums[column]), total - columnMinimums[column + 1])
                    var sizes = initialWidths
                    sizes[column] = first; sizes[column + 1] = total - first
                    let sum = sizes.reduce(0, +)
                    if sum > 0 { columnWeights = sizes.map { $0 / sum } }
                }
            }
            if let row {
                let total = initialHeights[row] + initialHeights[row + 1]
                if total >= rowMinimums[row] + rowMinimums[row + 1] {
                    let first = min(max(initialHeights[row] + point.y - current.y, rowMinimums[row]), total - rowMinimums[row + 1])
                    var sizes = initialHeights
                    sizes[row] = first; sizes[row + 1] = total - first
                    let sum = sizes.reduce(0, +)
                    if sum > 0 { rowWeights = sizes.map { $0 / sum } }
                }
            }
            layoutCells()
            if next.type == .leftMouseUp { break }
        }
    }
}
