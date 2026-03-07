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

    /// Helper: send N consecutive active polls
    private func sendActivePolls(_ notifier: TaskCompletionNotifier, count: Int, cost: Double = 0) {
        for _ in 0..<count {
            notifier.update(isActivelyWorking: true, currentCost: cost)
        }
    }

    func testTracksActiveSessionStart() {
        let notifier = TaskCompletionNotifier()
        notifier.notificationsEnabled = false
        notifier.soundEnabled = false

        sendActivePolls(notifier, count: 3, cost: 1.50)
        notifier.update(isActivelyWorking: false, currentCost: 2.00)
    }

    func testRepeatedIdleUpdatesDoNotRetrigger() {
        let notifier = TaskCompletionNotifier()
        notifier.notificationsEnabled = false
        notifier.soundEnabled = false

        sendActivePolls(notifier, count: 3)
        notifier.update(isActivelyWorking: false, currentCost: 0.50)
        // Further idle updates should not re-notify
        notifier.update(isActivelyWorking: false, currentCost: 0.50)
        notifier.update(isActivelyWorking: false, currentCost: 0.50)
    }

    func testMultipleActiveIdleCycles() {
        let notifier = TaskCompletionNotifier()
        notifier.notificationsEnabled = false
        notifier.soundEnabled = false

        // First cycle
        sendActivePolls(notifier, count: 3)
        notifier.update(isActivelyWorking: false, currentCost: 1.00)

        // Second cycle
        sendActivePolls(notifier, count: 3, cost: 1.00)
        notifier.update(isActivelyWorking: false, currentCost: 2.50)
    }

    func testBuildSummaryWithDurationAndCost() {
        let notifier = TaskCompletionNotifier()
        notifier.notificationsEnabled = false
        notifier.soundEnabled = false

        sendActivePolls(notifier, count: 3)
        notifier.update(isActivelyWorking: false, currentCost: 0.75)
    }

    func testZeroCostOmittedFromSummary() {
        let notifier = TaskCompletionNotifier()
        notifier.notificationsEnabled = false
        notifier.soundEnabled = false

        sendActivePolls(notifier, count: 3, cost: 5.00)
        notifier.update(isActivelyWorking: false, currentCost: 5.00)
    }

    func testDefaultCostParameterIsZero() {
        let notifier = TaskCompletionNotifier()
        notifier.notificationsEnabled = false
        notifier.soundEnabled = false

        sendActivePolls(notifier, count: 3)
        notifier.update(isActivelyWorking: false)
    }

    func testFewerThanRequiredActivePollsDoesNotTrigger() {
        let notifier = TaskCompletionNotifier()
        notifier.notificationsEnabled = false
        notifier.soundEnabled = false

        // Only 2 active polls (need 3) — should not fire
        sendActivePolls(notifier, count: 2)
        notifier.update(isActivelyWorking: false, currentCost: 0)
        // Should silently reset
        notifier.update(isActivelyWorking: false, currentCost: 0)
    }

    func testSingleActivePollDoesNotTrigger() {
        let notifier = TaskCompletionNotifier()
        notifier.notificationsEnabled = false
        notifier.soundEnabled = false

        // Single active blip
        notifier.update(isActivelyWorking: true, currentCost: 0)
        notifier.update(isActivelyWorking: false, currentCost: 0)
        // Back to active for a real session
        sendActivePolls(notifier, count: 3)
        notifier.update(isActivelyWorking: false, currentCost: 0)
    }
}
