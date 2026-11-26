import CoreGraphics

/// Tracks a left-button press until its release.
public struct LeftMousePress {
    public private(set) var start: CGPoint?

    public init() {}

    /// Starts a press. AppKit tracking loops, such as a button's, consume their own release, so a press can begin
    /// while an earlier one still looks unfinished; returns whether that happened.
    @discardableResult
    public mutating func begin(at point: CGPoint) -> Bool {
        let missedRelease = start != nil
        start = point
        return missedRelease
    }

    /// Returns whether the pointer moved far enough to count as a drag, or nil without a press.
    public mutating func end(at point: CGPoint) -> Bool? {
        guard let start else { return nil }
        self.start = nil
        return hypot(point.x - start.x, point.y - start.y) >= 4
    }

    public mutating func cancel() {
        start = nil
    }
}
