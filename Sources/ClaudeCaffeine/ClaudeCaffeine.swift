import AppKit
import Foundation
import UserNotifications

// Accessed from signal handler on an arbitrary thread — inherently racy but acceptable
// as best-effort cleanup during termination. forceDisable() performs a single shell call
// and a simple property write, minimising the race window.
nonisolated(unsafe) private var sharedClosedDisplayManager: ClosedDisplayManager?

@main
struct ClaudeCaffeine {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate

        installSignalHandlers()

        app.run()
    }

    private static func installSignalHandlers() {
        for sig: Int32 in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig) { _ in
                sharedClosedDisplayManager?.forceDisable()
                exit(0)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let activityMonitor = ClaudeTaskActivityMonitor()
    private let sleepAssertion = SleepAssertionManager()
    private let closedDisplayManager = ClosedDisplayManager()
    private let powerSourceMonitor = PowerSourceMonitor()
    private let batteryMonitor = BatteryMonitor()
    private let taskCompletionNotifier = TaskCompletionNotifier()
    private let menuBarAnimator = MenuBarAnimator()
    private let overnightMode = OvernightMode()
    private let costEstimator = SessionCostEstimator()

    /// How long a session can be idle before we release the sleep assertion.
    private let idleThreshold: TimeInterval = 60
    private let monitorFailureGracePeriod: TimeInterval = 30
    private var closedLidEnabled = true
    private var lowBatteryNotified = false
    private var preOvernightClosedLid = true

    private var statusItem: NSStatusItem?
    private var statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var processLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var sessionsLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var closedLidLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var lastCheckLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var closedLidToggleItem = NSMenuItem(
        title: "Enable Closed-Lid Mode",
        action: #selector(toggleClosedLid),
        keyEquivalent: ""
    )
    private var installHelperItem = NSMenuItem(
        title: "Install Helper…",
        action: #selector(installHelper),
        keyEquivalent: ""
    )
    private var uninstallHelperItem = NSMenuItem(
        title: "Uninstall Helper…",
        action: #selector(uninstallHelper),
        keyEquivalent: ""
    )
    private var notificationToggleItem = NSMenuItem(
        title: "Completion Notifications",
        action: #selector(toggleNotifications),
        keyEquivalent: ""
    )
    private var soundToggleItem = NSMenuItem(
        title: "Completion Sound",
        action: #selector(toggleSound),
        keyEquivalent: ""
    )
    private var overnightToggleItem = NSMenuItem(
        title: "Enable Overnight Mode",
        action: #selector(toggleOvernightMode),
        keyEquivalent: ""
    )
    private var overnightStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var costLineItem = NSMenuItem(title: "Cost: --", action: nil, keyEquivalent: "")
    private var costDetailLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var costByProjectItem = NSMenuItem(title: "Cost by Project", action: nil, keyEquivalent: "")
    private var costByProjectMenu = NSMenu()
    private var pollTimer: Timer?
    private var pollTask: Task<Void, Never>?
    private var isPollInFlight = false
    private var pollQueued = false
    private var lastSuccessfulPollAt: Date?
    private let idleFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        sharedClosedDisplayManager = closedDisplayManager

        setupMenuBar()
        menuBarAnimator.configure(statusItem: statusItem!)
        startPowerSourceMonitor()
        promptForHelperIfNeeded()
        refresh()
        pollTimer = Timer.scheduledTimer(
            timeInterval: 5,
            target: self,
            selector: #selector(handlePollTimer),
            userInfo: nil,
            repeats: true
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTask?.cancel()
        if overnightMode.isEnabled {
            _ = overnightMode.stop()
        }
        menuBarAnimator.stop()
        sleepAssertion.releaseAll()
        closedDisplayManager.forceDisable()
        powerSourceMonitor.stop()
    }

    // MARK: - Actions

    @objc
    private func handlePollTimer() {
        refresh()
    }

    @objc
    private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc
    private func toggleClosedLid() {
        guard HelperInstaller.isInstalled else {
            showAlert(
                title: "Helper Not Installed",
                message: "Closed-lid mode requires a privileged helper to control system sleep. Use \"Install Helper…\" first."
            )
            return
        }

        closedLidEnabled.toggle()
        if !closedLidEnabled {
            closedDisplayManager.disable()
        }
        lowBatteryNotified = false
        refresh()
    }

    @objc
    private func toggleNotifications() {
        taskCompletionNotifier.notificationsEnabled.toggle()
        notificationToggleItem.state = taskCompletionNotifier.notificationsEnabled ? .on : .off
    }

    @objc
    private func toggleSound() {
        taskCompletionNotifier.soundEnabled.toggle()
        soundToggleItem.state = taskCompletionNotifier.soundEnabled ? .on : .off
    }

    @objc
    private func toggleOvernightMode() {
        if overnightMode.isEnabled {
            let summary = overnightMode.stop()
            overnightMode.sendSummaryNotification(summary: summary, reason: "manually stopped")
            closedLidEnabled = preOvernightClosedLid
        } else {
            preOvernightClosedLid = closedLidEnabled
            if HelperInstaller.isInstalled {
                closedLidEnabled = true
            }
            overnightMode.start()
        }
        updateOvernightMenu()
        updateClosedLidMenu()
        refresh()
    }

    @objc
    private func installHelper() {
        do {
            try HelperInstaller.install()
            closedLidEnabled = true
            showAlert(
                title: "Helper Installed",
                message: "Closed-lid mode has been enabled."
            )
        } catch {
            showAlert(
                title: "Installation Failed",
                message: error.localizedDescription
            )
        }
        updateClosedLidMenu()
        refresh()
    }

    @objc
    private func uninstallHelper() {
        closedLidEnabled = false
        do {
            try HelperInstaller.uninstall()
            showAlert(
                title: "Helper Uninstalled",
                message: "The privileged helper has been removed. Closed-lid mode is no longer available."
            )
        } catch {
            showAlert(
                title: "Uninstall Failed",
                message: error.localizedDescription
            )
        }
        updateClosedLidMenu()
        refresh()
    }

    // MARK: - Menu

    private func setupMenuBar() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        let menu = NSMenu()
        statusLineItem.isEnabled = false
        processLineItem.isEnabled = false
        sessionsLineItem.isEnabled = false
        closedLidLineItem.isEnabled = false
        lastCheckLineItem.isEnabled = false
        menu.addItem(statusLineItem)
        menu.addItem(processLineItem)
        menu.addItem(sessionsLineItem)
        menu.addItem(closedLidLineItem)
        menu.addItem(lastCheckLineItem)
        menu.addItem(.separator())

        costLineItem.isEnabled = false
        costDetailLineItem.isEnabled = false
        costDetailLineItem.isHidden = true
        menu.addItem(costLineItem)
        menu.addItem(costDetailLineItem)
        costByProjectItem.isHidden = true
        menu.setSubmenu(costByProjectMenu, for: costByProjectItem)
        menu.addItem(costByProjectItem)
        menu.addItem(.separator())

        let closedLidMenu = NSMenu()
        closedLidToggleItem.target = self
        closedLidMenu.addItem(closedLidToggleItem)
        closedLidMenu.addItem(.separator())
        installHelperItem.target = self
        closedLidMenu.addItem(installHelperItem)
        uninstallHelperItem.target = self
        closedLidMenu.addItem(uninstallHelperItem)
        let closedLidParent = NSMenuItem(title: "Closed-Lid Mode", action: nil, keyEquivalent: "")
        menu.setSubmenu(closedLidMenu, for: closedLidParent)
        menu.addItem(closedLidParent)

        let notificationsMenu = NSMenu()
        notificationToggleItem.target = self
        notificationToggleItem.state = .on
        notificationsMenu.addItem(notificationToggleItem)
        soundToggleItem.target = self
        soundToggleItem.state = .on
        notificationsMenu.addItem(soundToggleItem)
        let notificationsParent = NSMenuItem(title: "Notifications", action: nil, keyEquivalent: "")
        menu.setSubmenu(notificationsMenu, for: notificationsParent)
        menu.addItem(notificationsParent)

        let overnightMenu = NSMenu()
        overnightToggleItem.target = self
        overnightMenu.addItem(overnightToggleItem)
        overnightStatusItem.isEnabled = false
        overnightStatusItem.isHidden = true
        overnightMenu.addItem(overnightStatusItem)
        let overnightParent = NSMenuItem(title: "Overnight Mode", action: nil, keyEquivalent: "")
        menu.setSubmenu(overnightMenu, for: overnightParent)
        menu.addItem(overnightParent)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit ClaudeCaffeine", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateClosedLidMenu()
    }

    private func updateClosedLidMenu() {
        let installed = HelperInstaller.isInstalled
        closedLidToggleItem.state = closedLidEnabled ? .on : .off
        closedLidToggleItem.isEnabled = installed
        closedLidToggleItem.title = installed ? "Enable Closed-Lid Mode" : "Enable Closed-Lid Mode (helper required)"
        installHelperItem.isHidden = installed
        uninstallHelperItem.isHidden = !installed
    }

    private func updateOvernightMenu() {
        let enabled = overnightMode.isEnabled
        overnightToggleItem.state = enabled ? .on : .off
        overnightToggleItem.title = enabled ? "Disable Overnight Mode" : "Enable Overnight Mode"
        if let status = overnightMode.statusText {
            overnightStatusItem.title = status
            overnightStatusItem.isHidden = false
        } else {
            overnightStatusItem.isHidden = true
        }
    }

    // MARK: - Power source monitoring

    private func startPowerSourceMonitor() {
        powerSourceMonitor.start { [weak self] in
            DispatchQueue.main.async {
                self?.handlePowerSourceChange()
            }
        }
    }

    private func handlePowerSourceChange() {
        guard closedLidEnabled, closedDisplayManager.isEnabled else { return }
        closedDisplayManager.reassert()
    }

    // MARK: - First-run helper prompt

    private func promptForHelperIfNeeded() {
        guard !HelperInstaller.isInstalled else { return }

        let alert = NSAlert()
        alert.messageText = "Install Closed-Lid Helper?"
        alert.informativeText = "ClaudeCaffeine can prevent your Mac from sleeping when you close the lid while Claude Code is working. This requires a small privileged helper. You can install or remove it later from the menu."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            do {
                try HelperInstaller.install()
                closedLidEnabled = true
            } catch {
                closedLidEnabled = false
                showAlert(title: "Installation Failed", message: error.localizedDescription)
            }
        } else {
            closedLidEnabled = false
        }
        updateClosedLidMenu()
    }

    // MARK: - Poll loop

    private func refresh() {
        guard !isPollInFlight else {
            pollQueued = true
            return
        }

        isPollInFlight = true
        let activityMonitor = self.activityMonitor
        let idleThreshold = self.idleThreshold
        pollTask = Task.detached(priority: .utility) { [activityMonitor, weak self] in
            let pollDate = Date()
            let snapshot = activityMonitor.poll(now: pollDate, idleThreshold: idleThreshold)
            await MainActor.run { [weak self] in
                self?.applyPoll(snapshot: snapshot, now: pollDate)
            }
        }
    }

    private func applyPoll(snapshot: ClaudeTaskActivityMonitor.PollSnapshot, now: Date) {
        defer {
            isPollInFlight = false
            pollTask = nil
            if pollQueued {
                pollQueued = false
                refresh()
            }
        }

        let activeSessions = snapshot.activeSessions
        let proc = snapshot.processStatus
        let isActivelyWorking = snapshot.isClaudeActivelyWorking
        var hasWarning = false
        var statusText: String
        var sessionsText: String

        let processText: String
        if proc.isActivelyWorking {
            processText = "Process: active (PIDs: \(proc.pids.map(String.init).joined(separator: ",")), CPU: \(String(format: "%.1f", proc.cpuUsage))%, net: connected)"
        } else if proc.isWaitingForInput {
            processText = "Process: idle at prompt (PIDs: \(proc.pids.map(String.init).joined(separator: ",")), CPU: \(String(format: "%.1f", proc.cpuUsage))%)"
        } else {
            processText = "Process: not running"
        }

        switch snapshot.status {
        case .ok:
            lastSuccessfulPollAt = now
            if isActivelyWorking {
                sleepAssertion.holdIfNeeded(reason: "Keeping Mac awake while Claude Code is actively working")
            } else {
                sleepAssertion.releaseAll()
            }
            statusText = sleepAssertion.isHeld ? "awake lock active" : "no lock"
            sessionsText = "Active sessions: \(activeSessions.count) (oldest idle \(oldestIdleText(from: activeSessions)))"
        case .tasksRootMissing:
            hasWarning = true
            if proc.isActivelyWorking {
                sleepAssertion.holdIfNeeded(reason: "Keeping Mac awake while Claude Code is actively working")
                statusText = "tasks folder missing; awake lock active (process detected)"
            } else {
                statusText = "tasks folder missing; \(lockStateDuringFailure(now: now))"
            }
            sessionsText = "Active sessions: unknown (missing ~/.claude/tasks)"
        case .ioError:
            hasWarning = true
            if isActivelyWorking {
                sleepAssertion.holdIfNeeded(reason: "Keeping Mac awake while Claude Code is actively working")
                statusText = "scan warning; awake lock active"
                sessionsText = activeSessions.isEmpty
                    ? "Active sessions: unknown (process detected)"
                    : "Active sessions: \(activeSessions.count)/\(snapshot.totalSessions) (partial scan)"
            } else {
                statusText = "scan warning; \(lockStateDuringFailure(now: now))"
                sessionsText = "Active sessions: unknown (filesystem read error)"
            }
        }

        applyClosedLidState(hasActiveSessions: isActivelyWorking)

        statusLineItem.title = "Status: \(statusText)"
        processLineItem.title = processText
        sessionsLineItem.title = sessionsText
        lastCheckLineItem.title = "Last check: \(DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .medium))"
        updateClosedLidMenu()
        updateCostDisplay()
        let todayCost = lastCostSnapshot?.todayCost ?? 0
        menuBarAnimator.update(isActive: isActivelyWorking, todayCost: todayCost)
        updateMenuBarIcon(
            isKeepingAwake: sleepAssertion.isHeld,
            closedLidActive: closedLidEnabled,
            hasWarning: hasWarning
        )
        taskCompletionNotifier.update(isActivelyWorking: isActivelyWorking, currentCost: todayCost)

        if overnightMode.isEnabled {
            overnightMode.update(isActivelyWorking: isActivelyWorking, now: now)
            updateOvernightMenu()
            if !overnightMode.isEnabled {
                closedLidEnabled = preOvernightClosedLid
                updateClosedLidMenu()
            }
        }
    }

    // MARK: - Closed-lid logic

    private func applyClosedLidState(hasActiveSessions: Bool) {
        guard closedLidEnabled else {
            if closedDisplayManager.isEnabled {
                closedDisplayManager.disable()
            }
            closedLidLineItem.title = "Closed-lid: disabled"
            return
        }

        if batteryMonitor.isBatteryLow {
            if closedDisplayManager.isEnabled {
                closedDisplayManager.disable()
            }
            if !lowBatteryNotified {
                lowBatteryNotified = true
                sendNotification(
                    title: "Closed-Lid Mode Suspended",
                    body: "Battery is at \(batteryMonitor.snapshot.batteryLevel)%. Closed-lid sleep prevention paused to conserve power."
                )
            }
            closedLidLineItem.title = "Closed-lid: suspended (low battery \(batteryMonitor.snapshot.batteryLevel)%)"
            return
        }

        lowBatteryNotified = false

        if hasActiveSessions {
            if !closedDisplayManager.isEnabled {
                closedDisplayManager.enable()
            }
            closedLidLineItem.title = "Closed-lid: active (preventing sleep)"
        } else {
            if closedDisplayManager.isEnabled {
                closedDisplayManager.disable()
            }
            closedLidLineItem.title = "Closed-lid: standby (no active sessions)"
        }
    }

    // MARK: - Cost display

    private var lastCostSnapshot: CostSnapshot?
    private var lastCostRefreshAt: Date?
    private let costRefreshInterval: TimeInterval = 30

    private func updateCostDisplay() {
        let now = Date()
        if let lastRefresh = lastCostRefreshAt, now.timeIntervalSince(lastRefresh) < costRefreshInterval,
           lastCostSnapshot != nil {
            return
        }
        lastCostRefreshAt = now
        let snapshot = costEstimator.estimateCosts(now: now)
        lastCostSnapshot = snapshot
        costLineItem.title = "Cost today: \(formatCost(snapshot.todayCost)) (\(snapshot.todaySessions) sessions)"
        if snapshot.weekCost > snapshot.todayCost {
            costDetailLineItem.title = "Cost this week: \(formatCost(snapshot.weekCost)) (\(snapshot.weekSessions) sessions)"
            costDetailLineItem.isHidden = false
        } else {
            costDetailLineItem.isHidden = true
        }

        costByProjectMenu.removeAllItems()
        if snapshot.projectCosts.isEmpty {
            costByProjectItem.isHidden = true
        } else {
            costByProjectItem.isHidden = false
            for project in snapshot.projectCosts {
                let name = displayName(for: project.projectName)
                var label = "\(name): \(formatCost(project.todayCost)) (\(project.todaySessions) sessions)"
                if project.weekCost > project.todayCost {
                    label += " · week: \(formatCost(project.weekCost))"
                }
                let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                item.isEnabled = false
                costByProjectMenu.addItem(item)
            }
        }
    }

    private func displayName(for projectPath: String) -> String {
        let decoded = projectPath.replacingOccurrences(of: "-", with: "/")
        return (decoded as NSString).lastPathComponent
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 { return "$0.00" }
        return String(format: "$%.2f", cost)
    }

    // MARK: - Helpers

    private func lockStateDuringFailure(now: Date) -> String {
        guard sleepAssertion.isHeld else {
            return "no lock"
        }
        guard let lastSuccessfulPollAt else {
            sleepAssertion.releaseIfHeld()
            return "lock released"
        }

        let elapsed = now.timeIntervalSince(lastSuccessfulPollAt)
        guard elapsed <= monitorFailureGracePeriod else {
            sleepAssertion.releaseIfHeld()
            return "lock released"
        }

        let remaining = monitorFailureGracePeriod - elapsed
        return "keeping lock for \(durationText(for: remaining)) grace"
    }

    private func oldestIdleText(from activeSessions: [ClaudeTaskActivityMonitor.SessionActivity]) -> String {
        guard let oldest = activeSessions.max(by: { $0.idleFor < $1.idleFor }) else {
            return "n/a"
        }
        return durationText(for: oldest.idleFor)
    }

    private func durationText(for duration: TimeInterval) -> String {
        idleFormatter.string(from: max(duration, 0)) ?? "0s"
    }

    private func updateMenuBarIcon(isKeepingAwake: Bool, closedLidActive: Bool, hasWarning: Bool) {
        guard let button = statusItem?.button else {
            return
        }

        // When the animator is running it controls the icon and title — skip static updates
        if isKeepingAwake && !hasWarning {
            return
        }

        let symbolName: String
        if hasWarning {
            symbolName = "exclamationmark.triangle"
        } else if closedLidActive {
            symbolName = "lock.laptopcomputer"
        } else {
            symbolName = "moon.zzz"
        }

        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ClaudeCaffeine")
        button.image?.isTemplate = true

        let todayCost = lastCostSnapshot?.todayCost ?? 0
        menuBarAnimator.updateCostTitle(todayCost: todayCost)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func sendNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
