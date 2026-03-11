import Foundation
import XCTest
@testable import ClaudeCaffeine

final class ThermalMonitorTests: XCTestCase {
    func testIsCriticalReturnsBool() {
        let monitor = ThermalMonitor()
        // Just verify it returns a valid Bool without crashing.
        // The actual value depends on the current thermal state of the test machine.
        let _ = monitor.isCritical
    }

    func testIsCriticalIsFalseUnderNormalConditions() {
        // On a healthy test machine the thermal state should not be critical.
        let monitor = ThermalMonitor()
        XCTAssertFalse(monitor.isCritical, "Expected non-critical thermal state on a healthy machine")
    }
}
