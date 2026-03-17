import Foundation

/// Applies CPU smoothing and hysteresis to raw process detection signals,
/// producing a stable active/idle state that resists oscillation from noisy
/// single-sample CPU readings.
///
/// The tracker maintains a sliding window of recent CPU samples and uses
/// separate enter/exit thresholds to create a dead zone that absorbs
/// fluctuations near the boundary.
@MainActor
final class SmoothedActivityTracker {
    enum ActivityState {
        case idle
        case active
    }

    struct Config {
        var cpuWindowSize: Int = 3
        var enterCPUThreshold: Double = 10.0
        var enterCPUWithConnectionsThreshold: Double = 3.0
        var exitCPUThreshold: Double = 2.0
        var requiredIdlePollsToExit: Int = 2
    }

    private(set) var state: ActivityState = .idle
    private var recentCPU: [Double] = []
    private var consecutiveIdlePolls = 0
    let config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    /// Records a new process status sample and returns the smoothed activity state.
    ///
    /// The raw `PollSnapshot.isClaudeActivelyWorking` is NOT used here — instead
    /// the tracker applies its own hysteresis logic to the underlying CPU and
    /// connection signals. The `hasFileActivity` flag allows ambiguous process
    /// states to count as active when corroborated by task directory changes.
    func update(processStatus: ClaudeProcessDetector.ProcessStatus, hasFileActivity: Bool) -> ActivityState {
        guard processStatus.isRunning else {
            recentCPU.removeAll()
            consecutiveIdlePolls = 0
            state = .idle
            return state
        }

        recentCPU.append(processStatus.cpuUsage)
        if recentCPU.count > config.cpuWindowSize {
            recentCPU.removeFirst()
        }

        let smoothedCPU = recentCPU.reduce(0, +) / Double(recentCPU.count)
        let hasConnections = processStatus.hasActiveConnections

        switch state {
        case .idle:
            consecutiveIdlePolls = 0
            if smoothedCPU > config.enterCPUThreshold
                || (hasConnections && smoothedCPU > config.enterCPUWithConnectionsThreshold) {
                state = .active
            } else if hasFileActivity && smoothedCPU > config.exitCPUThreshold {
                state = .active
            }

        case .active:
            if smoothedCPU < config.exitCPUThreshold && !hasConnections {
                consecutiveIdlePolls += 1
                if consecutiveIdlePolls >= config.requiredIdlePollsToExit {
                    state = .idle
                    consecutiveIdlePolls = 0
                }
            } else {
                consecutiveIdlePolls = 0
            }
        }

        return state
    }

    var smoothedCPU: Double {
        guard !recentCPU.isEmpty else { return 0 }
        return recentCPU.reduce(0, +) / Double(recentCPU.count)
    }

    func reset() {
        state = .idle
        recentCPU.removeAll()
        consecutiveIdlePolls = 0
    }
}
