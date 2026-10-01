import XCTest
@testable import ClaudeCaffeine

/// Runs `HookInstaller.idleJS` with node the way Claude Code runs the hook: event JSON on stdin.
final class IdleHookScriptTests: XCTestCase {
    private static let grace: TimeInterval = 15 * 60

    private static let nodeAvailable: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()

    private var tempDir: URL!
    private var sessionFile: URL { tempDir.appendingPathComponent(".claude/caffeine_sessions/session-1") }

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.nodeAvailable, "node is not available")
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("caffeine-idle-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent(".claude/caffeine_sessions"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testRateLimitStopFailureHoldsUntilShortlyAfterReset() throws {
        let reset = minuteStart(Date().addingTimeInterval(3600))
        let session = try runIdleHook(stopFailure(
            error: "rate_limit",
            message: "You've hit your session limit · resets \(clockTime(reset)) (Europe/Moscow)"
        ))

        let holdUntil = try XCTUnwrap(session?["holdUntil"] as? NSNumber, "a usage limit must start a hold")
        XCTAssertEqual(holdUntil.doubleValue / 1000, reset.addingTimeInterval(Self.grace).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNotNil(session?["timestamp"] as? NSNumber)
        XCTAssertNotNil(session?["pid"] as? NSNumber)
    }

    /// Claude Code drops ":00" on the hour, e.g. "resets 4pm".
    func testBareHourReset() throws {
        let hour = try XCTUnwrap(Calendar.current.dateInterval(of: .hour, for: Date().addingTimeInterval(90 * 60))).start
        let session = try runIdleHook(stopFailure(
            error: "rate_limit",
            message: "You've hit your session limit · resets \(clockTime(hour, format: "ha")) (Europe/Moscow)"
        ))

        let holdUntil = try XCTUnwrap(session?["holdUntil"] as? NSNumber)
        XCTAssertEqual(holdUntil.doubleValue / 1000, hour.addingTimeInterval(Self.grace).timeIntervalSince1970, accuracy: 0.001)
    }

    func testResetTimeWellInThePastMeansTomorrow() throws {
        let earlier = minuteStart(Date().addingTimeInterval(-2 * 3600))
        let session = try runIdleHook(stopFailure(
            error: "rate_limit",
            message: "You've hit your weekly limit · resets \(clockTime(earlier)) (Europe/Moscow) · progress saved"
        ))

        let tomorrow = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: earlier))
        let holdUntil = try XCTUnwrap(session?["holdUntil"] as? NSNumber)
        XCTAssertEqual(holdUntil.doubleValue / 1000, tomorrow.addingTimeInterval(Self.grace).timeIntervalSince1970, accuracy: 0.001)
    }

    /// A reset time that just passed means the limit is about to lift, not a wait until tomorrow.
    func testResetDueNowHoldsOnlyForTheGracePeriod() throws {
        let justPassed = minuteStart(Date().addingTimeInterval(-10 * 60))
        let before = Date()
        let session = try runIdleHook(stopFailure(
            error: "rate_limit",
            message: "You've hit your session limit · resets \(clockTime(justPassed)) (Europe/Moscow)"
        ))
        let after = Date()

        let holdUntil = try XCTUnwrap(session?["holdUntil"] as? NSNumber).doubleValue / 1000
        XCTAssertGreaterThanOrEqual(holdUntil, before.addingTimeInterval(Self.grace).timeIntervalSince1970 - 0.001)
        XCTAssertLessThanOrEqual(holdUntil, after.addingTimeInterval(Self.grace).timeIntervalSince1970 + 0.001)
    }

    func testOtherTurnEndsRemoveTheSession() throws {
        let limitMessage = "You've hit your session limit · resets 3pm (Europe/Moscow)"
        let inputs: [[String: Any]] = [
            ["session_id": "session-1", "hook_event_name": "Stop"],
            stopFailure(error: "overloaded", message: limitMessage),
            stopFailure(error: "rate_limit", message: "You've hit your weekly limit · resets Oct 6, 9am (Europe/Moscow)"),
            stopFailure(error: "rate_limit", message: "You've used 91% of your session limit · resets 3pm (Europe/Moscow)"),
            stopFailure(error: "rate_limit", message: "You've hit your session limit · resets 13pm"),
        ]
        for input in inputs {
            try #"{"timestamp": 1, "pid": 1}"#.write(to: sessionFile, atomically: true, encoding: .utf8)
            let session = try runIdleHook(input)
            XCTAssertNil(session, "\(input)")
        }
    }

    /// While the session sits at the limit Claude Code may send "waiting for your input" notifications,
    /// and background subagents may finish; neither ends the turn, so neither may end the hold.
    func testNonTurnEndingEventsKeepAnActiveHold() throws {
        let future = (Date().timeIntervalSince1970 + 3600) * 1000
        for event in ["Notification", "SubagentStop", "Elicitation"] {
            let input: [String: Any] = ["session_id": "session-1", "hook_event_name": event]
            try #"{"timestamp": 1, "pid": 1, "holdUntil": \#(future)}"#.write(to: sessionFile, atomically: true, encoding: .utf8)
            let held = try runIdleHook(input)
            XCTAssertEqual((held?["holdUntil"] as? NSNumber)?.doubleValue, future, "\(event) must not end the limit hold")
        }
        for event in ["Notification", "Elicitation"] {
            let input: [String: Any] = ["session_id": "session-1", "hook_event_name": event]
            try #"{"timestamp": 1, "pid": 1}"#.write(to: sessionFile, atomically: true, encoding: .utf8)
            let normal = try runIdleHook(input)
            XCTAssertNil(normal, "\(event) still ends a normal session")
        }
    }

    /// Subagent hooks carry the parent's session_id, so a finished subagent says nothing about the session.
    func testSubagentStopKeepsTheSessionActive() throws {
        try #"{"timestamp": 1, "pid": 1}"#.write(to: sessionFile, atomically: true, encoding: .utf8)
        let before = Date().timeIntervalSince1970 * 1000
        let session = try runIdleHook([
            "session_id": "session-1",
            "hook_event_name": "SubagentStop",
            "agent_id": "agent-1",
            "agent_type": "general-purpose",
            "background_tasks": [],
        ])

        let timestamp = try XCTUnwrap(session?["timestamp"] as? NSNumber, "a finished subagent must not end the session")
        XCTAssertGreaterThanOrEqual(timestamp.doubleValue, before)
    }

    /// "Waiting for 1 background agent to finish": the turn ended, the work did not.
    func testStopWhileBackgroundAgentsRunKeepsTheSessionActive() throws {
        for type in ["subagent", "workflow", "teammate"] {
            try #"{"timestamp": 1, "pid": 1}"#.write(to: sessionFile, atomically: true, encoding: .utf8)
            let session = try runIdleHook([
                "session_id": "session-1",
                "hook_event_name": "Stop",
                "background_tasks": [["id": "task-1", "type": type, "status": "running", "description": "part-2"]],
                "session_crons": [],
            ])
            XCTAssertNotNil(session?["timestamp"] as? NSNumber, "Stop with a running background \(type) must not end the session")
        }
    }

    /// Background shells (dev servers, watchers) are not Claude working; the turn is finished.
    func testStopWithOnlyBackgroundShellsEndsTheSession() throws {
        try #"{"timestamp": 1, "pid": 1}"#.write(to: sessionFile, atomically: true, encoding: .utf8)
        let session = try runIdleHook([
            "session_id": "session-1",
            "hook_event_name": "Stop",
            "background_tasks": [["id": "task-1", "type": "shell", "status": "running", "description": "npm run dev", "command": "npm run dev"]],
            "session_crons": [],
        ])
        XCTAssertNil(session)
    }

    // MARK: - Helpers

    private func stopFailure(error: String, message: String) -> [String: Any] {
        [
            "session_id": "session-1",
            "hook_event_name": "StopFailure",
            "error": error,
            "last_assistant_message": message,
        ]
    }

    /// Returns the session file the hook left behind, or nil if it removed it.
    private func runIdleHook(_ input: [String: Any]) throws -> [String: Any]? {
        let script = tempDir.appendingPathComponent("idle.js")
        try HookInstaller.idleJS.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = tempDir.path
        process.environment = environment
        let stdin = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: input))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))

        guard let data = try? Data(contentsOf: sessionFile) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func minuteStart(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .minute, for: date)!.start
    }

    /// Claude Code's reset format, e.g. "3:05pm" or "4pm".
    private func clockTime(_ date: Date, format: String = "h:mma") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date).lowercased()
    }
}
