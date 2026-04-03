import Foundation
import OSLog

enum HookInstaller {
    private static let logger = Logger(subsystem: "com.jmslau.claudecaffeine", category: "hooks")
    
    private static let hookCommandName = "touch ~/.claude/.caffeine_active"
    private static let rmCommandName = "rm -f ~/.claude/.caffeine_active"
    
    static var settingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = dict["hooks"] as? [String: [[String: Any]]] else { return false }
        
        let expectedHooks = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Elicitation", "Notification", "Stop", "StopFailure", "SubagentStop"]
        
        for hook in expectedHooks {
            let cmd = (hook == "UserPromptSubmit" || hook == "PreToolUse" || hook == "PostToolUse") ? hookCommandName : rmCommandName
            if hooks[hook]?.contains(where: { $0["command"] as? String == cmd }) != true {
                return false
            }
        }
        
        return true
    }

    static func install() throws {
        var dict = [String: Any]()
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = parsed
        }
        
        var hooks = dict["hooks"] as? [String: [[String: Any]]] ?? [String: [[String: Any]]]()
        
        let addHook = { (event: String, command: String, description: String) in
            var events = hooks[event] ?? []
            if !events.contains(where: { $0["command"] as? String == command }) {
                events.append(["command": command, "description": description])
            }
            hooks[event] = events
        }
        
        // Start events (wake up)
        addHook("UserPromptSubmit", hookCommandName, "ClaudeCaffeine Activity Pulse")
        addHook("PreToolUse", hookCommandName, "ClaudeCaffeine Activity Pulse")
        addHook("PostToolUse", hookCommandName, "ClaudeCaffeine Activity Pulse")
        
        // Stop events (go idle)
        addHook("Elicitation", rmCommandName, "ClaudeCaffeine Idle Signal")
        addHook("Notification", rmCommandName, "ClaudeCaffeine Idle Signal")
        addHook("Stop", rmCommandName, "ClaudeCaffeine Idle Signal")
        addHook("StopFailure", rmCommandName, "ClaudeCaffeine Idle Signal")
        addHook("SubagentStop", rmCommandName, "ClaudeCaffeine Idle Signal")
        
        dict["hooks"] = hooks
        
        let outData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        
        let dir = settingsURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try outData.write(to: settingsURL)
        logger.info("Successfully installed activity hooks in \(settingsURL.path)")
    }

    static func uninstall() throws {
        guard let data = try? Data(contentsOf: settingsURL),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = dict["hooks"] as? [String: [[String: Any]]] else { return }
        
        let removeHook = { (event: String, command: String) in
            if var events = hooks[event] {
                events.removeAll(where: { $0["command"] as? String == command })
                if events.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = events
                }
            }
        }
        
        removeHook("UserPromptSubmit", hookCommandName)
        removeHook("PreToolUse", hookCommandName)
        removeHook("PostToolUse", hookCommandName)
        removeHook("Elicitation", rmCommandName)
        removeHook("Notification", rmCommandName)
        removeHook("Stop", rmCommandName)
        removeHook("StopFailure", rmCommandName)
        removeHook("SubagentStop", rmCommandName)
        
        if hooks.isEmpty {
            dict.removeValue(forKey: "hooks")
        } else {
            dict["hooks"] = hooks
        }
        
        let outData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try outData.write(to: settingsURL)
        logger.info("Successfully uninstalled activity hooks from \(settingsURL.path)")
        
        // Cleanup state file
        let activeURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/.caffeine_active")
        try? FileManager.default.removeItem(at: activeURL)
    }
}
