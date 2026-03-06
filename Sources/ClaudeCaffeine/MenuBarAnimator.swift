import AppKit

@MainActor
final class MenuBarAnimator: NSObject {
    private weak var statusItem: NSStatusItem?
    private var animationTimer: Timer?
    private var isActive = false
    private var frameIndex = 0
    private var currentCost: Double = 0

    private static let activeFrames = ["bolt.circle", "bolt.circle.fill"]

    func configure(statusItem: NSStatusItem) {
        self.statusItem = statusItem
    }

    func update(isActive: Bool, todayCost: Double = 0) {
        currentCost = todayCost
        if isActive {
            startIfNeeded()
            tick()
        } else {
            stopAnimation()
            updateCostTitle(todayCost: todayCost)
        }
    }

    func updateCostTitle(todayCost: Double) {
        currentCost = todayCost
        statusItem?.button?.title = " \(formatCost(todayCost))"
    }

    func stop() {
        animationTimer?.invalidate()
        animationTimer = nil
        isActive = false
        frameIndex = 0
        currentCost = 0
        statusItem?.button?.title = ""
    }

    // MARK: - Private

    private func startIfNeeded() {
        if !isActive {
            isActive = true
            frameIndex = 0
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

    private func stopAnimation() {
        guard isActive else { return }
        animationTimer?.invalidate()
        animationTimer = nil
        isActive = false
    }

    @objc
    private func handleTimer() {
        if isActive {
            tick()
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private func tick() {
        guard let button = statusItem?.button else { return }

        let symbolName = Self.activeFrames[frameIndex % Self.activeFrames.count]
        frameIndex += 1

        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ClaudeCaffeine")
        button.image?.isTemplate = true
        button.title = " \(formatCost(currentCost))"
    }

    private func formatCost(_ cost: Double) -> String {
        String(format: "$%.2f", cost)
    }
}
