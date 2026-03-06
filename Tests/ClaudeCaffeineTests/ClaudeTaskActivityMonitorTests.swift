import Foundation
import XCTest
@testable import ClaudeCaffeine

final class ClaudeTaskActivityMonitorTests: XCTestCase {
    private var fixtureRootURL: URL!
    private let stubProcessNotRunning: @Sendable () -> ClaudeProcessDetector.ProcessStatus = { .notRunning }

    override func setUpWithError() throws {
        fixtureRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCaffeineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureRootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRootURL {
            try? FileManager.default.removeItem(at: fixtureRootURL)
        }
        fixtureRootURL = nil
    }

    func testPollReportsMissingTasksRoot() {
        let missingRoot = fixtureRootURL.appendingPathComponent("missing")
        let monitor = ClaudeTaskActivityMonitor(tasksRootURL: missingRoot, detectProcess: stubProcessNotRunning)

        let snapshot = monitor.poll(now: Date(timeIntervalSince1970: 1_000), idleThreshold: 60)

        XCTAssertEqual(snapshot.status, .tasksRootMissing)
        XCTAssertEqual(snapshot.totalSessions, 0)
        XCTAssertTrue(snapshot.activeSessions.isEmpty)
    }

    func testPollReportsIoErrorWhenTasksRootIsAFile() throws {
        let fileRoot = fixtureRootURL.appendingPathComponent("not-a-directory")
        XCTAssertTrue(FileManager.default.createFile(atPath: fileRoot.path, contents: Data()))
        let monitor = ClaudeTaskActivityMonitor(tasksRootURL: fileRoot, detectProcess: stubProcessNotRunning)

        let snapshot = monitor.poll(now: Date(timeIntervalSince1970: 1_000), idleThreshold: 60)

        XCTAssertEqual(snapshot.status, .ioError)
        XCTAssertEqual(snapshot.totalSessions, 0)
        XCTAssertTrue(snapshot.activeSessions.isEmpty)
    }

    func testPollDetectsActivityInNestedFiles() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let tasksRoot = fixtureRootURL.appendingPathComponent("tasks")
        let monitor = ClaudeTaskActivityMonitor(tasksRootURL: tasksRoot, detectProcess: stubProcessNotRunning)

        try createSessionFile(
            tasksRoot: tasksRoot,
            sessionID: "session-nested",
            relativeFilePath: "events/trace/output.log",
            modificationDate: now.addingTimeInterval(-15)
        )

        let snapshot = monitor.poll(now: now, idleThreshold: 60)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.totalSessions, 1)
        XCTAssertEqual(snapshot.activeSessions.map(\.sessionID), ["session-nested"])
    }

    func testPollExcludesIdleSessionsAndSortsByMostRecentActivity() throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let tasksRoot = fixtureRootURL.appendingPathComponent("tasks")
        let monitor = ClaudeTaskActivityMonitor(tasksRootURL: tasksRoot, detectProcess: stubProcessNotRunning)

        try createSessionFile(
            tasksRoot: tasksRoot,
            sessionID: "session-new",
            relativeFilePath: "log.txt",
            modificationDate: now.addingTimeInterval(-5)
        )
        try createSessionFile(
            tasksRoot: tasksRoot,
            sessionID: "session-old-active",
            relativeFilePath: "output/data.json",
            modificationDate: now.addingTimeInterval(-45)
        )
        try createSessionFile(
            tasksRoot: tasksRoot,
            sessionID: "session-idle",
            relativeFilePath: "log.txt",
            modificationDate: now.addingTimeInterval(-180)
        )

        let snapshot = monitor.poll(now: now, idleThreshold: 60)

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.totalSessions, 3)
        XCTAssertEqual(snapshot.activeSessions.map(\.sessionID), ["session-new", "session-old-active"])
    }

    // MARK: - Combined signal tests

    func testIsActivelyWorkingWhenProcessHasActiveConnections() {
        let tasksRoot = fixtureRootURL.appendingPathComponent("tasks-empty")
        try! FileManager.default.createDirectory(at: tasksRoot, withIntermediateDirectories: true)
        let activeProcess: @Sendable () -> ClaudeProcessDetector.ProcessStatus = {
            ClaudeProcessDetector.ProcessStatus(isRunning: true, hasActiveConnections: true, cpuUsage: 12.0, pids: [1234])
        }
        let monitor = ClaudeTaskActivityMonitor(tasksRootURL: tasksRoot, detectProcess: activeProcess)

        let snapshot = monitor.poll(now: Date(timeIntervalSince1970: 1_000), idleThreshold: 60)

        XCTAssertTrue(snapshot.isClaudeActivelyWorking)
        XCTAssertTrue(snapshot.isClaudeRunning)
        XCTAssertTrue(snapshot.activeSessions.isEmpty)
    }

    func testNotActivelyWorkingWhenFileActivityOnlyAndProcessNotRunning() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let tasksRoot = fixtureRootURL.appendingPathComponent("tasks-files")
        let monitor = ClaudeTaskActivityMonitor(tasksRootURL: tasksRoot, detectProcess: stubProcessNotRunning)

        try createSessionFile(
            tasksRoot: tasksRoot,
            sessionID: "session-1",
            relativeFilePath: "log.txt",
            modificationDate: now.addingTimeInterval(-10)
        )

        let snapshot = monitor.poll(now: now, idleThreshold: 60)

        XCTAssertFalse(snapshot.isClaudeActivelyWorking)
        XCTAssertFalse(snapshot.isClaudeRunning)
    }

    func testNotActivelyWorkingWhenIdleAtPromptWithKeepAliveConnections() {
        let tasksRoot = fixtureRootURL.appendingPathComponent("tasks-keepalive")
        try! FileManager.default.createDirectory(at: tasksRoot, withIntermediateDirectories: true)
        let idleWithConnections: @Sendable () -> ClaudeProcessDetector.ProcessStatus = {
            ClaudeProcessDetector.ProcessStatus(isRunning: true, hasActiveConnections: true, cpuUsage: 0.3, pids: [4321])
        }
        let monitor = ClaudeTaskActivityMonitor(tasksRootURL: tasksRoot, detectProcess: idleWithConnections)

        let snapshot = monitor.poll(now: Date(timeIntervalSince1970: 1_000), idleThreshold: 60)

        XCTAssertFalse(snapshot.isClaudeActivelyWorking)
        XCTAssertTrue(snapshot.isClaudeRunning)
    }

    func testActivelyWorkingWhenAmbiguousProcessWithFileActivity() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let tasksRoot = fixtureRootURL.appendingPathComponent("tasks-ambiguous")
        let ambiguousProcess: @Sendable () -> ClaudeProcessDetector.ProcessStatus = {
            ClaudeProcessDetector.ProcessStatus(isRunning: true, hasActiveConnections: false, cpuUsage: 3.0, pids: [7777])
        }
        let monitor = ClaudeTaskActivityMonitor(tasksRootURL: tasksRoot, detectProcess: ambiguousProcess)

        try createSessionFile(
            tasksRoot: tasksRoot,
            sessionID: "session-1",
            relativeFilePath: "log.txt",
            modificationDate: now.addingTimeInterval(-10)
        )

        let snapshot = monitor.poll(now: now, idleThreshold: 60)

        XCTAssertTrue(snapshot.processStatus.isAmbiguous)
        XCTAssertTrue(snapshot.isClaudeActivelyWorking)
    }

    func testNotActivelyWorkingWhenProcessIdleAndNoFileActivity() {
        let tasksRoot = fixtureRootURL.appendingPathComponent("tasks-idle")
        try! FileManager.default.createDirectory(at: tasksRoot, withIntermediateDirectories: true)
        let idleProcess: @Sendable () -> ClaudeProcessDetector.ProcessStatus = {
            ClaudeProcessDetector.ProcessStatus(isRunning: true, hasActiveConnections: false, cpuUsage: 0.1, pids: [5678])
        }
        let monitor = ClaudeTaskActivityMonitor(tasksRootURL: tasksRoot, detectProcess: idleProcess)

        let snapshot = monitor.poll(now: Date(timeIntervalSince1970: 1_000), idleThreshold: 60)

        XCTAssertFalse(snapshot.isClaudeActivelyWorking)
        XCTAssertTrue(snapshot.isClaudeRunning)
        XCTAssertTrue(snapshot.processStatus.isWaitingForInput)
    }

    func testIsActivelyWorkingWithBothSignals() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let tasksRoot = fixtureRootURL.appendingPathComponent("tasks-both")
        let activeProcess: @Sendable () -> ClaudeProcessDetector.ProcessStatus = {
            ClaudeProcessDetector.ProcessStatus(isRunning: true, hasActiveConnections: true, cpuUsage: 8.0, pids: [9999])
        }
        let monitor = ClaudeTaskActivityMonitor(tasksRootURL: tasksRoot, detectProcess: activeProcess)

        try createSessionFile(
            tasksRoot: tasksRoot,
            sessionID: "session-both",
            relativeFilePath: "log.txt",
            modificationDate: now.addingTimeInterval(-5)
        )

        let snapshot = monitor.poll(now: now, idleThreshold: 60)

        XCTAssertTrue(snapshot.isClaudeActivelyWorking)
        XCTAssertTrue(snapshot.isClaudeRunning)
        XCTAssertEqual(snapshot.activeSessions.count, 1)
    }

    func testProcessStatusIncludedInSnapshot() {
        let tasksRoot = fixtureRootURL.appendingPathComponent("tasks-proc")
        try! FileManager.default.createDirectory(at: tasksRoot, withIntermediateDirectories: true)
        let expectedPIDs: [Int32] = [111, 222]
        let customProcess: @Sendable () -> ClaudeProcessDetector.ProcessStatus = {
            ClaudeProcessDetector.ProcessStatus(isRunning: true, hasActiveConnections: false, cpuUsage: 2.5, pids: expectedPIDs)
        }
        let monitor = ClaudeTaskActivityMonitor(tasksRootURL: tasksRoot, detectProcess: customProcess)

        let snapshot = monitor.poll(now: Date(timeIntervalSince1970: 1_000), idleThreshold: 60)

        XCTAssertEqual(snapshot.processStatus.pids, expectedPIDs)
        XCTAssertEqual(snapshot.processStatus.cpuUsage, 2.5)
        XCTAssertFalse(snapshot.processStatus.hasActiveConnections)
    }

    // MARK: - Helpers

    private func createSessionFile(
        tasksRoot: URL,
        sessionID: String,
        relativeFilePath: String,
        modificationDate: Date
    ) throws {
        let sessionURL = tasksRoot.appendingPathComponent(sessionID, isDirectory: true)
        let fileURL = sessionURL.appendingPathComponent(relativeFilePath)
        let parentURL = fileURL.deletingLastPathComponent()

        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: Data("x".utf8)))
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: fileURL.path)
    }
}
