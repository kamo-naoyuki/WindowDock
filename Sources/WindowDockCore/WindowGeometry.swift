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

    public static func confirmedCoverage(for frame: CGRect, renderedFrames: [CGRect]) -> CGRect? {
        renderedFrames.map { frame.intersection($0) }
            .filter { !$0.isNull && !$0.isEmpty }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    /// Frames are ordered front-to-back among eligible workspaces, not all application windows.
    public static func workspaceTabDropTarget(at point: CGPoint, orderedFrames: [CGRect]) -> Int? {
        orderedFrames.firstIndex { $0.contains(point) } ??
            orderedFrames.firstIndex {
                let nearby = $0.insetBy(dx: -24, dy: -24)
                return point.x >= nearby.minX && point.x <= nearby.maxX &&
                    point.y >= nearby.minY && point.y <= nearby.maxY
            }
    }

    /// Insertion index for a tab dropped at `x`; points scrolled out of view count as the visible strip's edge.
    public static func tabInsertionIndex(
        at x: CGFloat, tabFrames: [CGRect], visibleMinX: CGFloat, visibleMaxX: CGFloat
    ) -> Int {
        let x = min(max(x, visibleMinX), visibleMaxX)
        return tabFrames.firstIndex { x < $0.midX } ?? tabFrames.count
    }

    /// Leading x of the insertion line before tab `index` (or after the last tab), kept inside the visible strip.
    public static func tabInsertionLineX(
        index: Int, tabFrames: [CGRect], emptyX: CGFloat,
        visibleMinX: CGFloat, visibleMaxX: CGFloat, lineWidth: CGFloat
    ) -> CGFloat {
        let x = tabFrames.indices.contains(index) ? tabFrames[index].minX : tabFrames.last?.maxX ?? emptyX
        return min(max(visibleMinX, x), visibleMaxX - lineWidth)
    }

    public static func tabWidths(preferredWidths: [CGFloat], available: CGFloat) -> [CGFloat] {
        let preferred = preferredWidths.map { min(200, max(48, ceil($0))) }
        var remaining = max(available, CGFloat(preferred.count) * 48)
        for (index, width) in preferred.sorted().enumerated() {
            let limit = remaining / CGFloat(preferred.count - index)
            if width >= limit {
                return preferred.map { min($0, limit) }
            }
            remaining -= width
        }
        return preferred
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
