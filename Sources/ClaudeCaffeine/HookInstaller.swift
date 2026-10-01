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

    // Raw string: the regex backslashes must reach the script unchanged.
    static let idleJS = #"""
const fs = require('fs');
const path = require('path');
const os = require('os');
const sessionsDir = path.join(os.homedir(), '.claude/caffeine_sessions');
// Claude Code's usage-limit message, e.g. "You've hit your session limit · resets 3:30pm (Europe/London)".
const LIMIT_RE = /you['’]ve\s+hit\s+your\s+[^·∙•]{0,40}?limit\s*[·∙•]\s*resets\s+(1[0-2]|[1-9])(?::([0-5]\d))?\s*(am|pm)\b/i;
// Claude Code continues on its own 30-90s after the reset (a server-tuned delay); stay awake well past that.
const HOLD_GRACE_MS = 15 * 60 * 1000;
const HOUR_MS = 60 * 60 * 1000;
// Events that do not end a turn; they must not end a running limit hold.
const KEEPS_HOLD = ['Notification', 'SubagentStop', 'Elicitation'];
// Background work that is Claude itself working (Claude Code's labels for local agent tasks).
const AGENT_TASK_TYPES = ['subagent', 'workflow', 'teammate'];

// When a usage limit ended the turn, returns when Auto-Resume should stop keeping the Mac awake.
function limitHoldUntil(input, now) {
    if (input.hook_event_name !== 'StopFailure' || input.error !== 'rate_limit') return null;
    const match = LIMIT_RE.exec(input.last_assistant_message || '');
    if (!match) return null;
    const reset = new Date(now);
    reset.setHours(Number(match[1]) % 12 + (match[3].toLowerCase() === 'pm' ? 12 : 0), Number(match[2] || 0), 0, 0);
    if (reset.getTime() <= now) {
        // Claude Code shows a bare time only for resets less than a day away: a time within the last hour
        // means the reset is due now, anything earlier means tomorrow.
        if (now - reset.getTime() < HOUR_MS) return now + HOLD_GRACE_MS;
        reset.setDate(reset.getDate() + 1);
    }
    return reset.getTime() + HOLD_GRACE_MS;
}

function isHolding(sessionFile, now) {
    try { return JSON.parse(fs.readFileSync(sessionFile, 'utf8')).holdUntil > now; } catch (e) { return false; }
}

// Subagent hooks carry the parent's session_id, so a finished subagent does not end the session, and a turn
// that ends while background agents run leaves the session paused, not done (see Stop's background_tasks).
function isStillWorking(input) {
    if (input.hook_event_name === 'SubagentStop') return true;
    return input.hook_event_name === 'Stop'
        && (input.background_tasks || []).some((task) => AGENT_TASK_TYPES.includes(task.type));
}

try {
    const input = JSON.parse(fs.readFileSync(0, 'utf8'));
    const sessionId = input.session_id;
    if (sessionId) {
        const sessionFile = path.join(sessionsDir, sessionId);
        const now = Date.now();
        const holdUntil = limitHoldUntil(input, now);
        if (holdUntil) {
            // The app honors holdUntil only while Auto-Resume is enabled; otherwise it treats this as idle.
            fs.mkdirSync(sessionsDir, { recursive: true });
            fs.writeFileSync(sessionFile, JSON.stringify({ timestamp: now, pid: process.ppid, holdUntil }));
        } else if (KEEPS_HOLD.includes(input.hook_event_name) && isHolding(sessionFile, now)) {
            // e.g. "Claude is waiting for your input" while the session sits at the limit: keep holding.
        } else if (isStillWorking(input)) {
            fs.mkdirSync(sessionsDir, { recursive: true });
            fs.writeFileSync(sessionFile, JSON.stringify({ timestamp: now, pid: process.ppid }));
        } else if (fs.existsSync(sessionFile)) {
            try { fs.unlinkSync(sessionFile); } catch (e) {}
        }
    }
} catch (e) {}
"""#

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
