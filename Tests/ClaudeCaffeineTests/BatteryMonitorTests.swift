import Foundation
import XCTest
@testable import ClaudeCaffeine

final class BatteryMonitorTests: XCTestCase {
    func testDefaultThresholdIsTenPercent() {
        let monitor = BatteryMonitor()
        XCTAssertEqual(monitor.lowBatteryThreshold, 10)
    }

    func testCustomThreshold() {
        let monitor = BatteryMonitor(lowBatteryThreshold: 20)
        XCTAssertEqual(monitor.lowBatteryThreshold, 20)
    }

    func testSnapshotReturnsValidData() {
        let snapshot = BatteryMonitor.currentSnapshot()
        XCTAssertGreaterThanOrEqual(snapshot.batteryLevel, 0)
        XCTAssertLessThanOrEqual(snapshot.batteryLevel, 100)
    }
}
