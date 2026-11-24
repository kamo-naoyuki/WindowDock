import XCTest

@testable import WindowDockCore

final class PaneLayoutTests: XCTestCase {
    func testRepeatedNestingReachesQuarterSizeInBothDirections() throws {
        var layout = PaneLayout.pane
        for axis in [PaneLayout.Axis.horizontal, .vertical, .horizontal, .vertical] {
            layout = try XCTUnwrap(layout.splittingPane(at: 0, axis: axis))
        }
        let geometry = try XCTUnwrap(layout.geometry(in: CGRect(x: 0, y: 0, width: 1224, height: 824)))
        XCTAssertEqual(geometry.panes[0].width, 300, accuracy: 0.001)
        XCTAssertEqual(geometry.panes[0].height, 200, accuracy: 0.001)
        XCTAssertNil(layout.splittingPane(at: 0, axis: .horizontal))
        XCTAssertNil(layout.splittingPane(at: 0, axis: .vertical))
        XCTAssertNil(layout.splittingPane(at: 2, axis: .horizontal))
        XCTAssertNotNil(layout.splittingPane(at: 2, axis: .vertical))
    }

    func testRepeatedNestingCanCreateSixteenPanes() throws {
        var layout = PaneLayout.pane
        for axis in [PaneLayout.Axis.horizontal, .horizontal, .vertical, .vertical] {
            for index in (0 ..< layout.paneCount).reversed() {
                layout = try XCTUnwrap(layout.splittingPane(at: index, axis: axis))
            }
        }
        let frames = try XCTUnwrap(layout.geometry(in: CGRect(x: 0, y: 0, width: 1224, height: 824))).panes
        XCTAssertEqual(frames.count, 16)
        for frame in frames {
            XCTAssertEqual(frame.width, 300, accuracy: 0.001)
            XCTAssertEqual(frame.height, 200, accuracy: 0.001)
        }
        XCTAssertNil(layout.splittingPane(at: 15, axis: .horizontal))
        XCTAssertNil(layout.splittingPane(at: 15, axis: .vertical))
        let closed = try XCTUnwrap(layout.removingPane(at: 15)).layout
        XCTAssertNotNil(closed.splittingPane(at: 14, axis: .vertical))
        XCTAssertNil(closed.splittingPane(at: 14, axis: .horizontal))
    }

    func testRightPaneSplitsWithoutDividingLeftAndResizesIndependently() throws {
        let columns = try XCTUnwrap(PaneLayout.pane.splittingPane(at: 0, axis: .horizontal))
        let layout = try XCTUnwrap(columns.splittingPane(at: 1, axis: .vertical))
        let bounds = CGRect(x: 20, y: 30, width: 808, height: 608)
        let geometry = try XCTUnwrap(layout.geometry(in: bounds))
        XCTAssertEqual(
            geometry.panes,
            [
                CGRect(x: 20, y: 30, width: 400, height: 608),
                CGRect(x: 428, y: 338, width: 400, height: 300),
                CGRect(x: 428, y: 30, width: 400, height: 300),
            ]
        )
        let divider = try XCTUnwrap(geometry.dividers.first { $0.axis == .vertical })
        let resized = try XCTUnwrap(layout.resizing(divider, by: 80))
        let frames = try XCTUnwrap(resized.geometry(in: bounds)).panes
        XCTAssertEqual(frames[0], geometry.panes[0])
        XCTAssertEqual(frames[1].height, 380, accuracy: 0.001)
        XCTAssertEqual(frames[2].height, 220, accuracy: 0.001)
        XCTAssertEqual(try JSONDecoder().decode(PaneLayout.self, from: JSONEncoder().encode(resized)), resized)
    }

    func testNestedMinimumsConstrainOnlyTheDraggedDivider() throws {
        let layout = try XCTUnwrap(
            PaneLayout.pane.splittingPane(at: 0, axis: .horizontal)?.splittingPane(at: 1, axis: .vertical)
        )
        let sizes = [
            0: CGSize(width: 200, height: 300),
            1: CGSize(width: 300, height: 180), 2: CGSize(width: 250, height: 120),
        ]
        XCTAssertEqual(layout.minimumSize(sizes, dividerThickness: 8), CGSize(width: 508, height: 308))
        let bounds = CGRect(x: 0, y: 0, width: 808, height: 608)
        let geometry = try XCTUnwrap(layout.geometry(in: bounds, minimums: sizes))
        let divider = try XCTUnwrap(geometry.dividers.first { $0.axis == .vertical })
        let resized = try XCTUnwrap(layout.resizing(divider, by: 1000))
        let frames = try XCTUnwrap(resized.geometry(in: bounds, minimums: sizes)).panes
        XCTAssertEqual(frames[0], geometry.panes[0])
        XCTAssertEqual(frames[2].height, 120, accuracy: 0.001)
        XCTAssertEqual(frames[1].height, 480, accuracy: 0.001)
    }

    func testSplitBlockersDistinguishSharedColumnsFromIndependentRows() {
        let layout = PaneLayout.grid(columnWeights: [1, 1], rowWeights: [1, 1])
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
        let wide = CGSize(width: 600, height: 0), small = CGSize(width: 160, height: 0)
        let cells = [0: wide, 3: wide]
        let windows = ["upper left": wide, "lower right": wide, "smaller tab in same pane": small]
        let assignments = ["upper left": 0, "lower right": 3, "smaller tab in same pane": 0]
        XCTAssertEqual(
            layout.minimumSizeBlockers(
                in: bounds, paneMinimums: cells, windowMinimums: windows, assignments: assignments, sharedTracks: (
                    2,
                    2
                )
            ),
            ["upper left", "lower right"]
        )
        XCTAssertTrue(layout.minimumSizeBlockers(
            in: bounds, paneMinimums: cells, windowMinimums: windows, assignments: assignments
        ).isEmpty)
    }

    func testSplitAndClosePreserveTabsAndRemapNestedSibling() throws {
        let split = try XCTUnwrap(
            PaneReflow.split(
                cells: ["left", "right"], activeCell: 1, at: 1,
                windowIDs: ["left", "right", "hidden"], assignments: ["left": 0, "right": 1, "hidden": 1]
            )
        )
        XCTAssertEqual(split.cells, ["left", "right", "hidden"])
        XCTAssertEqual(split.activeCell, 1)
        let layout = try XCTUnwrap(
            PaneLayout.pane.splittingPane(at: 0, axis: .horizontal)?.splittingPane(at: 1, axis: .vertical)
        )
        let removal = try XCTUnwrap(layout.removingPane(at: 1))
        XCTAssertEqual(removal.layout.paneCount, 2)
        XCTAssertEqual(removal.destination, 1)
        let closed = try XCTUnwrap(
            PaneReflow.close(
                cells: split.cells, activeCell: split.activeCell, at: 1,
                destination: removal.destination, assignments: split.assignments
            )
        )
        XCTAssertEqual(closed.cells, ["left", "hidden"])
        XCTAssertEqual(closed.assignments, ["left": 0, "right": 1, "hidden": 1])
        XCTAssertEqual(closed.activeCell, 1)
        XCTAssertNil(PaneLayout.pane.removingPane(at: 0))
    }

    func testSplittingBeforeActivePaneKeepsItsWindowAndEmptyPane() throws {
        let result = try XCTUnwrap(
            PaneReflow.split(
                cells: ["first", "second"], activeCell: 1, at: 0,
                windowIDs: ["first", "second"], assignments: ["first": 0, "second": 1]
            )
        )
        XCTAssertEqual(result.cells, ["first", nil, "second"])
        XCTAssertEqual(result.activeCell, 2)
        XCTAssertEqual(result.assignments["second"], 2)
        let empty = try XCTUnwrap(
            PaneReflow.close(
                cells: result.cells, activeCell: result.activeCell, at: 0, destination: 0,
                assignments: result.assignments
            )
        )
        XCTAssertEqual(empty.cells, [nil, "second"])
        XCTAssertEqual(empty.assignments["first"], 0)
    }

    func testSplittingAndClosingInsideGridPreservesOtherTracks() throws {
        let grid = PaneLayout.grid(columnWeights: [2, 1, 1], rowWeights: [1, 2])
        let bounds = CGRect(x: 0, y: 0, width: 1016, height: 908)
        let original = try XCTUnwrap(grid.geometry(in: bounds)).panes
        let nested = try XCTUnwrap(grid.splittingPane(at: 4, axis: .vertical))
        let frames = try XCTUnwrap(nested.geometry(in: bounds)).panes
        XCTAssertEqual(Array(frames.prefix(4)), Array(original.prefix(4)))
        XCTAssertEqual(frames[6], original[5])
        XCTAssertEqual(frames[4].maxY, original[4].maxY)
        XCTAssertEqual(frames[5].minY, original[4].minY)
        XCTAssertEqual(try XCTUnwrap(nested.removingPane(at: 4)).layout, grid)
    }
}
