import AppKit
import Foundation
import UserNotifications

@MainActor
final class TaskCompletionNotifier {
    var notificationsEnabled = true
    var soundEnabled = true

    private var consecutiveActivePolls = 0
    private var activeSessionStart: Date?
    private var sessionCostAtStart: Double = 0
    private var hadFileActivityDuringSession = false
    private var lastNotificationTime: Date?

    /// Minimum consecutive active polls before a completion notification can fire.
    /// Set to 4 (20 seconds at 5s polling) to allow the CPU smoothing window to
    /// stabilize before a transition can trigger a notification.
    private let requiredActivePolls = 4

    /// Suppress rapid-fire notifications caused by residual state oscillation.
    let cooldownInterval: TimeInterval = 60

    private let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    /// Injectable clock for testing cooldown behavior.
    var now: () -> Date = { Date() }

    init() {
        requestNotificationPermission()
    }

    /// Called every poll with the smoothed activity state.
    ///
    /// - Parameters:
    ///   - isActivelyWorking: Smoothed active/idle signal from `SmoothedActivityTracker`.
    ///   - hasFileActivity: Whether `~/.claude/tasks/` had recent file modifications this poll.
    ///   - currentCost: Cumulative session cost for display in the notification.
    func update(isActivelyWorking: Bool, hasFileActivity: Bool = false, currentCost: Double = 0) {
        if isActivelyWorking {
            if consecutiveActivePolls == 0 {
                activeSessionStart = Date()
                sessionCostAtStart = currentCost
                hadFileActivityDuringSession = false
            }
            if hasFileActivity { hadFileActivityDuringSession = true }
            consecutiveActivePolls += 1
            return
        }

        guard consecutiveActivePolls > 0 else { return }
        let hadEnoughActivePolls = consecutiveActivePolls >= requiredActivePolls
        consecutiveActivePolls = 0

        guard hadEnoughActivePolls else {
            activeSessionStart = nil
            sessionCostAtStart = 0
            hadFileActivityDuringSession = false
            return
        }

        guard hadFileActivityDuringSession else {
            activeSessionStart = nil
            sessionCostAtStart = 0
            hadFileActivityDuringSession = false
            return
        }

        let currentTime = now()
        if let last = lastNotificationTime, currentTime.timeIntervalSince(last) < cooldownInterval {
            activeSessionStart = nil
            sessionCostAtStart = 0
            hadFileActivityDuringSession = false
            return
        }

        let costDelta = currentCost - sessionCostAtStart
        notifyTaskCompletion(sessionCost: costDelta)
        lastNotificationTime = currentTime
        activeSessionStart = nil
        sessionCostAtStart = 0
        hadFileActivityDuringSession = false
    }

    // MARK: - Private

    private var notificationCenter: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundlePath.hasSuffix(".app") else { return nil }
        return UNUserNotificationCenter.current()
    }

    private func requestNotificationPermission() {
        notificationCenter?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyTaskCompletion(sessionCost: Double) {
        if soundEnabled {
            NSSound(named: "Glass")?.play()
        }

        guard notificationsEnabled else { return }

        let body = buildSummary(sessionCost: sessionCost)
        let content = UNMutableNotificationContent()
        content.title = "Claude Code finished working"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        notificationCenter?.add(request)
    }

    private func buildSummary(sessionCost: Double) -> String {
        var parts: [String] = []

        if let durationText = formattedDuration() {
            parts.append(durationText)
        }

        if sessionCost >= 0.01 {
            parts.append(String(format: "$%.2f", sessionCost))
        }

        if parts.isEmpty {
            return "Task completed."
        }
        return "Task completed — \(parts.joined(separator: " · "))."
    }

    private func formattedDuration() -> String? {
        guard let start = activeSessionStart else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed >= 1, let text = durationFormatter.string(from: elapsed) else { return nil }
        return text
    }
}
