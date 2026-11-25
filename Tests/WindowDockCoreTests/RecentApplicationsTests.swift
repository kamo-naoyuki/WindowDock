import WindowDockCore
import XCTest

final class RecentApplicationsTests: XCTestCase {
    func testRecentsSurviveReopeningAndStayBoundedWithoutDuplicates() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recents = RecentApplications(defaults: defaults)
        recents.seedIfNeeded(from: ["A", "B", "C", "D", "E", "F"])
        recents.record("B")
        for id in ["G", "H", "I", "J", "K"] { recents.record(id) }
        let reopened = RecentApplications(defaults: defaults)
        reopened.seedIfNeeded(from: ["Old"])
        XCTAssertEqual(reopened.identifiers, ["K", "J", "I", "H", "G", "B", "F", "E", "D", "C"])
    }
}
