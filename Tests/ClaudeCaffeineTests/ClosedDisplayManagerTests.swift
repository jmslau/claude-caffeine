import Foundation
import XCTest
@testable import ClaudeCaffeine

final class MockShellExecutor: ShellExecutor {
    var invocations: [(command: String, arguments: [String])] = []
    var nextResult = ShellResult(exitCode: 0, stdout: "", stderr: "")

    func run(_ command: String, arguments: [String]) -> ShellResult {
        invocations.append((command, arguments))
        return nextResult
    }
}

final class ClosedDisplayManagerTests: XCTestCase {
    private var executor: MockShellExecutor!

    override func setUp() {
        executor = MockShellExecutor()
    }

    func testInitialStateIsDisabled() {
        let manager = ClosedDisplayManager(executor: executor)
        XCTAssertEqual(manager.state, .disabled)
        XCTAssertFalse(manager.isEnabled)
    }

    func testEnableFailsWhenHelperNotInstalled() {
        let manager = ClosedDisplayManager(executor: executor, checkHelperInstalled: { false })

        let result = manager.enable()

        XCTAssertFalse(result)
        XCTAssertEqual(manager.state, .helperNotInstalled)
        XCTAssertTrue(executor.invocations.isEmpty)
    }

    func testDisableFromDisabledIsNoOp() {
        let manager = ClosedDisplayManager(executor: executor)

        let result = manager.disable()

        XCTAssertTrue(result)
        XCTAssertEqual(manager.state, .disabled)
        XCTAssertTrue(executor.invocations.isEmpty)
    }

    func testReassertDoesNothingWhenDisabled() {
        let manager = ClosedDisplayManager(executor: executor)

        manager.reassert()

        XCTAssertTrue(executor.invocations.isEmpty)
    }

    func testForceDisableCallsOffScript() {
        let manager = ClosedDisplayManager(
            scriptPath: "/test/claude-sleep-control.sh",
            executor: executor,
            checkHelperInstalled: { true }
        )
        manager.forceDisable()

        XCTAssertEqual(manager.state, .disabled)
        XCTAssertEqual(executor.invocations.count, 1)
        XCTAssertEqual(executor.invocations.first?.command, "/usr/bin/sudo")
        XCTAssertEqual(executor.invocations.first?.arguments, ["/test/claude-sleep-control.sh", "off"])
    }
}
