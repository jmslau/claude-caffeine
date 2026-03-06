import AppKit
import Foundation
import UserNotifications

@MainActor
final class TaskCompletionNotifier {
    var notificationsEnabled = true
    var soundEnabled = true

    private var wasActivelyWorking = false
    private var activeSessionStart: Date?
    private var sessionCostAtStart: Double = 0

    private let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    init() {
        requestNotificationPermission()
    }

    func update(isActivelyWorking: Bool, currentCost: Double = 0) {
        let transitionedToIdle = wasActivelyWorking && !isActivelyWorking

        if isActivelyWorking && !wasActivelyWorking {
            activeSessionStart = Date()
            sessionCostAtStart = currentCost
        }

        if transitionedToIdle {
            let costDelta = currentCost - sessionCostAtStart
            notifyTaskCompletion(sessionCost: costDelta)
            activeSessionStart = nil
            sessionCostAtStart = 0
        }

        wasActivelyWorking = isActivelyWorking
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
