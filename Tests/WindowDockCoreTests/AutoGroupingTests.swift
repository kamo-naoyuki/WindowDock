import WindowDockCore
import XCTest

final class AutoGroupingTests: XCTestCase {
    typealias Rules = AutoGroupRules<String>

    func testAppBelongsToTheFirstWorkspaceThatListsIt() {
        let rules = Rules([
            .init(workspace: "A", bundleIDs: ["com.a", "", "com.shared"]),
            .init(workspace: "B", bundleIDs: ["com.shared", "com.b"]),
            .init(workspace: "A", bundleIDs: ["com.a2"]),
        ])
        XCTAssertEqual(rules.bundleIDs(in: "A"), ["com.a", "com.shared", "com.a2"])
        XCTAssertEqual(rules.bundleIDs(in: "B"), ["com.b"])
        XCTAssertEqual(rules.workspace(for: "com.shared"), "A")
        XCTAssertNil(rules.workspace(for: "com.unknown"))
        XCTAssertEqual(rules.allBundleIDs, ["com.a", "com.shared", "com.a2", "com.b"])
    }

    func testAssigningMovesTheAppAndReportsItsPreviousWorkspace() {
        var rules = Rules([.init(workspace: "A", bundleIDs: ["com.app"])])
        XCTAssertNil(rules.assign("com.app", to: "A"))
        XCTAssertEqual(rules.assign("com.app", to: "B"), "A")
        XCTAssertEqual(rules.workspace(for: "com.app"), "B")
        XCTAssertEqual(rules.bundleIDs(in: "A"), [])
        XCTAssertNil(rules.assign("com.new", to: "B"))
        XCTAssertEqual(rules.bundleIDs(in: "B"), ["com.app", "com.new"])
        XCTAssertNil(rules.assign("", to: "B"))
        XCTAssertEqual(rules.bundleIDs(in: "B"), ["com.app", "com.new"])
    }

    func testUnassigningReportsTheWorkspaceThatCollectedTheApp() {
        var rules = Rules([.init(workspace: "A", bundleIDs: ["com.app", "com.other"])])
        XCTAssertEqual(rules.unassign("com.app"), "A")
        XCTAssertNil(rules.unassign("com.app"))
        XCTAssertEqual(rules.bundleIDs(in: "A"), ["com.other"])
    }

    func testOnlyWindowsOpenedAfterTheBaselineAreNew() {
        var ledger = AutoGroupWindowLedger<Int>()
        XCTAssertEqual(ledger.takeNew(from: [1, 2], epoch: ledger.epoch), [], "nothing is new before a baseline")
        ledger.setBaseline(nil)
        XCTAssertFalse(ledger.isBaselined, "a failed listing must not become an empty baseline")
        ledger.setBaseline([1, 2])
        XCTAssertEqual(ledger.takeNew(from: [1, 2, 3], epoch: ledger.epoch), [3])
        XCTAssertEqual(ledger.takeNew(from: [1, 2, 3], epoch: ledger.epoch), [], "each window is offered once")
    }

    func testRememberedWindowsAreNotOfferedAgain() {
        var ledger = AutoGroupWindowLedger<Int>()
        ledger.setBaseline([])
        ledger.remember(5)
        XCTAssertTrue(ledger.contains(5))
        XCTAssertEqual(ledger.takeNew(from: [5, 6], epoch: ledger.epoch), [6])
    }

    func testListingsReadBeforeANewBaselineAreIgnored() {
        var ledger = AutoGroupWindowLedger<Int>()
        ledger.setBaseline([1])
        let stale = ledger.epoch
        ledger.setBaseline([1, 2])
        XCTAssertEqual(ledger.takeNew(from: [1, 2, 3], epoch: stale), [])
        XCTAssertEqual(ledger.takeNew(from: [1, 2, 3], epoch: ledger.epoch), [3])
    }

    func testNothingIsNewWhileWaitingForAReplacementBaseline() {
        var ledger = AutoGroupWindowLedger<Int>()
        ledger.setBaseline([1])
        let stale = ledger.epoch
        ledger.invalidate()
        XCTAssertFalse(ledger.isBaselined)
        XCTAssertEqual(ledger.takeNew(from: [1, 2], epoch: ledger.epoch), [])
        ledger.setBaseline(nil)
        XCTAssertFalse(ledger.isBaselined, "a failed listing keeps waiting")
        ledger.setBaseline([1, 2])
        XCTAssertEqual(ledger.takeNew(from: [1, 2, 3], epoch: stale), [])
        XCTAssertEqual(ledger.takeNew(from: [1, 2, 3], epoch: ledger.epoch), [3])
    }
}
