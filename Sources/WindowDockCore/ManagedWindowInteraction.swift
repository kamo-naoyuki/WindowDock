import CoreGraphics

public enum ManagedWindowInteraction: Equatable {
    case move(CGVector)
    case resizeWorkspace(edges: WorkspaceResizeEdges, delta: CGSize)
    case moveDivider(edge: WorkspaceResizeEdges, delta: CGFloat)
    case maximize
    case ignore
}

public enum ManagedWindowInteractionClassifier {
    public static func classify(
        start: CGRect,
        current: CGRect,
        pane: CGRect,
        workspaceContent: CGRect,
        screenVisibleFrames: [CGRect],
        roundingTolerance: CGSize
    ) -> ManagedWindowInteraction {
        guard isValid(start), isValid(current), isValid(pane), isValid(workspaceContent),
              roundingTolerance.width.isFinite, roundingTolerance.width >= 0,
              roundingTolerance.height.isFinite, roundingTolerance.height >= 0,
              isAligned(start, in: pane, roundingTolerance: roundingTolerance)
        else { return .ignore }

        if screenVisibleFrames.contains(where: {
            isValid($0) && fits(current, $0, tolerance: roundingTolerance)
        }) {
            return .maximize
        }

        let widthChanged = abs(current.width - start.width) > roundingTolerance.width
        let heightChanged = abs(current.height - start.height) > roundingTolerance.height
        guard widthChanged || heightChanged else {
            let movement = CGVector(dx: current.minX - start.minX, dy: current.minY - start.minY)
            return hypot(movement.dx, movement.dy) >= 4 ? .move(movement) : .ignore
        }

        var movedEdges: [(edge: WorkspaceResizeEdges, delta: CGFloat)] = []
        if widthChanged {
            guard let edge = changedEdge(
                leading: current.minX - start.minX,
                trailing: current.maxX - start.maxX,
                tolerance: roundingTolerance.width,
                leadingEdge: .left,
                trailingEdge: .right
            ) else { return .ignore }
            movedEdges.append(edge)
        }
        if heightChanged {
            guard let edge = changedEdge(
                leading: current.minY - start.minY,
                trailing: current.maxY - start.maxY,
                tolerance: roundingTolerance.height,
                leadingEdge: .top,
                trailingEdge: .bottom
            ) else { return .ignore }
            movedEdges.append(edge)
        }

        let outerEdges = movedEdges.filter { isOuterEdge($0.edge, pane: pane, workspace: workspaceContent) }
        guard !outerEdges.isEmpty else {
            guard movedEdges.count == 1, let edge = movedEdges.first else { return .ignore }
            return .moveDivider(edge: edge.edge, delta: edge.delta)
        }
        guard outerEdges.count == movedEdges.count else { return .ignore }

        var edges: WorkspaceResizeEdges = []
        var delta = CGSize.zero
        for movedEdge in movedEdges {
            edges.insert(movedEdge.edge)
            if movedEdge.edge == .left || movedEdge.edge == .right {
                delta.width = movedEdge.delta
            } else {
                delta.height = -movedEdge.delta
            }
        }
        return .resizeWorkspace(edges: edges, delta: delta)
    }

    private static func changedEdge(
        leading: CGFloat,
        trailing: CGFloat,
        tolerance: CGFloat,
        leadingEdge: WorkspaceResizeEdges,
        trailingEdge: WorkspaceResizeEdges
    ) -> (edge: WorkspaceResizeEdges, delta: CGFloat)? {
        let leadingMoved = abs(leading) > tolerance
        let trailingMoved = abs(trailing) > tolerance
        guard leadingMoved != trailingMoved else { return nil }
        return leadingMoved ? (leadingEdge, leading) : (trailingEdge, trailing)
    }

    private static func isOuterEdge(_ edge: WorkspaceResizeEdges, pane: CGRect, workspace: CGRect) -> Bool {
        if edge == .left { return abs(pane.minX - workspace.minX) <= 1 }
        if edge == .right { return abs(pane.maxX - workspace.maxX) <= 1 }
        if edge == .top { return abs(pane.minY - workspace.minY) <= 1 }
        if edge == .bottom { return abs(pane.maxY - workspace.maxY) <= 1 }
        return false
    }

    /// An aligned window sits at its pane's origin; apps that size in steps can leave it slightly off the pane's size.
    private static func isAligned(_ start: CGRect, in pane: CGRect, roundingTolerance: CGSize) -> Bool {
        abs(start.minX - pane.minX) <= 1 && abs(start.minY - pane.minY) <= 1
            && abs(start.width - pane.width) <= roundingTolerance.width
            && abs(start.height - pane.height) <= roundingTolerance.height
    }

    private static func fits(_ actual: CGRect, _ expected: CGRect, tolerance: CGSize) -> Bool {
        abs(actual.minX - expected.minX) <= tolerance.width
            && abs(actual.minY - expected.minY) <= tolerance.height
            && abs(actual.width - expected.width) <= tolerance.width
            && abs(actual.height - expected.height) <= tolerance.height
    }

    private static func isValid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite
            && rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }
}
