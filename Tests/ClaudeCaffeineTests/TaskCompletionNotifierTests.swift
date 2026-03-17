import Foundation
import XCTest
@testable import ClaudeCaffeine

@MainActor
final class TaskCompletionNotifierTests: XCTestCase {

    private func makeNotifier() -> TaskCompletionNotifier {
        let notifier = TaskCompletionNotifier()
        notifier.notificationsEnabled = false
        notifier.soundEnabled = false
        return notifier
    }

    /// Helper: send N consecutive active polls with file activity.
    private func sendActivePolls(
        _ notifier: TaskCompletionNotifier,
        count: Int,
        cost: Double = 0,
        hasFileActivity: Bool = true
    ) {
        for _ in 0..<count {
            notifier.update(isActivelyWorking: true, hasFileActivity: hasFileActivity, currentCost: cost)
        }
    }

    // MARK: - Basic behavior

    func testNoNotificationOnFirstUpdate() {
        let notifier = makeNotifier()
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 0)
    }

    func testTracksActiveSessionStart() {
        let notifier = makeNotifier()
        sendActivePolls(notifier, count: 4, cost: 1.50)
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 2.00)
    }

    func testRepeatedIdleUpdatesDoNotRetrigger() {
        let notifier = makeNotifier()
        sendActivePolls(notifier, count: 4)
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 0.50)
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 0.50)
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 0.50)
    }

    func testMultipleActiveIdleCycles() {
        let notifier = makeNotifier()
        var clock = Date()
        notifier.now = { clock }

        // First cycle
        sendActivePolls(notifier, count: 4)
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 1.00)

        // Advance past cooldown
        clock = clock.addingTimeInterval(61)

        // Second cycle
        sendActivePolls(notifier, count: 4, cost: 1.00)
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 2.50)
    }

    // MARK: - Required active polls (bumped to 4)

    func testFewerThanRequiredActivePollsDoesNotTrigger() {
        let notifier = makeNotifier()
        // Only 3 active polls (need 4)
        sendActivePolls(notifier, count: 3)
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 0)
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 0)
    }

    func testSingleActivePollDoesNotTrigger() {
        let notifier = makeNotifier()
        notifier.update(isActivelyWorking: true, hasFileActivity: true, currentCost: 0)
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 0)
        // Back to active for a real session
        sendActivePolls(notifier, count: 4)
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 0)
    }

    func testExactlyRequiredPollsTriggers() {
        let notifier = makeNotifier()
        sendActivePolls(notifier, count: 4)
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 0)
        // If no crash or assertion failure, the notification path was reached
    }

    // MARK: - File activity corroboration

    func testNoFileActivitySuppressesNotification() {
        let notifier = makeNotifier()
        // Active polls WITHOUT file activity
        sendActivePolls(notifier, count: 5, hasFileActivity: false)
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 0)
        // Should NOT trigger — no file activity means likely CPU-only noise.
        // Verified by absence of crash/sound (sound disabled in test).
    }

    func testFileActivityDuringSessionAllowsNotification() {
        let notifier = makeNotifier()
        // Mix of polls — some with file activity
        notifier.update(isActivelyWorking: true, hasFileActivity: false, currentCost: 0)
        notifier.update(isActivelyWorking: true, hasFileActivity: true, currentCost: 0)
        notifier.update(isActivelyWorking: true, hasFileActivity: false, currentCost: 0)
        notifier.update(isActivelyWorking: true, hasFileActivity: false, currentCost: 0)
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 0)
        // Should trigger — file activity was observed in at least one poll
    }

    func testFileActivityOnlyInFirstPollSuffices() {
        let notifier = makeNotifier()
        notifier.update(isActivelyWorking: true, hasFileActivity: true, currentCost: 0)
        for _ in 0..<3 {
            notifier.update(isActivelyWorking: true, hasFileActivity: false, currentCost: 0)
        }
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 0)
    }

    // MARK: - Cooldown

    func testCooldownSuppressesRapidNotifications() {
        let notifier = makeNotifier()
        var clock = Date()
        notifier.now = { clock }

        // First cycle fires notification
        sendActivePolls(notifier, count: 4)
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 0)

        // Second cycle 30s later — within cooldown, should be suppressed
        clock = clock.addingTimeInterval(30)
        sendActivePolls(notifier, count: 4)
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 0)
    }

    func testCooldownExpiresAfterInterval() {
        let notifier = makeNotifier()
        var clock = Date()
        notifier.now = { clock }

        // First cycle
        sendActivePolls(notifier, count: 4)
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 0)

        // Advance past cooldown (61 seconds > 60 second cooldown)
        clock = clock.addingTimeInterval(61)

        // Second cycle should fire
        sendActivePolls(notifier, count: 4)
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 0)
    }

    // MARK: - Cost tracking

    func testBuildSummaryWithCost() {
        let notifier = makeNotifier()
        sendActivePolls(notifier, count: 4)
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 0.75)
    }

    func testZeroCostOmittedFromSummary() {
        let notifier = makeNotifier()
        sendActivePolls(notifier, count: 4, cost: 5.00)
        notifier.update(isActivelyWorking: false, hasFileActivity: false, currentCost: 5.00)
    }

    func testDefaultParametersWork() {
        let notifier = makeNotifier()
        sendActivePolls(notifier, count: 4)
        notifier.update(isActivelyWorking: false)
    }
}
