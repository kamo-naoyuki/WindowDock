import AppKit
import WindowDockCore

struct WorkspaceGridSize: Equatable {
    let columns: Int
    let rows: Int
    var cellCount: Int { columns * rows }
    var isValid: Bool {
        (1 ... PaneLayout.maximumDivisions).contains(columns) && (1 ... PaneLayout.maximumDivisions).contains(rows)
    }
    static let single = WorkspaceGridSize(columns: 1, rows: 1)
}

private final class WorkspaceGridCell: NSView {
    var onClick: (() -> Void)?
    var makeMenu: (() -> NSMenu?)?
    // The click that activates WindowDock must already hand focus to the pane's window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
}

final class WorkspaceGridView: NSView {
    private(set) var gridSize = WorkspaceGridSize.single
    private(set) var customLayout: PaneLayout?
    private(set) var areas: [NSView] = []
    var onActivate: ((Int) -> Void)?
    var onGeometryChange: (() -> Void)?
    var onCustomLayoutChange: ((PaneLayout) -> Void)?
    var menuForPane: ((Int) -> NSMenu?)?
    let dividerThickness = PaneLayout.dividerThickness
    private var columnWeights: [CGFloat] = [1]
    private var rowWeights: [CGFloat] = [1]
    private var columnMinimums: [CGFloat] = [0]
    private var rowMinimums: [CGFloat] = [0]
    private var activeCell = 0
    private var switchTargetCell: Int?
    private var pinnedCells: Set<Int> = []
    private var lastBoundsSize = NSSize.zero
    private var layingOut = false
    private var paneMinimums: [Int: CGSize] = [:]
    private var nestedDividers: [PaneLayout.Divider] = []

    var paneLayout: PaneLayout {
        customLayout ?? .grid(columnWeights: columnWeights, rowWeights: rowWeights)
    }

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
        if size != gridSize || customLayout != nil {
            gridSize = size
            customLayout = nil
            paneMinimums = [:]
            nestedDividers = []
            columnWeights = Array(repeating: 1 / CGFloat(size.columns), count: size.columns)
            rowWeights = Array(repeating: 1 / CGFloat(size.rows), count: size.rows)
            columnMinimums = Array(repeating: 0, count: size.columns)
            rowMinimums = Array(repeating: 0, count: size.rows)
            rebuild()
        }
        setActiveCell(activeCell)
        layoutCells()
    }

    func setCustomLayout(_ layout: PaneLayout, activeCell: Int) {
        precondition(layout.isValid)
        let rebuildNeeded = customLayout == nil || layout.paneCount != areas.count
        customLayout = layout
        if rebuildNeeded {
            paneMinimums = [:]
            rebuild()
        }
        setActiveCell(activeCell)
        layoutCells()
    }

    func setActiveCell(_ index: Int) {
        activeCell = min(max(0, index), max(0, areas.count - 1))
        updatePaneIndicators()
    }

    func setPaneIndicators(switchTargetCell: Int?, pinnedCells: Set<Int>) {
        self.switchTargetCell = switchTargetCell
        self.pinnedCells = pinnedCells
        updatePaneIndicators()
    }

    private func updatePaneIndicators() {
        for (i, area) in areas.enumerated() {
            if pinnedCells.contains(i) {
                area.layer?.borderWidth = 2
                area.layer?.borderColor = NSColor.systemOrange.cgColor
            } else if i == switchTargetCell {
                area.layer?.borderWidth = 3
                area.layer?.borderColor = NSColor.controlAccentColor.cgColor
            } else if i == activeCell {
                area.layer?.borderWidth = 1
                area.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
            } else {
                area.layer?.borderWidth = 0
            }
        }
    }

    private func rebuild() {
        areas.forEach { $0.removeFromSuperview() }
        areas = (0 ..< (customLayout?.paneCount ?? gridSize.cellCount)).map { index in
            let cell = WorkspaceGridCell()
            cell.wantsLayer = true
            // layoutCells() owns the frame. Expose it to Auto Layout for content pinned inside the cell.
            cell.translatesAutoresizingMaskIntoConstraints = true
            cell.onClick = { [weak self] in self?.onActivate?(index) }
            cell.makeMenu = { [weak self] in self?.menuForPane?(index) }
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
        if let customLayout {
            guard let minimum = customLayout.minimumSize(sizes, dividerThickness: dividerThickness),
                  minimum.width <= bounds.width, minimum.height <= bounds.height
            else { return false }
            paneMinimums = sizes
            layoutCells()
            return true
        }
        guard let (columns, rows) = WindowGeometry.trackMinimums(sizes, columns: gridSize.columns, rows: gridSize.rows)
        else { return false }
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
        guard !layingOut, areas.count == (customLayout?.paneCount ?? gridSize.cellCount) else { return }
        layingOut = true
        defer { layingOut = false }
        if let customLayout {
            guard
                let geometry = customLayout.geometry(
                    in: bounds, minimums: paneMinimums, dividerThickness: dividerThickness
                )
            else {
                assertionFailure("Invalid pane geometry")
                return
            }
            var changed = lastBoundsSize != bounds.size
            lastBoundsSize = bounds.size
            nestedDividers = geometry.dividers
            for (area, frame) in zip(areas, geometry.panes) where area.frame != frame {
                area.frame = frame
                changed = true
            }
            if changed {
                window?.invalidateCursorRects(for: self)
                onGeometryChange?()
            }
            return
        }
        let widths = lengths(
            columnWeights, minimums: columnMinimums,
            available: max(0, bounds.width - CGFloat(gridSize.columns - 1) * dividerThickness)
        )
        let heights = lengths(
            rowWeights, minimums: rowMinimums,
            available: max(0, bounds.height - CGFloat(gridSize.rows - 1) * dividerThickness)
        )
        var y = bounds.maxY
        var changed = lastBoundsSize != bounds.size
        lastBoundsSize = bounds.size
        for row in 0 ..< gridSize.rows {
            y -= heights[row]
            var x = bounds.minX
            for column in 0 ..< gridSize.columns {
                let area = areas[row * gridSize.columns + column]
                let frame = NSRect(x: x, y: y, width: widths[column], height: heights[row])
                if area.frame != frame {
                    area.frame = frame
                    changed = true
                }
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
        if customLayout != nil {
            for divider in nestedDividers {
                addCursorRect(divider.frame, cursor: divider.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
            }
            return
        }
        for column in 0 ..< (gridSize.columns - 1) {
            let edge = areas[column].frame.maxX
            addCursorRect(
                NSRect(x: edge, y: bounds.minY, width: dividerThickness, height: bounds.height),
                cursor: .resizeLeftRight
            )
        }
        for row in 0 ..< (gridSize.rows - 1) {
            let edge = areas[row * gridSize.columns].frame.minY
            addCursorRect(
                NSRect(x: bounds.minX, y: edge - dividerThickness, width: bounds.width, height: dividerThickness),
                cursor: .resizeUpDown
            )
        }
    }

    @discardableResult
    func resizePaneBoundary(at paneIndex: Int, edge: WorkspaceResizeEdges, by delta: CGFloat) -> Bool {
        guard delta.isFinite, areas.indices.contains(paneIndex) else { return false }
        if let customLayout {
            guard let geometry = customLayout.geometry(
                in: bounds, minimums: paneMinimums, dividerThickness: dividerThickness
            ), geometry.panes.indices.contains(paneIndex)
            else { return false }
            let pane = geometry.panes[paneIndex]
            guard let divider = geometry.dividers.first(where: { divider in
                switch edge {
                case .left:
                    return divider.axis == .horizontal && abs(pane.minX - divider.frame.maxX) <= 1
                case .right:
                    return divider.axis == .horizontal && abs(pane.maxX - divider.frame.minX) <= 1
                case .top:
                    return divider.axis == .vertical && abs(pane.maxY - divider.frame.minY) <= 1
                case .bottom:
                    return divider.axis == .vertical && abs(pane.minY - divider.frame.maxY) <= 1
                default:
                    return false
                }
            }), let resized = customLayout.resizing(divider, by: delta)
            else { return false }
            self.customLayout = resized
            onCustomLayoutChange?(resized)
            layoutCells()
            return true
        }

        return resizeGridBoundary(at: paneIndex, edge: edge, by: delta)
    }

    private func resizeGridBoundary(at paneIndex: Int, edge: WorkspaceResizeEdges, by delta: CGFloat) -> Bool {
        let row = paneIndex / gridSize.columns
        let column = paneIndex % gridSize.columns
        if edge == .left || edge == .right {
            let divider = edge == .left ? column - 1 : column
            guard (0 ..< gridSize.columns - 1).contains(divider) else { return false }
            var widths = (0 ..< gridSize.columns).map { areas[$0].frame.width }
            let total = widths[divider] + widths[divider + 1]
            guard total >= columnMinimums[divider] + columnMinimums[divider + 1] else { return false }
            widths[divider] = min(
                max(widths[divider] + delta, columnMinimums[divider]),
                total - columnMinimums[divider + 1]
            )
            widths[divider + 1] = total - widths[divider]
            let sum = widths.reduce(0, +)
            guard sum > 0 else { return false }
            columnWeights = widths.map { $0 / sum }
        } else if edge == .top || edge == .bottom {
            let divider = edge == .bottom ? row : row - 1
            guard (0 ..< gridSize.rows - 1).contains(divider) else { return false }
            var heights = (0 ..< gridSize.rows).map { areas[$0 * gridSize.columns].frame.height }
            let total = heights[divider] + heights[divider + 1]
            guard total >= rowMinimums[divider] + rowMinimums[divider + 1] else { return false }
            heights[divider] = min(
                max(heights[divider] + delta, rowMinimums[divider]),
                total - rowMinimums[divider + 1]
            )
            heights[divider + 1] = total - heights[divider]
            let sum = heights.reduce(0, +)
            guard sum > 0 else { return false }
            rowWeights = heights.map { $0 / sum }
        } else {
            return false
        }
        layoutCells()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let customLayout {
            guard let divider = nestedDividers.first(where: { $0.frame.contains(point) }) else { return }
            while let next = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking,
                dequeue: true
            )
            {
                let current = convert(next.locationInWindow, from: nil)
                let delta = divider.axis == .horizontal ? current.x - point.x : point.y - current.y
                if let resized = customLayout.resizing(divider, by: delta) {
                    self.customLayout = resized
                    onCustomLayoutChange?(resized)
                    layoutCells()
                }
                if next.type == .leftMouseUp { break }
            }
            return
        }
        let column = (0 ..< (gridSize.columns - 1)).first {
            abs(point.x - (areas[$0].frame.maxX + dividerThickness / 2)) <= dividerThickness / 2
        }
        let row = (0 ..< (gridSize.rows - 1)).first {
            abs(point.y - (areas[$0 * gridSize.columns].frame.minY - dividerThickness / 2)) <= dividerThickness / 2
        }
        guard column != nil || row != nil else { return }
        let initialWidths = (0 ..< gridSize.columns).map { areas[$0].frame.width }
        let initialHeights = (0 ..< gridSize.rows).map { areas[$0 * gridSize.columns].frame.height }
        while let next = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true
        )
        {
            let current = convert(next.locationInWindow, from: nil)
            if let column {
                let total = initialWidths[column] + initialWidths[column + 1]
                if total >= columnMinimums[column] + columnMinimums[column + 1] {
                    let first = min(
                        max(initialWidths[column] + current.x - point.x, columnMinimums[column]),
                        total - columnMinimums[column + 1]
                    )
                    var sizes = initialWidths
                    sizes[column] = first
                    sizes[column + 1] = total - first
                    let sum = sizes.reduce(0, +)
                    if sum > 0 { columnWeights = sizes.map { $0 / sum } }
                }
            }
            if let row {
                let total = initialHeights[row] + initialHeights[row + 1]
                if total >= rowMinimums[row] + rowMinimums[row + 1] {
                    let first = min(
                        max(initialHeights[row] + point.y - current.y, rowMinimums[row]), total - rowMinimums[row + 1]
                    )
                    var sizes = initialHeights
                    sizes[row] = first
                    sizes[row + 1] = total - first
                    let sum = sizes.reduce(0, +)
                    if sum > 0 { rowWeights = sizes.map { $0 / sum } }
                }
            }
            layoutCells()
            if next.type == .leftMouseUp { break }
        }
    }
}
