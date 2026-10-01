import Foundation

actor ClaudeHookMonitor {
    struct PollSnapshot: Sendable {
        let isActivelyWorking: Bool
        let lastActivityDate: Date?
        let activeSignals: [String]
        let sessionCount: Int
        let claudeSessionCount: Int
        let cursorSessionCount: Int
        /// Claude sessions stopped by a usage limit that Auto-Resume keeps awake until the limit resets.
        let limitHoldCount: Int

        init(
            isActivelyWorking: Bool,
            lastActivityDate: Date?,
            activeSignals: [String] = [],
            sessionCount: Int = 0,
            claudeSessionCount: Int = 0,
            cursorSessionCount: Int = 0,
            limitHoldCount: Int = 0
        ) {
            self.isActivelyWorking = isActivelyWorking
            self.lastActivityDate = lastActivityDate
            self.activeSignals = activeSignals
            self.sessionCount = sessionCount
            self.claudeSessionCount = claudeSessionCount
            self.cursorSessionCount = cursorSessionCount
            self.limitHoldCount = limitHoldCount
        }

        var activityLine: String {
            guard isActivelyWorking else {
                return limitHoldCount > 0 ? "Activity: Waiting for usage limit reset" : "Activity: Idle"
            }
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

    func poll(now: Date, idleThreshold: TimeInterval, honorLimitHolds: Bool = false) -> PollSnapshot {
        let hookStaleThreshold: TimeInterval = 300
        let claude = scanDirectory(claudeSessionsDir, now: now, staleThreshold: hookStaleThreshold, honorLimitHolds: honorLimitHolds)
        let cursor = scanDirectory(cursorSessionsDir, now: now, staleThreshold: hookStaleThreshold, honorLimitHolds: false)
        let claudeCount = claude.active
        let cursorCount = cursor.active
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
            cursorSessionCount: cursorCount,
            limitHoldCount: claude.held
        )
    }

    private func scanDirectory(
        _ sessionsDir: URL,
        now: Date,
        staleThreshold: TimeInterval,
        honorLimitHolds: Bool
    ) -> (active: Int, held: Int) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }

        var activeSessionCount = 0
        var heldSessionCount = 0
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

            // Written by the StopFailure hook when a usage limit ended the turn (Auto-Resume).
            if let holdUntilMs = double(from: json["holdUntil"]) {
                // idle.js never holds for more than a day; anything longer is not a hold to honor.
                let isPlausible = holdUntilMs - timestampMs <= 25 * 3600 * 1000
                if honorLimitHolds && isProcessAlive && isPlausible && now.timeIntervalSince1970 * 1000 < holdUntilMs {
                    heldSessionCount += 1
                } else {
                    try? fileManager.removeItem(at: fileURL)
                }
                continue
            }

            let isStale = elapsed > staleThreshold

            if !isProcessAlive || isStale {
                try? fileManager.removeItem(at: fileURL)
                continue
            }

            activeSessionCount += 1
        }
        return (activeSessionCount, heldSessionCount)
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
