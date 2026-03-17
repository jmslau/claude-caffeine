import Foundation
import XCTest
@testable import ClaudeCaffeine

@MainActor
final class SmoothedActivityTrackerTests: XCTestCase {

    private func makeStatus(
        cpu: Double,
        connections: Bool = false,
        pids: [Int32] = [1]
    ) -> ClaudeProcessDetector.ProcessStatus {
        ClaudeProcessDetector.ProcessStatus(
            isRunning: true,
            hasActiveConnections: connections,
            cpuUsage: cpu,
            pids: pids
        )
    }

    // MARK: - Idle → Active transitions

    func testHighCPUTransitionsToActive() {
        let tracker = SmoothedActivityTracker()

        let state = tracker.update(processStatus: makeStatus(cpu: 15), hasFileActivity: false)
        XCTAssertEqual(state, .active)
    }

    func testModestCPUWithConnectionsTransitionsToActive() {
        let tracker = SmoothedActivityTracker()

        let state = tracker.update(processStatus: makeStatus(cpu: 5, connections: true), hasFileActivity: false)
        XCTAssertEqual(state, .active)
    }

    func testLowCPUWithConnectionsStaysIdle() {
        let tracker = SmoothedActivityTracker()

        let state = tracker.update(processStatus: makeStatus(cpu: 2, connections: true), hasFileActivity: false)
        XCTAssertEqual(state, .idle)
    }

    func testModerateCPUAloneStaysIdle() {
        let tracker = SmoothedActivityTracker()

        let state = tracker.update(processStatus: makeStatus(cpu: 7), hasFileActivity: false)
        XCTAssertEqual(state, .idle)
    }

    func testFileActivityWithModerateCPUTransitionsToActive() {
        let tracker = SmoothedActivityTracker()

        let state = tracker.update(processStatus: makeStatus(cpu: 5), hasFileActivity: true)
        XCTAssertEqual(state, .active)
    }

    func testFileActivityWithVeryLowCPUStaysIdle() {
        let tracker = SmoothedActivityTracker()

        let state = tracker.update(processStatus: makeStatus(cpu: 1.5), hasFileActivity: true)
        XCTAssertEqual(state, .idle)
    }

    // MARK: - Active → Idle transitions (hysteresis)

    func testStaysActiveUntilEnoughIdlePolls() {
        let tracker = SmoothedActivityTracker()

        // Enter active
        tracker.update(processStatus: makeStatus(cpu: 15), hasFileActivity: false)
        XCTAssertEqual(tracker.state, .active)

        // First idle poll — smoothed CPU still high from window [15, 0.5]
        let state1 = tracker.update(processStatus: makeStatus(cpu: 0.5), hasFileActivity: false)
        XCTAssertEqual(state1, .active)

        // More idle polls to flush the window: [15, 0.5, 0.5] → avg 5.33, still > 2
        tracker.update(processStatus: makeStatus(cpu: 0.5), hasFileActivity: false)
        XCTAssertEqual(tracker.state, .active)

        // Window now [0.5, 0.5, 0.5] → avg 0.5 < 2.0 → consecutiveIdlePolls = 1
        tracker.update(processStatus: makeStatus(cpu: 0.5), hasFileActivity: false)
        XCTAssertEqual(tracker.state, .active)

        // consecutiveIdlePolls = 2 → exits
        let stateFinal = tracker.update(processStatus: makeStatus(cpu: 0.5), hasFileActivity: false)
        XCTAssertEqual(stateFinal, .idle)
    }

    func testActiveConnectionsPreventsExitEvenWithLowCPU() {
        let tracker = SmoothedActivityTracker()

        tracker.update(processStatus: makeStatus(cpu: 15), hasFileActivity: false)
        XCTAssertEqual(tracker.state, .active)

        // Low CPU but connections present — stays active
        tracker.update(processStatus: makeStatus(cpu: 0.5, connections: true), hasFileActivity: false)
        tracker.update(processStatus: makeStatus(cpu: 0.5, connections: true), hasFileActivity: false)
        XCTAssertEqual(tracker.state, .active)
    }

    func testIdlePollCounterResetsOnActivitySpike() {
        // Use windowSize=1 to isolate hysteresis behavior from smoothing
        let config = SmoothedActivityTracker.Config(
            cpuWindowSize: 1,
            enterCPUThreshold: 10,
            exitCPUThreshold: 2,
            requiredIdlePollsToExit: 2
        )
        let tracker = SmoothedActivityTracker(config: config)

        tracker.update(processStatus: makeStatus(cpu: 15), hasFileActivity: false)
        XCTAssertEqual(tracker.state, .active)

        // One idle poll — consecutiveIdlePolls = 1
        tracker.update(processStatus: makeStatus(cpu: 0.5), hasFileActivity: false)
        XCTAssertEqual(tracker.state, .active)

        // Activity spike resets the idle counter
        tracker.update(processStatus: makeStatus(cpu: 8), hasFileActivity: false)
        XCTAssertEqual(tracker.state, .active)

        // Need two fresh idle polls again
        tracker.update(processStatus: makeStatus(cpu: 0.5), hasFileActivity: false)
        XCTAssertEqual(tracker.state, .active)
        tracker.update(processStatus: makeStatus(cpu: 0.5), hasFileActivity: false)
        XCTAssertEqual(tracker.state, .idle)
    }

    // MARK: - CPU smoothing

    func testSmoothingAveragesOverWindow() {
        let config = SmoothedActivityTracker.Config(cpuWindowSize: 3, enterCPUThreshold: 10)
        let tracker = SmoothedActivityTracker(config: config)

        // 3 samples: 4, 4, 15 → average = 7.67 → below 10, stays idle
        tracker.update(processStatus: makeStatus(cpu: 4), hasFileActivity: false)
        tracker.update(processStatus: makeStatus(cpu: 4), hasFileActivity: false)
        let state = tracker.update(processStatus: makeStatus(cpu: 15), hasFileActivity: false)
        XCTAssertEqual(state, .idle)
    }

    func testSmoothingWindowSlides() {
        let config = SmoothedActivityTracker.Config(cpuWindowSize: 3, enterCPUThreshold: 10)
        let tracker = SmoothedActivityTracker(config: config)

        // Fill window: 4, 15, 15 → average = 11.33 → enters active
        tracker.update(processStatus: makeStatus(cpu: 4), hasFileActivity: false)
        tracker.update(processStatus: makeStatus(cpu: 15), hasFileActivity: false)
        let state = tracker.update(processStatus: makeStatus(cpu: 15), hasFileActivity: false)
        XCTAssertEqual(state, .active)
    }

    func testSmallSpikeSmoothedOutDoesNotTransition() {
        let config = SmoothedActivityTracker.Config(cpuWindowSize: 3, enterCPUThreshold: 10)
        let tracker = SmoothedActivityTracker(config: config)

        // A moderate spike of 12 surrounded by low values keeps the average below
        // the enter threshold: [2, 12] → avg 7, [2, 12, 2] → avg 5.33 → stays idle
        tracker.update(processStatus: makeStatus(cpu: 2), hasFileActivity: false)
        tracker.update(processStatus: makeStatus(cpu: 12), hasFileActivity: false)
        XCTAssertEqual(tracker.state, .idle)
        let state = tracker.update(processStatus: makeStatus(cpu: 2), hasFileActivity: false)
        XCTAssertEqual(state, .idle)
    }

    func testLargeSpikeTransitionsWhenWindowPartiallyFilled() {
        let config = SmoothedActivityTracker.Config(cpuWindowSize: 3, enterCPUThreshold: 10)
        let tracker = SmoothedActivityTracker(config: config)

        // A very large spike fills partial window above threshold: [2, 20] → avg 11 → active
        tracker.update(processStatus: makeStatus(cpu: 2), hasFileActivity: false)
        XCTAssertEqual(tracker.state, .idle)
        tracker.update(processStatus: makeStatus(cpu: 20), hasFileActivity: false)
        XCTAssertEqual(tracker.state, .active)
    }

    // MARK: - Process not running

    func testNotRunningResetsToIdle() {
        let tracker = SmoothedActivityTracker()

        // Enter active
        tracker.update(processStatus: makeStatus(cpu: 15), hasFileActivity: false)
        XCTAssertEqual(tracker.state, .active)

        // Process disappears
        let state = tracker.update(processStatus: .notRunning, hasFileActivity: false)
        XCTAssertEqual(state, .idle)
    }

    func testNotRunningClearsSmoothing() {
        let tracker = SmoothedActivityTracker()

        tracker.update(processStatus: makeStatus(cpu: 15), hasFileActivity: false)
        tracker.update(processStatus: .notRunning, hasFileActivity: false)

        XCTAssertEqual(tracker.smoothedCPU, 0)
    }

    // MARK: - Dead zone (the key oscillation fix)

    func testCPUFluctuatingInDeadZoneDoesNotOscillate() {
        let tracker = SmoothedActivityTracker()

        // Hover around 5-8% — should stay idle (below 10% enter threshold)
        for cpu in [5.0, 7.0, 6.0, 8.0, 5.0, 7.0, 6.0] {
            tracker.update(processStatus: makeStatus(cpu: cpu), hasFileActivity: false)
        }
        XCTAssertEqual(tracker.state, .idle)
    }

    func testCPUFluctuatingInDeadZoneWhileActiveStaysActive() {
        let tracker = SmoothedActivityTracker()

        // Enter active with clear signal
        tracker.update(processStatus: makeStatus(cpu: 20), hasFileActivity: false)
        tracker.update(processStatus: makeStatus(cpu: 20), hasFileActivity: false)
        tracker.update(processStatus: makeStatus(cpu: 20), hasFileActivity: false)
        XCTAssertEqual(tracker.state, .active)

        // CPU drops to dead zone (3-9%) — should stay active (above 2% exit threshold)
        for cpu in [5.0, 7.0, 4.0, 6.0, 5.0] {
            tracker.update(processStatus: makeStatus(cpu: cpu), hasFileActivity: false)
        }
        XCTAssertEqual(tracker.state, .active)
    }

    // MARK: - Reset

    func testResetClearsAllState() {
        let tracker = SmoothedActivityTracker()

        tracker.update(processStatus: makeStatus(cpu: 15), hasFileActivity: false)
        XCTAssertEqual(tracker.state, .active)

        tracker.reset()
        XCTAssertEqual(tracker.state, .idle)
        XCTAssertEqual(tracker.smoothedCPU, 0)
    }

    // MARK: - Custom config

    func testCustomThresholds() {
        let config = SmoothedActivityTracker.Config(
            cpuWindowSize: 1,
            enterCPUThreshold: 5,
            exitCPUThreshold: 1,
            requiredIdlePollsToExit: 1
        )
        let tracker = SmoothedActivityTracker(config: config)

        let state1 = tracker.update(processStatus: makeStatus(cpu: 6), hasFileActivity: false)
        XCTAssertEqual(state1, .active)

        let state2 = tracker.update(processStatus: makeStatus(cpu: 0.5), hasFileActivity: false)
        XCTAssertEqual(state2, .idle)
    }

    // MARK: - @discardableResult is not needed but we silence warnings

    @discardableResult
    private func advance(_ tracker: SmoothedActivityTracker, cpu: Double, connections: Bool = false, fileActivity: Bool = false) -> SmoothedActivityTracker.ActivityState {
        tracker.update(processStatus: makeStatus(cpu: cpu, connections: connections), hasFileActivity: fileActivity)
    }
}
