import XCTest
@testable import WindowDockCore

final class WorkspaceTabDragRouteTests: XCTestCase {
    private let source = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let destination = CGRect(x: 1000, y: 0, width: 800, height: 600)

    private func route(_ point: CGPoint, inSourceTabRow: Bool = false, destinations: [CGRect]? = nil) -> WorkspaceTabDragRoute {
        WorkspaceTabDragRoute.resolve(
            at: point, sourceFrame: source, sourceTabRowContains: inSourceTabRow,
            destinationFrames: destinations ?? [destination]
        )
    }

    func testSourceTabRowReordersEvenWhenAnotherWorkspaceOverlapsIt() {
        let overlapping = CGRect(x: 600, y: 500, width: 800, height: 600)
        XCTAssertEqual(route(CGPoint(x: 700, y: 590), inSourceTabRow: true, destinations: [overlapping]), .source)
    }

    func testAnotherWorkspaceReceivesTabInsideOrNearItsFrame() {
        XCTAssertEqual(route(CGPoint(x: 1200, y: 300)), .transfer(0))
        XCTAssertEqual(route(CGPoint(x: 980, y: 300)), .transfer(0))
        let front = CGRect(x: 1100, y: 100, width: 400, height: 300)
        XCTAssertEqual(route(CGPoint(x: 1200, y: 200), destinations: [front, destination]), .transfer(0))
    }

    func testSourceBodyKeepsTabInSourceForPaneMoves() {
        XCTAssertEqual(route(CGPoint(x: 400, y: 300)), .source)
        XCTAssertEqual(route(CGPoint(x: 400, y: 300), destinations: []), .source)
    }

    func testReleasingAwayFromEveryWorkspaceDoesNothing() {
        XCTAssertEqual(route(CGPoint(x: 900, y: 300)), .none)
        XCTAssertEqual(route(CGPoint(x: 400, y: 900)), .none)
        XCTAssertEqual(route(CGPoint(x: 2000, y: 300), destinations: []), .none)
    }
}
