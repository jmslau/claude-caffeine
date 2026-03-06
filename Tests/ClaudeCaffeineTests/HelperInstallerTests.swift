import Foundation
import XCTest
@testable import ClaudeCaffeine

final class HelperInstallerTests: XCTestCase {
    func testScriptContentsHasOnAndOffCases() {
        let script = HelperInstaller.scriptContents
        XCTAssertTrue(script.contains("on)"))
        XCTAssertTrue(script.contains("off)"))
        XCTAssertTrue(script.contains("pmset -a disablesleep 1"))
        XCTAssertTrue(script.contains("pmset -a disablesleep 0"))
    }

    func testScriptContentsRejectsInvalidArgs() {
        let script = HelperInstaller.scriptContents
        XCTAssertTrue(script.contains("Usage:"))
        XCTAssertTrue(script.contains("exit 1"))
    }

    func testScriptContentsUsesAbsolutePmsetPath() {
        let script = HelperInstaller.scriptContents
        XCTAssertTrue(script.contains("/usr/bin/pmset"))
        XCTAssertFalse(script.contains(" pmset "))
    }

    func testScriptPathIsInLibraryWithNoSpaces() {
        XCTAssertTrue(HelperInstaller.scriptPath.contains("Library/ClaudeCaffeine"))
        XCTAssertFalse(HelperInstaller.scriptPath.contains(" "))
        XCTAssertTrue(HelperInstaller.scriptPath.hasSuffix("claude-sleep-control.sh"))
    }

    func testSudoersPathIsInEtcSudoersD() {
        XCTAssertEqual(HelperInstaller.sudoersPath, "/private/etc/sudoers.d/claude_caffeine")
    }

    func testSudoersContentsReferencesScriptPath() {
        let contents = HelperInstaller.sudoersContents
        XCTAssertTrue(contents.contains(HelperInstaller.scriptPath))
        XCTAssertTrue(contents.contains("NOPASSWD"))
        XCTAssertTrue(contents.contains(NSUserName()))
        XCTAssertFalse(contents.hasPrefix("ALL ALL"))
    }
}
