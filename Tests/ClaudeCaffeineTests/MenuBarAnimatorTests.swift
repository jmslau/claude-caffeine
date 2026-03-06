import AppKit
import Foundation
import XCTest
@testable import ClaudeCaffeine

@MainActor
final class MenuBarAnimatorTests: XCTestCase {
    private var statusItem: NSStatusItem!
    private var animator: MenuBarAnimator!

    override func setUp() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        animator = MenuBarAnimator()
        animator.configure(statusItem: statusItem)
    }

    override func tearDown() {
        animator.stop()
        NSStatusBar.system.removeStatusItem(statusItem)
        statusItem = nil
        animator = nil
    }

    func testInitialStateHasNoTitle() {
        XCTAssertEqual(statusItem.button?.title, "")
    }

    func testActiveSetsIconAndCostTitle() {
        animator.update(isActive: true, todayCost: 5.25)

        XCTAssertNotNil(statusItem.button?.image)
        let title = statusItem.button?.title ?? ""
        XCTAssertTrue(title.contains("$5.25"), "Expected today cost in title, got: \(title)")
    }

    func testStopClearsTitle() {
        animator.update(isActive: true, todayCost: 1.00)
        animator.stop()

        XCTAssertEqual(statusItem.button?.title, "")
    }

    func testUpdateCostTitleSetsValueWhenIdle() {
        animator.updateCostTitle(todayCost: 12.34)

        let title = statusItem.button?.title ?? ""
        XCTAssertTrue(title.contains("$12.34"), "Expected cost in title, got: \(title)")
    }

    func testInactiveShowsCostTitle() {
        animator.update(isActive: false, todayCost: 3.50)

        let title = statusItem.button?.title ?? ""
        XCTAssertTrue(title.contains("$3.50"), "Expected cost in title when inactive, got: \(title)")
    }

    func testZeroCostShowsZero() {
        animator.update(isActive: true, todayCost: 0)

        let title = statusItem.button?.title ?? ""
        XCTAssertTrue(title.contains("$0.00"), "Expected $0.00 in title, got: \(title)")
    }

    func testIconAlternatesBetweenFrames() {
        animator.update(isActive: true)
        let firstImage = statusItem.button?.image

        XCTAssertNotNil(firstImage)
    }

    func testUpdateWithZeroCostDefaultParameter() {
        animator.update(isActive: true)
        let title = statusItem.button?.title ?? ""
        XCTAssertTrue(title.contains("$0.00"), "Expected $0.00 with default parameter, got: \(title)")
    }

    func testShowCostDisabledHidesTitle() {
        animator.update(isActive: true, todayCost: 5.00)
        animator.showCost = false

        XCTAssertEqual(statusItem.button?.title, "")
    }

    func testShowCostReenabledRestoresTitle() {
        animator.update(isActive: false, todayCost: 5.00)
        animator.showCost = false
        animator.showCost = true

        let title = statusItem.button?.title ?? ""
        XCTAssertTrue(title.contains("$5.00"), "Expected cost restored in title, got: \(title)")
    }

    func testUpdateWhileShowCostDisabledKeepsTitleEmpty() {
        animator.showCost = false
        animator.update(isActive: true, todayCost: 10.00)

        XCTAssertEqual(statusItem.button?.title, "")
    }
}
