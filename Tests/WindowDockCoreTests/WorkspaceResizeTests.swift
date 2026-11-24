import XCTest

@testable import WindowDockCore

final class WorkspaceResizeTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)

    func testTopEdgeAndUpperCornersResizeInsteadOfMovingTheTitlebar() {
        XCTAssertEqual(WorkspaceResize.edges(at: CGPoint(x: 450, y: 598), in: bounds), .top)
        XCTAssertEqual(WorkspaceResize.edges(at: CGPoint(x: 898, y: 598), in: bounds), [.top, .right])
        XCTAssertEqual(WorkspaceResize.edges(at: CGPoint(x: 2, y: 598), in: bounds), [.top, .left])
        XCTAssertEqual(WorkspaceResize.edges(at: CGPoint(x: 898, y: 585), in: bounds), .right)
        XCTAssertEqual(WorkspaceResize.edges(at: CGPoint(x: 450, y: 585), in: bounds), [])
    }

    func testNativeResizeMarginOutsideTheFrameCountsAsEdge() {
        XCTAssertEqual(WorkspaceResize.edges(at: CGPoint(x: 450, y: 603), in: bounds), .top)
        XCTAssertEqual(WorkspaceResize.edges(at: CGPoint(x: -3, y: 300), in: bounds), .left)
    }

    func testGripResizesRightAndBottomBeyondTheEdgeBands() {
        XCTAssertEqual(WorkspaceResize.edges(at: CGPoint(x: 885, y: 15), in: bounds), [.right, .bottom])
        XCTAssertEqual(WorkspaceResize.edges(at: CGPoint(x: 450, y: 300), in: bounds), [])
    }

    func testLeftBottomResizeClampsWhilePreservingOppositeEdges() {
        let frame = CGRect(x: 100, y: 100, width: 900, height: 600)
        let minimum = CGSize(width: 240, height: 180)
        let clamped = WorkspaceResize.resizedFrame(
            from: frame, delta: CGSize(width: 1000, height: 1000), edges: [.left, .bottom], minimumSize: minimum
        )
        XCTAssertEqual(clamped.size, minimum)
        XCTAssertEqual(clamped.maxX, frame.maxX)
        XCTAssertEqual(clamped.maxY, frame.maxY)
    }

    func testTopResizeStopsAtTheMenuBarWithoutShrinkingAWindowAlreadyAboveIt() {
        let frame = CGRect(x: 100, y: 100, width: 900, height: 600)
        let minimum = CGSize(width: 240, height: 180)
        let limited = WorkspaceResize.resizedFrame(
            from: frame, delta: CGSize(width: 0, height: 300), edges: .top, minimumSize: minimum, maximumTop: 750
        )
        XCTAssertEqual(limited, CGRect(x: 100, y: 100, width: 900, height: 650))
        let above = CGRect(x: 100, y: 200, width: 900, height: 600)
        let unchanged = WorkspaceResize.resizedFrame(
            from: above, delta: CGSize(width: 0, height: 20), edges: .top, minimumSize: minimum, maximumTop: 750
        )
        XCTAssertEqual(unchanged, above)
    }
}
