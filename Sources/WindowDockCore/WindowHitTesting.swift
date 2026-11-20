import CoreGraphics

public enum WindowHitTesting {
    public static func frontmostWindow(
        at point: CGPoint, windows: [(id: UInt32, frame: CGRect)], excluding: Set<UInt32>
    ) -> UInt32? {
        windows.first { !excluding.contains($0.id) && $0.frame.contains(point) }?.id
    }
}
