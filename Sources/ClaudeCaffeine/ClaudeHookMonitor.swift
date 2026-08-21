import Foundation

actor ClaudeHookMonitor {
    struct PollSnapshot: Sendable {
        let isActivelyWorking: Bool
        let lastActivityDate: Date?
        let activeSignals: [String]
        let sessionCount: Int
        let claudeSessionCount: Int
        let cursorSessionCount: Int

        init(
            isActivelyWorking: Bool,
            lastActivityDate: Date?,
            activeSignals: [String] = [],
            sessionCount: Int = 0,
            claudeSessionCount: Int = 0,
            cursorSessionCount: Int = 0
        ) {
            self.isActivelyWorking = isActivelyWorking
            self.lastActivityDate = lastActivityDate
            self.activeSignals = activeSignals
            self.sessionCount = sessionCount
            self.claudeSessionCount = claudeSessionCount
            self.cursorSessionCount = cursorSessionCount
        }

        var activityLine: String {
            guard isActivelyWorking else { return "Activity: Idle" }
            var parts: [String] = []
            if claudeSessionCount > 0 {
                parts.append("Claude \(claudeSessionCount)")
            }
            if cursorSessionCount > 0 {
                parts.append("Cursor \(cursorSessionCount)")
            }
            if parts.isEmpty {
                return "Activity: Active"
            }
            return "Activity: Active (\(parts.joined(separator: ", ")))"
        }

        var sleepAssertionReason: String {
            let claudeActive = claudeSessionCount > 0
            let cursorActive = cursorSessionCount > 0
            if claudeActive && cursorActive {
                return "Keeping Mac awake while Claude Code and Cursor are actively working"
            }
            if cursorActive {
                return "Keeping Mac awake while Cursor is actively working"
            }
            return "Keeping Mac awake while Claude Code is actively working"
        }
    }

    private let claudeSessionsDir: URL
    private let cursorSessionsDir: URL
    private var lastObservedActiveDate: Date?

    init(
        claudeSessionsDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/caffeine_sessions"),
        cursorSessionsDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cursor/caffeine_sessions")
    ) {
        self.claudeSessionsDir = claudeSessionsDir
        self.cursorSessionsDir = cursorSessionsDir
    }

    func poll(now: Date, idleThreshold: TimeInterval) -> PollSnapshot {
        let hookStaleThreshold: TimeInterval = 300
        let claudeCount = scanDirectory(claudeSessionsDir, now: now, staleThreshold: hookStaleThreshold)
        let cursorCount = scanDirectory(cursorSessionsDir, now: now, staleThreshold: hookStaleThreshold)
        let foundAnyActive = claudeCount > 0 || cursorCount > 0

        if foundAnyActive {
            lastObservedActiveDate = now
        }

        var activeSignals: [String] = []
        if claudeCount > 0 {
            activeSignals.append("\(claudeCount) Claude")
        }
        if cursorCount > 0 {
            activeSignals.append("\(cursorCount) Cursor")
        }

        return PollSnapshot(
            isActivelyWorking: foundAnyActive,
            lastActivityDate: lastObservedActiveDate,
            activeSignals: activeSignals,
            sessionCount: claudeCount + cursorCount,
            claudeSessionCount: claudeCount,
            cursorSessionCount: cursorCount
        )
    }

    private func scanDirectory(_ sessionsDir: URL, now: Date, staleThreshold: TimeInterval) -> Int {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var activeSessionCount = 0
        for fileURL in contents {
            guard let data = try? Data(contentsOf: fileURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestampMs = double(from: json["timestamp"]),
                  let pid = int32(from: json["pid"]) else {
                if let attr = try? fileManager.attributesOfItem(atPath: fileURL.path),
                   let modDate = attr[FileAttributeKey.modificationDate] as? Date,
                   now.timeIntervalSince(modDate) > staleThreshold {
                    try? fileManager.removeItem(at: fileURL)
                }
                continue
            }

            let lastHookDate = Date(timeIntervalSince1970: timestampMs / 1000.0)
            let elapsed = now.timeIntervalSince(lastHookDate)
            let isProcessAlive = kill(pid, 0) == 0
            let isStale = elapsed > staleThreshold

            if !isProcessAlive || isStale {
                try? fileManager.removeItem(at: fileURL)
                continue
            }

            activeSessionCount += 1
        }
        return activeSessionCount
    }

    private func double(from value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private func int32(from value: Any?) -> Int32? {
        if let number = value as? Int32 { return number }
        if let number = value as? Int { return Int32(number) }
        if let number = value as? NSNumber { return number.int32Value }
        return nil
    }
}
