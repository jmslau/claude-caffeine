# ClaudeCaffeine

**Keeps your Mac awake while Claude Code is working — even with the lid closed.**

ClaudeCaffeine is a lightweight macOS menu bar app that detects active Claude Code sessions and prevents sleep. When Claude goes idle, your Mac sleeps normally again.

## Install

```bash
brew install --cask jmslau/tap/claude-caffeine
```

Or build from source:

```bash
git clone https://github.com/jmslau/claude-caffeine.git
cd claude-caffeine
swift build -c release
./scripts/make-app-bundle.sh
cp -r dist/ClaudeCaffeine.app /Applications/
open /Applications/ClaudeCaffeine.app
```

Requires macOS 13 (Ventura) or later.

## The Problem

You start a Claude Code task — a multi-file refactor, a test suite, a long build-and-fix loop. You step away or close the lid. macOS puts your machine to sleep. The API call drops. You come back to a half-finished job.

ClaudeCaffeine makes this a non-issue.

## Features

- **Sleep prevention** — Holds a macOS sleep assertion while Claude Code is actively working
- **Closed-lid mode** — Keeps your MacBook running with the lid shut (requires one-time helper install)
- **Smart detection** — Monitors Claude process CPU, network connections, and `~/.claude/tasks/` file activity
- **Task completion alerts** — Notification + sound when Claude finishes working
- **Session cost tracking** — Shows estimated API cost for today and this week in the menu bar
- **Overnight mode** — Unattended multi-hour sessions with auto-disable after 12h and a summary notification
- **Configurable idle threshold** — 1, 2, 5, or 10 minute sensitivity
- **Low battery protection** — Suspends closed-lid mode below 10% battery
- **Clean shutdown** — Always restores normal sleep on quit, crash, or signal

## How Detection Works

Every 5 seconds, the app checks two signals:

1. **Process-level** — Finds running `claude` processes, checks CPU usage, and inspects network connections. High CPU or active connections with moderate CPU means Claude is working.

2. **File-level** — Watches `~/.claude/tasks/` for recent modifications. Catches tool-execution phases where the API connection may be momentarily quiet.

Both signals must go quiet before the sleep lock is released.

## Menu Bar

| Icon | Meaning |
|------|---------|
| **bolt** (animated) | Claude is working — Mac is being kept awake, with elapsed timer |
| **lock.laptop** | Closed-lid mode enabled |
| **moon.zzz** | Idle — no active Claude Code sessions |
| **pause** | Monitoring paused |
| **warning** | Scan issue — holding lock during grace period |

The menu shows live status: process state, active sessions, closed-lid state, session cost for today/week, and last check time.

## Closed-Lid Mode

The standout feature. Your MacBook stays awake with the lid shut while Claude is working. The moment Claude goes idle, normal sleep resumes.

On first launch, you'll be prompted to install a small privileged helper (requires admin password). You can skip this — the app still prevents idle sleep, just not lid-close sleep. Install or remove it any time from the menu.

**How it works:** A shell script toggles `pmset disablesleep`, authorized via a scoped sudoers entry for your user only.

**Thermal note:** With the lid closed, cooling is reduced. Claude Code tasks are mostly network I/O, but use a hard surface or vertical stand for extended sessions.

**Manual recovery** if the app crashes without cleanup:

```bash
sudo pmset -a disablesleep 0
```

## Session Cost Tracking

The app parses Claude Code's session logs (`~/.claude/projects/`) to estimate API costs based on token usage. The menu bar shows:

- **Cost today** with session count
- **Cost this week** (rolling 7 days)

Pricing covers Opus, Sonnet, and Haiku model families including cache read/write tokens. Costs refresh every 30 seconds.

## Overnight Mode

For unattended multi-hour sessions. Enable from the menu before you leave.

- Forces monitoring and closed-lid mode on
- Tracks active vs. idle time with transition logging
- Auto-disables after 12 hours as a safety measure
- Sends a summary notification with duration, active/idle breakdown, and transition count

Previous settings are restored when overnight mode ends.

## Configuration

**Idle threshold** — How long Claude must be quiet before releasing the sleep lock:

| Threshold | Best for |
|-----------|----------|
| 1 min | Fast feedback, may flicker between states |
| **2 min** | Default — good balance for most tasks |
| 5 min | Long builds with gaps between steps |
| 10 min | Very conservative |

**Notifications** — Toggle completion notifications and sound independently.

## Development

```bash
swift build          # debug build
swift test           # run tests
swift run            # run from source
```

Release build:

```bash
./scripts/release.sh 1.0.0
```

This builds the binary, creates a signed `.app` bundle, generates a zip archive, computes the SHA256, and updates the Homebrew cask formula.

## Uninstall

```bash
brew uninstall claude-caffeine
```

If you installed the closed-lid helper, remove it first via **Closed-Lid Mode > Uninstall Helper** in the menu bar, or manually:

```bash
sudo rm /private/etc/sudoers.d/claude_caffeine
rm -rf ~/Library/ClaudeCaffeine
```

## License

MIT
