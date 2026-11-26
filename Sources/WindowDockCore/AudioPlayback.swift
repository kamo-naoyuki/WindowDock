import Foundation

/// Which applications a process playing audio may be playing for.
public enum AudioPlaybackAttribution {
    /// Each process counts for itself, for the process macOS holds responsible for it (Safari for its WebKit GPU
    /// process), and for their ancestors below launchd (a browser for its audio helper).
    public static func applications(
        of processes: Set<pid_t>, responsible: (pid_t) -> pid_t?, parent: (pid_t) -> pid_t?
    ) -> Set<pid_t> {
        var applications = Set<pid_t>()
        for process in processes {
            for start in [process, responsible(process)].compactMap({ $0 }) {
                var next: pid_t? = start
                // A process already counted had its ancestors counted too.
                for _ in 0 ..< 16 {
                    guard let pid = next, pid > 1, applications.insert(pid).inserted else { break }
                    next = parent(pid)
                }
            }
        }
        return applications
    }
}

/// Keeps applications marked as playing for a moment after their audio stops, like Chrome's recently audible tabs,
/// so the indicator doesn't flicker between sounds.
public struct RecentlyAudibleApplications {
    public let hold: TimeInterval
    private var playing: Set<pid_t> = []
    private var stopped: [pid_t: TimeInterval] = [:]

    public init(hold: TimeInterval) { self.hold = hold }

    /// Records the applications playing at `time`; returns them with those that stopped less than `hold` before.
    public mutating func update(playing now: Set<pid_t>, at time: TimeInterval) -> Set<pid_t> {
        for application in playing.subtracting(now) { stopped[application] = time }
        playing = now
        stopped = stopped.filter { !now.contains($0.key) && time - $0.value < hold }
        return now.union(stopped.keys)
    }

    /// When the next application that stopped playing stops counting as audible.
    public var nextExpiry: TimeInterval? { stopped.values.min().map { $0 + hold } }
}
