import Foundation
import XCTest
@testable import ClaudeCaffeine

final class ClaudeHookMonitorTests: XCTestCase {
    private var claudeDir: URL!
    private var cursorDir: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("caffeine-monitor-\(UUID().uuidString)", isDirectory: true)
        claudeDir = root.appendingPathComponent("claude", isDirectory: true)
        cursorDir = root.appendingPathComponent("cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let claudeDir {
            try? FileManager.default.removeItem(at: claudeDir.deletingLastPathComponent())
        }
    }

    func testCursorSessionAloneIsActive() async throws {
        try writeSession(in: cursorDir, id: "conv-1", timestamp: Date(), pid: getpid())
        let snapshot = await poll()
        XCTAssertTrue(snapshot.isActivelyWorking)
        XCTAssertEqual(snapshot.cursorSessionCount, 1)
        XCTAssertEqual(snapshot.claudeSessionCount, 0)
        XCTAssertEqual(snapshot.sessionCount, 1)
        XCTAssertEqual(snapshot.activityLine, "Activity: Active (Cursor 1)")
        XCTAssertEqual(snapshot.sleepAssertionReason, "Keeping Mac awake while Cursor is actively working")
    }

    func testClaudeAndCursorSessionsAreORed() async throws {
        try writeSession(in: claudeDir, id: "s1", timestamp: Date(), pid: getpid())
        try writeSession(in: claudeDir, id: "s2", timestamp: Date(), pid: getpid())
        try writeSession(in: cursorDir, id: "c1", timestamp: Date(), pid: getpid())
        let snapshot = await poll()
        XCTAssertTrue(snapshot.isActivelyWorking)
        XCTAssertEqual(snapshot.claudeSessionCount, 2)
        XCTAssertEqual(snapshot.cursorSessionCount, 1)
        XCTAssertEqual(snapshot.sessionCount, 3)
        XCTAssertEqual(snapshot.activityLine, "Activity: Active (Claude 2, Cursor 1)")
        XCTAssertEqual(
            snapshot.sleepAssertionReason,
            "Keeping Mac awake while Claude Code and Cursor are actively working"
        )
    }

    func testStaleCursorSessionIsIgnoredAndRemoved() async throws {
        let stale = Date().addingTimeInterval(-400)
        try writeSession(in: cursorDir, id: "old", timestamp: stale, pid: getpid())
        let snapshot = await poll()
        XCTAssertFalse(snapshot.isActivelyWorking)
        XCTAssertEqual(snapshot.cursorSessionCount, 0)
        XCTAssertEqual(snapshot.activityLine, "Activity: Idle")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cursorDir.appendingPathComponent("old").path))
    }

    func testDeadPidSessionIsRemoved() async throws {
        try writeSession(in: cursorDir, id: "zombie", timestamp: Date(), pid: 1_999_999_999)
        let snapshot = await poll()
        XCTAssertFalse(snapshot.isActivelyWorking)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cursorDir.appendingPathComponent("zombie").path))
    }

    func testMissingDirectoriesAreIdle() async {
        let missingClaude = claudeDir.appendingPathComponent("missing")
        let missingCursor = cursorDir.appendingPathComponent("missing")
        let monitor = ClaudeHookMonitor(
            claudeSessionsDir: missingClaude,
            cursorSessionsDir: missingCursor
        )
        let snapshot = await monitor.poll(now: Date(), idleThreshold: 60)
        XCTAssertFalse(snapshot.isActivelyWorking)
        XCTAssertEqual(snapshot.sessionCount, 0)
        XCTAssertEqual(snapshot.activityLine, "Activity: Idle")
    }

    func testIdleSnapshotSleepReasonDefaultsToClaude() {
        let snapshot = ClaudeHookMonitor.PollSnapshot(
            isActivelyWorking: false,
            lastActivityDate: nil
        )
        XCTAssertEqual(snapshot.activityLine, "Activity: Idle")
        XCTAssertEqual(
            snapshot.sleepAssertionReason,
            "Keeping Mac awake while Claude Code is actively working"
        )
    }

    private func poll() async -> ClaudeHookMonitor.PollSnapshot {
        let monitor = ClaudeHookMonitor(
            claudeSessionsDir: claudeDir,
            cursorSessionsDir: cursorDir
        )
        return await monitor.poll(now: Date(), idleThreshold: 60)
    }

    private func writeSession(in directory: URL, id: String, timestamp: Date, pid: pid_t) throws {
        let payload: [String: Any] = [
            "timestamp": timestamp.timeIntervalSince1970 * 1000,
            "pid": Int(pid),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: directory.appendingPathComponent(id))
    }
}
