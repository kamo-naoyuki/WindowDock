import CoreGraphics

/// Where a tab released (or hovering) during a tab drag is delivered.
public enum WorkspaceTabDragRoute: Equatable {
    /// Nothing happens: ownership and tab order stay unchanged.
    case none
    /// Reorder within, or move into a pane of, the source workspace.
    case source
    /// Move the tab to the destination at this index.
    case transfer(Int)

    /// `destinationFrames` are the other workspaces ordered front to back among workspaces only, so ordinary
    /// windows covering a workspace do not block it; the first `destinationsInFront` of them are in front of the
    /// source. Where workspaces overlap, the frontmost one receives the tab, as the user sees it.
    public static func resolve(
        at point: CGPoint, sourceFrame: CGRect, sourceTabRowContains: Bool, destinationFrames: [CGRect],
        destinationsInFront: Int
    ) -> Self {
        let inFront = min(max(destinationsInFront, 0), destinationFrames.count)
        if let index = destinationFrames[..<inFront].firstIndex(where: { $0.contains(point) }) {
            return .transfer(index)
        }
        if sourceTabRowContains || sourceFrame.contains(point) { return .source }
        if let index = WindowGeometry.workspaceTabDropTarget(at: point, orderedFrames: destinationFrames) {
            return .transfer(index)
        }
        return .none
    }
}
