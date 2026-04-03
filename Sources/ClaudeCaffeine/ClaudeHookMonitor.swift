import Foundation

actor ClaudeHookMonitor {
    struct PollSnapshot: Sendable {
        let isActivelyWorking: Bool
        let lastActivityDate: Date?
        let activeSignals: [String]
        let isTasksDirectoryMissing: Bool = false
        
        init(isActivelyWorking: Bool, lastActivityDate: Date?, activeSignals: [String] = []) {
            self.isActivelyWorking = isActivelyWorking
            self.lastActivityDate = lastActivityDate
            self.activeSignals = activeSignals
        }
    }

    private let activeFileURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/.caffeine_active")
    private var lastObservedActiveDate: Date?
    private let gracePeriod: TimeInterval = 10.0

    func poll(now: Date, idleThreshold: TimeInterval) -> PollSnapshot {
        var isActivelyWorking = false
        var activeSignals: [String] = []
        
        let fileExists = FileManager.default.fileExists(atPath: activeFileURL.path)
        
        if fileExists {
            isActivelyWorking = true
            activeSignals.append("Hooks")
            lastObservedActiveDate = now
        } else if let lastActive = lastObservedActiveDate, now.timeIntervalSince(lastActive) < gracePeriod {
            // Grace period: keep it "actively working" for a few seconds after the file is removed
            isActivelyWorking = true
            activeSignals.append("Hooks (Grace)")
        }

        return PollSnapshot(
            isActivelyWorking: isActivelyWorking,
            lastActivityDate: lastObservedActiveDate,
            activeSignals: activeSignals
        )
    }
}
