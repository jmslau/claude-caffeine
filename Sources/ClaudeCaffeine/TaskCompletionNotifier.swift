import AppKit
import Foundation
import UserNotifications

@MainActor
final class TaskCompletionNotifier {
    var notificationsEnabled = true
    var soundEnabled = true

    private var wasActivelyWorking = false
    private var activeSessionStart: Date?

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

    func update(isActivelyWorking: Bool) {
        let transitionedToIdle = wasActivelyWorking && !isActivelyWorking

        if isActivelyWorking && !wasActivelyWorking {
            activeSessionStart = Date()
        }

        if transitionedToIdle {
            notifyTaskCompletion()
            activeSessionStart = nil
        }

        wasActivelyWorking = isActivelyWorking
    }

    // MARK: - Private

    private var notificationCenter: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    private func requestNotificationPermission() {
        notificationCenter?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyTaskCompletion() {
        if soundEnabled {
            NSSound(named: "Glass")?.play()
        }

        guard notificationsEnabled else { return }

        let durationText = formattedDuration()
        let content = UNMutableNotificationContent()
        content.title = "Claude Code finished working"
        content.body = "Task completed\(durationText)."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        notificationCenter?.add(request)
    }

    private func formattedDuration() -> String {
        guard let start = activeSessionStart else { return "" }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed >= 1, let text = durationFormatter.string(from: elapsed) else { return "" }
        return " after \(text)"
    }
}
