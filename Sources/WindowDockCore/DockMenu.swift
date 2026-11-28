import Foundation

/// An item of an app's Dock menu, as read from the Dock through Accessibility.
public struct DockMenuItem: Equatable, Sendable {
    public var title: String
    public var isEnabled: Bool
    /// False for separators, section headers such as Chrome's “Profiles”, and items that open a submenu.
    public var performsAction: Bool
    public var isChecked: Bool
    /// Replaces the item above it while Option is held, like Force Quit under Quit.
    public var isAlternate: Bool
    public var submenu: [DockMenuItem]

    public init(title: String, isEnabled: Bool = true, performsAction: Bool = true, isChecked: Bool = false,
                isAlternate: Bool = false, submenu: [DockMenuItem] = []) {
        self.title = title
        self.isEnabled = isEnabled
        self.performsAction = performsAction
        self.isChecked = isChecked
        self.isAlternate = isAlternate
        self.submenu = submenu
    }

    public static let separator = DockMenuItem(title: "", isEnabled: false, performsAction: false)

    public var isSeparator: Bool { title.isEmpty && !performsAction && submenu.isEmpty }
}

/// Finds a chosen item again in a newly opened Dock menu. Titles identify it rather than positions, because the
/// window list at the top of the menu can change before the item is chosen.
public struct DockMenuPath: Hashable, Sendable {
    public struct Step: Hashable, Sendable {
        public var title: String
        /// How many earlier items in the same menu have this title.
        public var occurrence: Int
    }

    public var steps: [Step]

    /// The path of the item at `indices`, one index for each menu level.
    public init?(indices: [Int], in items: [DockMenuItem]) {
        var steps: [Step] = []
        var menu = items
        for (depth, index) in indices.enumerated() {
            guard menu.indices.contains(index) else { return nil }
            let title = menu[index].title
            steps.append(Step(title: title, occurrence: menu[..<index].filter { $0.title == title }.count))
            if depth < indices.count - 1 { menu = menu[index].submenu }
        }
        guard !steps.isEmpty else { return nil }
        self.steps = steps
    }

    /// The item's index at each menu level of `items`, or nil when the menu no longer has it.
    public func indices(in items: [DockMenuItem]) -> [Int]? {
        var result: [Int] = []
        var menu = items
        for (depth, step) in steps.enumerated() {
            let matches = menu.indices.filter { menu[$0].title == step.title }
            guard matches.indices.contains(step.occurrence) else { return nil }
            let index = matches[step.occurrence]
            result.append(index)
            if depth < steps.count - 1 { menu = menu[index].submenu }
        }
        return result
    }
}

public extension Array where Element == DockMenuItem {
    /// Whether the item is one of the Dock's own commands: the Options submenu and the items below it, such as Hide
    /// and Quit. Unlike the windows and the app's commands above them, they never open a window of a running app.
    func isDockCommand(_ path: DockMenuPath) -> Bool {
        guard let top = path.indices(in: self)?.first,
              let options = lastIndex(where: { !$0.submenu.isEmpty }) else { return false }
        return top >= options
    }
}
