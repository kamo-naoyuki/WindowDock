import Foundation

public struct GridReflowResult<ID: Hashable> {
    public var cells: [ID?]
    public var activeCell: Int
    public var assignments: [ID: Int]
}

public enum GridReflow {
    /// Re-places windows after the grid changes size, keeping each one in its row/column when it still fits.
    /// Empty cells are filled from `fillIDs` (all of `windowIDs` when nil).
    public static func reflow<ID: Hashable>(
        oldColumns: Int,
        oldCells: [ID?],
        activeCell: Int,
        newColumns: Int,
        newRows: Int,
        windowIDs: [ID],
        assignments: [ID: Int],
        fillIDs: [ID]? = nil
    ) -> GridReflowResult<ID> {
        let oldSelected = oldCells[activeCell]
        let row = min(activeCell / oldColumns, newRows - 1)
        let column = min(activeCell % oldColumns, newColumns - 1)
        var active = row * newColumns + column
        var cells = [ID?](repeating: nil, count: newColumns * newRows)
        for (index, id) in oldCells.enumerated() {
            let row = index / oldColumns
            let column = index % oldColumns
            if row < newRows, column < newColumns {
                cells[row * newColumns + column] = id
            }
        }
        for id in oldCells.compactMap({ $0 }) where !cells.contains(where: { $0 == id }) {
            guard let empty = cells.firstIndex(where: { $0 == nil }) else { break }
            cells[empty] = id
        }
        if let oldSelected {
            if let index = cells.firstIndex(where: { $0 == oldSelected }) {
                active = index
            } else {
                cells[active] = oldSelected
            }
        }
        for id in fillIDs ?? windowIDs where !cells.contains(where: { $0 == id }) {
            guard let empty = cells.firstIndex(where: { $0 == nil }) else { break }
            cells[empty] = id
        }
        var newAssignments = assignments
        for id in windowIDs {
            let old = assignments[id] ?? 0
            newAssignments[id] = min(old / oldColumns, newRows - 1) * newColumns + min(old % oldColumns, newColumns - 1)
        }
        for (index, id) in cells.enumerated() {
            if let id { newAssignments[id] = index }
        }
        return GridReflowResult(cells: cells, activeCell: active, assignments: newAssignments)
    }
}
