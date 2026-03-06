import AppKit

@MainActor
final class MenuBarAnimator: NSObject {
    private weak var statusItem: NSStatusItem?
    private var animationTimer: Timer?
    private var accumulatedSeconds: TimeInterval = 0
    private var lastTickDate: Date?
    private var isActive = false
    private var frameIndex = 0

    private static let activeFrames = ["bolt.circle", "bolt.circle.fill"]

    private let elapsedFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()

    func configure(statusItem: NSStatusItem) {
        self.statusItem = statusItem
    }

    func update(isActive: Bool) {
        if isActive {
            startIfNeeded()
        } else {
            pause()
        }
    }

    // MARK: - Private

    private func startIfNeeded() {
        if !isActive {
            isActive = true
            lastTickDate = Date()
            if accumulatedSeconds == 0 {
                frameIndex = 0
            }
        }
        guard animationTimer == nil else { return }

        tick()
        animationTimer = Timer.scheduledTimer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(handleTimer),
            userInfo: nil,
            repeats: true
        )
    }

    /// Pause accumulation but keep the timer display and accumulated time.
    private func pause() {
        guard isActive else { return }
        // Flush any remaining time since the last tick
        if let last = lastTickDate {
            accumulatedSeconds += Date().timeIntervalSince(last)
        }
        isActive = false
        lastTickDate = nil
    }

    func stop() {
        animationTimer?.invalidate()
        animationTimer = nil
        accumulatedSeconds = 0
        lastTickDate = nil
        isActive = false
        frameIndex = 0
        statusItem?.button?.title = ""
    }

    @objc
    private func handleTimer() {
        if isActive {
            tick()
        } else {
            // Idle — stop the display timer to avoid wasting cycles
            animationTimer?.invalidate()
            animationTimer = nil
            statusItem?.button?.title = ""
        }
    }

    private func tick() {
        guard let button = statusItem?.button else { return }

        let now = Date()
        if let last = lastTickDate {
            accumulatedSeconds += now.timeIntervalSince(last)
        }
        lastTickDate = now

        let symbolName = Self.activeFrames[frameIndex % Self.activeFrames.count]
        frameIndex += 1

        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ClaudeCaffeine")
        button.image?.isTemplate = true

        button.title = " \(elapsedFormatter.string(from: max(accumulatedSeconds, 0)) ?? "0m 0s")"
    }
}
