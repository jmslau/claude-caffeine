const fs = require('fs');
const path = require('path');
const os = require('os');

const sessionsDir = path.join(os.homedir(), '.claude/caffeine_sessions');
if (!fs.existsSync(sessionsDir)) {
    try {
        fs.mkdirSync(sessionsDir, { recursive: true });
    } catch (e) {}
}

try {
    // Read JSON from stdin
    const input = JSON.parse(fs.readFileSync(0, 'utf8'));
    const sessionId = input.session_id;
    if (sessionId) {
        fs.writeFileSync(path.join(sessionsDir, sessionId), Date.now().toString());
    }
} catch (e) {
    // Silently fail if JSON or file op fails
}
