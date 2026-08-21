import Foundation
import XCTest
@testable import ClaudeCaffeine

final class CursorHookInstallerTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("caffeine-cursor-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    func testInstallCreatesScriptsAndHooksJSON() throws {
        let env = CursorHookInstaller.Environment(home: tempHome)
        try CursorHookInstaller.install(environment: env)

        XCTAssertTrue(FileManager.default.fileExists(atPath: env.activeScriptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.idleScriptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.hooksJSON.path))
        XCTAssertTrue(CursorHookInstaller.isInstalled(environment: env))

        let active = try String(contentsOf: env.activeScriptURL, encoding: .utf8)
        XCTAssertTrue(active.contains("conversation_id"))
        XCTAssertTrue(active.contains(env.sessionsDir.path))

        let idle = try String(contentsOf: env.idleScriptURL, encoding: .utf8)
        XCTAssertTrue(idle.contains("unlinkSync"))
        XCTAssertFalse(idle.contains("followup_message"))
        XCTAssertFalse(idle.contains("continue"))
    }

    func testInstallMergesWithoutClobberingExistingHooks() throws {
        let env = CursorHookInstaller.Environment(home: tempHome)
        try FileManager.default.createDirectory(
            at: env.hooksJSON.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing: [String: Any] = [
            "version": 1,
            "hooks": [
                "preToolUse": [
                    ["command": "./hooks/audit.sh", "timeout": 10],
                ],
                "afterFileEdit": [
                    ["command": "./hooks/format.sh"],
                ],
            ],
        ]
        let existingData = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted])
        try existingData.write(to: env.hooksJSON)

        try CursorHookInstaller.install(environment: env)

        let parsed = try readJSON(env.hooksJSON)
        XCTAssertEqual((parsed["version"] as? NSNumber)?.intValue, 1)
        let hooks = parsed["hooks"] as? [String: Any]
        let preToolUse = dictionaryEntries(hooks?["preToolUse"])
        XCTAssertEqual(preToolUse.count, 2)
        XCTAssertTrue(preToolUse.contains { ($0["command"] as? String) == "./hooks/audit.sh" })
        XCTAssertTrue(preToolUse.contains(where: CursorHookInstaller.isCaffeineEntry))

        let afterFileEdit = dictionaryEntries(hooks?["afterFileEdit"])
        XCTAssertEqual(afterFileEdit.count, 1)
        XCTAssertEqual(afterFileEdit.first?["command"] as? String, "./hooks/format.sh")
    }

    func testInstallIsIdempotent() throws {
        let env = CursorHookInstaller.Environment(home: tempHome)
        try CursorHookInstaller.install(environment: env)
        try CursorHookInstaller.install(environment: env)

        let parsed = try readJSON(env.hooksJSON)
        let hooks = parsed["hooks"] as? [String: Any]
        for event in CursorHookInstaller.activeEvents + CursorHookInstaller.idleEvents {
            let entries = dictionaryEntries(hooks?[event])
            let caffeineEntries = entries.filter(CursorHookInstaller.isCaffeineEntry)
            XCTAssertEqual(caffeineEntries.count, 1, "expected one caffeine hook for \(event)")
            XCTAssertEqual(
                (caffeineEntries.first?["timeout"] as? NSNumber)?.intValue,
                CursorHookInstaller.hookTimeoutSeconds
            )
        }
    }

    func testUninstallRemovesCaffeineHooksButKeepsOthers() throws {
        let env = CursorHookInstaller.Environment(home: tempHome)
        try FileManager.default.createDirectory(
            at: env.hooksJSON.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing: [String: Any] = [
            "version": 1,
            "hooks": [
                "stop": [
                    ["command": "./hooks/audit.sh"],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: env.hooksJSON)

        try CursorHookInstaller.install(environment: env)
        try CursorHookInstaller.uninstall(environment: env)

        XCTAssertFalse(CursorHookInstaller.isInstalled(environment: env))
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.hooksDir.path))

        let parsed = try readJSON(env.hooksJSON)
        let hooks = parsed["hooks"] as? [String: Any]
        let stop = dictionaryEntries(hooks?["stop"])
        XCTAssertEqual(stop.count, 1)
        XCTAssertEqual(stop.first?["command"] as? String, "./hooks/audit.sh")
        XCTAssertFalse(stop.contains(where: CursorHookInstaller.isCaffeineEntry))
    }

    func testActiveEventsDoNotIncludeSessionStartOrTabHooks() {
        XCTAssertFalse(CursorHookInstaller.activeEvents.contains("sessionStart"))
        XCTAssertFalse(CursorHookInstaller.activeEvents.contains("beforeTabFileRead"))
        XCTAssertFalse(CursorHookInstaller.activeEvents.contains("afterTabFileEdit"))
        XCTAssertTrue(CursorHookInstaller.idleEvents.contains("stop"))
        XCTAssertTrue(CursorHookInstaller.idleEvents.contains("sessionEnd"))
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(parsed as? [String: Any])
    }

    private func dictionaryEntries(_ value: Any?) -> [[String: Any]] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { $0 as? [String: Any] }
    }
}
