import Foundation

actor ClaudeHookMonitor {
    struct PollSnapshot: Sendable {
        let isActivelyWorking: Bool
        let lastActivityDate: Date?
        let isTasksDirectoryMissing: Bool = false
    }

    private let activeFileURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/.caffeine_active")
    private var lastObservedActiveDate: Date?
    private let gracePeriod: TimeInterval = 10.0

    func poll(now: Date, idleThreshold: TimeInterval) -> PollSnapshot {
        var isActivelyWorking = false
        
        let fileExists = FileManager.default.fileExists(atPath: activeFileURL.path)
        
        if fileExists {
            isActivelyWorking = true
            lastObservedActiveDate = now
        } else if let lastActive = lastObservedActiveDate, now.timeIntervalSince(lastActive) < gracePeriod {
            // Grace period: keep it "actively working" for a few seconds after the file is removed
            isActivelyWorking = true
        }

        return PollSnapshot(
            isActivelyWorking: isActivelyWorking,
            lastActivityDate: lastObservedActiveDate
        )
    }
}
