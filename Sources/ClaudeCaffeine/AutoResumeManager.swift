import Foundation
import os.log

public enum AutoResumeState: String, Codable {
    case enabled
    case disabled
}

/// Auto-Resume keeps the Mac awake after a usage limit ends a Claude Code turn, until the limit resets, so
/// Claude Code can continue on its own. The StopFailure hook (`HookInstaller.idleJS`) writes the hold and
/// `ClaudeHookMonitor` honors it while Auto-Resume is enabled.
@MainActor
public class AutoResumeManager {
    public static let shared = AutoResumeManager()
    
    private let logger = Logger(subsystem: "com.claude.caffeine", category: "AutoResumeManager")
    private var homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    private var claudeConfigDir: URL { homeDirectory.appendingPathComponent(".claude") }
    private var wrapperScriptURL: URL { claudeConfigDir.appendingPathComponent("auto-resume-wrapper.py") }

    public init() {}

    /// For testing purposes
    internal func setHomeDirectory(_ url: URL) {
        self.homeDirectory = url
    }

    public var isEnabled: Bool {
        return UserDefaults.standard.string(forKey: "AutoResumeState") == AutoResumeState.enabled.rawValue
    }

    public func enable() {
        logger.info("Enabling Auto-Resume...")
        UserDefaults.standard.set(AutoResumeState.enabled.rawValue, forKey: "AutoResumeState")
        removeLegacyWrapper()
        logger.info("Auto-Resume enabled successfully.")
    }

    public func disable() {
        logger.info("Disabling Auto-Resume...")
        UserDefaults.standard.set(AutoResumeState.disabled.rawValue, forKey: "AutoResumeState")
        removeLegacyWrapper()
        logger.info("Auto-Resume disabled successfully.")
    }

    /// Up to v1.3.6 Auto-Resume aliased `claude` to a Python PTY wrapper in shell profiles. Turns that wrapper into a
    /// pass-through (shells opened before the update still alias `claude` to it) and removes the alias. Best effort.
    public func removeLegacyWrapper() {
        if FileManager.default.fileExists(atPath: wrapperScriptURL.path) {
            do {
                try Self.legacyWrapperPassThrough.write(to: wrapperScriptURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperScriptURL.path)
            } catch {
                logger.error("Failed to replace the legacy Auto-Resume wrapper: \(error.localizedDescription)")
            }
        }
        for profile in getProfiles() {
            do {
                try removeAlias(from: profile)
            } catch {
                logger.error("Failed to remove the Auto-Resume alias from \(profile.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private static let legacyWrapperPassThrough = """
    #!/usr/bin/env python3
    # Left by Claude Caffeine: Auto-Resume no longer wraps claude. Shells opened before the update
    # may still alias `claude` to this file, so it only runs the real claude.
    import os
    import shutil
    import sys
    claude = shutil.which("claude") or os.path.expanduser("~/.claude/local/claude")
    os.execv(claude, ["claude"] + sys.argv[1:])

    """

    private let markerBegin = "# BEGIN CLAUDE CAFFEINE AUTO-RESUME"
    private let markerEnd = "# END CLAUDE CAFFEINE AUTO-RESUME"

    /// Lines matching this pattern appear when Swift string interpolation never ran (e.g. raw multiline `#"""…"""#` where `\(` is literal). They break `source ~/.zshrc`.
    private static let corruptedSwiftTemplateNeedles: [String] = [
        "\\(" + "markerBegin" + ")",
        "\\(" + "markerEnd" + ")",
        "\\(" + "wrapperScriptURL.path" + ")"
    ]

    private func stripCorruptedSwiftTemplateLines(_ content: String) -> String {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                !Self.corruptedSwiftTemplateNeedles.contains { String(line).contains($0) }
            }
            .joined(separator: "\n")
    }
    
    private func getProfiles() -> [URL] {
        return [
            homeDirectory.appendingPathComponent(".zshrc"),
            homeDirectory.appendingPathComponent(".bash_profile"),
            homeDirectory.appendingPathComponent(".bashrc")
        ]
    }

    private func removeAlias(from profile: URL) throws {
        // Write through symlinks (dotfile managers) and keep the file's permissions.
        let target = profile.resolvingSymlinksInPath()
        guard let original = try? String(contentsOf: target, encoding: .utf8) else { return }
        var content = stripCorruptedSwiftTemplateLines(original)
        if content.contains(markerBegin) {
            let regexPattern = "\\n?\(NSRegularExpression.escapedPattern(for: markerBegin)).*?\(NSRegularExpression.escapedPattern(for: markerEnd))\\n?"
            let regex = try NSRegularExpression(pattern: regexPattern, options: .dotMatchesLineSeparators)
            content = regex.stringByReplacingMatches(in: content, options: [], range: NSRange(location: 0, length: content.utf16.count), withTemplate: "\n")
        }
        guard content != original else { return }
        let permissions = try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
        try content.write(to: target, atomically: true, encoding: .utf8)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
    }
}
