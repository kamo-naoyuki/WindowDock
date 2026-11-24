import XCTest

@testable import WindowDockCore

final class GridReflowTests: XCTestCase {
    func testGrowingKeepsPositions() {
        let r = GridReflow.reflow(
            oldColumns: 1, oldCells: ["a"], activeCell: 0, newColumns: 2, newRows: 1,
            windowIDs: ["a", "b"], assignments: ["a": 0, "b": 0])
        XCTAssertEqual(r.cells, ["a", "b"])
        XCTAssertEqual(r.activeCell, 0)
        XCTAssertEqual(r.assignments["b"], 1)
    }

    func testShrinkingMovesDroppedWindowsToEmptyCells() {
        let r = GridReflow.reflow(
            oldColumns: 2, oldCells: ["a", "b"], activeCell: 1, newColumns: 1, newRows: 1,
            windowIDs: ["a", "b"], assignments: ["a": 0, "b": 1])
        XCTAssertEqual(r.cells, ["b"])
        XCTAssertEqual(r.activeCell, 0)
        XCTAssertEqual(r.assignments["b"], 0)
        XCTAssertEqual(r.assignments["a"], 0)
    }

    func testActiveCellFollowsSelectedWindow() {
        let r = GridReflow.reflow(
            oldColumns: 2, oldCells: ["a", "b", nil, nil], activeCell: 1, newColumns: 3, newRows: 1,
            windowIDs: ["a", "b"], assignments: ["a": 0, "b": 1])
        XCTAssertEqual(r.cells, ["a", "b", nil])
        XCTAssertEqual(r.activeCell, 1)
    }
}
