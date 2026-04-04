import Foundation
import os.log

public enum AutoResumeState: String, Codable {
    case enabled
    case disabled
}

@MainActor
public class AutoResumeManager {
    public static let shared = AutoResumeManager()
    
    private let logger = Logger(subsystem: "com.claude.caffeine", category: "AutoResumeManager")
    private var homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    private var claudeConfigDir: URL { homeDirectory.appendingPathComponent(".claude") }
    private var wrapperScriptURL: URL { claudeConfigDir.appendingPathComponent("auto-resume-wrapper.py") }

    public init() {}

    /// For testing purposes
    internal func setHomeDirectory(_ url: URL) {
        self.homeDirectory = url
    }

    public var isEnabled: Bool {
        return UserDefaults.standard.string(forKey: "AutoResumeState") == AutoResumeState.enabled.rawValue
    }

    public func enable() throws {
        logger.info("Enabling Auto-Resume...")
        
        // Ensure .claude directory exists
        if !FileManager.default.fileExists(atPath: claudeConfigDir.path) {
            try FileManager.default.createDirectory(at: claudeConfigDir, withIntermediateDirectories: true)
        }
        
        // Write the wrapper script
        try writeWrapperScript()
        
        // Update profile
        try injectAlias()
        
        UserDefaults.standard.set(AutoResumeState.enabled.rawValue, forKey: "AutoResumeState")
        logger.info("Auto-Resume enabled successfully.")
    }

    public func disable() throws {
        logger.info("Disabling Auto-Resume...")
        
        // Remove the wrapper script if it exists
        if FileManager.default.fileExists(atPath: wrapperScriptURL.path) {
            try FileManager.default.removeItem(at: wrapperScriptURL)
        }
        
        // Remove alias block from profiles
        try removeAlias()
        
        UserDefaults.standard.set(AutoResumeState.disabled.rawValue, forKey: "AutoResumeState")
        logger.info("Auto-Resume disabled successfully.")
    }

    private func writeWrapperScript() throws {
        // We use double backslashes in the Swift string to get a single backslash in the Python file.
        // Python raw strings r"..." only need one backslash for \d.
        let script = """
        #!/usr/bin/env python3
        
        import os
        import pty
        import select
        import sys
        import tty
        import time
        import re
        from datetime import datetime, timedelta
        import signal
        import termios
        import struct
        import fcntl
        from pathlib import Path

        def get_seconds_until(hour, minute, ampm):
            now = datetime.now()
            if ampm == 'pm' and hour != 12: hour += 12
            elif ampm == 'am' and hour == 12: hour = 0
            target = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
            if target <= now: target += timedelta(days=1)
            return (target - now).total_seconds()

        def set_winsize(fd, row, col, xpix=0, ypix=0):
            winsize = struct.pack("HHHH", row, col, xpix, ypix)
            try:
                fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)
            except OSError:
                pass

        def get_original_executable():
            path_env = os.environ.get("PATH", "")
            for p in path_env.split(os.pathsep):
                exec_path = os.path.join(p, "claude")
                if os.path.isfile(exec_path) and os.access(exec_path, os.X_OK):
                    try:
                        with open(exec_path, 'r', encoding='utf-8') as f:
                            first_line = f.readline()
                            if "python3" not in first_line:
                                return exec_path
                    except Exception:
                        pass
            return "claude"

        def main():
            if not sys.stdout.isatty():
                original_exe = get_original_executable()
                os.execvp(original_exe, ["claude"] + sys.argv[1:])

            limit_regex = re.compile(r"resets (\\\\d{1,2})(?::(\\\\d{2}))?(am|pm)", re.IGNORECASE)
            
            sessions_dir = Path.home() / ".claude" / "caffeine_sessions"
            session_file = sessions_dir / f"auto-resume-{os.getpid()}"
            
            original_exe = get_original_executable()
            cmd = ["claude"] + sys.argv[1:]
            
            pid, master_fd = pty.fork()
            if pid == pty.CHILD:
                os.execvp(original_exe, cmd)
                
            def sigwinch_handler(sig, data):
                s = struct.pack("HHHH", 0, 0, 0, 0)
                try:
                    a = struct.unpack('hhhh', fcntl.ioctl(sys.stdout.fileno(), termios.TIOCGWINSZ, s))
                    set_winsize(master_fd, a[0], a[1])
                except Exception:
                    pass

            signal.signal(signal.SIGWINCH, sigwinch_handler)
            sigwinch_handler(None, None)
            
            try:
                mode = tty.tcgetattr(sys.stdin.fileno())
                tty.setraw(sys.stdin.fileno())
            except tty.error:
                mode = None

            buf = ""
            try:
                while True:
                    r, w, e = select.select([sys.stdin.fileno(), master_fd], [], [])
                    if sys.stdin.fileno() in r:
                        try:
                            d = os.read(sys.stdin.fileno(), 1024)
                            if not d: break
                            os.write(master_fd, d)
                        except OSError:
                            break
                            
                    if master_fd in r:
                        try:
                            d = os.read(master_fd, 1024)
                            if not d: break
                            os.write(sys.stdout.fileno(), d)
                            
                            text = d.decode('utf-8', errors='ignore')
                            buf += text
                            buf = buf[-1000:]
                            
                            if ("hit your limit" in buf or "limit" in buf) and "resets " in buf:
                                match = limit_regex.search(buf)
                                if match:
                                    h = int(match.group(1))
                                    m = int(match.group(2) or 0)
                                    ampm = match.group(3).lower()
                                    sleep_time = get_seconds_until(h, m, ampm) + 60
                                    if 0 < sleep_time < 86400:
                                        msg = f"\\\\r\\\\n\\\\033[93m[Claude Caffeine] Over limit! Auto-resuming in {int(sleep_time/60)} minutes...\\\\033[0m\\\\r\\\\n"
                                        sys.stdout.write(msg)
                                        sys.stdout.flush()
                                        
                                        # Keep Mac awake during wait
                                        try:
                                            sessions_dir.mkdir(parents=True, exist_ok=True)
                                            session_file.touch()
                                        except: pass
                                        
                                        time.sleep(sleep_time)
                                        
                                        try: session_file.unlink()
                                        except: pass
                                        
                                        os.write(master_fd, b'\\\\r')
                                        buf = ""
                        except OSError:
                            break
            finally:
                if mode is not None:
                    tty.tcsetattr(sys.stdin.fileno(), tty.TCSAFLUSH, mode)
                try: session_file.unlink()
                except: pass
                os.waitpid(pid, 0)

        if __name__ == "__main__": main()
        """
        
        do {
            try script.write(to: wrapperScriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperScriptURL.path)
        } catch {
            logger.error("Failed to write wrapper script: \\(error)")
            throw error
        }
    }

    private let markerBegin = "# BEGIN CLAUDE CAFFEINE AUTO-RESUME"
    private let markerEnd = "# END CLAUDE CAFFEINE AUTO-RESUME"

    /// Lines matching this pattern appear when Swift string interpolation never ran (e.g. raw multiline `#"""…"""#` where `\(` is literal). They break `source ~/.zshrc`.
    private static let corruptedSwiftTemplateNeedles: [String] = [
        "\\(" + "markerBegin" + ")",
        "\\(" + "markerEnd" + ")",
        "\\(" + "wrapperScriptURL.path" + ")"
    ]

    /// Builds the profile snippet without multiline `\(…)` literals so a packaging mistake cannot ship Swift source into user shell files.
    private func makeProfileBlock(wrapperPath: String) -> String {
        markerBegin + "\n" + "alias claude=\"python3 " + wrapperPath + "\"\n" + markerEnd
    }

    private func stripCorruptedSwiftTemplateLines(_ content: String) -> String {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                !Self.corruptedSwiftTemplateNeedles.contains { String(line).contains($0) }
            }
            .joined(separator: "\n")
    }
    
    private func getProfiles() -> [URL] {
        return [
            homeDirectory.appendingPathComponent(".zshrc"),
            homeDirectory.appendingPathComponent(".bash_profile"),
            homeDirectory.appendingPathComponent(".bashrc")
        ]
    }

    private func injectAlias() throws {
        let block = makeProfileBlock(wrapperPath: wrapperScriptURL.path)

        let profiles = getProfiles()
        var injected = false
        
        for profile in profiles {
            if FileManager.default.fileExists(atPath: profile.path) {
                var content = try String(contentsOf: profile, encoding: .utf8)
                content = stripCorruptedSwiftTemplateLines(content)
                
                if content.contains(markerBegin) {
                    let escapedBegin = NSRegularExpression.escapedPattern(for: markerBegin)
                    let escapedEnd = NSRegularExpression.escapedPattern(for: markerEnd)
                    let regex = try NSRegularExpression(pattern: "\n?\(escapedBegin).*?\(escapedEnd)\n?", options: .dotMatchesLineSeparators)
                    content = regex.stringByReplacingMatches(in: content, options: [], range: NSRange(location: 0, length: content.count), withTemplate: "\n" + block + "\n")
                } else {
                    content += "\n" + block + "\n"
                }
                
                try content.write(to: profile, atomically: true, encoding: .utf8)
                injected = true
            }
        }
        
        if !injected {
            let zshrc = getProfiles()[0]
            try? (block + "\n").write(to: zshrc, atomically: true, encoding: .utf8)
        }
    }

    private func removeAlias() throws {
        let profiles = getProfiles()
        
        let regexPattern = "\\n?\(NSRegularExpression.escapedPattern(for: markerBegin)).*?\(NSRegularExpression.escapedPattern(for: markerEnd))\\n?"
        let regex = try NSRegularExpression(pattern: regexPattern, options: .dotMatchesLineSeparators)

        for profile in profiles {
            if FileManager.default.fileExists(atPath: profile.path) {
                var content = try String(contentsOf: profile, encoding: .utf8)
                content = stripCorruptedSwiftTemplateLines(content)
                if content.contains(markerBegin) {
                    let newContent = regex.stringByReplacingMatches(in: content, options: [], range: NSRange(location: 0, length: content.count), withTemplate: "\n")
                    try newContent.write(to: profile, atomically: true, encoding: .utf8)
                }
            }
        }
    }
}
