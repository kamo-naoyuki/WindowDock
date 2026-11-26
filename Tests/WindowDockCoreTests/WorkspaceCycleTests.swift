import WindowDockCore
import XCTest

final class WorkspaceCycleTests: XCTestCase {
    func testWrapsAroundInBothDirections() {
        XCTAssertEqual(WorkspaceCycle.target(from: 2, offset: 1, count: 3) { _ in true }, 0)
        XCTAssertEqual(WorkspaceCycle.target(from: 0, offset: -1, count: 3) { _ in true }, 2)
    }

    func testSkipsIneligibleWorkspacesAndNeverReturnsTheCurrentOne() {
        XCTAssertEqual(WorkspaceCycle.target(from: 0, offset: 1, count: 4) { $0 == 3 }, 3)
        XCTAssertNil(WorkspaceCycle.target(from: 1, offset: 1, count: 3) { $0 == 1 })
        XCTAssertNil(WorkspaceCycle.target(from: 0, offset: -1, count: 1) { _ in true })
    }

    func testStartsAtAnEndWithoutACurrentWorkspace() {
        XCTAssertEqual(WorkspaceCycle.target(from: nil, offset: 1, count: 3) { _ in true }, 0)
        XCTAssertEqual(WorkspaceCycle.target(from: nil, offset: -1, count: 3) { _ in true }, 2)
    }
}
