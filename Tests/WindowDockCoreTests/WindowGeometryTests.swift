import XCTest
@testable import WindowDockCore

final class WindowGeometryTests: XCTestCase {
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

    func testTrackMinimumsTakeMaxPerColumnAndRow() {
        let result = WindowGeometry.trackMinimums(
            [0: CGSize(width: 300, height: 100), 1: CGSize(width: 200, height: 250), 2: CGSize(width: 400, height: 50)],
            columns: 2, rows: 2)
        XCTAssertEqual(result?.columns, [400, 200])
        XCTAssertEqual(result?.rows, [250, 50])
    }

    func testTrackMinimumsIgnoreOutOfRangeAndRejectInvalid() {
        let ignored = WindowGeometry.trackMinimums([9: CGSize(width: 500, height: 500)], columns: 2, rows: 1)
        XCTAssertEqual(ignored?.columns, [0, 0])
        XCTAssertNil(WindowGeometry.trackMinimums([0: CGSize(width: -1, height: 10)], columns: 1, rows: 1))
        XCTAssertNil(WindowGeometry.trackMinimums([0: CGSize(width: .infinity, height: 10)], columns: 1, rows: 1))
    }
}
