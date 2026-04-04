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
        // Record timestamp and Claude's PID (ppid)
        const data = {
            timestamp: Date.now(),
            pid: process.ppid
        };
        fs.writeFileSync(path.join(sessionsDir, sessionId), JSON.stringify(data));
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
              let rootHooks = dict["hooks"] as? [String: [[String: Any]]] else { return false }
        
        let expectedEvents = ["UserPromptSubmit", "PreToolUse", "Stop", "Elicitation"]
        for event in expectedEvents {
            guard let eventHooks = rootHooks[event] else { return false }
            // Check if any of the hook entries contains our caffeine script
            let found = eventHooks.contains { entry in
                if let subHooks = entry["hooks"] as? [[String: Any]] {
                    return subHooks.contains { sub in
                        (sub["command"] as? String)?.contains("caffeine-hooks") == true
                    }
                }
                return false
            }
            if !found { return false }
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
        
        var rootHooks = dict["hooks"] as? [String: [[String: Any]]] ?? [String: [[String: Any]]]()
        
        let addHook = { (event: String, command: String, description: String) in
            var events = rootHooks[event] ?? []
            // Remove any legacy caffeine hooks first
            events.removeAll(where: { 
                if ( ($0["command"] as? String) ?? "" ).contains("caffeine-hooks") { return true }
                if let subHooks = $0["hooks"] as? [[String: Any]] {
                    return subHooks.contains { sub in
                        (sub["command"] as? String)?.contains("caffeine-hooks") == true
                    }
                }
                return false
            })
            
            // New structure: 
            // { "matcher": "*", "hooks": [ { "type": "command", "command": "...", "description": "..." } ] }
            let hookEntry: [String: Any] = [
                "matcher": "*",
                "hooks": [
                    [
                        "type": "command",
                        "command": command,
                        "description": description
                    ]
                ]
            ]
            events.append(hookEntry)
            rootHooks[event] = events
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
        addHook("Notification", idleCommand, "ClaudeCaffeine (Idle for Prompts)")
        
        dict["hooks"] = rootHooks
        
        let outData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try outData.write(to: settingsURL)
        logger.info("Successfully installed session-aware activity hooks")
    }

    static func uninstall() throws {
        guard let data = try? Data(contentsOf: settingsURL),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var rootHooks = dict["hooks"] as? [String: [[String: Any]]] else { return }
        
        for event in rootHooks.keys {
            if var events = rootHooks[event] {
                events.removeAll(where: { 
                    if ( ($0["command"] as? String) ?? "" ).contains("caffeine-hooks") { return true }
                    if let subHooks = $0["hooks"] as? [[String: Any]] {
                        return subHooks.contains { sub in
                            (sub["command"] as? String)?.contains("caffeine-hooks") == true
                        }
                    }
                    return false
                })
                if events.isEmpty {
                    rootHooks.removeValue(forKey: event)
                } else {
                    rootHooks[event] = events
                }
            }
        }
        
        dict["hooks"] = rootHooks
        let outData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try outData.write(to: settingsURL)
        
        // Cleanup
        try? FileManager.default.removeItem(at: hooksDir)
        let sessionsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/caffeine_sessions")
        try? FileManager.default.removeItem(at: sessionsDir)
    }
}
