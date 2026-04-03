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
        var isActivelyWorking = false
        var activeSignals: [String] = []
        var sessionCount = 0
        
        let fileManager = FileManager.default
        if let contents = try? fileManager.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey], options: []) {
            for fileURL in contents {
                guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                      let modDate = attributes[.modificationDate] as? Date else { continue }
                
                // Safety cleanup of orphan files
                if now.timeIntervalSince(modDate) > maxSessionAge {
                    try? fileManager.removeItem(at: fileURL)
                    continue
                }
                
                // If it was touched recently, or exists at all, it represents an active session
                // We trust the hooks to touch/rm correctly, but any file existence here means "Active".
                sessionCount += 1
                isActivelyWorking = true
                lastObservedActiveDate = now
            }
        }
        
        if isActivelyWorking {
            activeSignals.append("\(sessionCount) Sessions")
        }

        return PollSnapshot(
            isActivelyWorking: isActivelyWorking,
            lastActivityDate: lastObservedActiveDate,
            activeSignals: activeSignals,
            sessionCount: sessionCount
        )
    }
}
