import XCTest
@testable import WindowDockCore

final class WorkspaceTabDragRouteTests: XCTestCase {
    private let source = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let destination = CGRect(x: 1000, y: 0, width: 800, height: 600)

    private func route(
        _ point: CGPoint, inSourceTabRow: Bool = false, destinations: [CGRect]? = nil, inFront: Int = 0
    ) -> WorkspaceTabDragRoute {
        WorkspaceTabDragRoute.resolve(
            at: point, sourceFrame: source, sourceTabRowContains: inSourceTabRow,
            destinationFrames: destinations ?? [destination], destinationsInFront: inFront
        )
    }

    func testSourceTabRowReordersWhenAnotherWorkspaceIsBehindIt() {
        let overlapping = CGRect(x: 600, y: 500, width: 800, height: 600)
        XCTAssertEqual(route(CGPoint(x: 700, y: 590), inSourceTabRow: true, destinations: [overlapping]), .source)
        // A workspace in front covers that part of the tab row.
        XCTAssertEqual(route(CGPoint(x: 700, y: 590), inSourceTabRow: true, destinations: [overlapping], inFront: 1), .transfer(0))
    }

    func testFrontmostWorkspaceReceivesTabWhereWorkspacesOverlap() {
        let overlapping = CGRect(x: 600, y: 300, width: 800, height: 600)
        let overlap = CGPoint(x: 700, y: 400)
        // A workspace hidden behind the source must not take a tab moved between the source's panes.
        XCTAssertEqual(route(overlap, destinations: [overlapping]), .source)
        XCTAssertEqual(route(CGPoint(x: 1000, y: 400), destinations: [overlapping]), .transfer(0))
        // Once that workspace has come in front, the overlap is its own.
        XCTAssertEqual(route(overlap, destinations: [overlapping], inFront: 1), .transfer(0))
        let behind = CGRect(x: 500, y: 200, width: 800, height: 600)
        XCTAssertEqual(route(overlap, destinations: [overlapping, behind], inFront: 1), .transfer(0))
        XCTAssertEqual(route(CGPoint(x: 550, y: 250), destinations: [overlapping, behind], inFront: 1), .source)
    }

    func testNearbyMarginDoesNotTakeTheSourceBody() {
        let adjacent = CGRect(x: 810, y: 0, width: 800, height: 600)
        XCTAssertEqual(route(CGPoint(x: 795, y: 300), destinations: [adjacent]), .source)
        XCTAssertEqual(route(CGPoint(x: 805, y: 300), destinations: [adjacent]), .transfer(0))
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
