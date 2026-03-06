import Foundation
import XCTest
@testable import ClaudeCaffeine

final class SessionCostEstimatorTests: XCTestCase {
    private var fixtureRootURL: URL!

    override func setUpWithError() throws {
        fixtureRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostEstimatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureRootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRootURL {
            try? FileManager.default.removeItem(at: fixtureRootURL)
        }
        fixtureRootURL = nil
    }

    func testEmptyProjectsReturnsZeroCost() {
        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts()

        XCTAssertEqual(snapshot.todayCost, 0)
        XCTAssertEqual(snapshot.weekCost, 0)
        XCTAssertEqual(snapshot.todaySessions, 0)
        XCTAssertTrue(snapshot.activeSessions.isEmpty)
    }

    func testParsesTokenUsageFromAssistantMessages() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("test-project")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let sessionLines = [
            assistantLine(model: "claude-sonnet-4-6", input: 100, output: 50, cacheCreation: 200, cacheRead: 1000, timestamp: ts),
            assistantLine(model: "claude-sonnet-4-6", input: 150, output: 80, cacheCreation: 0, cacheRead: 500, timestamp: ts),
        ]
        let sessionFile = projectDir.appendingPathComponent("session-1.jsonl")
        try sessionLines.joined(separator: "\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        XCTAssertEqual(snapshot.todaySessions, 1)
        XCTAssertEqual(snapshot.activeSessions.count, 1)

        let session = snapshot.activeSessions[0]
        XCTAssertEqual(session.sessionID, "session-1")
        XCTAssertEqual(session.messageCount, 2)
        XCTAssertEqual(session.totalUsage.inputTokens, 250)
        XCTAssertEqual(session.totalUsage.outputTokens, 130)
        XCTAssertEqual(session.totalUsage.cacheCreationTokens, 200)
        XCTAssertEqual(session.totalUsage.cacheReadTokens, 1500)
        XCTAssertGreaterThan(session.totalCost, 0)
    }

    func testOpusPricingHigherThanSonnet() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("pricing-test")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let opusSession = projectDir.appendingPathComponent("opus.jsonl")
        try assistantLine(model: "claude-opus-4-6", input: 1000, output: 500, cacheCreation: 0, cacheRead: 0, timestamp: ts)
            .write(to: opusSession, atomically: true, encoding: .utf8)

        let sonnetSession = projectDir.appendingPathComponent("sonnet.jsonl")
        try assistantLine(model: "claude-sonnet-4-6", input: 1000, output: 500, cacheCreation: 0, cacheRead: 0, timestamp: ts)
            .write(to: sonnetSession, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        let sessions = snapshot.activeSessions.sorted { $0.totalCost > $1.totalCost }
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].model, "claude-opus-4-6")
        XCTAssertEqual(sessions[1].model, "claude-sonnet-4-6")
        XCTAssertGreaterThan(sessions[0].totalCost, sessions[1].totalCost)
    }

    func testOldSessionsNotInTodayButInWeek() throws {
        let now = Date()
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 3600)
        let tsOld = ISO8601DateFormatter().string(from: threeDaysAgo)
        let tsNow = ISO8601DateFormatter().string(from: now)

        let projectDir = fixtureRootURL.appendingPathComponent("week-test")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let oldSession = projectDir.appendingPathComponent("old.jsonl")
        try assistantLine(model: "claude-sonnet-4-6", input: 500, output: 200, cacheCreation: 0, cacheRead: 0, timestamp: tsOld)
            .write(to: oldSession, atomically: true, encoding: .utf8)

        let todaySession = projectDir.appendingPathComponent("today.jsonl")
        try assistantLine(model: "claude-sonnet-4-6", input: 500, output: 200, cacheCreation: 0, cacheRead: 0, timestamp: tsNow)
            .write(to: todaySession, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        XCTAssertEqual(snapshot.todaySessions, 1)
        XCTAssertEqual(snapshot.weekSessions, 2)
        XCTAssertGreaterThan(snapshot.weekCost, snapshot.todayCost)
    }

    func testIgnoresNonAssistantLines() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("mixed-test")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines = [
            "{\"type\":\"user\",\"timestamp\":\"\(ts)\",\"message\":{\"role\":\"user\"}}",
            assistantLine(model: "claude-sonnet-4-6", input: 100, output: 50, cacheCreation: 0, cacheRead: 0, timestamp: ts),
            "{\"type\":\"system\",\"timestamp\":\"\(ts)\"}",
        ]
        let sessionFile = projectDir.appendingPathComponent("mixed.jsonl")
        try lines.joined(separator: "\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        XCTAssertEqual(snapshot.activeSessions.first?.messageCount, 1)
    }

    func testMissingProjectsRootReturnsEmpty() {
        let missing = fixtureRootURL.appendingPathComponent("nonexistent")
        let estimator = SessionCostEstimator(projectsRootURL: missing)
        let snapshot = estimator.estimateCosts()

        XCTAssertEqual(snapshot.todayCost, 0)
        XCTAssertEqual(snapshot.todaySessions, 0)
    }

    // MARK: - Helpers

    private func assistantLine(
        model: String,
        input: Int,
        output: Int,
        cacheCreation: Int,
        cacheRead: Int,
        timestamp: String
    ) -> String {
        """
        {"type":"assistant","timestamp":"\(timestamp)","message":{"model":"\(model)","role":"assistant","content":[],"usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(cacheCreation),"cache_read_input_tokens":\(cacheRead)}}}
        """
    }
}
