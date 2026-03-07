import Foundation
import OSLog

private let logger = Logger(subsystem: "com.jmslau.claudecaffeine", category: "closedLid")

struct ClosedLidReport: Equatable {
    let duration: TimeInterval
    let didSleepAfterIdle: Bool

    var durationText: String {
        let totalSeconds = Int(duration)
        if totalSeconds < 60 {
            return "\(totalSeconds) sec"
        } else if totalSeconds < 3600 {
            let mins = totalSeconds / 60
            let secs = totalSeconds % 60
            let minsText = mins == 1 ? "1 min" : "\(mins) mins"
            return secs > 0 ? "\(minsText) \(secs) sec" : minsText
        } else {
            let hours = totalSeconds / 3600
            let mins = (totalSeconds % 3600) / 60
            let hoursText = hours == 1 ? "1 hour" : "\(hours) hours"
            return mins > 0 ? "\(hoursText) \(mins) mins" : hoursText
        }
    }

    var message: String {
        var text = "Claude kept working for an extra \(durationText) while your laptop lid was closed."
        if didSleepAfterIdle {
            text += "\nYour Mac went to sleep after Claude went idle."
        }
        return text
    }
}

@MainActor
final class ClosedLidReporter {
    private(set) var activeStart: Date?
    private(set) var pendingDuration: TimeInterval?
    private(set) var didSleepAfterClosedLid = false

    let minimumDuration: TimeInterval

    init(minimumDuration: TimeInterval = 10) {
        self.minimumDuration = minimumDuration
    }

    func recordStart(now: Date = Date()) {
        if activeStart == nil {
            logger.info("Closed-lid tracking started")
            activeStart = now
        }
    }

    func recordEnd(now: Date = Date()) {
        guard let start = activeStart else { return }
        let duration = now.timeIntervalSince(start)
        activeStart = nil
        logger.info("Closed-lid tracking ended, duration=\(Int(duration))s, minimum=\(Int(self.minimumDuration))s")
        if duration >= minimumDuration {
            pendingDuration = duration
        }
    }

    func recordWake() {
        if pendingDuration != nil {
            didSleepAfterClosedLid = true
        }
    }

    /// Snapshots an in-progress session (e.g. when the lid is opened while Claude is still working).
    /// Resets tracking so the same period isn't reported again.
    func snapshotActive(now: Date = Date()) {
        guard let start = activeStart else { return }
        let duration = now.timeIntervalSince(start)
        activeStart = nil
        if duration >= minimumDuration {
            pendingDuration = duration
        }
    }

    func consumeReport() -> ClosedLidReport? {
        guard let duration = pendingDuration else { return nil }
        pendingDuration = nil
        let didSleep = didSleepAfterClosedLid
        didSleepAfterClosedLid = false
        return ClosedLidReport(duration: duration, didSleepAfterIdle: didSleep)
    }
}
