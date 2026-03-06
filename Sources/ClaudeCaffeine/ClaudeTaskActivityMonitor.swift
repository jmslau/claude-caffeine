import Foundation

struct ClaudeTaskActivityMonitor: Sendable {
    enum PollStatus: Sendable, Equatable {
        case ok
        case tasksRootMissing
        case ioError
    }

    struct SessionActivity: Sendable {
        let sessionID: String
        let lastActivityAt: Date
        let idleFor: TimeInterval
    }

    struct PollSnapshot: Sendable {
        let activeSessions: [SessionActivity]
        let totalSessions: Int
        let status: PollStatus
        let processStatus: ClaudeProcessDetector.ProcessStatus

        /// Claude Code is actively working if the process is making API calls / using CPU,
        /// OR if there is recent file activity in ~/.claude/tasks during ambiguous process
        /// states (e.g. brief CPU dips during tool execution). File activity alone is not
        /// sufficient when the process is clearly idle at the prompt.
        var isClaudeActivelyWorking: Bool {
            processStatus.isActivelyWorking || (processStatus.isAmbiguous && !activeSessions.isEmpty)
        }

        var isClaudeRunning: Bool {
            processStatus.isRunning
        }
    }

    let tasksRootURL: URL
    let detectProcess: @Sendable () -> ClaudeProcessDetector.ProcessStatus

    init(
        tasksRootURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/tasks"),
        detectProcess: @escaping @Sendable () -> ClaudeProcessDetector.ProcessStatus = ClaudeProcessDetector().detect
    ) {
        self.tasksRootURL = tasksRootURL
        self.detectProcess = detectProcess
    }

    func poll(now: Date = Date(), idleThreshold: TimeInterval) -> PollSnapshot {
        let processStatus = detectProcess()

        guard idleThreshold > 0 else {
            return PollSnapshot(activeSessions: [], totalSessions: 0, status: .ok, processStatus: processStatus)
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: tasksRootURL.path, isDirectory: &isDirectory) else {
            return PollSnapshot(activeSessions: [], totalSessions: 0, status: .tasksRootMissing, processStatus: processStatus)
        }
        guard isDirectory.boolValue else {
            return PollSnapshot(activeSessions: [], totalSessions: 0, status: .ioError, processStatus: processStatus)
        }

        let fileManager = FileManager.default
        let taskDirectories: [URL]
        do {
            taskDirectories = try fileManager.contentsOfDirectory(
                at: tasksRootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return PollSnapshot(activeSessions: [], totalSessions: 0, status: .ioError, processStatus: processStatus)
        }

        var totalSessions = 0
        var hadReadError = false
        var activeSessions: [SessionActivity] = []
        for directoryURL in taskDirectories {
            let values: URLResourceValues
            do {
                values = try directoryURL.resourceValues(forKeys: [.isDirectoryKey])
            } catch {
                hadReadError = true
                continue
            }
            guard values.isDirectory == true else {
                continue
            }
            totalSessions += 1

            let lastActivity: Date?
            do {
                lastActivity = try latestActivityDate(in: directoryURL)
            } catch {
                hadReadError = true
                continue
            }
            guard let lastActivity else {
                continue
            }

            let idleFor = now.timeIntervalSince(lastActivity)
            guard idleFor <= idleThreshold else {
                continue
            }

            activeSessions.append(
                SessionActivity(
                    sessionID: directoryURL.lastPathComponent,
                    lastActivityAt: lastActivity,
                    idleFor: idleFor
                )
            )
        }

        activeSessions.sort(by: { $0.lastActivityAt > $1.lastActivityAt })
        let status: PollStatus = hadReadError ? .ioError : .ok
        return PollSnapshot(activeSessions: activeSessions, totalSessions: totalSessions, status: status, processStatus: processStatus)
    }

    func activeSessions(now: Date = Date(), idleThreshold: TimeInterval) -> [SessionActivity] {
        poll(now: now, idleThreshold: idleThreshold).activeSessions
    }

    private func latestActivityDate(in directoryURL: URL) throws -> Date? {
        let fileManager = FileManager.default
        var encounteredEnumerationError = false
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                encounteredEnumerationError = true
                return true
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var latestDate: Date?
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else {
                continue
            }

            guard let modifiedAt = values?.contentModificationDate else {
                continue
            }

            if latestDate == nil || modifiedAt > latestDate! {
                latestDate = modifiedAt
            }
        }

        if encounteredEnumerationError {
            throw CocoaError(.fileReadUnknown)
        }
        return latestDate
    }
}
