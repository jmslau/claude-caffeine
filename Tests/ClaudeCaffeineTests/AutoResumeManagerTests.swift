import XCTest
@testable import ClaudeCaffeine

@MainActor
final class AutoResumeManagerTests: XCTestCase {
    private var tempDir: URL!
    private var manager: AutoResumeManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        manager = AutoResumeManager.shared
        manager.setHomeDirectory(tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testEnableWritesWrapperAndAlias() throws {
        let zshrc = tempDir.appendingPathComponent(".zshrc")
        try "existing content".write(to: zshrc, atomically: true, encoding: .utf8)
        
        try manager.enable()
        
        let wrapper = tempDir.appendingPathComponent(".claude/auto-resume-wrapper.py")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wrapper.path))
        
        let content = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertTrue(content.contains("# BEGIN CLAUDE CAFFEINE AUTO-RESUME"))
        XCTAssertTrue(content.contains("alias claude="))
    }

    func testDisableRemovesWrapperAndAlias() throws {
        let zshrc = tempDir.appendingPathComponent(".zshrc")
        try "existing content".write(to: zshrc, atomically: true, encoding: .utf8)
        
        try manager.enable()
        try manager.disable()
        
        let wrapper = tempDir.appendingPathComponent(".claude/auto-resume-wrapper.py")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wrapper.path))
        
        let content = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertFalse(content.contains("# BEGIN CLAUDE CAFFEINE AUTO-RESUME"))
        XCTAssertTrue(content.contains("existing content"))
    }

    /// Regression: literal Swift template text must never remain in ~/.zshrc (breaks `source ~/.zshrc`).
    func testEnableStripsCorruptedSwiftTemplateLines() throws {
        let zshrc = tempDir.appendingPathComponent(".zshrc")
        let badLine1 = "\\n\\(" + "markerBegin" + ")"
        let badLine2 = "alias claude=\"python3 \\(" + "wrapperScriptURL.path" + ")\""
        let badLine3 = "\\(" + "markerEnd" + ")"
        try """
        existing content
        \(badLine1)
        \(badLine2)
        \(badLine3)
        """.write(to: zshrc, atomically: true, encoding: .utf8)

        try manager.enable()

        let content = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertTrue(content.contains("existing content"))
        XCTAssertFalse(content.contains("\\(" + "markerBegin" + ")"))
        XCTAssertFalse(content.contains("\\(" + "wrapperScriptURL.path" + ")"))
        XCTAssertTrue(content.contains("# BEGIN CLAUDE CAFFEINE AUTO-RESUME"))
        let aliasLines = content.components(separatedBy: .newlines).filter { $0.hasPrefix("alias claude=") }
        XCTAssertEqual(aliasLines.count, 1, "Expected a single alias line after cleanup")
    }
}
