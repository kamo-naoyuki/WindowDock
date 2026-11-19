import Foundation
import CoreGraphics

public enum WindowGeometry {
    // AppKit uses a bottom-left origin; Accessibility uses the primary display's top-left.
    public static func accessibilityRect(from screenRect: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(
            x: screenRect.minX,
            y: primaryScreenTop - screenRect.maxY,
            width: screenRect.width,
            height: screenRect.height
        )
    }

    public static func screenRect(from accessibilityRect: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        self.accessibilityRect(from: accessibilityRect, primaryScreenTop: primaryScreenTop)
    }

    public static func fits(_ actual: CGRect, requested: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(actual.minX - requested.minX) <= tolerance &&
        abs(actual.minY - requested.minY) <= tolerance &&
        abs(actual.width - requested.width) <= tolerance &&
        abs(actual.height - requested.height) <= tolerance
    }

    // Water-fill proportional lengths around hard minimums without changing the saved ratios.
    public static func lengths(_ weights: [CGFloat], minimums: [CGFloat], available: CGFloat) -> [CGFloat] {
        guard available > 0 else { return Array(repeating: 0, count: weights.count) }
        let totalMinimum = minimums.reduce(0, +)
        if totalMinimum > available {
            return totalMinimum > 0 ? minimums.map { available * $0 / totalMinimum } : weights.map { available * $0 }
        }
        var result = Array(repeating: CGFloat(0), count: weights.count)
        var free = Set(weights.indices)
        var remaining = available
        while !free.isEmpty {
            let weightSum = free.reduce(CGFloat(0)) { $0 + weights[$1] }
            let count = CGFloat(free.count)
            let fixed = free.filter { index in
                let share = weightSum > 0 ? remaining * weights[index] / weightSum : remaining / count
                return share < minimums[index]
            }
            if fixed.isEmpty {
                for index in free {
                    result[index] = weightSum > 0 ? remaining * weights[index] / weightSum : remaining / count
                }
                break
            }
            for index in fixed {
                result[index] = minimums[index]
                remaining -= minimums[index]
                free.remove(index)
            }
        }
        return result
    }

    /// Per-column and per-row minimums needed by the windows in each cell, or nil if a size is invalid.
    public static func trackMinimums(
        _ sizes: [Int: CGSize], columns: Int, rows: Int
    ) -> (columns: [CGFloat], rows: [CGFloat])? {
        var columnMinimums = Array(repeating: CGFloat(0), count: columns)
        var rowMinimums = Array(repeating: CGFloat(0), count: rows)
        for (index, size) in sizes where index >= 0 && index < columns * rows {
            guard size.width.isFinite, size.height.isFinite, size.width >= 0, size.height >= 0 else { return nil }
            columnMinimums[index % columns] = max(columnMinimums[index % columns], size.width)
            rowMinimums[index / columns] = max(rowMinimums[index / columns], size.height)
        }
        return (columnMinimums, rowMinimums)
    }
}
