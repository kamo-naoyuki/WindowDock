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
    /// windows covering a workspace do not block it.
    public static func resolve(
        at point: CGPoint, sourceFrame: CGRect, sourceTabRowContains: Bool, destinationFrames: [CGRect]
    ) -> Self {
        if sourceTabRowContains { return .source }
        if let index = WindowGeometry.workspaceTabDropTarget(at: point, orderedFrames: destinationFrames) {
            return .transfer(index)
        }
        return sourceFrame.contains(point) ? .source : .none
    }
}
