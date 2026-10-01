import XCTest
@testable import ClaudeCaffeine

@MainActor
final class AutoResumeManagerTests: XCTestCase {
    private var tempDir: URL!
    private var manager: AutoResumeManager!

    private var zshrc: URL { tempDir.appendingPathComponent(".zshrc") }
    private var wrapper: URL { tempDir.appendingPathComponent(".claude/auto-resume-wrapper.py") }

    /// The profile block v1.3.6 and earlier added when Auto-Resume was enabled.
    private var legacyBlock: String {
        "# BEGIN CLAUDE CAFFEINE AUTO-RESUME\nalias claude=\"python3 \(wrapper.path)\"\n# END CLAUDE CAFFEINE AUTO-RESUME"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        manager = AutoResumeManager.shared
        manager.setHomeDirectory(tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testEnableAndDisableToggleState() throws {
        manager.enable()
        XCTAssertTrue(manager.isEnabled)
        manager.disable()
        XCTAssertFalse(manager.isEnabled)
    }

    func testEnableDoesNotTouchShellProfiles() throws {
        try "existing content\n".write(to: zshrc, atomically: true, encoding: .utf8)

        manager.enable()

        XCTAssertEqual(try String(contentsOf: zshrc, encoding: .utf8), "existing content\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wrapper.path))
    }

    func testLegacyWrapperAliasIsRemovedAndWrapperPassesThrough() throws {
        try "existing content\n\(legacyBlock)\nafter\n".write(to: zshrc, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: wrapper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old PTY wrapper".write(to: wrapper, atomically: true, encoding: .utf8)

        manager.removeLegacyWrapper()

        let content = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertFalse(content.contains("CLAUDE CAFFEINE AUTO-RESUME"))
        XCTAssertFalse(content.contains("alias claude="))
        XCTAssertTrue(content.contains("existing content"))
        XCTAssertTrue(content.contains("after"))
        // Shells opened before the update still alias `claude` to this file.
        let script = try String(contentsOf: wrapper, encoding: .utf8)
        XCTAssertTrue(script.contains(#"shutil.which("claude")"#))
    }

    func testLegacyAliasIsRemovedFromProfilesWithNonASCIIText() throws {
        try "export PROMPT='🚀 ☕️ ~ '\n\(legacyBlock)\n".write(to: zshrc, atomically: true, encoding: .utf8)

        manager.disable()

        let content = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertFalse(content.contains("CLAUDE CAFFEINE AUTO-RESUME"))
        XCTAssertTrue(content.contains("🚀 ☕️"))
    }

    /// Regression: literal Swift template text must never remain in ~/.zshrc (breaks `source ~/.zshrc`).
    func testLegacyCleanupStripsCorruptedSwiftTemplateLines() throws {
        let badLine1 = "\\n\\(" + "markerBegin" + ")"
        let badLine2 = "alias claude=\"python3 \\(" + "wrapperScriptURL.path" + ")\""
        let badLine3 = "\\(" + "markerEnd" + ")"
        try """
        existing content
        \(badLine1)
        \(badLine2)
        \(badLine3)
        """.write(to: zshrc, atomically: true, encoding: .utf8)

        manager.enable()

        let content = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertTrue(content.contains("existing content"))
        XCTAssertFalse(content.contains("\\(" + "markerBegin" + ")"))
        XCTAssertFalse(content.contains("\\(" + "wrapperScriptURL.path" + ")"))
        XCTAssertFalse(content.contains("alias claude="))
    }

    func testLegacyAliasIsRemovedThroughSymlinkedProfileKeepingPermissions() throws {
        let dotfiles = tempDir.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let realProfile = dotfiles.appendingPathComponent("zshrc")
        try "existing content\n\(legacyBlock)\n".write(to: realProfile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: realProfile.path)
        try FileManager.default.createSymbolicLink(at: zshrc, withDestinationURL: realProfile)

        manager.removeLegacyWrapper()

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: zshrc.path), realProfile.path)
        XCTAssertFalse(try String(contentsOf: realProfile, encoding: .utf8).contains("CLAUDE CAFFEINE AUTO-RESUME"))
        let permissions = try FileManager.default.attributesOfItem(atPath: realProfile.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testToggleWorksWhenAProfileCannotBeRewritten() throws {
        try "\(legacyBlock)\n".write(to: zshrc, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tempDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path) }

        manager.enable()
        XCTAssertTrue(manager.isEnabled)
        manager.disable()
        XCTAssertFalse(manager.isEnabled)
    }

    func testPassThroughWrapperRunsRealClaudeWithArguments() throws {
        let bin = tempDir.appendingPathComponent("bin")
        try installFakeClaude(at: bin.appendingPathComponent("claude"))

        let result = try runPassThroughWrapper(path: "\(bin.path):/usr/bin:/bin", arguments: ["-p", "two words", ""])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "-p|two words||")
    }

    /// Installs that are only reachable through Claude Code's own `~/.claude/local/claude` alias.
    func testPassThroughWrapperFallsBackToLocalInstall() throws {
        try installFakeClaude(at: tempDir.appendingPathComponent(".claude/local/claude"))

        let result = try runPassThroughWrapper(path: "/usr/bin:/bin", arguments: ["--version"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "--version|")
    }

    // MARK: - Helpers

    private func installFakeClaude(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/bash\nprintf '%s|' \"$@\"\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Neutralizes a legacy wrapper and runs it the way a stale `alias claude="python3 …"` would.
    private func runPassThroughWrapper(path: String, arguments: [String]) throws -> (status: Int32, output: String) {
        try FileManager.default.createDirectory(at: wrapper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old PTY wrapper".write(to: wrapper, atomically: true, encoding: .utf8)
        manager.removeLegacyWrapper()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", wrapper.path] + arguments
        process.environment = ["PATH": path, "HOME": tempDir.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        // `env` exits 127 without python3; the /usr/bin stub fails like this without the Command Line Tools.
        try XCTSkipIf(process.terminationStatus == 127 || errors.contains("xcode-select") || errors.contains("xcrun: error"), "python3 is not available")
        XCTAssertTrue(errors.isEmpty, errors)
        return (process.terminationStatus, output)
    }
}
