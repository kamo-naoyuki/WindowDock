import WindowDockCore
import XCTest

final class DockMenuTests: XCTestCase {
    private let options = DockMenuItem(title: "Options", performsAction: false, submenu: [
        DockMenuItem(title: "Keep in Dock", isChecked: true),
        DockMenuItem(title: "Show in Finder"),
    ])

    private func menu(windows: [String], appItems: [DockMenuItem] = [DockMenuItem(title: "New Window")])
        -> [DockMenuItem] {
        windows.map { DockMenuItem(title: $0) } + [.separator] + appItems + [.separator, options, .separator]
            + [DockMenuItem(title: "Hide"), DockMenuItem(title: "Quit"),
               DockMenuItem(title: "Force Quit", isAlternate: true)]
    }

    func testChosenItemIsFoundAfterTheWindowListChanges() throws {
        let opened = menu(windows: ["Inbox", "Docs"])
        let reopened = menu(windows: ["Docs"])
        let newWindow = try XCTUnwrap(DockMenuPath(indices: [3], in: opened))
        let showInFinder = try XCTUnwrap(DockMenuPath(indices: [5, 1], in: opened))

        XCTAssertEqual(newWindow.indices(in: reopened), [2])
        XCTAssertEqual(showInFinder.indices(in: reopened), [4, 1])
        XCTAssertNil(DockMenuPath(indices: [0], in: opened)?.indices(in: reopened), "the Inbox window was closed")
        XCTAssertNil(DockMenuPath(indices: [5, 2], in: opened))
    }

    func testWindowsWithTheSameTitleKeepTheirOrder() throws {
        let second = try XCTUnwrap(DockMenuPath(indices: [1], in: menu(windows: ["Untitled", "Untitled"])))

        XCTAssertEqual(second.indices(in: menu(windows: ["Other", "Untitled", "Untitled"])), [2])
        XCTAssertNil(second.indices(in: menu(windows: ["Untitled"])))
    }

    func testOnlyOptionsAndTheItemsBelowAreDockCommands() throws {
        let recent = DockMenuItem(title: "Recent", performsAction: false, submenu: [DockMenuItem(title: "a.txt")])
        let items = menu(windows: ["Inbox"], appItems: [recent, DockMenuItem(title: "New Window")])
        func isDockCommand(_ indices: [Int]) throws -> Bool {
            try items.isDockCommand(XCTUnwrap(DockMenuPath(indices: indices, in: items)))
        }

        XCTAssertFalse(try isDockCommand([0]), "window")
        XCTAssertFalse(try isDockCommand([2, 0]), "the app's own submenu")
        XCTAssertFalse(try isDockCommand([3]), "the app's command")
        XCTAssertTrue(try isDockCommand([5, 1]))
        XCTAssertTrue(try isDockCommand([7]))
        XCTAssertTrue(try isDockCommand([9]))
        let withoutOptions = [DockMenuItem(title: "New Window"), DockMenuItem(title: "Quit")]
        XCTAssertFalse(try withoutOptions.isDockCommand(XCTUnwrap(DockMenuPath(indices: [1], in: withoutOptions))))
    }
}
