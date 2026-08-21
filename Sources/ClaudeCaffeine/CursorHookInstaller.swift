import Foundation
import OSLog

enum CursorHookInstaller {
    private static let logger = Logger(subsystem: "com.jmslau.claudecaffeine", category: "cursor-hooks")
    static let marker = "caffeine-hooks"
    static let hookTimeoutSeconds = 5

    static let activeEvents = [
        "beforeSubmitPrompt",
        "preToolUse",
        "postToolUse",
        "beforeShellExecution",
        "afterAgentThought",
        "subagentStart",
    ]

    static let idleEvents = [
        "stop",
        "sessionEnd",
    ]

    struct Environment: Sendable {
        let home: URL

        var hooksDir: URL { home.appendingPathComponent(".cursor/caffeine-hooks") }
        var hooksJSON: URL { home.appendingPathComponent(".cursor/hooks.json") }
        var sessionsDir: URL { home.appendingPathComponent(".cursor/caffeine_sessions") }
        var activeScriptURL: URL { hooksDir.appendingPathComponent("active.js") }
        var idleScriptURL: URL { hooksDir.appendingPathComponent("idle.js") }

        static let `default` = Environment(home: URL(fileURLWithPath: NSHomeDirectory()))
    }

    static func activeJS(sessionsDir: URL) -> String {
        """
        const fs = require('fs');
        const path = require('path');
        const sessionsDir = \(jsStringLiteral(sessionsDir.path));
        if (!fs.existsSync(sessionsDir)) {
            try { fs.mkdirSync(sessionsDir, { recursive: true }); } catch (e) {}
        }
        try {
            const input = JSON.parse(fs.readFileSync(0, 'utf8'));
            const sessionId = input.conversation_id || input.session_id;
            if (sessionId) {
                const safeId = String(sessionId).replace(/[/\\\\]/g, '_');
                const data = {
                    timestamp: Date.now(),
                    pid: process.ppid
                };
                fs.writeFileSync(path.join(sessionsDir, safeId), JSON.stringify(data));
            }
        } catch (e) {}
        """
    }

    static func idleJS(sessionsDir: URL) -> String {
        """
        const fs = require('fs');
        const path = require('path');
        const sessionsDir = \(jsStringLiteral(sessionsDir.path));
        try {
            const input = JSON.parse(fs.readFileSync(0, 'utf8'));
            const sessionId = input.conversation_id || input.session_id;
            if (sessionId) {
                const safeId = String(sessionId).replace(/[/\\\\]/g, '_');
                const sessionFile = path.join(sessionsDir, safeId);
                if (fs.existsSync(sessionFile)) {
                    try { fs.unlinkSync(sessionFile); } catch (e) {}
                }
            }
        } catch (e) {}
        """
    }

    static var isInstalled: Bool {
        isInstalled(environment: .default)
    }

    static func isInstalled(environment: Environment) -> Bool {
        guard let rootHooks = readHooks(from: environment.hooksJSON) else { return false }
        let expected = activeEvents + idleEvents
        for event in expected {
            guard let entries = rootHooks[event], entries.contains(where: isCaffeineEntry) else {
                return false
            }
        }
        return true
    }

    static func install() throws {
        try install(environment: .default)
    }

    static func install(environment: Environment) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: environment.hooksDir.path) {
            try fileManager.createDirectory(at: environment.hooksDir, withIntermediateDirectories: true)
        }

        try activeJS(sessionsDir: environment.sessionsDir)
            .write(to: environment.activeScriptURL, atomically: true, encoding: .utf8)
        try idleJS(sessionsDir: environment.sessionsDir)
            .write(to: environment.idleScriptURL, atomically: true, encoding: .utf8)

        var dict = readJSON(from: environment.hooksJSON) ?? [String: Any]()
        if dict["version"] == nil {
            dict["version"] = 1
        }

        var rootHooks = dict["hooks"] as? [String: Any] ?? [String: Any]()
        let activeCommand = "node \(environment.activeScriptURL.path)"
        let idleCommand = "node \(environment.idleScriptURL.path)"

        for event in activeEvents {
            rootHooks[event] = upsertHook(in: rootHooks[event], command: activeCommand)
        }
        for event in idleEvents {
            rootHooks[event] = upsertHook(in: rootHooks[event], command: idleCommand)
        }

        dict["hooks"] = rootHooks

        let parent = environment.hooksJSON.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let outData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try outData.write(to: environment.hooksJSON, options: .atomic)
        logger.info("Successfully installed Cursor activity hooks")
    }

    static func uninstall() throws {
        try uninstall(environment: .default)
    }

    static func uninstall(environment: Environment) throws {
        guard var dict = readJSON(from: environment.hooksJSON) else {
            try? FileManager.default.removeItem(at: environment.hooksDir)
            try? FileManager.default.removeItem(at: environment.sessionsDir)
            return
        }

        if var rootHooks = dict["hooks"] as? [String: Any] {
            for event in rootHooks.keys {
                let remaining = stripCaffeineEntries(from: rootHooks[event])
                if remaining.isEmpty {
                    rootHooks.removeValue(forKey: event)
                } else {
                    rootHooks[event] = remaining
                }
            }
            dict["hooks"] = rootHooks
            let outData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try outData.write(to: environment.hooksJSON, options: .atomic)
        }

        try? FileManager.default.removeItem(at: environment.hooksDir)
        try? FileManager.default.removeItem(at: environment.sessionsDir)
    }

    // MARK: - JSON helpers

    private static func readJSON(from url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parsed
    }

    private static func readHooks(from url: URL) -> [String: [[String: Any]]]? {
        guard let dict = readJSON(from: url),
              let hooks = dict["hooks"] as? [String: Any] else {
            return nil
        }
        var result: [String: [[String: Any]]] = [:]
        for (event, value) in hooks {
            result[event] = dictionaryEntries(from: value)
        }
        return result
    }

    private static func upsertHook(in existing: Any?, command: String) -> [[String: Any]] {
        var entries = dictionaryEntries(from: existing)
        entries.removeAll(where: isCaffeineEntry)
        entries.append([
            "command": command,
            "timeout": hookTimeoutSeconds,
        ])
        return entries
    }

    private static func stripCaffeineEntries(from existing: Any?) -> [[String: Any]] {
        dictionaryEntries(from: existing).filter { !isCaffeineEntry($0) }
    }

    private static func dictionaryEntries(from value: Any?) -> [[String: Any]] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { $0 as? [String: Any] }
    }

    static func isCaffeineEntry(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains(marker) == true
    }

    private static func jsStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }
}
