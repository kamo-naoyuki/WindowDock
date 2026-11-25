import Foundation

public struct RecentApplications {
    private let defaults: UserDefaults
    private let key = "recentTabApplicationIDs"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var identifiers: [String] { defaults.stringArray(forKey: key) ?? [] }

    public func record(_ id: String) {
        guard !id.isEmpty else { return }
        defaults.set(Array(([id] + identifiers.filter { $0 != id }).prefix(10)), forKey: key)
    }

    public func seedIfNeeded(from ids: [String]) {
        guard defaults.object(forKey: key) == nil else { return }
        for id in ids { record(id) }
    }
}
