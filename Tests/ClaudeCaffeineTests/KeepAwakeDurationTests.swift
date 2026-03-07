import Foundation
import XCTest
@testable import ClaudeCaffeine

final class KeepAwakeDurationTests: XCTestCase {

    func testOffAlwaysReturnsFalse() {
        let now = Date()
        let idleSince = now.addingTimeInterval(-1)
        XCTAssertFalse(KeepAwakeDuration.shouldKeepAwake(duration: .off, idleSince: idleSince, now: now))
    }

    func testOffWithNilIdleSinceReturnsFalse() {
        XCTAssertFalse(KeepAwakeDuration.shouldKeepAwake(duration: .off, idleSince: nil, now: Date()))
    }

    func testForeverAlwaysReturnsTrue() {
        let now = Date()
        let idleSince = now.addingTimeInterval(-86400) // 24 hours ago
        XCTAssertTrue(KeepAwakeDuration.shouldKeepAwake(duration: .forever, idleSince: idleSince, now: now))
    }

    func testForeverWithNilIdleSinceReturnsFalse() {
        XCTAssertFalse(KeepAwakeDuration.shouldKeepAwake(duration: .forever, idleSince: nil, now: Date()))
    }

    func testOneHourWithinWindow() {
        let now = Date()
        let idleSince = now.addingTimeInterval(-1800) // 30 minutes ago
        XCTAssertTrue(KeepAwakeDuration.shouldKeepAwake(duration: .oneHour, idleSince: idleSince, now: now))
    }

    func testOneHourExpired() {
        let now = Date()
        let idleSince = now.addingTimeInterval(-3601) // just over 1 hour
        XCTAssertFalse(KeepAwakeDuration.shouldKeepAwake(duration: .oneHour, idleSince: idleSince, now: now))
    }

    func testTwoHoursWithinWindow() {
        let now = Date()
        let idleSince = now.addingTimeInterval(-3600) // 1 hour ago
        XCTAssertTrue(KeepAwakeDuration.shouldKeepAwake(duration: .twoHours, idleSince: idleSince, now: now))
    }

    func testTwoHoursExpired() {
        let now = Date()
        let idleSince = now.addingTimeInterval(-7201)
        XCTAssertFalse(KeepAwakeDuration.shouldKeepAwake(duration: .twoHours, idleSince: idleSince, now: now))
    }

    func testFourHoursAtBoundary() {
        let now = Date()
        // Exactly at boundary should return false (elapsed >= rawValue)
        let idleSince = now.addingTimeInterval(-14400)
        XCTAssertFalse(KeepAwakeDuration.shouldKeepAwake(duration: .fourHours, idleSince: idleSince, now: now))
    }

    func testTwelveHoursWithinWindow() {
        let now = Date()
        let idleSince = now.addingTimeInterval(-43199) // 1 second before expiry
        XCTAssertTrue(KeepAwakeDuration.shouldKeepAwake(duration: .twelveHours, idleSince: idleSince, now: now))
    }

    func testNilIdleSinceAlwaysReturnsFalse() {
        for duration in KeepAwakeDuration.allCases {
            XCTAssertFalse(
                KeepAwakeDuration.shouldKeepAwake(duration: duration, idleSince: nil, now: Date()),
                "\(duration.label) should return false with nil idleSince"
            )
        }
    }

    func testLabels() {
        XCTAssertEqual(KeepAwakeDuration.off.label, "Off")
        XCTAssertEqual(KeepAwakeDuration.oneHour.label, "1 Hour")
        XCTAssertEqual(KeepAwakeDuration.twoHours.label, "2 Hours")
        XCTAssertEqual(KeepAwakeDuration.fourHours.label, "4 Hours")
        XCTAssertEqual(KeepAwakeDuration.twelveHours.label, "12 Hours")
        XCTAssertEqual(KeepAwakeDuration.forever.label, "Forever")
    }

    func testAllCasesCount() {
        XCTAssertEqual(KeepAwakeDuration.allCases.count, 6)
    }
}
