import XCTest

@testable import WindowDockCore

final class WindowGeometryTests: XCTestCase {
    func testTabsShareAvailableWidthAndOnlyWrapOnOverflow() {
        func rows(_ n: Int, available: CGFloat = 288, wrap: Bool = true)
            -> (contentWidth: CGFloat, secondRow: Int?, viewport: CGFloat) {
            WindowGeometry.horizontalTabRows(count: n, available: available, chrome: 34, spacing: 2, wrap: wrap)
        }
        XCTAssertEqual(rows(0).viewport, 0)
        XCTAssertEqual(rows(1).contentWidth, 200)
        XCTAssertEqual(rows(2).contentWidth, 109)
        XCTAssertNil(rows(5).secondRow)
        XCTAssertEqual(rows(6).secondRow, 5)
        XCTAssertEqual(rows(11).secondRow, 6)
        XCTAssertEqual(rows(11).contentWidth, 22)
        XCTAssertNil(rows(6, wrap: false).secondRow)
    }

    private let insertionTabs = [
        CGRect(x: 0, y: 0, width: 100, height: 28),
        CGRect(x: 102, y: 0, width: 80, height: 28),
        CGRect(x: 184, y: 0, width: 200, height: 28),
    ]

    func testTabInsertionIndexSwitchesAtTabCenters() {
        func index(_ x: CGFloat) -> Int {
            WindowGeometry.tabInsertionIndex(at: x, tabFrames: insertionTabs, visibleMinX: 0, visibleMaxX: 1000)
        }
        XCTAssertEqual(index(10), 0)
        XCTAssertEqual(index(49), 0)
        XCTAssertEqual(index(50), 1)
        XCTAssertEqual(index(150), 2)
        XCTAssertEqual(index(300), 3)
        XCTAssertEqual(WindowGeometry.tabInsertionIndex(at: 300, tabFrames: [], visibleMinX: 0, visibleMaxX: 0), 0)
    }

    func testTabInsertionIndexIgnoresTabsScrolledOutOfView() {
        XCTAssertEqual(
            WindowGeometry.tabInsertionIndex(at: -500, tabFrames: insertionTabs, visibleMinX: 102, visibleMaxX: 250), 1
        )
        XCTAssertEqual(
            WindowGeometry.tabInsertionIndex(at: 1000, tabFrames: insertionTabs, visibleMinX: 102, visibleMaxX: 250), 2
        )
    }

    func testTabInsertionLineMatchesInsertionIndexAndStaysVisible() {
        func line(_ index: Int, _ frames: [CGRect], _ minX: CGFloat, _ maxX: CGFloat) -> CGFloat {
            WindowGeometry.tabInsertionLineX(
                index: index, tabFrames: frames, emptyX: 40, visibleMinX: minX, visibleMaxX: maxX, lineWidth: 3
            )
        }
        XCTAssertEqual(line(1, insertionTabs, 0, 1000), 102)
        XCTAssertEqual(line(3, insertionTabs, 0, 1000), 384)
        XCTAssertEqual(line(3, insertionTabs, 102, 250), 247)
        XCTAssertEqual(line(0, insertionTabs, 102, 250), 102)
        XCTAssertEqual(line(0, [], 0, 600), 40)
    }

    func testTabDropSelectsFrontmostOverlappingWorkspace() {
        let front = CGRect(x: 200, y: 100, width: 500, height: 400)
        let back = CGRect(x: 100, y: 100, width: 700, height: 500)
        let point = CGPoint(x: 300, y: 200)
        XCTAssertEqual(WindowGeometry.workspaceTabDropTarget(at: point, orderedFrames: [front, back]), 0)
        XCTAssertEqual(WindowGeometry.workspaceTabDropTarget(at: point, orderedFrames: [back, front]), 0)
        XCTAssertEqual(
            WindowGeometry.workspaceTabDropTarget(at: CGPoint(x: 150, y: 200), orderedFrames: [front, back]), 1
        )
    }

    func testTabDropAcceptsNearbyWorkspaceButNotDistantWorkspace() {
        let frame = CGRect(x: 100, y: 100, width: 500, height: 400)
        XCTAssertEqual(WindowGeometry.workspaceTabDropTarget(at: CGPoint(x: 80, y: 200), orderedFrames: [frame]), 0)
        XCTAssertEqual(WindowGeometry.workspaceTabDropTarget(at: CGPoint(x: 76, y: 200), orderedFrames: [frame]), 0)
        XCTAssertEqual(WindowGeometry.workspaceTabDropTarget(at: CGPoint(x: 624, y: 200), orderedFrames: [frame]), 0)
        XCTAssertNil(WindowGeometry.workspaceTabDropTarget(at: CGPoint(x: 75, y: 200), orderedFrames: [frame]))
        XCTAssertNil(WindowGeometry.workspaceTabDropTarget(at: CGPoint(x: 625, y: 200), orderedFrames: [frame]))
        XCTAssertNil(WindowGeometry.workspaceTabDropTarget(at: CGPoint(x: 300, y: 200), orderedFrames: []))
        let covering = CGRect(x: 0, y: 100, width: 90, height: 400)
        XCTAssertEqual(
            WindowGeometry.workspaceTabDropTarget(at: CGPoint(x: 80, y: 200), orderedFrames: [frame, covering]), 1
        )
    }

    func testConvertsPrimaryDisplayCoordinates() {
        let rect = CGRect(x: 100, y: 200, width: 900, height: 600)
        XCTAssertEqual(
            WindowGeometry.accessibilityRect(from: rect, primaryScreenTop: 1080),
            CGRect(x: 100, y: 280, width: 900, height: 600)
        )
    }

    func testConvertsDisplayAboveAndLeftOfPrimary() {
        let rect = CGRect(x: -1600, y: 1200, width: 1400, height: 900)
        XCTAssertEqual(
            WindowGeometry.accessibilityRect(from: rect, primaryScreenTop: 1080),
            CGRect(x: -1600, y: -1020, width: 1400, height: 900)
        )
    }

    func testConvertsDisplayBelowPrimary() {
        let rect = CGRect(x: 100, y: -900, width: 1000, height: 700)
        XCTAssertEqual(
            WindowGeometry.accessibilityRect(from: rect, primaryScreenTop: 1080),
            CGRect(x: 100, y: 1280, width: 1000, height: 700)
        )
    }

    func testLengthsSplitByWeight() {
        let result = WindowGeometry.lengths([0.25, 0.75], minimums: [0, 0], available: 400)
        XCTAssertEqual(result, [100, 300])
    }

    func testLengthsHonorMinimumAndRedistribute() {
        let result = WindowGeometry.lengths([0.5, 0.25, 0.25], minimums: [0, 200, 0], available: 400)
        XCTAssertEqual(result[0], 400.0 / 3, accuracy: 0.001)
        XCTAssertEqual(result[1], 200, accuracy: 0.001)
        XCTAssertEqual(result[2], 200.0 / 3, accuracy: 0.001)
    }

    func testLengthsScaleMinimumsWhenTooSmall() {
        let result = WindowGeometry.lengths([0.5, 0.5], minimums: [300, 100], available: 200)
        XCTAssertEqual(result, [150, 50])
    }

    func testLengthsZeroAvailable() {
        XCTAssertEqual(WindowGeometry.lengths([1], minimums: [0], available: 0), [0])
    }

    func testDetectsAppSizeConstraintsButAllowsRounding() {
        let requested = CGRect(x: 100, y: 200, width: 900, height: 600)
        XCTAssertTrue(WindowGeometry.fits(CGRect(x: 101, y: 198, width: 902, height: 600), requested: requested))
        XCTAssertFalse(WindowGeometry.fits(CGRect(x: 100, y: 200, width: 1000, height: 600), requested: requested))
        XCTAssertFalse(WindowGeometry.fits(CGRect(x: 110, y: 200, width: 900, height: 600), requested: requested))
    }

    func testCoverageDoesNotExposeAreaBeforeRenderedWindowCatchesUp() {
        let reported = CGRect(x: 200, y: 100, width: 500, height: 400)
        let stillRendered = reported.offsetBy(dx: -80, dy: 0)
        XCTAssertEqual(
            WindowGeometry.confirmedCoverage(for: reported, renderedFrames: [stillRendered]),
            CGRect(x: 200, y: 100, width: 420, height: 400)
        )
        XCTAssertEqual(WindowGeometry.confirmedCoverage(for: reported, renderedFrames: [reported]), reported)
        XCTAssertNil(WindowGeometry.confirmedCoverage(for: reported, renderedFrames: []))
        XCTAssertNil(
            WindowGeometry.confirmedCoverage(for: reported, renderedFrames: [reported.offsetBy(dx: 600, dy: 0)])
        )
    }

    func testTrackMinimumsTakeMaxPerColumnAndRow() {
        let result = WindowGeometry.trackMinimums(
            [
                0: CGSize(width: 300, height: 100), 1: CGSize(width: 200, height: 250),
                2: CGSize(width: 400, height: 50),
            ],
            columns: 2, rows: 2
        )
        XCTAssertEqual(result?.columns, [400, 200])
        XCTAssertEqual(result?.rows, [250, 50])
    }

    func testTrackMinimumsIgnoreOutOfRangeAndRejectInvalid() {
        let ignored = WindowGeometry.trackMinimums([9: CGSize(width: 500, height: 500)], columns: 2, rows: 1)
        XCTAssertEqual(ignored?.columns, [0, 0])
        XCTAssertNil(WindowGeometry.trackMinimums([0: CGSize(width: -1, height: 10)], columns: 1, rows: 1))
        XCTAssertNil(
            WindowGeometry.trackMinimums([0: CGSize(width: CGFloat.infinity, height: 10)], columns: 1, rows: 1)
        )
    }
}
