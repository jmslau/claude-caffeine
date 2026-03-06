import Foundation

enum HelperInstaller {

    // Path must have NO spaces -- sudoers splits command paths on whitespace.
    static let appSupportDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/ClaudeCaffeine"
    }()

    static let scriptPath: String = {
        "\(appSupportDir)/claude-sleep-control.sh"
    }()

    static let sudoersPath = "/private/etc/sudoers.d/claude_caffeine"

    static let tmpSudoersPath = "/tmp/claude_caffeine_sudoers"

    static let scriptContents = """
    #!/bin/bash
    set -euo pipefail
    case "${1:-}" in
      on)  /usr/bin/pmset -a disablesleep 1 ;;
      off) /usr/bin/pmset -a disablesleep 0 ;;
      *)   echo "Usage: claude-sleep-control.sh on|off" >&2; exit 1 ;;
    esac
    """

    static var sudoersContents: String {
        "\(NSUserName()) ALL = (root) NOPASSWD: \(scriptPath)\n"
    }

    static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: scriptPath)
            && fm.fileExists(atPath: sudoersPath)
    }

    enum InstallError: LocalizedError {
        case scriptWriteFailed
        case sudoersValidationFailed(String)
        case osascriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .scriptWriteFailed:
                return "Failed to write helper script"
            case .sudoersValidationFailed(let detail):
                return "Sudoers validation failed: \(detail)"
            case .osascriptFailed(let detail):
                return "Admin authentication failed: \(detail)"
            }
        }
    }

    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: appSupportDir, withIntermediateDirectories: true)

        guard fm.createFile(atPath: scriptPath, contents: Data(scriptContents.utf8)) else {
            throw InstallError.scriptWriteFailed
        }

        let chmodResult = runProcess("/bin/chmod", arguments: ["+x", scriptPath])
        if chmodResult.exitCode != 0 {
            throw InstallError.scriptWriteFailed
        }

        // Write sudoers content to temp file using Swift -- avoids shell quoting.
        guard fm.createFile(atPath: tmpSudoersPath, contents: Data(sudoersContents.utf8)) else {
            try? fm.removeItem(atPath: scriptPath)
            throw InstallError.scriptWriteFailed
        }

        // Validate sudoers syntax before installing (non-privileged check).
        let visudoCheck = runProcess("/usr/sbin/visudo", arguments: ["-csf", tmpSudoersPath])
        if visudoCheck.exitCode != 0 {
            try? fm.removeItem(atPath: tmpSudoersPath)
            try? fm.removeItem(atPath: scriptPath)
            throw InstallError.sudoersValidationFailed(
                visudoCheck.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        // Only the cp/chmod/chown need root -- all paths are space-free.
        let shellCommands = [
            "cp \(tmpSudoersPath) \(sudoersPath)",
            "chmod 0440 \(sudoersPath)",
            "chown root:wheel \(sudoersPath)",
            "rm -f \(tmpSudoersPath)",
        ].joined(separator: " && ")

        let appleScript = "do shell script \"\(shellCommands)\" with administrator privileges"

        let result = runProcess(
            "/usr/bin/osascript",
            arguments: ["-e", appleScript]
        )

        if result.exitCode != 0 {
            try? fm.removeItem(atPath: scriptPath)
            try? fm.removeItem(atPath: tmpSudoersPath)
            let detail = result.stderr.isEmpty
                ? "exit code \(result.exitCode)"
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallError.osascriptFailed(detail)
        }
    }

    static func uninstall() throws {
        let closedDisplay = ClosedDisplayManager()
        closedDisplay.forceDisable()

        let appleScript = "do shell script \"rm -f \(sudoersPath)\" with administrator privileges"

        let result = runProcess("/usr/bin/osascript", arguments: ["-e", appleScript])
        if result.exitCode != 0 {
            let detail = result.stderr.isEmpty
                ? "exit code \(result.exitCode)"
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallError.osascriptFailed(detail)
        }

        try? FileManager.default.removeItem(atPath: scriptPath)
    }

    private static func runProcess(_ command: String, arguments: [String]) -> ShellResult {
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
