import Foundation

public extension IndexSet {
    /// All candidate rows belonging to any running application represented in the selection.
    func includingWindowsOfSelectedApps(in processIDs: [Int32]) -> IndexSet {
        let apps = Set(intersection(IndexSet(integersIn: processIDs.indices)).map { processIDs[$0] })
        return IndexSet(processIDs.indices.filter { apps.contains(processIDs[$0]) })
    }
}
