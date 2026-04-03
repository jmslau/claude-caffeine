import Foundation
import OSLog

enum HookInstaller {
    private static let logger = Logger(subsystem: "com.jmslau.claudecaffeine", category: "hooks")
    
    private static let hooksDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/caffeine-hooks")
    private static let activeScriptURL = hooksDir.appendingPathComponent("active.js")
    private static let idleScriptURL = hooksDir.appendingPathComponent("idle.js")
    
    private static let activeCommand = "node \(activeScriptURL.path)"
    private static let idleCommand = "node \(idleScriptURL.path)"
    
    // JS Script contents
    private static let activeJS = """
const fs = require('fs');
const path = require('path');
const os = require('os');
const sessionsDir = path.join(os.homedir(), '.claude/caffeine_sessions');
if (!fs.existsSync(sessionsDir)) {
    try { fs.mkdirSync(sessionsDir, { recursive: true }); } catch (e) {}
}
try {
    const input = JSON.parse(fs.readFileSync(0, 'utf8'));
    const sessionId = input.session_id;
    if (sessionId) {
        fs.writeFileSync(path.join(sessionsDir, sessionId), Date.now().toString());
    }
} catch (e) {}
"""

    private static let idleJS = """
const fs = require('fs');
const path = require('path');
const os = require('os');
const sessionsDir = path.join(os.homedir(), '.claude/caffeine_sessions');
try {
    const input = JSON.parse(fs.readFileSync(0, 'utf8'));
    const sessionId = input.session_id;
    if (sessionId) {
        const sessionFile = path.join(sessionsDir, sessionId);
        if (fs.existsSync(sessionFile)) {
            try { fs.unlinkSync(sessionFile); } catch (e) {}
        }
    }
} catch (e) {}
"""

    static var settingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = dict["hooks"] as? [String: [[String: Any]]] else { return false }
        
        // Basic check: do we have our active/idle commands in the right events?
        let expectedEvents = ["UserPromptSubmit", "PreToolUse", "Stop", "Elicitation"]
        for event in expectedEvents {
            if hooks[event]?.contains(where: { ($0["command"] as? String)?.contains("caffeine-hooks") == true }) != true {
                return false
            }
        }
        
        return true
    }

    static func install() throws {
        // 1. Create hooks directory
        if !FileManager.default.fileExists(atPath: hooksDir.path) {
            try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        }
        
        // 2. Write JS scripts
        try activeJS.write(to: activeScriptURL, atomically: true, encoding: .utf8)
        try idleJS.write(to: idleScriptURL, atomically: true, encoding: .utf8)
        
        // 3. Update settings.json
        var dict = [String: Any]()
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = parsed
        }
        
        var hooks = dict["hooks"] as? [String: [[String: Any]]] ?? [String: [[String: Any]]]()
        
        let addHook = { (event: String, command: String, description: String) in
            var events = hooks[event] ?? []
            // Remove any legacy caffeine hooks first
            events.removeAll(where: { 
                let cmd = ($0["command"] as? String) ?? ""
                return cmd.contains(".caffeine_active") || cmd.contains("caffeine-hooks") 
            })
            events.append(["command": command, "description": description])
            hooks[event] = events
        }
        
        // Active hooks
        addHook("UserPromptSubmit", activeCommand, "ClaudeCaffeine (Active)")
        addHook("PreToolUse", activeCommand, "ClaudeCaffeine (Active)")
        addHook("PostToolUse", activeCommand, "ClaudeCaffeine (Active)")
        
        // Idle hooks
        addHook("Elicitation", idleCommand, "ClaudeCaffeine (Idle)")
        addHook("Stop", idleCommand, "ClaudeCaffeine (Idle)")
        addHook("StopFailure", idleCommand, "ClaudeCaffeine (Idle)")
        addHook("SubagentStop", idleCommand, "ClaudeCaffeine (Idle)")
        
        // Special: Notification with idle/permission prompts
        // For simple command hooks, we can't easily differentiate matcher in this Swift helper 
        // without more complex logic, but we'll add it generally for now.
        // Better: add a Notification hook that calls idleCommand always? No, too aggressive.
        // Actually, if we hit a permission prompt, Claude Code fires Notification.
        addHook("Notification", idleCommand, "ClaudeCaffeine (Idle for Prompts)")
        
        dict["hooks"] = hooks
        
        let outData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try outData.write(to: settingsURL)
        logger.info("Successfully installed session-aware activity hooks")
    }

    static func uninstall() throws {
        guard let data = try? Data(contentsOf: settingsURL),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = dict["hooks"] as? [String: [[String: Any]]] else { return }
        
        for event in hooks.keys {
            if var events = hooks[event] {
                events.removeAll(where: { 
                    let cmd = ($0["command"] as? String) ?? ""
                    return cmd.contains("caffeine-hooks") || cmd.contains(".caffeine_active")
                })
                if events.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = events
                }
            }
        }
        
        dict["hooks"] = hooks
        let outData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try outData.write(to: settingsURL)
        
        // Cleanup
        try? FileManager.default.removeItem(at: hooksDir)
        let sessionsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/caffeine_sessions")
        try? FileManager.default.removeItem(at: sessionsDir)
    }
}
