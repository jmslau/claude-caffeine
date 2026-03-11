import Foundation

final class ThermalMonitor {
    var isCritical: Bool {
        ProcessInfo.processInfo.thermalState == .critical
    }
}
