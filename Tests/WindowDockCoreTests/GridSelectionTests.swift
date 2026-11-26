import WindowDockCore
import XCTest

final class GridSelectionTests: XCTestCase {
    func testPlainClickActsOnTheItemUntilSelectionStarts() {
        var selection = GridSelection()
        XCTAssertTrue(selection.click(2, command: false, shift: false))
        XCTAssertNil(selection.rows)

        XCTAssertFalse(selection.click(2, command: true, shift: false))
        XCTAssertFalse(selection.click(4, command: false, shift: false))
        XCTAssertEqual(selection.rows, IndexSet([2, 4]))
        XCTAssertFalse(selection.click(2, command: false, shift: false))
        XCTAssertEqual(selection.rows, IndexSet([4]))

        selection.cancel()
        XCTAssertTrue(selection.click(4, command: false, shift: false))
    }

    func testShiftClickGrowsAndShrinksARangeFromTheLastClick() {
        var selection = GridSelection()
        selection.begin()
        XCTAssertEqual(selection.rows, IndexSet())
        _ = selection.click(1, command: false, shift: false)
        _ = selection.click(4, command: false, shift: true)
        XCTAssertEqual(selection.rows, IndexSet(1 ... 4))
        _ = selection.click(2, command: false, shift: true)
        XCTAssertEqual(selection.rows, IndexSet(1 ... 2))
        _ = selection.click(0, command: false, shift: true)
        XCTAssertEqual(selection.rows, IndexSet(0 ... 1))
    }

    func testShiftClickKeepsItemsCheckedBeforeTheRange() {
        var selection = GridSelection()
        _ = selection.click(7, command: true, shift: false)
        _ = selection.click(2, command: true, shift: false)
        _ = selection.click(4, command: false, shift: true)
        XCTAssertEqual(selection.rows, IndexSet([2, 3, 4, 7]))
    }
}
