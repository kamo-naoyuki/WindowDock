import XCTest
@testable import WindowDockCore

final class WindowHitTestingTests: XCTestCase {
    func testFindsVisibleWorkspaceUnderDraggedWindowAndFeedback() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let windows: [(id: UInt32, frame: CGRect)] = [(1, frame), (2, frame), (3, frame)]
        XCTAssertEqual(WindowHitTesting.frontmostWindow(
            at: CGPoint(x: 50, y: 50), windows: windows, excluding: [1, 2]
        ), 3)
    }

    func testOtherWindowsBlockWorkspaceOnlyWhereTheyOverlap() {
        let windows: [(id: UInt32, frame: CGRect)] = [
            (1, CGRect(x: 0, y: 0, width: 100, height: 100)),
            (2, CGRect(x: 0, y: 0, width: 40, height: 100)),
            (3, CGRect(x: 0, y: 0, width: 100, height: 100))
        ]
        XCTAssertEqual(WindowHitTesting.frontmostWindow(
            at: CGPoint(x: 20, y: 50), windows: windows, excluding: [1]
        ), 2)
        XCTAssertEqual(WindowHitTesting.frontmostWindow(
            at: CGPoint(x: 80, y: 50), windows: windows, excluding: [1]
        ), 3)
        XCTAssertNil(WindowHitTesting.frontmostWindow(
            at: CGPoint(x: 150, y: 50), windows: windows, excluding: [1]
        ))
    }

    func testOverlappingWorkspacesUseFrontmost() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let windows: [(id: UInt32, frame: CGRect)] = [(1, frame), (2, frame), (3, frame)]
        XCTAssertEqual(WindowHitTesting.frontmostWindow(
            at: CGPoint(x: 50, y: 50), windows: windows, excluding: [1]
        ), 2)
    }
}
