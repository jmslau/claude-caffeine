import Foundation
import UserNotifications

struct SessionEvent {
    let timestamp: Date
    let event: String
}

struct OvernightSummary {
    let duration: TimeInterval
    let events: [SessionEvent]
    let activeTime: TimeInterval
    let idleTime: TimeInterval
    let transitionCount: Int
}

@MainActor
final class OvernightMode {
    private(set) var isEnabled = false
    private(set) var startedAt: Date?
    private var sessionLog: [SessionEvent] = []
    private var wasActive = false
    private var lastTransitionAt: Date?
    private var accumulatedActiveTime: TimeInterval = 0
    private var accumulatedIdleTime: TimeInterval = 0
    private var transitions = 0

    private static let maxDuration: TimeInterval = 12 * 60 * 60

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()

    var statusText: String? {
        guard isEnabled, let startedAt else { return nil }
        return "Running since \(timeFormatter.string(from: startedAt))"
    }

    func start() {
        let now = Date()
        isEnabled = true
        startedAt = now
        sessionLog = []
        wasActive = false
        lastTransitionAt = now
        accumulatedActiveTime = 0
        accumulatedIdleTime = 0
        transitions = 0
        logEvent("Overnight mode started")
    }

    func stop() -> OvernightSummary {
        flushAccumulatedTime(now: Date())
        logEvent("Overnight mode stopped")
        let summary = OvernightSummary(
            duration: Date().timeIntervalSince(startedAt ?? Date()),
            events: sessionLog,
            activeTime: accumulatedActiveTime,
            idleTime: accumulatedIdleTime,
            transitionCount: transitions
        )
        isEnabled = false
        startedAt = nil
        sessionLog = []
        return summary
    }

    func update(isActivelyWorking: Bool, now: Date = Date()) {
        guard isEnabled else { return }

        if shouldAutoDisable(now: now) {
            let summary = stop()
            sendSummaryNotification(summary: summary, reason: "auto-disabled after 12h")
            return
        }

        if isActivelyWorking != wasActive {
            flushAccumulatedTime(now: now)
            transitions += 1
            let event = isActivelyWorking ? "Claude became active" : "Claude went idle"
            logEvent(event)
            wasActive = isActivelyWorking
            lastTransitionAt = now
        }
    }

    func sendSummaryNotification(summary: OvernightSummary, reason: String = "stopped") {
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let duration = durationFormatter.string(from: summary.duration) ?? "0m"
        let active = durationFormatter.string(from: summary.activeTime) ?? "0m"
        let idle = durationFormatter.string(from: summary.idleTime) ?? "0m"

        let content = UNMutableNotificationContent()
        content.title = "Overnight Mode Summary"
        content.body = "Duration: \(duration) | Active: \(active) | Idle: \(idle) | Transitions: \(summary.transitionCount)"
        content.sound = .default
        if #available(macOS 14.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        let request = UNNotificationRequest(identifier: "overnight-summary", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Private

    private func logEvent(_ event: String) {
        sessionLog.append(SessionEvent(timestamp: Date(), event: event))
    }

    private func flushAccumulatedTime(now: Date) {
        guard let last = lastTransitionAt else { return }
        let elapsed = now.timeIntervalSince(last)
        if wasActive {
            accumulatedActiveTime += elapsed
        } else {
            accumulatedIdleTime += elapsed
        }
        lastTransitionAt = now
    }

    private func shouldAutoDisable(now: Date) -> Bool {
        guard let startedAt else { return false }
        return now.timeIntervalSince(startedAt) >= Self.maxDuration
    }
}
