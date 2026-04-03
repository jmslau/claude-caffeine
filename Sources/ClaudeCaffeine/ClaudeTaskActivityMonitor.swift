import Foundation
import os.log

public struct ClaudeTaskActivityMonitor: Sendable {
    private let logger = Logger(subsystem: "com.jmslau.claudecaffeine", category: "TaskMonitor")
    private let tasksRootURL: URL
    
    public struct Snapshot: Sendable {
        public let hasActiveSessions: Bool
        public let lastActivityDate: Date?
        public let isTasksDirectoryMissing: Bool
    }

    public init(tasksRootURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/tasks")) {
        self.tasksRootURL = tasksRootURL
    }

    public func poll(idleThreshold: TimeInterval) -> Snapshot {
        var isMissing = false
        var lastActivityDate: Date? = nil
        var hasActiveSessions = false
        
        let fm = FileManager.default
        guard fm.fileExists(atPath: tasksRootURL.path) else {
            return Snapshot(hasActiveSessions: false, lastActivityDate: nil, isTasksDirectoryMissing: true)
        }
        
        do {
            let taskDirs = try fm.contentsOfDirectory(at: tasksRootURL, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
            
            for dir in taskDirs {
                let resourceValues = try dir.resourceValues(forKeys: [.contentModificationDateKey])
                if let modDate = resourceValues.contentModificationDate {
                    if lastActivityDate == nil || modDate > lastActivityDate! {
                        lastActivityDate = modDate
                    }
                    
                    if Date().timeIntervalSince(modDate) < idleThreshold {
                        hasActiveSessions = true
                    }
                }
                
                // Also scan inside the directory for specific tool output or log files if needed,
                // but usually the directory modification date is updated when files inside change.
            }
        } catch {
            logger.error("Failed to scan tasks directory: \(error.localizedDescription)")
            isMissing = true
        }

        return Snapshot(
            hasActiveSessions: hasActiveSessions,
            lastActivityDate: lastActivityDate,
            isTasksDirectoryMissing: isMissing
        )
    }
}
