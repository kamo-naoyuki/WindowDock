import XCTest

@testable import WindowDockCore

final class CombinedTabTitleTests: XCTestCase {
    private let measure: (String) -> CGFloat = { CGFloat($0.count) }

    func testShortensTheLongNameSoTheShortOneStaysWhole() {
        let names = ["window-driven-workspace.md — window_switcher", "ssh ks000"]
        XCTAssertEqual(
            CombinedTabTitle.fitted(names, width: 30, measure: measure),
            ["window-driven-works…", "ssh ks000"]
        )
        XCTAssertEqual(CombinedTabTitle.fitted(names, width: 100, measure: measure), names)
    }

    func testSharesTheWidthBetweenLongNames() {
        let names = ["Mail — Inbox", "Safari — Start Page", "Notes"]
        XCTAssertEqual(CombinedTabTitle.fitted(names, width: 19, measure: measure), ["Mail…", "Safar…", "Notes"])
    }
}
