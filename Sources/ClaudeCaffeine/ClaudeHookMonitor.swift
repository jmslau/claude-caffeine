import Foundation

actor ClaudeHookMonitor {
    struct PollSnapshot: Sendable {
        let isActivelyWorking: Bool
        let lastActivityDate: Date?
        let activeSignals: [String]
        let sessionCount: Int
        
        init(isActivelyWorking: Bool, lastActivityDate: Date?, activeSignals: [String] = [], sessionCount: Int = 0) {
            self.isActivelyWorking = isActivelyWorking
            self.lastActivityDate = lastActivityDate
            self.activeSignals = activeSignals
            self.sessionCount = sessionCount
        }
    }

    private let sessionsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/caffeine_sessions")
    private let maxSessionAge: TimeInterval = 3600.0 * 12 // 12 hours safety cleanup
    private var lastObservedActiveDate: Date?

    func poll(now: Date, idleThreshold: TimeInterval) -> PollSnapshot {
        var activeSessionCount = 0
        var foundAnyActive = false
        
        let fileManager = FileManager.default
        let hookStaleThreshold: TimeInterval = 300 // 5 minutes
        
        if let contents = try? fileManager.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil, options: []) {
            for fileURL in contents {
                guard let data = try? Data(contentsOf: fileURL),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let timestampMs = json["timestamp"] as? Double,
                      let pid = json["pid"] as? Int32 else {
                    // Legacy or Corrupt file - cleanup if old
                    if let attr = try? fileManager.attributesOfItem(atPath: fileURL.path),
                       let modDate = attr[.modificationDate] as? Date,
                       now.timeIntervalSince(modDate) > hookStaleThreshold {
                        try? fileManager.removeItem(at: fileURL)
                    }
                    continue
                }
                
                let lastHookDate = Date(timeIntervalSince1970: timestampMs / 1000.0)
                let elapsed = now.timeIntervalSince(lastHookDate)
                
                // 1. Check PID liveness (kill with signal 0 checks existence)
                let isProcessAlive = kill(pid, 0) == 0
                
                // 2. Check if stale (Escape key handling)
                let isStale = elapsed > hookStaleThreshold
                
                if !isProcessAlive || isStale {
                    // Cleanup zombie session
                    try? fileManager.removeItem(at: fileURL)
                    continue
                }
                
                activeSessionCount += 1
                foundAnyActive = true
            }
        }
        
        if foundAnyActive {
            lastObservedActiveDate = now
        }
        
        let activeSignals = foundAnyActive ? ["\(activeSessionCount) Sessions"] : []

        return PollSnapshot(
            isActivelyWorking: foundAnyActive,
            lastActivityDate: lastObservedActiveDate,
            activeSignals: activeSignals,
            sessionCount: activeSessionCount
        )
    }
}
