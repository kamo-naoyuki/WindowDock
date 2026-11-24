import CoreGraphics
import Foundation

/// Leaves are indexed depth-first, left-to-right or top-to-bottom. Frames use a bottom-left origin.
public indirect enum PaneLayout: Codable, Equatable {
    public static let maximumDivisions = 4
    public static let dividerThickness: CGFloat = 8

    public enum Axis: String, Codable {
        case horizontal
        case vertical
    }

    case pane
    case split(axis: Axis, weights: [CGFloat], children: [PaneLayout])

    public var paneCount: Int {
        switch self {
        case .pane: return 1
        case .split(_, _, let children): return children.reduce(0) { $0 + $1.paneCount }
        }
    }

    public var isValid: Bool {
        switch self {
        case .pane: return true
        case .split(_, let weights, let children):
            return children.count >= 2 && weights.count == children.count
                && weights.allSatisfy { $0.isFinite && $0 >= 0 } && weights.reduce(0, +) > 0
                && weights.reduce(0, +).isFinite && children.allSatisfy(\.isValid)
        }
    }

    public static func grid(columnWeights: [CGFloat], rowWeights: [CGFloat]) -> PaneLayout {
        let row: PaneLayout =
            columnWeights.count == 1
            ? .pane
            : .split(
                axis: .horizontal, weights: columnWeights,
                children: columnWeights.map { _ in .pane })
        return rowWeights.count == 1
            ? row : .split(axis: .vertical, weights: rowWeights, children: rowWeights.map { _ in row })
    }

    public func canSplitPane(at index: Int, axis: Axis) -> Bool {
        guard isValid, index >= 0 else { return false }
        return splitCapacity(at: index, axis: axis, remaining: Self.maximumDivisions) >= 2
    }

    private func splitCapacity(at index: Int, axis: Axis, remaining: Int) -> Int {
        switch self {
        case .pane: return index == 0 ? remaining : 0
        case .split(let direction, _, let children):
            // Divider positions do not change the grid-equivalent subdivision count.
            let capacity = direction == axis ? remaining / children.count : remaining
            var offset = 0
            for child in children {
                if index < offset + child.paneCount {
                    return child.splitCapacity(at: index - offset, axis: axis, remaining: capacity)
                }
                offset += child.paneCount
            }
            return 0
        }
    }

    public func splittingPane(at index: Int, axis: Axis) -> PaneLayout? {
        guard canSplitPane(at: index, axis: axis) else { return nil }
        switch self {
        case .pane:
            return .split(axis: axis, weights: [1, 1], children: [.pane, .pane])
        case .split(let direction, let weights, var children):
            var offset = 0
            for child in children.indices {
                if index < offset + children[child].paneCount {
                    guard let replacement = children[child].splittingPane(at: index - offset, axis: axis) else {
                        return nil
                    }
                    children[child] = replacement
                    return .split(axis: direction, weights: weights, children: children)
                }
                offset += children[child].paneCount
            }
            return nil
        }
    }

    public struct Removal {
        public var layout: PaneLayout
        public var destination: Int
    }

    public func removingPane(at index: Int) -> Removal? {
        guard index >= 0 && index < paneCount,
            case .split(let axis, var weights, var children) = self
        else { return nil }
        var offset = 0
        for child in children.indices {
            let count = children[child].paneCount
            if index < offset + count {
                if count == 1 {
                    children.remove(at: child)
                    weights.remove(at: child)
                    let layout =
                        children.count == 1 ? children[0] : .split(axis: axis, weights: weights, children: children)
                    return Removal(layout: layout, destination: child == 0 ? 0 : offset - 1)
                }
                guard let removal = children[child].removingPane(at: index - offset) else { return nil }
                children[child] = removal.layout
                return Removal(
                    layout: .split(axis: axis, weights: weights, children: children),
                    destination: offset + removal.destination
                )
            }
            offset += count
        }
        return nil
    }

    public struct Divider {
        public var path: [Int]
        public var index: Int
        public var axis: Axis
        public var frame: CGRect
        public var lengths: [CGFloat]
        public var minimums: [CGFloat]
    }

    public struct Geometry {
        public var panes: [CGRect]
        public var dividers: [Divider]
    }

    public func minimumSize(_ sizes: [Int: CGSize], dividerThickness: CGFloat) -> CGSize? {
        guard isValid, dividerThickness.isFinite, dividerThickness >= 0,
            sizes.values.allSatisfy({
                $0.width.isFinite && $0.height.isFinite && $0.width >= 0 && $0.height >= 0
            })
        else { return nil }
        return minimumSize(sizes, offset: 0, dividerThickness: dividerThickness)
    }

    private func minimumSize(_ sizes: [Int: CGSize], offset: Int, dividerThickness: CGFloat) -> CGSize {
        switch self {
        case .pane: return sizes[offset] ?? .zero
        case .split(let axis, _, let children):
            var next = offset
            let minimums = children.map { child -> CGSize in
                defer { next += child.paneCount }
                return child.minimumSize(sizes, offset: next, dividerThickness: dividerThickness)
            }
            let dividers = CGFloat(children.count - 1) * dividerThickness
            switch axis {
            case .horizontal:
                return CGSize(
                    width: minimums.reduce(dividers) { $0 + $1.width },
                    height: minimums.map(\.height).max() ?? 0)
            case .vertical:
                return CGSize(
                    width: minimums.map(\.width).max() ?? 0,
                    height: minimums.reduce(dividers) { $0 + $1.height })
            }
        }
    }

    public func geometry(
        in bounds: CGRect, minimums: [Int: CGSize] = [:], dividerThickness: CGFloat = PaneLayout.dividerThickness
    ) -> Geometry? {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
            bounds.width.isFinite, bounds.height.isFinite, bounds.width >= 0, bounds.height >= 0,
            minimumSize(minimums, dividerThickness: dividerThickness) != nil
        else { return nil }
        var result = Geometry(panes: [], dividers: [])
        appendGeometry(in: bounds, minimums: minimums, dividerThickness: dividerThickness, path: [], result: &result)
        return result
    }

    private func appendGeometry(
        in bounds: CGRect, minimums: [Int: CGSize], dividerThickness: CGFloat,
        path: [Int], result: inout Geometry
    ) {
        guard case .split(let axis, let weights, let children) = self else {
            result.panes.append(bounds)
            return
        }
        var offset = result.panes.count
        let childMinimums = children.map { child -> CGFloat in
            defer { offset += child.paneCount }
            let size = child.minimumSize(minimums, offset: offset, dividerThickness: dividerThickness)
            return axis == .horizontal ? size.width : size.height
        }
        let extent = axis == .horizontal ? bounds.width : bounds.height
        let thickness = min(dividerThickness, extent / CGFloat(children.count - 1))
        let lengths = WindowGeometry.lengths(
            weights, minimums: childMinimums,
            available: max(0, extent - CGFloat(children.count - 1) * thickness)
        )
        var position = axis == .horizontal ? bounds.minX : bounds.maxY
        for index in children.indices {
            let frame: CGRect
            if axis == .horizontal {
                frame = CGRect(x: position, y: bounds.minY, width: lengths[index], height: bounds.height)
                position += lengths[index]
            } else {
                position -= lengths[index]
                frame = CGRect(x: bounds.minX, y: position, width: bounds.width, height: lengths[index])
            }
            children[index].appendGeometry(
                in: frame, minimums: minimums, dividerThickness: dividerThickness,
                path: path + [index], result: &result
            )
            if index < children.count - 1 {
                let divider =
                    axis == .horizontal
                    ? CGRect(x: position, y: bounds.minY, width: thickness, height: bounds.height)
                    : CGRect(x: bounds.minX, y: position - thickness, width: bounds.width, height: thickness)
                result.dividers.append(
                    Divider(
                        path: path, index: index, axis: axis, frame: divider, lengths: lengths, minimums: childMinimums
                    ))
                position += axis == .horizontal ? thickness : -thickness
            }
        }
    }

    public func resizing(_ divider: Divider, by delta: CGFloat) -> PaneLayout? {
        let index = divider.index
        guard delta.isFinite, index >= 0, index + 1 < divider.lengths.count,
            divider.minimums.count == divider.lengths.count
        else { return nil }
        var lengths = divider.lengths
        let total = lengths[index] + lengths[index + 1]
        let firstMinimum = max(divider.minimums[index], 1)
        let secondMinimum = max(divider.minimums[index + 1], 1)
        guard total >= firstMinimum + secondMinimum else { return nil }
        lengths[index] = min(max(lengths[index] + delta, firstMinimum), total - secondMinimum)
        lengths[index + 1] = total - lengths[index]
        let sum = lengths.reduce(0, +)
        guard sum > 0 else { return nil }
        return replacingWeights(lengths.map { $0 / sum }, at: divider.path)
    }

    private func replacingWeights(_ replacement: [CGFloat], at path: [Int]) -> PaneLayout? {
        guard case .split(let axis, let weights, var children) = self else { return nil }
        guard let index = path.first else {
            guard replacement.count == children.count else { return nil }
            return .split(axis: axis, weights: replacement, children: children)
        }
        guard children.indices.contains(index),
            let child = children[index].replacingWeights(replacement, at: Array(path.dropFirst()))
        else { return nil }
        children[index] = child
        return .split(axis: axis, weights: weights, children: children)
    }
}
