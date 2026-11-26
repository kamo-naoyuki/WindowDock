import Foundation

/// Selection in a grid where a plain click acts on one item, and Command- or Shift-clicks select several.
public struct GridSelection: Equatable {
    private struct RangeStart: Equatable {
        var index: Int
        var checked: IndexSet
    }

    /// nil while a plain click acts on the item. An empty set is still in multi-select mode.
    public private(set) var rows: IndexSet?
    private var rangeStart: RangeStart?

    public init(rows: IndexSet? = nil) {
        self.rows = rows
    }

    public var isSelecting: Bool { rows != nil }

    public mutating func begin() { select(IndexSet()) }

    public mutating func cancel() {
        rows = nil
        rangeStart = nil
    }

    public mutating func select(_ rows: IndexSet) {
        self.rows = rows
        rangeStart = nil
    }

    /// Returns true when the click should act on the item instead of changing the selection.
    public mutating func click(_ index: Int, command: Bool, shift: Bool) -> Bool {
        var rows = self.rows ?? IndexSet()
        if shift {
            let start = rangeStart ?? RangeStart(index: rows.last ?? index, checked: rows)
            rangeStart = start
            rows = start.checked.union(IndexSet(integersIn: min(start.index, index) ... max(start.index, index)))
        } else if command || self.rows != nil {
            if rows.contains(index) { rows.remove(index) } else { rows.insert(index) }
            rangeStart = RangeStart(index: index, checked: rows)
        } else {
            return true
        }
        self.rows = rows
        return false
    }
}
