import CoreGraphics
import Foundation

final class DisplayBrightnessManager {
    private var savedBrightness: Float?

    // DisplayServices private framework function signatures
    private typealias GetBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32

    /// Closures wrapping brightness get/set. Using closures allows test injection.
    private let _getBrightness: ((CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)?
    private let _setBrightness: ((CGDirectDisplayID, Float) -> Int32)?

    init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_NOW) else {
            _getBrightness = nil
            _setBrightness = nil
            debugLog("init: failed to load DisplayServices framework")
            return
        }

        let getSym = dlsym(handle, "DisplayServicesGetBrightness")
        let setSym = dlsym(handle, "DisplayServicesSetBrightness")
        let getFunc = getSym.map { unsafeBitCast($0, to: GetBrightnessFunc.self) }
        let setFunc = setSym.map { unsafeBitCast($0, to: SetBrightnessFunc.self) }
        _getBrightness = getFunc.map { fn in { fn($0, $1) } }
        _setBrightness = setFunc.map { fn in { fn($0, $1) } }
        debugLog("init: DisplayServices loaded (get=\(getFunc != nil), set=\(setFunc != nil))")
    }

    /// Test-only initializer with injected brightness functions.
    init(
        getBrightness: ((CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)?,
        setBrightness: ((CGDirectDisplayID, Float) -> Int32)?
    ) {
        _getBrightness = getBrightness
        _setBrightness = setBrightness
    }

    /// Dims the built-in display to minimum brightness, saving the current level.
    /// No-op if brightness was already saved (idempotent).
    func dim() {
        guard savedBrightness == nil else { return }
        guard let getBrightness = _getBrightness, let setBrightness = _setBrightness else { return }

        let displayID = CGMainDisplayID()
        var current: Float = 0
        guard getBrightness(displayID, &current) == 0 else { return }

        savedBrightness = current
        _ = setBrightness(displayID, 0)
        debugLog("dim: saved=\(current)")
    }

    /// Restores the display brightness to the level saved by `dim()`.
    /// No-op if `dim()` was never called or already restored.
    func restore() {
        guard let brightness = savedBrightness else { return }
        savedBrightness = nil
        guard let setBrightness = _setBrightness else { return }

        _ = setBrightness(CGMainDisplayID(), brightness)
        debugLog("restore: brightness=\(brightness)")
    }

    var isDimmed: Bool { savedBrightness != nil }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[brightness] \(message)")
        #endif
    }
}
