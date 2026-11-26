import CoreGraphics
import XCTest
@testable import WindowDockCore

final class LeftMousePressTests: XCTestCase {
    func testPressAfterAReleaseConsumedByATrackingLoopStartsANewPress() {
        var press = LeftMousePress()
        XCTAssertFalse(press.begin(at: CGPoint(x: 10, y: 10)))

        XCTAssertTrue(press.begin(at: CGPoint(x: 300, y: 200)))
        XCTAssertEqual(press.end(at: CGPoint(x: 301, y: 200)), false)
        XCTAssertNil(press.start)
    }
}
