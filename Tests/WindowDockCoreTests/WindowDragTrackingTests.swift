import XCTest

@testable import WindowDockCore

final class WindowDragTrackingTests: XCTestCase {
    private let original = WindowServerWindow(
        id: 10, processID: 20, frame: CGRect(x: 40, y: 80, width: 500, height: 400))
    private let own = WindowServerWindow(id: 11, processID: 1, frame: CGRect(x: 40, y: 80, width: 500, height: 400))
    private let start = CGPoint(x: 100, y: 100)
    private let end = CGPoint(x: 300, y: 200)
    private var moved: WindowServerWindow {
        WindowServerWindow(
            id: original.id, processID: original.processID, frame: original.frame.offsetBy(dx: 200, dy: 100))
    }

    private func isIdle(_ update: WorkspaceWindowDragTracker.Update) -> Bool {
        if case .idle = update { return true }
        return false
    }

    private func pressedTracker() -> WorkspaceWindowDragTracker {
        var tracker = WorkspaceWindowDragTracker()
        _ = tracker.update(buttonDown: false, point: start, windows: [own, original], ownPID: 1)
        _ = tracker.update(buttonDown: true, point: start, windows: [own, original], ownPID: 1)
        return tracker
    }

    func testDropRequiresAnActualMoveWithoutResizing() {
        let drag = WorkspaceWindowDrag(window: original, originalFrame: original.frame, startPoint: start)
        let point = CGPoint(x: 220, y: 180)
        var movedFrame = original.frame.offsetBy(dx: 120, dy: 80)
        XCTAssertTrue(drag.canDrop(at: point, actualFrame: movedFrame, acceptsPoint: true))
        XCTAssertFalse(drag.canDrop(at: point, actualFrame: original.frame, acceptsPoint: true))
        XCTAssertFalse(drag.canDrop(at: point, actualFrame: movedFrame, acceptsPoint: false))
        movedFrame.size.width += 20
        XCTAssertFalse(drag.canDrop(at: point, actualFrame: movedFrame, acceptsPoint: true))
    }

    func testSampledMoveIsDetectedWithoutMouseEventsAndReleasedOnce() {
        var tracker = WorkspaceWindowDragTracker()
        _ = tracker.update(buttonDown: false, point: start, windows: [own, original], ownPID: 1)
        // The first sample can arrive after a native titlebar drag has already started.
        let first = WindowServerWindow(
            id: original.id, processID: original.processID, frame: original.frame.offsetBy(dx: 10, dy: 0))
        _ = tracker.update(buttonDown: true, point: CGPoint(x: 110, y: 100), windows: [own, first], ownPID: 1)
        guard case .moving(let drag) = tracker.update(buttonDown: true, point: end, windows: [own, moved], ownPID: 1)
        else {
            return XCTFail("window movement was not detected without mouse events")
        }
        XCTAssertEqual(drag.window.id, original.id)
        XCTAssertEqual(drag.originalFrame, original.frame)
        guard case .released(let released) = tracker.update(buttonDown: false, point: end, windows: [moved], ownPID: 1)
        else {
            return XCTFail("the released button did not finish the window drag")
        }
        XCTAssertTrue(released.canDrop(at: end, actualFrame: moved.frame, acceptsPoint: true))
        XCTAssertTrue(isIdle(tracker.update(buttonDown: false, point: end, windows: [moved], ownPID: 1)))
    }

    func testStationaryWindowIsNotDropped() {
        var tracker = pressedTracker()
        XCTAssertTrue(isIdle(tracker.update(buttonDown: false, point: end, windows: [original], ownPID: 1)))
    }

    func testResizedWindowIsNotDroppedEvenAfterMoving() {
        var tracker = pressedTracker()
        let resized = WindowServerWindow(
            id: original.id, processID: original.processID,
            frame: CGRect(x: 240, y: 180, width: 530, height: 400))
        _ = tracker.update(buttonDown: true, point: end, windows: [resized], ownPID: 1)
        XCTAssertTrue(isIdle(tracker.update(buttonDown: false, point: end, windows: [moved], ownPID: 1)))
    }

    func testCancelledDragIsNotDropped() {
        var tracker = pressedTracker()
        tracker.cancel()
        XCTAssertTrue(isIdle(tracker.update(buttonDown: true, point: end, windows: [moved], ownPID: 1)))
        XCTAssertTrue(isIdle(tracker.update(buttonDown: false, point: end, windows: [moved], ownPID: 1)))
    }

    func testOwnAndNewlyCreatedWindowsAreNotDropped() {
        var tracker = pressedTracker()
        let windows = [
            WindowServerWindow(id: own.id, processID: own.processID, frame: moved.frame),
            WindowServerWindow(id: 99, processID: original.processID, frame: moved.frame),
        ]
        XCTAssertTrue(isIdle(tracker.update(buttonDown: false, point: end, windows: windows, ownPID: 1)))
    }

    func testMovingAWorkspaceDoesNotOfferItsFollowingWindowToAnotherWorkspace() {
        var tracker = WorkspaceWindowDragTracker()
        let workspace = WindowServerWindow(id: 1, processID: 10, frame: CGRect(x: 100, y: 100, width: 700, height: 500))
        let managed = WindowServerWindow(id: 2, processID: 20, frame: workspace.frame)
        let press = CGPoint(x: 180, y: 120)
        let release = CGPoint(x: 280, y: 120)
        _ = tracker.update(buttonDown: false, point: press, windows: [workspace, managed], ownPID: 10)
        _ = tracker.update(buttonDown: true, point: press, windows: [workspace, managed], ownPID: 10)
        let movedWorkspace = WindowServerWindow(id: 1, processID: 10, frame: workspace.frame.offsetBy(dx: 100, dy: 0))
        let movedManaged = WindowServerWindow(id: 2, processID: 20, frame: managed.frame.offsetBy(dx: 100, dy: 0))
        XCTAssertTrue(
            isIdle(
                tracker.update(buttonDown: true, point: release, windows: [movedManaged, movedWorkspace], ownPID: 10)))
        XCTAssertTrue(
            isIdle(
                tracker.update(buttonDown: false, point: release, windows: [movedManaged, movedWorkspace], ownPID: 10)))

        _ = tracker.update(buttonDown: true, point: release, windows: [movedManaged, movedWorkspace], ownPID: 10)
        let draggedAgain = WindowServerWindow(id: 2, processID: 20, frame: movedManaged.frame.offsetBy(dx: 100, dy: 0))
        guard
            case .moving = tracker.update(
                buttonDown: true, point: CGPoint(x: 380, y: 120),
                windows: [draggedAgain, movedWorkspace], ownPID: 10)
        else {
            return XCTFail("workspace suppression blocked the next genuine foreign-window drag")
        }
    }

    func testTransparentWorkspaceOverAForeignWindowStillAllowsDraggingIt() {
        var tracker = WorkspaceWindowDragTracker()
        let workspace = WindowServerWindow(id: 1, processID: 10, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let foreign = WindowServerWindow(id: 2, processID: 20, frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        _ = tracker.update(
            buttonDown: false, point: CGPoint(x: 150, y: 110), windows: [workspace, foreign], ownPID: 10)
        _ = tracker.update(buttonDown: true, point: CGPoint(x: 150, y: 110), windows: [workspace, foreign], ownPID: 10)
        let dragged = WindowServerWindow(id: 2, processID: 20, frame: foreign.frame.offsetBy(dx: 150, dy: 0))
        guard
            case .moving(let drag) = tracker.update(
                buttonDown: true, point: CGPoint(x: 300, y: 110),
                windows: [workspace, dragged], ownPID: 10)
        else {
            return XCTFail("a stationary workspace above a foreign window suppressed its drag")
        }
        XCTAssertEqual(drag.window.id, foreign.id)
    }
}
