import Foundation

struct ClaudeProcessDetector: Sendable {
    struct ProcessStatus: Sendable, Equatable {
        let isRunning: Bool
        let hasActiveConnections: Bool
        let cpuUsage: Double
        let pids: [Int32]

        var isActivelyWorking: Bool {
            isRunning && (cpuUsage > 5.0 || (hasActiveConnections && cpuUsage > 1.0))
        }

        /// Process is running but not doing meaningful work — idle at the prompt.
        /// Requires CPU near zero; a small amount of CPU with connections may indicate
        /// a brief dip during tool execution rather than true idleness.
        var isWaitingForInput: Bool {
            isRunning && cpuUsage <= 1.0 && !hasActiveConnections
        }

        /// Process is running with some ambiguous activity — not clearly working,
        /// not clearly idle. File-activity signals can tip the balance.
        var isAmbiguous: Bool {
            isRunning && !isActivelyWorking && !isWaitingForInput
        }

        static let notRunning = ProcessStatus(
            isRunning: false, hasActiveConnections: false, cpuUsage: 0, pids: []
        )
    }

    func detect() -> ProcessStatus {
        let pids = findClaudePIDs()
        guard !pids.isEmpty else { return .notRunning }

        let hasConnections = checkActiveConnections(pids: pids)
        let cpu = aggregateCPUUsage(pids: pids)

        return ProcessStatus(
            isRunning: true,
            hasActiveConnections: hasConnections,
            cpuUsage: cpu,
            pids: pids
        )
    }

    private func findClaudePIDs() -> [Int32] {
        guard let output = runShell("/bin/ps", arguments: ["-axo", "pid=,args="], timeout: 3) else {
            return []
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var pids: [Int32] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2,
                  let pid = Int32(parts[0]) else { continue }
            guard pid != ownPID else { continue }
            // Extract the executable basename and match "claude" exactly,
            // avoiding false positives from editors/helpers that have "claude"
            // in project paths (e.g. Cursor Helper with "claude-caffeine")
            let executable = String(parts[1]).split(separator: " ").first.map(String.init) ?? ""
            let basename = URL(fileURLWithPath: executable).lastPathComponent
            guard basename == "claude" else { continue }
            pids.append(pid)
        }
        return pids
    }

    private func checkActiveConnections(pids: [Int32]) -> Bool {
        let pidList = pids.map(String.init).joined(separator: ",")
        guard let output = runShell(
            "/usr/sbin/lsof", arguments: ["-i", "-a", "-p", pidList], timeout: 5
        ) else { return false }
        return output.contains("ESTABLISHED")
    }

    private func aggregateCPUUsage(pids: [Int32]) -> Double {
        let pidList = pids.map(String.init).joined(separator: ",")
        guard let output = runShell("/bin/ps", arguments: ["-p", pidList, "-o", "%cpu="], timeout: 3) else {
            return 0
        }
        return output
            .split(separator: "\n")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .reduce(0, +)
    }

    private func runShell(_ command: String, arguments: [String], timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Schedule a watchdog to kill the process if it exceeds the timeout.
        // readDataToEndOfFile + waitUntilExit block the current thread but
        // are reliable across all threading contexts (unlike terminationHandler).
        let watchdog = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
