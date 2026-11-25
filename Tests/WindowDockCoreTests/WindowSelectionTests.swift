import WindowDockCore
import XCTest

final class WindowSelectionTests: XCTestCase {
    func testSelectsWindowsOfAllRepresentedAppsWithoutIncludingUnselectedApps() {
        let apps: [Int32] = [10, 20, 30, 10, 20, 30]
        XCTAssertEqual(IndexSet([0, 4]).includingWindowsOfSelectedApps(in: apps), IndexSet([0, 1, 3, 4]))
        XCTAssertTrue(IndexSet().includingWindowsOfSelectedApps(in: apps).isEmpty)
    }
}
