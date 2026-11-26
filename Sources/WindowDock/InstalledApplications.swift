import AppKit
import CoreServices
import WindowDockCore

enum InstalledApplications {
    // Nonisolated async: filesystem and Spotlight work stays off the new-tab UI's main actor.
    static func load() async -> [LauncherApplication] {
        let files = FileManager.default
        let workspace = NSWorkspace.shared
        let usage = RecentApplications().dates
        var apps: [LauncherApplication] = []
        var paths = Set<URL>(), identifiers = Set<String>()

        func flag(_ key: String, in bundle: Bundle) -> Bool {
            let value = bundle.object(forInfoDictionaryKey: key)
            return (value as? Bool) ?? (value as? NSString)?.boolValue ?? false
        }

        func include(_ candidate: URL) {
            guard candidate.pathExtension.lowercased() == "app" else { return }
            let url = candidate.standardizedFileURL
            guard paths.insert(url).inserted,
                  !url.deletingLastPathComponent().pathComponents.contains(where: {
                      $0.hasPrefix(".") || $0.lowercased().hasSuffix(".app")
                  }),
                  let bundle = Bundle(url: url), bundle.executableURL != nil,
                  !flag("LSBackgroundOnly", in: bundle), !flag("LSUIElement", in: bundle) else { return }
            if let id = bundle.bundleIdentifier {
                guard id != Bundle.main.bundleIdentifier, identifiers.insert(id).inserted else { return }
            }
            let opened = MDItemCreateWithURL(nil, url as CFURL)
                .flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
            let activated = bundle.bundleIdentifier.flatMap { usage[$0] }
            apps.append(LauncherApplication(url: url, name: files.displayName(atPath: url.path),
                                            lastUsed: [opened, activated].compactMap { $0 }.max()))
        }

        // Prefer the running copy. This also includes Finder, which isn't in an Applications folder.
        for app in workspace.runningApplications where app.activationPolicy == .regular {
            if let url = app.bundleURL { include(url) }
        }
        // Standard install locations still work when Spotlight is disabled or hasn't indexed a new app.
        for root in files.urls(for: .applicationDirectory, in: [.userDomainMask, .localDomainMask, .systemDomainMask]) {
            guard let entries = files.enumerator(at: root, includingPropertiesForKeys: [],
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            while let url = entries.nextObject() as? URL {
                if Task.isCancelled { return [] }
                include(url)
            }
        }
        for id in usage.keys where !identifiers.contains(id) {
            if let url = workspace.urlForApplication(withBundleIdentifier: id) { include(url) }
        }
        // Include indexed apps installed elsewhere without crawling the user's home or mounted disks.
        if let query = MDQueryCreate(nil, "kMDItemContentTypeTree == 'com.apple.application-bundle'" as CFString,
                                     nil, nil) {
            MDQuerySetSearchScope(query, [kMDQueryScopeComputerIndexed] as CFArray, 0)
            if MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) {
                for index in 0 ..< MDQueryGetResultCount(query) {
                    if Task.isCancelled { return [] }
                    guard let result = MDQueryGetResultAtIndex(query, index) else { continue }
                    let item = Unmanaged<MDItem>.fromOpaque(result).takeUnretainedValue()
                    if let path = MDItemCopyAttribute(item, kMDItemPath) as? String {
                        include(URL(fileURLWithPath: path))
                    }
                }
            }
        }
        return LauncherApplication.inUsageOrder(apps)
    }
}
