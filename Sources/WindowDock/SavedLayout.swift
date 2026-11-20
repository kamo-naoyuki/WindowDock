import AppKit

/// The windows that were registered when the app last quit, used only to suggest a selection.
struct SavedWindow: Codable {
    var bundleID: String
    var title: String
    var frame: CGRect
}

struct SavedProject: Codable {
    var name: String
    var windows: [SavedWindow]
    var columns: Int?
    var rows: Int?

    var gridSize: WorkspaceGridSize? {
        guard let columns, let rows else { return nil }
        let size = WorkspaceGridSize(columns: columns, rows: rows)
        return size.isValid ? size : nil
    }
}

enum SavedLayout {
    private static let key = "lastWindows"

    static func save(_ projects: [SavedProject]) {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Replaces projects with the same name and appends new ones, keeping every other saved project.
    static func upsert(_ projects: [SavedProject]) {
        var all = load()
        for project in projects {
            if let index = all.firstIndex(where: { $0.name == project.name }) {
                all[index] = project
            } else {
                all.append(project)
            }
        }
        save(all)
    }

    static func remove(named name: String) {
        save(load().filter { $0.name != name })
    }

    static func load() -> [SavedProject] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        if let projects = try? JSONDecoder().decode([SavedProject].self, from: data) { return projects }
        // Earlier versions saved a flat window list.
        if let windows = try? JSONDecoder().decode([SavedWindow].self, from: data) {
            return [SavedProject(name: L("プロジェクト %d", 1), windows: windows)]
        }
        return []
    }

    /// Titles change easily, so the app is the hard requirement and title/position only rank candidates.
    static func suggest(_ saved: [SavedWindow], among candidates: [WindowCandidate]) -> [Int] {
        var claimed = Set<Int>()
        for entry in saved {
            var best: (index: Int, score: Int)?
            for (index, candidate) in candidates.enumerated()
            where !claimed.contains(index) && candidate.application.bundleIdentifier == entry.bundleID {
                var score = 0
                if !entry.title.isEmpty, candidate.title == entry.title { score += 4 }
                if let frame = try? WindowAccess.frame(candidate.element) {
                    let distance = abs(frame.minX - entry.frame.minX) + abs(frame.minY - entry.frame.minY)
                        + abs(frame.width - entry.frame.width) + abs(frame.height - entry.frame.height)
                    if distance < 40 { score += 3 } else if distance < 400 { score += 1 }
                }
                if best == nil || score > best!.score { best = (index, score) }
            }
            if let best { claimed.insert(best.index) }
        }
        return claimed.sorted()
    }
}
