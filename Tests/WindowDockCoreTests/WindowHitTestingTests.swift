import XCTest

@testable import WindowDockCore

final class WindowHitTestingTests: XCTestCase {
    func testActivationByClickingOwnWindowIsRecognized() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let windows: [(id: UInt32, ownerPID: Int32, frame: CGRect)] = [
            (1, 9, CGRect(x: 0, y: 0, width: 100, height: 20)),
            (2, 7, frame),
            (3, 7, frame),
        ]
        let click = { (point: CGPoint, buttonDown: Bool, age: Double) in
            WindowHitTesting.activatingClick(
                at: point, windows: windows, ownPID: 7, buttonDown: buttonDown, secondsSinceMouseDown: age
            )
        }
        XCTAssertEqual(click(CGPoint(x: 50, y: 50), true, 10), 2)
        XCTAssertEqual(click(CGPoint(x: 50, y: 50), false, 0.1), 2, "a quick click may already be released")
        XCTAssertNil(click(CGPoint(x: 50, y: 50), false, 3), "Cmd+Tab long after the last click")
        XCTAssertNil(click(CGPoint(x: 50, y: 10), true, 0), "the menu bar or Dock above the workspace")
        XCTAssertNil(click(CGPoint(x: 150, y: 50), true, 0))
    }

    func testActivationByClickingAnotherAppIsNotOwnClick() {
        let windows: [(id: UInt32, ownerPID: Int32, frame: CGRect)] = [
            (1, 9, CGRect(x: 0, y: 0, width: 40, height: 100)),
            (2, 7, CGRect(x: 0, y: 0, width: 100, height: 100)),
        ]
        XCTAssertNil(
            WindowHitTesting.activatingClick(
                at: CGPoint(x: 20, y: 50), windows: windows, ownPID: 7, buttonDown: true, secondsSinceMouseDown: 0
            )
        )
        XCTAssertEqual(
            WindowHitTesting.activatingClick(
                at: CGPoint(x: 80, y: 50), windows: windows, ownPID: 7, buttonDown: true, secondsSinceMouseDown: 0
            ), 2
        )
    }
}
