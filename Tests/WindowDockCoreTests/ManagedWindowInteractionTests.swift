import CoreGraphics
import XCTest
@testable import WindowDockCore

final class ManagedWindowInteractionTests: XCTestCase {
    private let tolerance = CGSize(width: 12, height: 20)
    private let workspace = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let leftPane = CGRect(x: 0, y: 0, width: 496, height: 800)
    private let rightPane = CGRect(x: 504, y: 0, width: 496, height: 800)

    func testMovedWindowWithSizeRoundingIsAWorkspaceMove() {
        let current = CGRect(x: 30, y: 40, width: 502, height: 812)

        XCTAssertEqual(
            ManagedWindowInteractionClassifier.classify(
                start: leftPane,
                current: current,
                pane: leftPane,
                workspaceContent: workspace,
                screenVisibleFrames: [],
                roundingTolerance: tolerance
            ),
            .move(CGVector(dx: 30, dy: 40))
        )
    }

    func testOuterResizeUsesScreenSpaceDeltaAndAllChangedOuterEdges() {
        let current = CGRect(x: -50, y: 0, width: 546, height: 850)

        XCTAssertEqual(
            ManagedWindowInteractionClassifier.classify(
                start: leftPane,
                current: current,
                pane: leftPane,
                workspaceContent: workspace,
                screenVisibleFrames: [],
                roundingTolerance: tolerance
            ),
            .resizeWorkspace(edges: [.left, .bottom], delta: CGSize(width: -50, height: -50))
        )
    }

    func testInnerEdgeResizeMovesOnlyItsAdjacentDivider() {
        let current = CGRect(x: 0, y: 0, width: 576, height: 800)

        XCTAssertEqual(
            ManagedWindowInteractionClassifier.classify(
                start: leftPane,
                current: current,
                pane: leftPane,
                workspaceContent: workspace,
                screenVisibleFrames: [],
                roundingTolerance: tolerance
            ),
            .moveDivider(edge: .right, delta: 80)
        )
    }

    func testInnerVerticalEdgeResizeUsesAXDelta() {
        let topPane = CGRect(x: 0, y: 0, width: 1000, height: 396)
        let current = CGRect(x: 0, y: 0, width: 1000, height: 476)

        XCTAssertEqual(
            ManagedWindowInteractionClassifier.classify(
                start: topPane,
                current: current,
                pane: topPane,
                workspaceContent: workspace,
                screenVisibleFrames: [],
                roundingTolerance: tolerance
            ),
            .moveDivider(edge: .bottom, delta: 80)
        )
    }

    func testMaximizeMatchesAnyScreenVisibleFrameOnlyWhenStartWasAligned() {
        let secondScreen = CGRect(x: 1024, y: 0, width: 1440, height: 900)

        XCTAssertEqual(
            ManagedWindowInteractionClassifier.classify(
                start: rightPane,
                current: secondScreen,
                pane: rightPane,
                workspaceContent: workspace,
                screenVisibleFrames: [workspace, secondScreen],
                roundingTolerance: tolerance
            ),
            .maximize
        )
        XCTAssertEqual(
            ManagedWindowInteractionClassifier.classify(
                start: rightPane.offsetBy(dx: 10, dy: 0),
                current: secondScreen,
                pane: rightPane,
                workspaceContent: workspace,
                screenVisibleFrames: [secondScreen],
                roundingTolerance: tolerance
            ),
            .ignore
        )
    }

    func testSizeRoundedWindowCanStillResizeOrMaximize() {
        // Apps such as Terminal round their size down, so an aligned window can be smaller than its pane.
        let rounded = CGRect(x: 0, y: 0, width: 490, height: 785)

        XCTAssertEqual(
            ManagedWindowInteractionClassifier.classify(
                start: rounded,
                current: CGRect(x: 0, y: 0, width: 570, height: 785),
                pane: leftPane,
                workspaceContent: workspace,
                screenVisibleFrames: [],
                roundingTolerance: tolerance
            ),
            .moveDivider(edge: .right, delta: 80)
        )
        XCTAssertEqual(
            ManagedWindowInteractionClassifier.classify(
                start: rounded,
                current: workspace,
                pane: leftPane,
                workspaceContent: workspace,
                screenVisibleFrames: [workspace],
                roundingTolerance: tolerance
            ),
            .maximize
        )
    }

    func testAmbiguousResizeAndSubToleranceSizeChangeAreIgnored() {
        let centeredResize = CGRect(x: -50, y: 0, width: 596, height: 800)
        let smallResize = CGRect(x: 0, y: 0, width: 504, height: 800)

        for current in [centeredResize, smallResize] {
            XCTAssertEqual(
                ManagedWindowInteractionClassifier.classify(
                    start: leftPane,
                    current: current,
                    pane: leftPane,
                    workspaceContent: workspace,
                    screenVisibleFrames: [],
                    roundingTolerance: tolerance
                ),
                .ignore
            )
        }
    }
}
