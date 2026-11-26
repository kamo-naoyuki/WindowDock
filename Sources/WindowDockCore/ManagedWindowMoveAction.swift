public enum ManagedWindowMoveAction: String, CaseIterable, Sendable {
    case follow
    case returnToPane
    case nothing

    public static func migrated(from legacyValue: Bool?) -> Self {
        guard let legacyValue else { return .follow }
        return legacyValue ? .returnToPane : .nothing
    }
}
