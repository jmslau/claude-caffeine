import Foundation

final class ClosedDisplayManager {
    enum State: Equatable {
        case disabled
        case enabled
        case helperNotInstalled
        case error(String)
    }

    private(set) var state: State = .disabled
    private let scriptPath: String
    private let executor: ShellExecutor
    private let checkHelperInstalled: () -> Bool

    var isEnabled: Bool { state == .enabled }
    var isHelperInstalled: Bool { checkHelperInstalled() }

    init(
        scriptPath: String = HelperInstaller.scriptPath,
        executor: ShellExecutor = ProcessShellExecutor(),
        checkHelperInstalled: @escaping () -> Bool = { HelperInstaller.isInstalled }
    ) {
        self.scriptPath = scriptPath
        self.executor = executor
        self.checkHelperInstalled = checkHelperInstalled
    }

    @discardableResult
    func enable() -> Bool {
        guard isHelperInstalled else {
            state = .helperNotInstalled
            return false
        }

        let result = executor.run("/usr/bin/sudo", arguments: [scriptPath, "on"])
        if result.exitCode == 0 {
            state = .enabled
            return true
        } else {
            state = .error("pmset failed: \(result.stderr)")
            return false
        }
    }

    @discardableResult
    func disable() -> Bool {
        let needsShutdown: Bool
        switch state {
        case .enabled, .error:
            needsShutdown = true
        case .disabled, .helperNotInstalled:
            state = .disabled
            return true
        }

        guard needsShutdown, isHelperInstalled else {
            state = .disabled
            return true
        }

        let result = executor.run("/usr/bin/sudo", arguments: [scriptPath, "off"])
        state = .disabled
        return result.exitCode == 0
    }

    func reassert() {
        guard state == .enabled else { return }
        _ = executor.run("/usr/bin/sudo", arguments: [scriptPath, "on"])
    }

    func forceDisable() {
        guard isHelperInstalled else { return }
        _ = executor.run("/usr/bin/sudo", arguments: [scriptPath, "off"])
        state = .disabled
    }
}

struct ShellResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

protocol ShellExecutor {
    func run(_ command: String, arguments: [String]) -> ShellResult
}

final class ProcessShellExecutor: ShellExecutor {
    func run(_ command: String, arguments: [String]) -> ShellResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ShellResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        // Read pipes before waiting to avoid deadlock when pipe buffer fills
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
