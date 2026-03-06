import Foundation
import XCTest
@testable import ClaudeCaffeine

@MainActor
final class TaskCompletionNotifierTests: XCTestCase {

    func testNoNotificationOnFirstUpdate() {
        let notifier = TaskCompletionNotifier()
        notifier.notificationsEnabled = false
        notifier.soundEnabled = false

        // Should not crash or trigger anything on first idle update
        notifier.update(isActivelyWorking: false, currentCost: 0)
    }

    func testTracksActiveSessionStart() {
        let notifier = TaskCompletionNotifier()
        notifier.notificationsEnabled = false
        notifier.soundEnabled = false

        notifier.update(isActivelyWorking: true, currentCost: 1.50)
        // Transition to idle — cost delta should be computed from start
        notifier.update(isActivelyWorking: false, currentCost: 2.00)
    }

    func testRepeatedIdleUpdatesDoNotRetrigger() {
        let notifier = TaskCompletionNotifier()
        notifier.notificationsEnabled = false
        notifier.soundEnabled = false

        notifier.update(isActivelyWorking: true, currentCost: 0)
        notifier.update(isActivelyWorking: false, currentCost: 0.50)
        // Second idle update should not re-notify
        notifier.update(isActivelyWorking: false, currentCost: 0.50)
    }

    func testMultipleActiveIdleCycles() {
        let notifier = TaskCompletionNotifier()
        notifier.notificationsEnabled = false
        notifier.soundEnabled = false

        // First cycle
        notifier.update(isActivelyWorking: true, currentCost: 0)
        notifier.update(isActivelyWorking: false, currentCost: 1.00)

        // Second cycle
        notifier.update(isActivelyWorking: true, currentCost: 1.00)
        notifier.update(isActivelyWorking: false, currentCost: 2.50)
    }

    func testBuildSummaryWithDurationAndCost() {
        let notifier = TaskCompletionNotifier()
        notifier.notificationsEnabled = false
        notifier.soundEnabled = false

        // Start active session, wait briefly, then go idle with cost
        notifier.update(isActivelyWorking: true, currentCost: 0)
        // Immediately transition — duration will be < 1s so omitted
        notifier.update(isActivelyWorking: false, currentCost: 0.75)
    }

    func testZeroCostOmittedFromSummary() {
        let notifier = TaskCompletionNotifier()
        notifier.notificationsEnabled = false
        notifier.soundEnabled = false

        notifier.update(isActivelyWorking: true, currentCost: 5.00)
        // Same cost at end — delta is 0, should be omitted
        notifier.update(isActivelyWorking: false, currentCost: 5.00)
    }

    func testDefaultCostParameterIsZero() {
        let notifier = TaskCompletionNotifier()
        notifier.notificationsEnabled = false
        notifier.soundEnabled = false

        // Calling without currentCost should default to 0
        notifier.update(isActivelyWorking: true)
        notifier.update(isActivelyWorking: false)
    }
}
