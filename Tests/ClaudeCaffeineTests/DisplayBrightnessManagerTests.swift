import CoreGraphics
import Foundation
import XCTest
@testable import ClaudeCaffeine

final class DisplayBrightnessManagerTests: XCTestCase {

    /// Creates a manager with fake get/set that track calls via closures.
    private func makeManager(
        currentBrightness: Float = 0.75,
        getResult: Int32 = 0,
        setResult: Int32 = 0,
        onSet: @escaping (Float) -> Void = { _ in }
    ) -> DisplayBrightnessManager {
        let get: (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32 = { _, ptr in
            ptr.pointee = currentBrightness
            return getResult
        }
        let set: (CGDirectDisplayID, Float) -> Int32 = { _, value in
            onSet(value)
            return setResult
        }
        return DisplayBrightnessManager(getBrightness: get, setBrightness: set)
    }

    func testDimSetsBrightnessToZero() {
        var setBrightnessValue: Float?
        let manager = makeManager(currentBrightness: 0.8) { setBrightnessValue = $0 }

        manager.dim()

        XCTAssertEqual(setBrightnessValue, 0)
        XCTAssertTrue(manager.isDimmed)
    }

    func testDimIsIdempotent() {
        var setCallCount = 0
        let manager = makeManager { _ in setCallCount += 1 }

        manager.dim()
        manager.dim()

        XCTAssertEqual(setCallCount, 1)
    }

    func testRestoreAfterDim() {
        var lastSetValue: Float?
        let manager = makeManager(currentBrightness: 0.65) { lastSetValue = $0 }

        manager.dim()
        XCTAssertTrue(manager.isDimmed)

        manager.restore()
        XCTAssertEqual(lastSetValue, 0.65)
        XCTAssertFalse(manager.isDimmed)
    }

    func testRestoreWithoutDimIsNoOp() {
        var setCallCount = 0
        let manager = makeManager { _ in setCallCount += 1 }

        manager.restore()

        XCTAssertEqual(setCallCount, 0)
        XCTAssertFalse(manager.isDimmed)
    }

    func testRestoreIsIdempotent() {
        var setCallCount = 0
        let manager = makeManager { _ in setCallCount += 1 }

        manager.dim()
        manager.restore()
        manager.restore()

        // 1 for dim (set to 0), 1 for restore (set to original)
        XCTAssertEqual(setCallCount, 2)
    }

    func testDimFailsWhenGetBrightnessFails() {
        var setCallCount = 0
        let manager = makeManager(getResult: -1) { _ in setCallCount += 1 }

        manager.dim()

        XCTAssertEqual(setCallCount, 0)
        XCTAssertFalse(manager.isDimmed)
    }

    func testNilFunctionsAreNoOp() {
        let manager = DisplayBrightnessManager(getBrightness: nil, setBrightness: nil)

        manager.dim()
        XCTAssertFalse(manager.isDimmed)

        manager.restore()
        XCTAssertFalse(manager.isDimmed)
    }

    func testDimRestoreCycle() {
        var values: [Float] = []
        let manager = makeManager(currentBrightness: 0.5) { values.append($0) }

        manager.dim()
        manager.restore()
        manager.dim()
        manager.restore()

        XCTAssertEqual(values, [0, 0.5, 0, 0.5])
    }
}
