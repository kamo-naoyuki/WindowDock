import CoreGraphics

/// The title of a tab that combines several windows, such as "Mail|Safari".
public enum CombinedTabTitle {
    public static let separator = "|"

    public static func joined(_ names: [String]) -> String {
        names.joined(separator: separator)
    }

    /// Shortens the longest names first, so that a narrow tab still shows part of every window's name.
    public static func fitted(_ names: [String], width: CGFloat, measure: (String) -> CGFloat) -> [String] {
        guard names.count > 1, measure(joined(names)) > width else { return names }
        let widths = names.map(measure)
        var remaining = width - measure(separator) * CGFloat(names.count - 1)
        var limits = widths
        for (rank, index) in widths.indices.sorted(by: { widths[$0] < widths[$1] }).enumerated() {
            limits[index] = min(widths[index], max(0, remaining) / CGFloat(names.count - rank))
            remaining -= limits[index]
        }
        return names.indices.map { index in
            widths[index] <= limits[index] ? names[index] : truncated(names[index], to: limits[index], measure: measure)
        }
    }

    /// Keeps at least the first character, so that each window stays recognizable.
    static func truncated(_ name: String, to width: CGFloat, measure: (String) -> CGFloat) -> String {
        let characters = Array(name)
        guard characters.count > 1 else { return name }
        func prefix(_ count: Int) -> String {
            var text = String(characters[..<count])
            while text.count > 1, text.last?.isWhitespace == true {
                text.removeLast()
            }
            return text + "…"
        }
        var low = 1
        var high = characters.count - 1
        var best = 1
        while low <= high {
            let middle = (low + high) / 2
            if measure(prefix(middle)) <= width {
                best = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return prefix(best)
    }
}
