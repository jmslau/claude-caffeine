import Foundation
import XCTest
@testable import ClaudeCaffeine

@MainActor
final class ClosedLidReporterTests: XCTestCase {

    func testNoReportWithoutActivity() {
        let reporter = ClosedLidReporter()
        XCTAssertNil(reporter.consumeReport())
    }

    func testNoReportWhenDurationBelowMinimum() {
        let reporter = ClosedLidReporter()
        let start = Date()
        reporter.recordStart(now: start)
        reporter.recordEnd(now: start.addingTimeInterval(5))

        XCTAssertNil(reporter.consumeReport())
    }

    func testReportGeneratedWhenDurationAboveMinimum() {
        let reporter = ClosedLidReporter()
        let start = Date()
        reporter.recordStart(now: start)
        reporter.recordEnd(now: start.addingTimeInterval(120))

        let report = reporter.consumeReport()
        XCTAssertNotNil(report)
        XCTAssertEqual(report?.duration, 120)
        XCTAssertFalse(report!.didSleepAfterIdle)
    }

    func testReportConsumedOnlyOnce() {
        let reporter = ClosedLidReporter()
        let start = Date()
        reporter.recordStart(now: start)
        reporter.recordEnd(now: start.addingTimeInterval(120))

        XCTAssertNotNil(reporter.consumeReport())
        XCTAssertNil(reporter.consumeReport())
    }

    func testWakeSetsSleepFlag() {
        let reporter = ClosedLidReporter()
        let start = Date()
        reporter.recordStart(now: start)
        reporter.recordEnd(now: start.addingTimeInterval(300))
        reporter.recordWake()

        let report = reporter.consumeReport()
        XCTAssertNotNil(report)
        XCTAssertTrue(report!.didSleepAfterIdle)
    }

    func testWakeWithoutPendingReportDoesNotSetFlag() {
        let reporter = ClosedLidReporter()
        reporter.recordWake()

        XCTAssertNil(reporter.consumeReport())
        XCTAssertFalse(reporter.didSleepAfterClosedLid)
    }

    func testSleepFlagClearedAfterConsume() {
        let reporter = ClosedLidReporter()
        let start = Date()
        reporter.recordStart(now: start)
        reporter.recordEnd(now: start.addingTimeInterval(120))
        reporter.recordWake()

        _ = reporter.consumeReport()
        XCTAssertFalse(reporter.didSleepAfterClosedLid)
    }

    func testRecordStartIsIdempotent() {
        let reporter = ClosedLidReporter()
        let early = Date()
        let late = early.addingTimeInterval(60)
        reporter.recordStart(now: early)
        reporter.recordStart(now: late)
        reporter.recordEnd(now: early.addingTimeInterval(120))

        let report = reporter.consumeReport()
        XCTAssertEqual(report?.duration, 120, "Should use the first start time")
    }

    func testRecordEndWithoutStartIsNoOp() {
        let reporter = ClosedLidReporter()
        reporter.recordEnd()
        XCTAssertNil(reporter.consumeReport())
    }

    func testCustomMinimumDuration() {
        let reporter = ClosedLidReporter(minimumDuration: 10)
        let start = Date()
        reporter.recordStart(now: start)
        reporter.recordEnd(now: start.addingTimeInterval(15))

        XCTAssertNotNil(reporter.consumeReport())
    }

    // MARK: - Report message tests

    func testDurationTextSeconds() {
        XCTAssertEqual(ClosedLidReport(duration: 15, didSleepAfterIdle: false).durationText, "15 sec")
        XCTAssertEqual(ClosedLidReport(duration: 1, didSleepAfterIdle: false).durationText, "1 sec")
        XCTAssertEqual(ClosedLidReport(duration: 59, didSleepAfterIdle: false).durationText, "59 sec")
    }

    func testDurationTextMinutes() {
        XCTAssertEqual(ClosedLidReport(duration: 60, didSleepAfterIdle: false).durationText, "1 min")
        XCTAssertEqual(ClosedLidReport(duration: 300, didSleepAfterIdle: false).durationText, "5 mins")
        XCTAssertEqual(ClosedLidReport(duration: 551, didSleepAfterIdle: false).durationText, "9 mins 11 sec")
    }

    func testDurationTextHours() {
        XCTAssertEqual(ClosedLidReport(duration: 3600, didSleepAfterIdle: false).durationText, "1 hour")
        XCTAssertEqual(ClosedLidReport(duration: 5400, didSleepAfterIdle: false).durationText, "1 hour 30 mins")
        XCTAssertEqual(ClosedLidReport(duration: 9000, didSleepAfterIdle: false).durationText, "2 hours 30 mins")
    }

    func testMessageShowsMinutes() {
        let report = ClosedLidReport(duration: 300, didSleepAfterIdle: false)
        XCTAssertTrue(report.message.contains("5 mins"), "Expected '5 mins' in: \(report.message)")
        XCTAssertFalse(report.message.contains("went to sleep"))
    }

    func testMessageShowsHoursAndMinutes() {
        let report = ClosedLidReport(duration: 5400, didSleepAfterIdle: false)
        XCTAssertTrue(report.message.contains("1 hour 30 mins"), "Expected '1 hour 30 mins' in: \(report.message)")
    }

    func testMessageIncludesSleepSentence() {
        let report = ClosedLidReport(duration: 300, didSleepAfterIdle: true)
        XCTAssertTrue(report.message.contains("went to sleep"), "Expected sleep sentence in: \(report.message)")
    }

    func testMessageOmitsSleepSentenceWhenNoSleep() {
        let report = ClosedLidReport(duration: 300, didSleepAfterIdle: false)
        XCTAssertFalse(report.message.contains("went to sleep"))
    }

    // MARK: - snapshotActive tests

    func testSnapshotActiveCreatesReportWhileStillActive() {
        let reporter = ClosedLidReporter()
        let start = Date()
        reporter.recordStart(now: start)
        reporter.snapshotActive(now: start.addingTimeInterval(180))

        let report = reporter.consumeReport()
        XCTAssertNotNil(report)
        XCTAssertEqual(report?.duration, 180)
        XCTAssertFalse(report!.didSleepAfterIdle)
    }

    func testSnapshotActiveResetsTracking() {
        let reporter = ClosedLidReporter()
        let start = Date()
        reporter.recordStart(now: start)
        reporter.snapshotActive(now: start.addingTimeInterval(120))

        XCTAssertNil(reporter.activeStart, "activeStart should be nil after snapshot")

        // A subsequent recordEnd should be a no-op
        reporter.recordEnd(now: start.addingTimeInterval(300))
        _ = reporter.consumeReport() // consume the snapshot report
        XCTAssertNil(reporter.consumeReport(), "No second report from recordEnd after snapshot")
    }

    func testSnapshotActiveBelowMinimumIsIgnored() {
        let reporter = ClosedLidReporter()
        let start = Date()
        reporter.recordStart(now: start)
        reporter.snapshotActive(now: start.addingTimeInterval(5))

        XCTAssertNil(reporter.consumeReport())
    }

    func testSnapshotActiveWithoutStartIsNoOp() {
        let reporter = ClosedLidReporter()
        reporter.snapshotActive()
        XCTAssertNil(reporter.consumeReport())
    }

    func testLidOpenedThenMacSleptScenario() {
        // Lid closed → Claude works 30min → Claude finishes → Mac sleeps → User opens lid
        let reporter = ClosedLidReporter()
        let start = Date()
        reporter.recordStart(now: start)
        reporter.recordEnd(now: start.addingTimeInterval(1800))
        reporter.recordWake()

        let report = reporter.consumeReport()
        XCTAssertNotNil(report)
        XCTAssertTrue(report!.didSleepAfterIdle)
        XCTAssertEqual(report!.duration, 1800)
    }

    func testLidOpenedWhileClaudeStillWorking() {
        // Lid closed → Claude works → User opens lid (no sleep)
        let reporter = ClosedLidReporter()
        let start = Date()
        reporter.recordStart(now: start)
        reporter.snapshotActive(now: start.addingTimeInterval(600))

        let report = reporter.consumeReport()
        XCTAssertNotNil(report)
        XCTAssertFalse(report!.didSleepAfterIdle)
        XCTAssertEqual(report!.duration, 600)
    }

    func testMultipleCycles() {
        let reporter = ClosedLidReporter()

        // First cycle
        let start1 = Date()
        reporter.recordStart(now: start1)
        reporter.recordEnd(now: start1.addingTimeInterval(180))
        reporter.recordWake()

        let report1 = reporter.consumeReport()
        XCTAssertNotNil(report1)
        XCTAssertTrue(report1!.didSleepAfterIdle)

        // Second cycle - no sleep
        let start2 = Date()
        reporter.recordStart(now: start2)
        reporter.recordEnd(now: start2.addingTimeInterval(120))

        let report2 = reporter.consumeReport()
        XCTAssertNotNil(report2)
        XCTAssertFalse(report2!.didSleepAfterIdle)
    }
}
