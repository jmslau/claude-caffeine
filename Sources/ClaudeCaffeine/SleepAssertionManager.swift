import Foundation
import IOKit.pwr_mgt

final class SleepAssertionManager {
    private var systemAssertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private(set) var isHeld = false
    private(set) var isDisplayHeld = false

    func holdIfNeeded(reason: String) {
        guard !isHeld else {
            return
        }

        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &systemAssertionID
        )

        if result == kIOReturnSuccess {
            isHeld = true
        }
    }

    func releaseIfHeld() {
        guard isHeld else {
            return
        }

        IOPMAssertionRelease(systemAssertionID)
        systemAssertionID = 0
        isHeld = false
    }

    func holdDisplayIfNeeded(reason: String) {
        guard !isDisplayHeld else {
            return
        }

        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &displayAssertionID
        )

        if result == kIOReturnSuccess {
            isDisplayHeld = true
        }
    }

    func releaseDisplayIfHeld() {
        guard isDisplayHeld else {
            return
        }

        IOPMAssertionRelease(displayAssertionID)
        displayAssertionID = 0
        isDisplayHeld = false
    }

    func releaseAll() {
        releaseIfHeld()
        releaseDisplayIfHeld()
    }

    deinit {
        releaseAll()
    }
}
