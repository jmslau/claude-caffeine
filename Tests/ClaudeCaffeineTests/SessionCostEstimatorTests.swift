import Foundation
import XCTest
@testable import ClaudeCaffeine

@MainActor
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

    func testParsesMillisecondTimestamps() throws {
        // Use "now" and derive the timestamp from it so the test works in any timezone
        let now = Date()
        let fiveMinutesAgo = now.addingTimeInterval(-300)
        // Format with milliseconds, matching Claude Code's actual output
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        df.timeZone = TimeZone(identifier: "UTC")
        let ts = df.string(from: fiveMinutesAgo)

        let projectDir = fixtureRootURL.appendingPathComponent("millis-test")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let sessionFile = projectDir.appendingPathComponent("millis.jsonl")
        try assistantLine(model: "claude-sonnet-4-6", input: 1000, output: 500, cacheCreation: 0, cacheRead: 0, timestamp: ts)
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        XCTAssertEqual(snapshot.todaySessions, 1, "Session with millisecond timestamp should be counted as today")
        XCTAssertGreaterThan(snapshot.todayCost, 0)
        XCTAssertNotNil(snapshot.activeSessions.first?.firstMessageAt)
        XCTAssertNotNil(snapshot.activeSessions.first?.lastMessageAt)
    }

    func testProjectCostsGroupedByProject() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)

        let projectA = fixtureRootURL.appendingPathComponent("project-a")
        let projectB = fixtureRootURL.appendingPathComponent("project-b")
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)

        // Two sessions in project-a
        try assistantLine(model: "claude-sonnet-4-6", input: 1000, output: 500, cacheCreation: 0, cacheRead: 0, timestamp: ts)
            .write(to: projectA.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        try assistantLine(model: "claude-sonnet-4-6", input: 500, output: 200, cacheCreation: 0, cacheRead: 0, timestamp: ts)
            .write(to: projectA.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8)

        // One session in project-b
        try assistantLine(model: "claude-opus-4-6", input: 1000, output: 500, cacheCreation: 0, cacheRead: 0, timestamp: ts)
            .write(to: projectB.appendingPathComponent("s3.jsonl"), atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        XCTAssertEqual(snapshot.projectCosts.count, 2)
        // Sorted by todayCost descending — opus is more expensive
        XCTAssertEqual(snapshot.projectCosts[0].projectName, "project-b")
        XCTAssertEqual(snapshot.projectCosts[0].todaySessions, 1)
        XCTAssertEqual(snapshot.projectCosts[1].projectName, "project-a")
        XCTAssertEqual(snapshot.projectCosts[1].todaySessions, 2)
        XCTAssertGreaterThan(snapshot.projectCosts[0].todayCost, 0)
        XCTAssertGreaterThan(snapshot.projectCosts[1].todayCost, 0)
    }

    func testMissingProjectsRootReturnsEmpty() {
        let missing = fixtureRootURL.appendingPathComponent("nonexistent")
        let estimator = SessionCostEstimator(projectsRootURL: missing)
        let snapshot = estimator.estimateCosts()

        XCTAssertEqual(snapshot.todayCost, 0)
        XCTAssertEqual(snapshot.todaySessions, 0)
    }

    func testSkipsSyntheticAssistantLines() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("synthetic-test")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let synthetic = """
        {"type":"assistant","timestamp":"\(ts)","message":{"model":"<synthetic>","role":"assistant","content":[],"usage":{"input_tokens":999999,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        let real = assistantLine(model: "claude-sonnet-4-6", input: 100, output: 50, cacheCreation: 0, cacheRead: 0, timestamp: ts)
        let sessionFile = projectDir.appendingPathComponent("synth.jsonl")
        try [synthetic, real].joined(separator: "\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        XCTAssertEqual(snapshot.activeSessions.first?.messageCount, 1)
        XCTAssertEqual(snapshot.activeSessions.first?.totalUsage.inputTokens, 100)
    }

    func testSkipsAssistantWhenInputTokensMissing() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("no-input-tokens")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let noInputKey = """
        {"type":"assistant","timestamp":"\(ts)","message":{"model":"claude-sonnet-4-6","role":"assistant","content":[],"usage":{"output_tokens":50}}}
        """
        let valid = assistantLine(model: "claude-sonnet-4-6", input: 200, output: 10, cacheCreation: 0, cacheRead: 0, timestamp: ts)
        let sessionFile = projectDir.appendingPathComponent("mixed.jsonl")
        try [noInputKey, valid].joined(separator: "\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        XCTAssertEqual(snapshot.activeSessions.first?.messageCount, 1)
        XCTAssertEqual(snapshot.activeSessions.first?.totalUsage.inputTokens, 200)
    }

    func testOpus46UsesAnthropicStandardRates() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("opus-rate")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // $5 / MTok in, $25 / MTok out (no cache)
        let sessionFile = projectDir.appendingPathComponent("o.jsonl")
        try assistantLine(model: "claude-opus-4-6", input: 1000, output: 500, cacheCreation: 0, cacheRead: 0, timestamp: ts)
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        let expected = (1000.0 * 5.0 + 500.0 * 25.0) / 1_000_000.0
        XCTAssertEqual(snapshot.activeSessions.first?.totalCost ?? 0, expected, accuracy: 1e-9)
    }

    func testLegacyOpus41CostsMoreThanOpus46ForSameTokens() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("opus-legacy-vs-new")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        try assistantLine(model: "claude-opus-4-1", input: 1000, output: 500, cacheCreation: 0, cacheRead: 0, timestamp: ts)
            .write(to: projectDir.appendingPathComponent("41.jsonl"), atomically: true, encoding: .utf8)
        try assistantLine(model: "claude-opus-4-6", input: 1000, output: 500, cacheCreation: 0, cacheRead: 0, timestamp: ts)
            .write(to: projectDir.appendingPathComponent("46.jsonl"), atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)
        let costs = snapshot.activeSessions.map(\.totalCost).sorted(by: >)
        XCTAssertEqual(costs.count, 2)
        XCTAssertGreaterThan(costs[0], costs[1], "Opus 4.1 (legacy) should cost more than Opus 4.6 for identical usage")
    }

    func testParsesFractionalTokenNumbersInJSON() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("float-tokens")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let line = """
        {"type":"assistant","timestamp":"\(ts)","message":{"model":"claude-sonnet-4-6","role":"assistant","content":[],"usage":{"input_tokens":100.0,"output_tokens":50.5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        let sessionFile = projectDir.appendingPathComponent("f.jsonl")
        try line.write(to: sessionFile, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        XCTAssertEqual(snapshot.activeSessions.first?.totalUsage.inputTokens, 100)
        XCTAssertEqual(snapshot.activeSessions.first?.totalUsage.outputTokens, 51)
    }

    func testCountsAssistantRowWithZeroInputTokens() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("zero-input")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let line = """
        {"type":"assistant","timestamp":"\(ts)","message":{"model":"claude-sonnet-4-6","role":"assistant","content":[],"usage":{"input_tokens":0,"output_tokens":42,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        let sessionFile = projectDir.appendingPathComponent("z.jsonl")
        try line.write(to: sessionFile, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        XCTAssertEqual(snapshot.activeSessions.first?.messageCount, 1)
        XCTAssertEqual(snapshot.activeSessions.first?.totalUsage.inputTokens, 0)
        XCTAssertEqual(snapshot.activeSessions.first?.totalUsage.outputTokens, 42)
    }

    func testSkipsAssistantWhenInputTokensJSONNull() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("null-input")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let nullInput = """
        {"type":"assistant","timestamp":"\(ts)","message":{"model":"claude-sonnet-4-6","role":"assistant","content":[],"usage":{"input_tokens":null,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        let valid = assistantLine(model: "claude-sonnet-4-6", input: 50, output: 10, cacheCreation: 0, cacheRead: 0, timestamp: ts)
        let sessionFile = projectDir.appendingPathComponent("n.jsonl")
        try [nullInput, valid].joined(separator: "\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        XCTAssertEqual(snapshot.activeSessions.first?.messageCount, 1)
        XCTAssertEqual(snapshot.activeSessions.first?.totalUsage.inputTokens, 50)
    }

    func testMalformedJSONLineDoesNotBreakFollowingValidLines() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("malformed")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines = [
            "not json at all {{{",
            assistantLine(model: "claude-sonnet-4-6", input: 10, output: 5, cacheCreation: 0, cacheRead: 0, timestamp: ts),
            "{broken",
        ]
        let sessionFile = projectDir.appendingPathComponent("m.jsonl")
        try lines.joined(separator: "\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        XCTAssertEqual(snapshot.activeSessions.first?.messageCount, 1)
        XCTAssertEqual(snapshot.activeSessions.first?.totalUsage.inputTokens, 10)
    }

    func testOpus4SnapshotIdUsesLegacyPricing() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("opus4-snap")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let sessionFile = projectDir.appendingPathComponent("legacy.jsonl")
        try assistantLine(model: "claude-opus-4-20250514", input: 1000, output: 500, cacheCreation: 0, cacheRead: 0, timestamp: ts)
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        let expectedLegacy = (1000.0 * 15.0 + 500.0 * 75.0) / 1_000_000.0
        XCTAssertEqual(snapshot.activeSessions.first?.totalCost ?? 0, expectedLegacy, accuracy: 1e-9)
    }

    func testOpus45UsesCheapTierNotLegacy() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("opus45")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let sessionFile = projectDir.appendingPathComponent("p.jsonl")
        try assistantLine(model: "claude-opus-4-5", input: 1000, output: 500, cacheCreation: 0, cacheRead: 0, timestamp: ts)
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        let expectedCheap = (1000.0 * 5.0 + 500.0 * 25.0) / 1_000_000.0
        XCTAssertEqual(snapshot.activeSessions.first?.totalCost ?? 0, expectedCheap, accuracy: 1e-9)
    }

    func testHaiku45CostsMoreThanHaiku35ForSameTokens() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("haiku-tier")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        try assistantLine(model: "claude-haiku-4-5", input: 10_000, output: 5000, cacheCreation: 0, cacheRead: 0, timestamp: ts)
            .write(to: projectDir.appendingPathComponent("h45.jsonl"), atomically: true, encoding: .utf8)
        try assistantLine(model: "claude-haiku-3-5", input: 10_000, output: 5000, cacheCreation: 0, cacheRead: 0, timestamp: ts)
            .write(to: projectDir.appendingPathComponent("h35.jsonl"), atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)
        let byModel = Dictionary(uniqueKeysWithValues: snapshot.activeSessions.map { ($0.model, $0.totalCost) })

        XCTAssertGreaterThan(byModel["claude-haiku-4-5"] ?? 0, byModel["claude-haiku-3-5"] ?? 0)
    }

    func testSonnetCacheTokenCostMatchesFormula() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("cache-formula")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // input 100, cache_creation 400, cache_read 1000, output 0
        let sessionFile = projectDir.appendingPathComponent("c.jsonl")
        try assistantLine(model: "claude-sonnet-4-6", input: 100, output: 0, cacheCreation: 400, cacheRead: 1000, timestamp: ts)
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        let expected = (100.0 * 3.0 + 0.0 * 15.0 + 400.0 * 3.75 + 1000.0 * 0.30) / 1_000_000.0
        XCTAssertEqual(snapshot.activeSessions.first?.totalCost ?? 0, expected, accuracy: 1e-9)
    }

    func testDominantModelIsMostFrequentAssistantModelId() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("dominant")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines = [
            assistantLine(model: "claude-haiku-4-5", input: 10, output: 1, cacheCreation: 0, cacheRead: 0, timestamp: ts),
            assistantLine(model: "claude-haiku-4-5", input: 10, output: 1, cacheCreation: 0, cacheRead: 0, timestamp: ts),
            assistantLine(model: "claude-haiku-4-5", input: 10, output: 1, cacheCreation: 0, cacheRead: 0, timestamp: ts),
            assistantLine(model: "claude-sonnet-4-6", input: 10, output: 1, cacheCreation: 0, cacheRead: 0, timestamp: ts),
        ]
        let sessionFile = projectDir.appendingPathComponent("d.jsonl")
        try lines.joined(separator: "\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        XCTAssertEqual(snapshot.activeSessions.first?.model, "claude-haiku-4-5")
    }

    func testUnknownModelIdUsesSonnetFallbackPricing() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("unknown-model")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let sessionFile = projectDir.appendingPathComponent("u.jsonl")
        try assistantLine(model: "custom-vendor-model-xyz", input: 1000, output: 500, cacheCreation: 0, cacheRead: 0, timestamp: ts)
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        let expectedSonnetFallback = (1000.0 * 3.0 + 500.0 * 15.0) / 1_000_000.0
        XCTAssertEqual(snapshot.activeSessions.first?.totalCost ?? 0, expectedSonnetFallback, accuracy: 1e-9)
    }

    func testSessionWithOnlyNonBillableLinesProducesNoActiveSession() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("empty-billable")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines = [
            "{\"type\":\"user\",\"timestamp\":\"\(ts)\",\"message\":{\"role\":\"user\"}}",
            "{\"type\":\"assistant\",\"timestamp\":\"\(ts)\",\"message\":{\"model\":\"claude-sonnet-4-6\",\"role\":\"assistant\",\"content\":[],\"usage\":{\"output_tokens\":50}}}",
        ]
        let sessionFile = projectDir.appendingPathComponent("e.jsonl")
        try lines.joined(separator: "\n").write(to: sessionFile, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        XCTAssertEqual(snapshot.todaySessions, 0)
        XCTAssertTrue(snapshot.activeSessions.isEmpty)
    }

    func testRollingWeekCostSumsTodayAndEarlierWeekSessions() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 3600)
        let tsOld = ISO8601DateFormatter().string(from: threeDaysAgo)

        let projectDir = fixtureRootURL.appendingPathComponent("week-sum")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        try assistantLine(model: "claude-sonnet-4-6", input: 100, output: 50, cacheCreation: 0, cacheRead: 0, timestamp: tsOld)
            .write(to: projectDir.appendingPathComponent("week-only.jsonl"), atomically: true, encoding: .utf8)
        try assistantLine(model: "claude-sonnet-4-6", input: 200, output: 100, cacheCreation: 0, cacheRead: 0, timestamp: ts)
            .write(to: projectDir.appendingPathComponent("today-only.jsonl"), atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        let oldExpected = (100.0 * 3.0 + 50.0 * 15.0) / 1_000_000.0
        let todayExpected = (200.0 * 3.0 + 100.0 * 15.0) / 1_000_000.0
        XCTAssertEqual(snapshot.todayCost, todayExpected, accuracy: 1e-9)
        XCTAssertEqual(snapshot.weekCost, oldExpected + todayExpected, accuracy: 1e-9)
        XCTAssertEqual(snapshot.todaySessions, 1)
        XCTAssertEqual(snapshot.weekSessions, 2)
    }

    func testOpus47UsesSameCheapTierAsOpus46() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("opus47")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let sessionFile = projectDir.appendingPathComponent("47.jsonl")
        try assistantLine(model: "claude-opus-4-7", input: 800, output: 400, cacheCreation: 0, cacheRead: 0, timestamp: ts)
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        let expected = (800.0 * 5.0 + 400.0 * 25.0) / 1_000_000.0
        XCTAssertEqual(snapshot.activeSessions.first?.totalCost ?? 0, expected, accuracy: 1e-9)
    }

    func testRepeatedEstimateCostsStableForSameFiles() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("stable")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let sessionFile = projectDir.appendingPathComponent("s.jsonl")
        try assistantLine(model: "claude-sonnet-4-6", input: 500, output: 200, cacheCreation: 0, cacheRead: 0, timestamp: ts)
            .write(to: sessionFile, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let a = estimator.estimateCosts(now: now)
        let b = estimator.estimateCosts(now: now)

        XCTAssertEqual(a.todayCost, b.todayCost, accuracy: 1e-12)
        XCTAssertEqual(a.activeSessions.first?.totalUsage, b.activeSessions.first?.totalUsage)
    }

    func testParsesNumericTokensFromStringJSON() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let projectDir = fixtureRootURL.appendingPathComponent("string-nums")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let line = """
        {"type":"assistant","timestamp":"\(ts)","message":{"model":"claude-sonnet-4-6","role":"assistant","content":[],"usage":{"input_tokens":"99","output_tokens":"1","cache_creation_input_tokens":"0","cache_read_input_tokens":"0"}}}
        """
        let sessionFile = projectDir.appendingPathComponent("str.jsonl")
        try line.write(to: sessionFile, atomically: true, encoding: .utf8)

        let estimator = SessionCostEstimator(projectsRootURL: fixtureRootURL)
        let snapshot = estimator.estimateCosts(now: now)

        XCTAssertEqual(snapshot.activeSessions.first?.totalUsage.inputTokens, 99)
        XCTAssertEqual(snapshot.activeSessions.first?.totalUsage.outputTokens, 1)
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
