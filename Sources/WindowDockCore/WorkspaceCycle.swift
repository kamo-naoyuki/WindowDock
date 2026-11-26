/// Picks the workspace that "Next/Previous Workspace" switches to.
public enum WorkspaceCycle {
    /// The first eligible index `offset` steps from `current`, wrapping around; nil when no other workspace qualifies.
    /// Without a current workspace, forward starts at the first one and backward at the last one.
    public static func target(from current: Int?, offset: Int, count: Int, isEligible: (Int) -> Bool) -> Int? {
        guard count > 0, offset != 0 else { return nil }
        let step = offset > 0 ? 1 : -1
        var index = current ?? (step > 0 ? -1 : count)
        for _ in 0 ..< count {
            index = ((index + step) % count + count) % count
            if index == current { return nil }
            if isEligible(index) { return index }
        }
        return nil
    }
}
