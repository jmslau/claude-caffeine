const fs = require('fs');
const path = require('path');
const os = require('os');

const sessionsDir = path.join(os.homedir(), '.claude/caffeine_sessions');

try {
    // Read JSON from stdin
    const input = JSON.parse(fs.readFileSync(0, 'utf8'));
    const sessionId = input.session_id;
    if (sessionId) {
        const sessionFile = path.join(sessionsDir, sessionId);
        if (fs.existsSync(sessionFile)) {
            try {
                fs.unlinkSync(sessionFile);
            } catch (e) {}
        }
    }
} catch (e) {
    // Silently fail
}
