# Claude Caffeine 
![Claude Caffeine](assets/icon-small.png)

**Problem:** You start a Claude Code task or a Cursor agent, then you realize you need to step away. You can't close your Mac laptop because sleep would stop the work. You have 2 bad options — walk around with the lid open, or stop the agent.

**Solution:** Claude Caffeine is a lightweight menu bar app that keeps your Mac awake *only* while Claude Code or a local Cursor agent is working — including with the **lid closed**. The moment they go idle, normal sleep resumes. No config, no account, runs entirely locally.

![App icon](assets/claude-caffeine.png)
---

## Key Features

| | |
|---|---|
| **Close the lid, keep agents running** | Close your MacBook and walk away. Claude Code and local Cursor agents keep working. When they go idle, your Mac will go to sleep. When you open the lid, a popover shows how long it ran while closed. |
| **See your API spend at a glance** | Menu bar shows cost today and this week; submenu breaks it down by project. For **Claude Code API users only** (pay-per-token); estimates use Anthropic’s published rates. |

Plus: task-completion notifications with sound, configurable keep-awake timer after idle, low-battery protection, and clean shutdown so sleep always restores on quit.

---

## Install


**macOS 13 (Ventura) or later.**

```bash
brew install --cask jmslau/tap/claude-caffeine
xattr -d com.apple.quarantine /Applications/Claude\ Caffeine.app
open /Applications/Claude\ Caffeine.app
```

The `xattr` command clears the macOS Gatekeeper warning (the app isn’t notarized yet). Or go to **System Settings → Privacy & Security** and click **Open Anyway** after the first launch attempt.

### Upgrade

```bash
brew upgrade --cask jmslau/tap/claude-caffeine
xattr -d com.apple.quarantine /Applications/Claude\ Caffeine.app
open /Applications/Claude\ Caffeine.app
```

If `brew upgrade` fails with "App source is not there", run `brew uninstall --cask claude-caffeine` then reinstall with the install command above.

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

---

## How it works

The app monitors **Claude Code** and **local Cursor agents** using native hooks.

1. **Claude Code hooks** — Claude Code is configured to trigger scripts on session events (UserPromptSubmit, PreToolUse, Stop, etc.). These scripts manage session files under `~/.claude/caffeine_sessions/`.
2. **Cursor hooks** — User-level hooks in `~/.cursor/hooks.json` fire on Agent Chat / Cmd+K events (`beforeSubmitPrompt`, `preToolUse`, `stop`, `sessionEnd`, and related heartbeats). These scripts manage session files under `~/.cursor/caffeine_sessions/`. Cursor **cloud agents** are not covered: they already run off-machine, and user-level hooks do not load there.
3. **Heartbeat** — To handle manual interrupts (like pressing Escape) or crashes, the app uses a 5-minute heartbeat timeout and PID liveness checks.

If any valid Claude Code or Cursor session is active, the Mac stays awake. When sessions time out or end, the sleep lock is released. Tab completions do not count as agent activity.

---

## Cursor support

Local Cursor agents keep the Mac awake the same way Claude Code does. On first launch, Claude Caffeine installs user-level hooks in `~/.cursor/hooks.json` (existing hooks are preserved) and writes session files under `~/.cursor/caffeine_sessions/`. Hook scripts use Node.js.

| Covered | Not covered |
|---|---|
| Agent Chat, Cmd+K, and local background agents | **Cloud agents** — they already run on Cursor’s VMs, so sleeping the Mac does not stop them |
| Multiple concurrent local agents | **Tab completions** — inline autocomplete is not treated as an agent |

The menu shows combined status, for example `Activity: Active (Claude 2, Cursor 1)`.

Cursor already holds an idle wake lock during an agent loop, but it cannot prevent lid-close sleep. Closed-lid mode is the part Claude Caffeine adds.

---

## Closed-lid mode

The standout feature: your MacBook stays awake with the lid shut while Claude Code or a local Cursor agent is working. When you open the lid, you get a clear summary of how long it ran while closed.

![Open-lid summary popover](assets/open-lid-notification.png)

On first launch you’ll be prompted to install a small privileged helper (admin password once). You can skip it — the app still prevents idle sleep, just not lid-close sleep. Install or remove it anytime from the menu.

**Under the hood:** A scoped sudoers entry lets your user run a script that toggles `pmset disablesleep`. Lid state comes from the IOKit clamshell sensor, so it’s reliable regardless of display settings.

**Thermal note:** With the lid closed, cooling is reduced. Use a hard surface or stand for long sessions.

**If the app exits without cleanup:**

```bash
sudo pmset -a disablesleep 0
```

---

## Session cost tracking (API users)

The app reads Claude Code session logs (`~/.claude/projects/`) to estimate API cost from token usage. In the menu bar you see:

- **Cost today** and session count  
- **Cost this week** (rolling 7 days)  
- **Cost by project** in a submenu  

Pricing follows Anthropic’s **standard** API table (per-model input/output and 5m prompt-cache write / cache-hit rates). Each billable assistant row in the JSONL is costed by its own model; rows with `model: "<synthetic>"` are excluded (same as common community parsers). Estimates do **not** include fast mode, Batch API, geo routing premiums, or a split between 5m vs 1h cache writes (logs only expose aggregate cache token counts). Costs refresh every 30 seconds.

> **Note:** These are estimates for **API (pay-per-token) usage**. If you’re on Claude Pro or Max, the numbers won’t match your actual bill.

You can hide the cost meter from the menu: **Show Cost Meter** toggle.

---

## Keep Awake After Idle

By default, your Mac sleeps as soon as Claude Code and Cursor go idle. If you're using **Claude Remote** (controlling Claude Code from your phone) or waiting on a long local Cursor run, you may want the Mac to stay awake longer — or indefinitely.

From the menu, choose **Keep Awake After Idle** and pick a duration:

| Option | Use case |
|--------|----------|
| **Off** (default) | Mac sleeps when Claude Code and Cursor go idle |
| **1–4 Hours** | Lid closed in your backpack; saves battery |
| **12 Hours** | Overnight unattended session |
| **Forever** | Plugged in at home, using Claude Remote or leaving local agents ready all day |

The menu shows a countdown while idle. Low-battery protection still applies regardless of the setting.

---

## Menu bar

| Icon | Meaning |
|------|--------|
| Animated bolt | Claude Code or a Cursor agent is working — Mac is being kept awake |
| Padlock on laptop | Closed-lid mode on, waiting for activity |
| Moon with zzz | Idle — no active Claude Code or Cursor sessions |
| Warning triangle | Scan issue — lock held during grace period |

The menu shows live status: Claude and Cursor activity counts, closed-lid state, today/week cost (if enabled), and last check time.

---

## Configuration

- **Keep Awake After Idle** — How long to hold the sleep lock after Claude Code and Cursor go idle (Off, 1h, 2h, 4h, 12h, Forever).
- **Show Cost Meter** — Show or hide the cost display in the menu bar (on by default).
- **Notifications** — Toggle completion notifications and sound separately.

---

## Development

```bash
swift build          # debug build
swift test           # run tests
swift run            # run from source
```

Release build and cask update:

```bash
./scripts/release.sh X.X.X
```

---

## Changelog

### Unreleased

- **No more "finished working" while Claude still works** — Claude Code sends subagent hooks with the parent's session id, so every finished subagent (`SubagentStop`) ended the whole session, and a turn that ended while background agents kept running ("Waiting for 1 background agent to finish") counted as done. Both fired a premature completion notification and could let the Mac sleep mid-task. Now a finished subagent keeps the session active, and so does a `Stop` whose `background_tasks` still lists agent work; background shells such as dev servers do not.
- **Auto-Resume works again, without a shell wrapper** — Since v1.3.3 Auto-Resume never did anything: the Python wrapper's limit regex was double-escaped and never matched. It now uses Claude Code's `StopFailure` hook: when a usage limit ends a turn ("You've hit your session limit · resets 3pm"), Claude Caffeine keeps the Mac awake, including closed-lid, until shortly after the reset. That is what the interactive Claude Code CLI needs to continue on its own: choose "Wait here, then continue automatically" when the limit is reached (or run `/rate-limit-options`) if it isn't already set to. The hold also applies to sessions in the desktop app and IDEs, which don't continue by themselves. It ignores the 70%+ usage warnings and never types into your session. The `claude` alias is removed from your shell profile on launch, and the old wrapper becomes a pass-through for terminals that are still open.

### v1.3.6

- **Updated pricing for Sonnet 5, Opus 5, Opus 4.8, and Fable 5** — Sonnet 5 now uses Anthropic’s permanent \$2 / \$10 per MTok rate (5m cache write \$2.50, cache hit \$0.20), not the Sonnet 4.x \$3 / \$15 tier. Opus 5 and Opus 4.8 stay on the current Opus \$5 / \$25 tier; Fable 5 stays at \$10 / \$50.
- **Cursor agent support** — Local Cursor Agent Chat, Cmd+K, and background agents keep the Mac awake (including closed-lid). Cloud agents and Tab completions are not covered.

### v1.3.5

- **Updated pricing for Opus 4.7** — Opus 4.5, 4.6, and 4.7 use Anthropic’s current standard API rates (\$5 / \$25 per MTok in/out, with 5m cache write and cache-hit pricing). Legacy Opus 4 / 4.1 and snapshot-style ids keep the older tier.
- **Session cost parsing** — Skips `<synthetic>` assistant rows; only counts assistant usage rows with an explicit `input_tokens` field (aligned with common JSONL parsers). Token counts coerce safely from JSON numbers or strings.
- **Haiku 4.5 pricing** — Corrected to the published Haiku 4.5 tier vs Haiku 3.5.
- **Regression tests** — Expanded coverage for tiers, cache math, malformed JSON lines, and week vs today rollups.

### v1.3.4

- **Auto-Resume shell profile safety** — Profile injection no longer uses multiline Swift interpolation for the `~/.zshrc` snippet, and enabling Auto-Resume strips accidental “Swift template” garbage lines so `source ~/.zshrc` cannot break from a bad install. Toggle Auto-Resume off and on once to repair an affected profile.

### v1.3.3

- **Hook-based activity detection** — Migrated from legacy process/file polling to native Claude Code hooks (`settings.json`). Faster, more reliable, and lower overhead.
- **Heartbeat monitoring** — Robust detection of manual terminal interrupts (Escape key) and crashes via a 5-minute heartbeat timeout and PID liveness checks.
- **Auto-Resume after limit reached** — You kick off Claude before going to bed, and it uses up token limit in the first 10 mins. Claude Caffeine will now auto-resume Claude after the token limit is reset.

### v1.3.2

- **Smarter completion notifications** — Reduced false-positive "task completed" sounds caused by CPU fluctuations when Claude is idle. A new multi-layer detection system uses CPU smoothing (3-sample sliding window), hysteresis with separate enter/exit thresholds, file-activity corroboration, and a 60-second cooldown between notifications.

### v1.3.1

- **Thermal protection** — Releases the sleep lock and suspends closed-lid mode when macOS reports a critical thermal state, letting your Mac cool down automatically.

### v1.3.0

- **Keep Awake After Idle** — Designed for Claude Remote sessions, you can now keep your computer awake even after Claude goes idle. Configurable timer (1h, 2h, 4h, 12h, Forever) to hold the sleep lock after Claude becomes idle. 
- **Auto-dim screen when lid is closed** - Save more battery. While Claude Caffeine will keep your laptop awake to run Claude, it will auto dim the screen when the lid is closed to save battery. When you open your lid again, it will automatically resume to the previous brightness.

### v1.2.2

- **Closed-lid popover redesign** — Duration in large bold text for quick reading.
- **Improved duration formatting** — "15 sec", "9 mins 11 sec", or "2 hours 13 mins".
- **Lower summary threshold** — Popover after 10 seconds of closed-lid activity (was 60).
- **IOKit lid detection** — Uses hardware clamshell sensor for reliability when `pmset disablesleep` is active.

### v1.2.1

- **App icon** — Custom coffee cup + lightning bolt in Claude terracotta.
- **App renamed** — "Claude Caffeine.app" in Applications.
- **Gatekeeper** — Added `xattr` instructions for unsigned app warning.

### v1.2.0

- **Closed-lid summary popover** — Shows how long Claude ran while the lid was closed when you open it.

### v1.1.1

- **Show Cost Meter toggle** — Hide/show cost in menu bar; API pricing disclaimer.

### v1.1.0

- **Session cost tracking** — From `~/.claude/projects/` JSONL; per-model pricing including cache tokens.
- **Cost by project** — Submenu with per-project breakdown.
- **Task completion notifications** — Notification + sound with duration and cost delta.
- **Animated menu bar icon** — Bolt animates when Claude is active; live today cost.
- **Per-model pricing** — Accurate for mixed-model sessions.
- **API pricing disclaimer** — Cost estimates for pay-per-token API users only.

### v1.0.0

- Initial release: sleep prevention, closed-lid mode, detection, low battery protection, clean shutdown.

---

## Uninstall

```bash
brew uninstall claude-caffeine
```

If you installed the closed-lid helper, remove it first via **Closed-Lid Mode → Uninstall Helper**, or:

```bash
sudo rm /private/etc/sudoers.d/claude_caffeine
rm -rf ~/Library/ClaudeCaffeine
```

To remove the Cursor hooks Claude Caffeine added (this does not delete other entries in `hooks.json`):

```bash
rm -rf ~/.cursor/caffeine-hooks ~/.cursor/caffeine_sessions
```

Then delete any `caffeine-hooks` commands from `~/.cursor/hooks.json`.

---

## License

MIT
