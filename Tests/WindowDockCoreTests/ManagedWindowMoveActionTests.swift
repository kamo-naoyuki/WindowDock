import XCTest

@testable import WindowDockCore

final class ManagedWindowMoveActionTests: XCTestCase {
    func testLegacyPreferenceMigratesToEquivalentAction() {
        XCTAssertEqual(ManagedWindowMoveAction.migrated(from: true), .returnToPane)
        XCTAssertEqual(ManagedWindowMoveAction.migrated(from: false), .nothing)
    }

    func testNewInstallFollowsManagedWindows() {
        XCTAssertEqual(ManagedWindowMoveAction.migrated(from: nil), .follow)
    }
}
