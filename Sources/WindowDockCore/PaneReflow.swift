import Foundation

public enum PaneReflow {
    public static func split<ID: Hashable>(
        cells: [ID?], activeCell: Int, at index: Int, windowIDs: [ID], assignments: [ID: Int]
    ) -> GridReflowResult<ID>? {
        guard cells.indices.contains(index), cells.indices.contains(activeCell) else { return nil }
        var result = cells
        result.insert(nil, at: index + 1)
        var mapped = assignments.mapValues { $0 > index ? $0 + 1 : $0 }
        let hidden = windowIDs.filter { !cells.contains($0) }
        if let next = hidden.first(where: { assignments[$0] == index }) ?? hidden.first {
            result[index + 1] = next
            mapped[next] = index + 1
        }
        return GridReflowResult(
            cells: result, activeCell: activeCell > index ? activeCell + 1 : activeCell, assignments: mapped
        )
    }

    public static func close<ID: Hashable>(
        cells: [ID?], activeCell: Int, at index: Int, destination: Int, assignments: [ID: Int]
    ) -> GridReflowResult<ID>? {
        guard cells.count > 1, cells.indices.contains(index), cells.indices.contains(activeCell),
              destination >= 0 && destination < cells.count - 1
        else { return nil }
        var result = cells
        result.remove(at: index)
        func mapped(_ old: Int) -> Int {
            old == index ? destination : old > index ? old - 1 : old
        }
        return GridReflowResult(
            cells: result, activeCell: mapped(activeCell), assignments: assignments.mapValues(mapped)
        )
    }
}
