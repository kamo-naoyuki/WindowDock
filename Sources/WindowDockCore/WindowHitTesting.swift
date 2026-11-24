import CoreGraphics

public enum WindowHitTesting {
    public static func frontmostWindow(
        at point: CGPoint, windows: [(id: UInt32, frame: CGRect)], excluding: Set<UInt32>
    ) -> UInt32? {
        windows.first { !excluding.contains($0.id) && $0.frame.contains(point) }?.id
    }

    /// The app's own window whose click just activated the app, if any. Such an activation raises only the
    /// clicked window, unlike Cmd+Tab or the Dock, which raise all of them. `windows` is front to back.
    public static func activatingClick(
        at point: CGPoint, windows: [(id: UInt32, ownerPID: Int32, frame: CGRect)],
        ownPID: Int32, buttonDown: Bool, secondsSinceMouseDown: Double
    ) -> UInt32? {
        guard buttonDown || secondsSinceMouseDown < 0.5,
            let front = windows.first(where: { $0.frame.contains(point) }),
            front.ownerPID == ownPID
        else { return nil }
        return front.id
    }
}
