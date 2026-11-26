import Foundation

public struct RecentApplications {
    private let defaults: UserDefaults
    private let key = "applicationLastUsedDates"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var dates: [String: Date] { defaults.dictionary(forKey: key) as? [String: Date] ?? [:] }

    public func record(_ id: String, at date: Date = Date()) {
        var updated = dates
        updated[id] = date
        defaults.set(updated, forKey: key)
    }
}

public struct LauncherApplication {
    public let url: URL
    public let name: String
    public let lastUsed: Date?

    public init(url: URL, name: String, lastUsed: Date?) {
        self.url = url
        self.name = name
        self.lastUsed = lastUsed
    }

    public static func inUsageOrder(_ apps: [Self]) -> [Self] {
        apps.sorted {
            let left = $0.lastUsed ?? .distantPast, right = $1.lastUsed ?? .distantPast
            if left != right { return left > right }
            let byName = $0.name.localizedStandardCompare($1.name)
            return byName == .orderedSame ? $0.url.path < $1.url.path : byName == .orderedAscending
        }
    }
}
