import CoreGraphics

public struct WorkspaceResizeEdges: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let left = Self(rawValue: 1 << 0)
    public static let right = Self(rawValue: 1 << 1)
    public static let bottom = Self(rawValue: 1 << 2)
    public static let top = Self(rawValue: 1 << 3)
}

/// Application-controlled workspace resizing, in AppKit's bottom-left coordinates.
public enum WorkspaceResize {
    public static let edgeThickness: CGFloat = 8
    public static let gripSize: CGFloat = 18

    public static func grip(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.maxX - gripSize, y: bounds.minY, width: gripSize, height: gripSize)
    }

    /// Points outside `bounds` (the native resize margin) count as the nearest edges.
    public static func edges(at point: CGPoint, in bounds: CGRect) -> WorkspaceResizeEdges {
        if grip(in: bounds).contains(point) { return [.right, .bottom] }
        var edges: WorkspaceResizeEdges = []
        if point.x < bounds.minX + edgeThickness { edges.insert(.left) }
        if point.x > bounds.maxX - edgeThickness { edges.insert(.right) }
        if point.y < bounds.minY + edgeThickness { edges.insert(.bottom) }
        if point.y > bounds.maxY - edgeThickness { edges.insert(.top) }
        return edges
    }

    public static func resizedFrame(
        from frame: CGRect,
        delta: CGSize,
        edges: WorkspaceResizeEdges,
        minimumSize: CGSize,
        maximumTop: CGFloat = .greatestFiniteMagnitude
    ) -> CGRect {
        var result = frame
        if edges.contains(.left) {
            result.size.width = max(minimumSize.width, frame.width - delta.width)
            result.origin.x = frame.maxX - result.width
        } else if edges.contains(.right) {
            result.size.width = max(minimumSize.width, frame.width + delta.width)
        }
        if edges.contains(.bottom) {
            result.size.height = max(minimumSize.height, frame.height - delta.height)
            result.origin.y = frame.maxY - result.height
        } else if edges.contains(.top) {
            // Like native resizing, the top edge stops at the menu bar but never shrinks a window already above it.
            let top = max(maximumTop, frame.maxY)
            result.size.height = max(minimumSize.height, min(frame.height + delta.height, top - frame.minY))
        }
        return result
    }
}
