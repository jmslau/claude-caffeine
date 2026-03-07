# Claude Caffeine

You kick off a Claude Code task — a multi-file refactor, a test suite, a long build-and-fix loop. You close the lid and walk away. You come back to a half-finished job because macOS put your machine to sleep.

**Claude Caffeine fixes this.** A lightweight menu bar app that keeps your Mac awake while Claude Code is working — even with the lid closed. The moment Claude goes idle, normal sleep resumes.

## Install

```bash
brew install --cask jmslau/tap/claude-caffeine
```

On first launch, macOS may show a Gatekeeper warning (the app isn't notarized yet). To clear it:

```bash
xattr -d com.apple.quarantine /Applications/Claude\ Caffeine.app
open /Applications/Claude\ Caffeine.app
```

Or go to **System Settings > Privacy & Security** and click **"Open Anyway"**.

Requires macOS 13 (Ventura) or later.

<details>
<summary>Build from source</summary>

```bash
git clone https://github.com/jmslau/claude-caffeine.git
cd claude-caffeine
swift build -c release
./scripts/make-app-bundle.sh
cp -r dist/Claude\ Caffeine.app /Applications/
open /Applications/Claude\ Caffeine.app
```

</details>

## What it does

**Keeps your Mac awake while Claude is working** — automatically, zero configuration. Sleep prevention engages when Claude Code is active and releases the moment it goes idle.

**Works with the lid closed** — close the lid, walk away. Claude keeps running. Open it later and a popover tells you exactly how long Claude worked while it was shut.

**Tracks your costs** — running API cost estimate in the menu bar, broken down by day, week, and project.

| | |
|---|---|
| **Task completion alerts** | Notification + sound when Claude finishes, with duration and cost summary |
| **Overnight mode** | Unattended multi-hour sessions with auto-disable after 12h |
| **Low battery protection** | Suspends closed-lid mode below 10% to conserve power |
| **Clean shutdown** | Always restores normal sleep on quit, crash, or signal |
| **Runs entirely locally** | No telemetry, no network calls, no account required |

## Closed-Lid Mode

The standout feature. Your MacBook stays awake with the lid shut while Claude is working. The moment Claude goes idle, normal sleep resumes.

On first launch, you'll be prompted to install a small privileged helper (requires admin password). You can skip this — the app still prevents idle sleep, just not lid-close sleep. Install or remove it any time from the menu.

**How it works:** A shell script toggles `pmset disablesleep`, authorized via a scoped sudoers entry for your user only. Lid state is detected via the IOKit hardware clamshell sensor, so it works reliably regardless of display power settings.

**Thermal note:** With the lid closed, cooling is reduced. Claude Code tasks are mostly network I/O, but use a hard surface or vertical stand for extended sessions.

**Manual recovery** if the app crashes without cleanup:

```bash
sudo pmset -a disablesleep 0
```

## Session Cost Tracking

The app parses Claude Code's session logs (`~/.claude/projects/`) to estimate API costs based on token usage. The menu bar shows:

- **Cost today** with session count
- **Cost this week** (rolling 7 days)
- **Cost by project** in a submenu

Pricing covers Opus, Sonnet, and Haiku model families including cache read/write tokens. Each message is costed using its own model, so sessions that mix models (e.g., Opus with Haiku subagents) get accurate per-model pricing. Costs refresh every 30 seconds.

> **Note:** Cost estimates use Anthropic's pay-per-token API rates. If you're on a Claude Pro or Max subscription plan, the displayed costs won't reflect your actual billing.

## Overnight Mode

For unattended multi-hour sessions. Enable from the menu before you leave.

- Forces closed-lid mode on
- Tracks active vs. idle time with transition logging
- Auto-disables after 12 hours as a safety measure
- Sends a summary notification with duration, active/idle breakdown, and transition count

Previous settings are restored when overnight mode ends.

## Menu Bar

| Icon | Meaning |
|------|---------|
| Animated bolt | Claude is working — Mac is being kept awake |
| Padlock on laptop | Closed-lid mode enabled, waiting for activity |
| Moon with zzz | Idle — no active Claude Code sessions |
| Warning triangle | Scan issue — holding lock during grace period |

The menu shows live status: process state, active sessions, closed-lid state, session cost for today/week, and last check time.

<details>
<summary>How detection works</summary>

Every 5 seconds, the app checks two signals:

1. **Process-level** — Finds running `claude` processes, checks CPU usage, and inspects network connections. High CPU or active connections with moderate CPU means Claude is working.

2. **File-level** — Watches `~/.claude/tasks/` for recent modifications. Catches tool-execution phases where the API connection may be momentarily quiet.

Both signals must go quiet before the sleep lock is released.

</details>

## Configuration

**Show Cost Meter** — Toggle the running cost display in the menu bar on or off. Enabled by default.

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

## Changelog

### v1.2.2

- **Closed-lid popover redesign** — Duration is now displayed in large bold text so it's immediately readable at a glance.
- **Improved duration formatting** — Shows "15 sec", "9 mins 11 sec", or "2 hours 13 mins" instead of abbreviated units.
- **Lower summary threshold** — Popover now triggers after 10 seconds of closed-lid activity (was 60 seconds).
- **IOKit lid detection** — Uses the hardware clamshell sensor (`AppleClamshellState`) instead of CoreGraphics display lists, fixing reliability issues when `pmset disablesleep` is active.

### v1.2.1

- **App icon** — Custom coffee cup + lightning bolt icon in Claude's terracotta.
- **App renamed** — Bundle is now "Claude Caffeine.app" (with a space) in Applications.
- **Gatekeeper bypass** — Added `xattr` instructions for unsigned app warning.

### v1.2.0

- **Closed-lid summary popover** — When you open the lid, shows how long Claude kept working while it was closed. If the Mac slept after Claude went idle, that's noted too.

### v1.1.1

- **Show Cost Meter toggle** — Menu item to hide/show the cost display in the menu bar, with API pricing disclaimer.

### v1.1.0

- **Session cost tracking** — Parses `~/.claude/projects/` JSONL logs to estimate API costs. Per-model pricing (Opus, Sonnet, Haiku) including cache tokens. Costs refresh every 30 seconds with file-level caching.
- **Cost by project** — Submenu breaking down costs per project.
- **Task completion notifications** — Notification + sound when Claude finishes, with duration and cost delta summary.
- **Animated menu bar icon** — Bolt icon animates while Claude is active, with live today cost display.
- **Per-model pricing** — Each message is costed using its own model, so mixed-model sessions are accurate.
- **Removed pause monitoring** — Redundant since the sleep lock auto-releases when Claude goes idle.
- **API pricing disclaimer** — README note that cost estimates are for pay-per-token API users only.

### v1.0.0

- Initial release: sleep prevention, closed-lid mode, smart detection, overnight mode, low battery protection, clean shutdown.

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
