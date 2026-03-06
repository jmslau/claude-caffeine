# AGENTS.md

## Project Overview

ClaudeCaffeine is a macOS menu bar app (Swift 6.2, Swift Package Manager) that prevents your Mac from sleeping while Claude Code is actively working. It detects Claude Code activity through process inspection and file monitoring, holds IOKit sleep assertions, and optionally prevents lid-close sleep via a privileged helper.

**Target platform:** macOS 13+ (Ventura and later)
**Runtime:** Runs as a menu bar accessory app (`NSApplication.shared` with `.accessory` activation policy)

## Architecture

```
ClaudeCaffeine.swift          Entry point + AppDelegate (menu bar UI, poll loop, state machine)
    |
    +-- ClaudeTaskActivityMonitor  Polls ~/.claude/tasks/ for file modifications
    |       |
    |       +-- ClaudeProcessDetector  Finds `claude` PIDs, checks lsof for API connections, reads CPU
    |
    +-- SleepAssertionManager      Holds/releases IOKit power assertions (idle sleep + display sleep)
    |
    +-- ClosedDisplayManager       Toggles `pmset disablesleep` via privileged helper script
    |       |
    |       +-- ShellExecutor      Protocol for running shell commands (injectable for testing)
    |
    +-- HelperInstaller            Installs/uninstalls sudoers entry + helper script for closed-lid mode
    |
    +-- BatteryMonitor             Reads IOKit power source info, detects low battery
    |
    +-- PowerSourceMonitor         CFRunLoop-based listener for AC/battery power source changes
```

## Detection Model

The app uses a dual-signal approach, polled every 5 seconds:

1. **Process detection** (`ClaudeProcessDetector`) — Finds running `claude` processes via `ps`, checks for `ESTABLISHED` network connections via `lsof`, and reads CPU usage. A process with active connections OR >5% CPU is considered "actively working."

2. **File activity** (`ClaudeTaskActivityMonitor`) — Scans `~/.claude/tasks/` subdirectories for recent file modifications within the idle threshold. This catches tool-execution phases where the API connection may be momentarily idle.

Either signal keeps the Mac awake. Both must go quiet before the sleep lock is released.

## Key Design Decisions

- **No third-party dependencies.** The entire app is built on Foundation, AppKit, IOKit, and UserNotifications. This keeps the binary small and the attack surface minimal.
- **Sendable-first concurrency.** `ClaudeProcessDetector` and `ClaudeTaskActivityMonitor` are `Sendable` structs. The poll runs on a detached `Task` with `.utility` priority, results are applied on `@MainActor`.
- **Signal handler cleanup.** A `nonisolated(unsafe)` reference to `ClosedDisplayManager` allows SIGTERM/SIGINT/SIGHUP handlers to call `forceDisable()` before exit, ensuring `pmset disablesleep` is always reset.
- **Immutable data flow.** Poll results are captured in `PollSnapshot` value types. The `AppDelegate` applies state changes based on the snapshot — it never mutates shared state from background threads.
- **Testability via injection.** `ClosedDisplayManager` accepts a `ShellExecutor` protocol and a `checkHelperInstalled` closure. `ClaudeTaskActivityMonitor` accepts a custom `tasksRootURL` and `detectProcess` closure. Tests use these seams to avoid touching the real filesystem or running privileged commands.

## Source Files

| File | Lines | Role |
|------|-------|------|
| `ClaudeCaffeine.swift` | ~540 | App entry point, `AppDelegate`, menu bar UI, poll loop, state transitions |
| `ClaudeTaskActivityMonitor.swift` | ~160 | Scans `~/.claude/tasks/` for active sessions based on file modification times |
| `ClaudeProcessDetector.swift` | ~110 | Detects running `claude` processes, checks network connections and CPU usage |
| `SleepAssertionManager.swift` | ~70 | Creates/releases `IOPMAssertion` for system and display sleep prevention |
| `ClosedDisplayManager.swift` | ~120 | State machine for `pmset disablesleep` toggling via privileged helper |
| `HelperInstaller.swift` | ~155 | Installs/uninstalls the sudoers entry and shell script for closed-lid mode |
| `BatteryMonitor.swift` | ~50 | Reads battery level and charging state from IOKit power sources |
| `PowerSourceMonitor.swift` | ~50 | Listens for AC/battery power source changes via `IOPSNotificationCreateRunLoopSource` |

## Test Files

| File | What it tests |
|------|---------------|
| `BatteryMonitorTests.swift` | Battery level reading, low-battery threshold logic |
| `ClaudeTaskActivityMonitorTests.swift` | Session scanning, idle detection, error handling for missing/broken task dirs |
| `ClosedDisplayManagerTests.swift` | Enable/disable state machine, helper-not-installed guard, force disable |
| `HelperInstallerTests.swift` | Script writing, sudoers validation, install/uninstall flows |

## How to Work on This Project

### Build & Run
```bash
swift build           # Debug build
swift build -c release  # Release build (.build/release/ClaudeCaffeine)
swift run             # Build + run
swift test            # Run all tests
```

### App Bundle
```bash
./scripts/make-app-bundle.sh    # Creates dist/Claude Caffeine.app
```

### Important Constraints

- **No `console.log` equivalent** — Use `os.Logger` or remove debug prints before committing.
- **Privileged operations** are isolated to `HelperInstaller` and `ClosedDisplayManager`. All paths in sudoers entries must be space-free.
- **Process detection** matches the exact basename `claude` to avoid false positives from editors or helpers with "claude" in their path.
- **The poll loop** uses a coalescing guard (`isPollInFlight` + `pollQueued`) to prevent overlapping polls when the 5-second timer fires while a scan is still running.
- **Signal handlers** are intentionally minimal — they call `forceDisable()` and `exit(0)`. No locks, no allocations.

### When Adding Features

- Keep detection logic in `ClaudeTaskActivityMonitor` or `ClaudeProcessDetector` — not in `AppDelegate`.
- Keep UI state updates in `applyPoll()` on `@MainActor`. Don't touch UI from background tasks.
- If you add a new component, make it injectable for testing (protocol or closure injection, like `ShellExecutor`).
- The `AppDelegate` is already at ~540 lines. Extract new menu sections or complex logic into separate types if they push it further.

### Tracking Progress with Beads

This project uses **[beads](https://github.com/steveyegge/beads)** (`bd`) — a distributed, Dolt-powered, git-backed graph issue tracker designed for AI agents. Always use `bd` to track what you're working on.

#### First-Time Setup

```bash
# Install bd (one-time, system-wide)
brew install beads        # or: npm install -g @beads/bd

# Initialize in this project (creates .beads/ with a Dolt database)
cd ClaudeCaffeine
bd init
```

#### Session Workflow

1. **Check for ready tasks** (no open blockers):
   ```bash
   bd ready
   ```

2. **Claim a task** atomically (sets assignee + in_progress):
   ```bash
   bd update <id> --claim
   ```

3. **Or create a new task** if none exists for your work:
   ```bash
   bd create "Add notification sounds" -p 1
   ```

4. **Reference the issue ID in commits**:
   ```bash
   git commit -m "Add completion chime support (bd-a1b2)"
   ```

5. **Close when done**:
   ```bash
   bd close <id> --reason "Completed"
   ```

#### Essential Commands

| Command | Action |
|---------|--------|
| `bd ready` | List tasks with no open blockers |
| `bd create "Title" -p 0` | Create a P0 task |
| `bd update <id> --claim` | Atomically claim a task |
| `bd show <id>` | View task details and audit trail |
| `bd dep add <child> <parent>` | Link tasks (blocks, related, parent-child) |
| `bd list` | List all issues |
| `bd sync` | Sync Dolt database with remote |

#### Important Rules

- **DO NOT use `bd edit`** — it opens an interactive editor that AI agents can't use. Use `bd update` with flags instead:
  ```bash
  bd update <id> --description "new description"
  bd update <id> --title "new title"
  ```
- **Use `--json` flag** when parsing output programmatically.
- **Use stdin for special characters** (backticks, quotes):
  ```bash
  echo 'Description with `backticks`' | bd create "Title" --stdin
  ```
- **Include issue IDs in commit messages** — enables `bd doctor` to detect orphaned issues.

#### Why This Matters

Beads survives conversation compaction. If context is lost mid-session, run `bd show <id>` on your current issue to recover where you left off. Hash-based IDs (`bd-a1b2`) prevent merge collisions across multi-agent and multi-branch workflows.

### Planned Features (from ISSUES.md)

- **CKA-1:** Task completion notifications with sound (active-to-idle transition detection)
- **CKA-2:** Live animated menu bar icon + cost/token counter
- **CKA-3:** Homebrew cask formula
- **CKA-4:** Overnight mode with morning summary

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
