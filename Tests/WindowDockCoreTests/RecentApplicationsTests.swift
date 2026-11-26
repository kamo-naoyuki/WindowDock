import WindowDockCore
import XCTest

final class RecentApplicationsTests: XCTestCase {
    func testReusedAppMovesAheadOfMoreThanTenOthersAndUnusedAppsFollowByName() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recents = RecentApplications(defaults: defaults)
        for i in 1 ... 12 { recents.record("App \(i)", at: Date(timeIntervalSince1970: Double(i))) }
        recents.record("App 1", at: Date(timeIntervalSince1970: 20))
        let dates = RecentApplications(defaults: defaults).dates
        let apps = (1 ... 14).reversed().map { i in
            let name = "App \(i)"
            return LauncherApplication(url: URL(fileURLWithPath: "/\(name).app"), name: name, lastUsed: dates[name])
        }
        XCTAssertEqual(LauncherApplication.inUsageOrder(apps).map(\.name),
                       ["App 1"] + (2 ... 12).reversed().map { "App \($0)" } + ["App 13", "App 14"])
    }
}
