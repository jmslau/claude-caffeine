import Foundation
import IOKit.ps

final class BatteryMonitor {
    struct Snapshot {
        let batteryLevel: Int
        let isCharging: Bool
        let hasBattery: Bool
    }

    let lowBatteryThreshold: Int

    init(lowBatteryThreshold: Int = 10) {
        self.lowBatteryThreshold = lowBatteryThreshold
    }

    var snapshot: Snapshot {
        Self.currentSnapshot()
    }

    var isBatteryLow: Bool {
        let snap = snapshot
        guard snap.hasBattery else { return false }
        return !snap.isCharging && snap.batteryLevel <= lowBatteryThreshold
    }

    static func currentSnapshot() -> Snapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return Snapshot(batteryLevel: 100, isCharging: false, hasBattery: false)
        }

        for item in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, item)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            guard let type = desc[kIOPSTypeKey] as? String, type == kIOPSInternalBatteryType else {
                continue
            }

            let capacity = desc[kIOPSCurrentCapacityKey] as? Int ?? 100
            let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false

            return Snapshot(batteryLevel: capacity, isCharging: isCharging, hasBattery: true)
        }

        return Snapshot(batteryLevel: 100, isCharging: false, hasBattery: false)
    }
}
