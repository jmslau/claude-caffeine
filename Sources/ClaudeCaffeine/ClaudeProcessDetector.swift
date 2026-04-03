import Foundation
import os.log

public struct ClaudeProcessDetector: Sendable {
    private let logger = Logger(subsystem: "com.jmslau.claudecaffeine", category: "ProcessDetector")

    public struct Snapshot: Sendable {
        public let isProcessRunning: Bool
        public let hasActiveConnections: Bool
        public let cpuUsage: Double
        
        public var isActivelyWorking: Bool {
            return hasActiveConnections || cpuUsage > 5.0
        }
    }

    public init() {}

    public func poll() -> Snapshot {
        let pids = findClaudePIDs()
        if pids.isEmpty {
            return Snapshot(isProcessRunning: false, hasActiveConnections: false, cpuUsage: 0.0)
        }

        let hasConnections = pids.contains { checkConnections(pid: $0) }
        let maxCPU = pids.map { getCPUUsage(pid: $0) }.max() ?? 0.0

        return Snapshot(
            isProcessRunning: true,
            hasActiveConnections: hasConnections,
            cpuUsage: maxCPU
        )
    }

    private func findClaudePIDs() -> [Int32] {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-ax", "-o", "pid,comm"]
        task.standardOutput = Pipe()
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = (task.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            return output.components(separatedBy: "\n")
                .compactMap { line in
                    let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
                    guard parts.count >= 2 else { return nil }
                    let pidString = parts[0]
                    let command = parts[1...].joined(separator: " ")
                    
                    // Match the exact basename 'claude' to avoid helper processes
                    if command.hasSuffix("/claude") || command == "claude" {
                        return Int32(pidString)
                    }
                    return nil
                }
        } catch {
            logger.error("Failed to run ps: \(error.localizedDescription)")
            return []
        }
    }

    private func checkConnections(pid: Int32) -> Bool {
        let task = Process()
        task.launchPath = "/usr/sbin/lsof"
        task.arguments = ["-p", "\(pid)", "-a", "-i"]
        task.standardOutput = Pipe()
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = (task.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            // Look for established connections, which usually indicate an active API turn
            return output.contains("ESTABLISHED")
        } catch {
            return false
        }
    }

    private func getCPUUsage(pid: Int32) -> Double {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-p", "\(pid)", "-o", "pcpu"]
        task.standardOutput = Pipe()
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = (task.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            let lines = output.components(separatedBy: "\n")
            if lines.count >= 2 {
                return Double(lines[1].trimmingCharacters(in: .whitespaces)) ?? 0.0
            }
            return 0.0
        } catch {
            return 0.0
        }
    }
}
