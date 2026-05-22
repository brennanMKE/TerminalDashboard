# Terminal Dashboard — Product Requirements

## Overview

`tuidash` is a single CLI tool built in Swift using SwiftTUI. It supports two operating modes:

- **Dedicated mode** — runs one view full-screen with no tab bar and no view switching. The user picks the view as a subcommand.
- **Auto mode** — runs all data sources simultaneously and temporarily surfaces the most relevant view when a significant event fires, then returns to the user's chosen view.

The working directory is assumed to be a git-managed project. A per-project configuration file stores defaults so the tool can run without arguments.

**Tech stack:** Swift 6.0+, macOS 13+, SwiftTUI, Swift Package Manager.

---

## Subcommands

```
tuidash             Auto mode (default)
tuidash auto        Auto mode (explicit)
tuidash git         Dedicated Git Status view
tuidash crashes     Dedicated Crashes view
tuidash logs        Dedicated Logs view
tuidash config      Interactive setup wizard; writes config to working directory
```

---

## Configuration File

Running `tuidash config` launches a short interactive wizard and writes `.tuidash.toml` to the working directory.

```toml
# .tuidash.toml — project-level configuration

[git]
repo = "."                          # path relative to config file location
tool = "gitup {dir} -t"             # optional; {dir} is replaced with the repo path at runtime

[crashes]
app = "MyApp"                       # crash log filename prefix filter
output = "./crashes"                # extraction destination

[logs]
subsystem = "com.example.MyApp"
categories = ["networking", "auth"] # optional; empty = all categories
process = ""                        # optional process name filter
level = "info"                      # minimum log level
```

**Precedence:** CLI flags > `.tuidash.toml` in working directory > `~/.config/tuidash/config.toml` (global fallback).

If a required value (`app` for crashes, `subsystem` for logs) is absent from both sources, the view shows a "not configured" prompt rather than crashing.

---

## Dedicated Mode

When a view subcommand is given, only that view and its data source run. There is no tab bar. The full terminal area belongs to the single view. No view-switching shortcuts are active.

```
┌─────────────────────────────────────────────────────────────────┐
│  Git Status — main — ↑ 0  ↓ 2 — updated 14:32:01               │  ← view header
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│                   view content                                    │
│                                                                   │
├─────────────────────────────────────────────────────────────────┤
│  Pushed to origin/main                                           │  ← status / errors only
└─────────────────────────────────────────────────────────────────┘
```

---

## Auto Mode

All three data sources run in the background. The tab bar reflects live activity across all of them.

```
┌─────────────────────────────────────────────────────────────────┐
│  [G] Git   [C] Crashes ●   [L] Logs ●●                     AUTO │  ← tab bar
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│                   active view content                             │
│                                                                   │
├─────────────────────────────────────────────────────────────────┤
│  Auto → Logs: error detected — returning in 8s                  │  ← status / errors only
└─────────────────────────────────────────────────────────────────┘
```

### Tab Bar

- Active tab is bold/highlighted.
- Inactive tabs show a badge for unseen significant events:
  - `●` — one new event since last viewed.
  - `●●` — two or more events.
  - Badge clears when that tab becomes visible.
- `AUTO` on the right is bright when Auto Mode is active, dim when suspended.

---

## View Switching

### Manual shortcuts

> **Note:** `Cmd+Shift` combinations are typically intercepted by the terminal emulator before reaching the app. These are the *intended* shortcuts; the exact receivable bindings (likely Ctrl variants or bare letters when no text field is focused) will be confirmed against SwiftTUI's keyboard event API during implementation.

| Intended shortcut | Action |
|---|---|
| Cmd+Shift+G | Switch to Git Status |
| Cmd+Shift+C | Switch to Crashes |
| Cmd+Shift+L | Switch to Logs |
| Cmd+Shift+A | Toggle Auto Mode |
| Cmd+H | Open Help overlay |

Manually switching to a view:
1. Makes that view the **home view** — the view Auto Mode returns to after a temporary switch.
2. Clears the badge for that view.
3. Does not suspend Auto Mode (auto switching can still occur; it will return here after 10s).

### Auto Mode — temporary view switching

When a data source emits a significant event and Auto Mode is active:

1. The badge for that view increments.
2. The visible view switches to the view with the highest-priority pending event.
3. A countdown banner appears in the tab bar: `"Auto → Logs: error — returning in 10s"`.
4. After **10 seconds**, the view automatically reverts to the **home view** (the last view the user manually selected, or the initial view at launch).
5. The badge for the auto-surfaced view clears when it becomes visible, even temporarily.

If the user **manually switches views** during the 10s window, that view becomes the new home view and the countdown is cancelled.

If the user presses **Cmd+Shift+A** during the 10s window, Auto Mode is suspended and the current view stays pinned — no revert occurs.

If a **second significant event** fires while the countdown is running, the timer resets to 10s and the banner updates to reflect the new event. If the new event is higher priority (e.g. `critical` while showing `error`), the view switches again.

---

## Help Overlay

Pressing Cmd+H from any context opens a modal overlay that covers the content area. The tab bar (in auto mode) remains visible. Pressing any key or Cmd+H again dismisses it.

The overlay has two sections:

### Navigation (shown in both dedicated and auto mode)

| Shortcut | Action |
|---|---|
| Cmd+Shift+G | Switch to Git Status |
| Cmd+Shift+C | Switch to Crashes |
| Cmd+Shift+L | Switch to Logs |
| Cmd+Shift+A | Toggle Auto Mode |
| Cmd+H / ? | Toggle this help screen |
| q / Ctrl-C | Quit |

In dedicated mode, the navigation section is omitted and a note reads "Running in dedicated mode — view switching disabled."

### Current view actions

Dynamically populated based on the active view:

**Git Status**

| Shortcut | Action |
|---|---|
| `p` | Push current branch to remote |
| `u` | Pull from remote (fast-forward) |
| `r` | Rebase onto remote branch |
| `o` | Open in external git tool (requires `tool` in config) |

**Crashes**

| Shortcut | Action |
|---|---|
| `↑` / `↓` | Move selection |
| `e` | Extract selected crash to output directory |
| `E` | Extract all matched crashes |

**Logs**

| Shortcut | Action |
|---|---|
| `Space` | Toggle pause / resume |
| `c` | Clear log buffer |

---

## Data Source Architecture

Each data source is an independent Swift actor that:
- Runs continuously from launch until quit.
- Emits typed **`DashboardEvent`** values with a severity level.
- Has no knowledge of which view is currently visible.

In dedicated mode, only the matching data source is started. The `AutoCoordinator` is not instantiated.

### Event severity levels

| Severity | Meaning |
|---|---|
| `info` | Routine state change — does not trigger auto switching |
| `warning` | Noteworthy but not urgent — does not trigger auto switching |
| `error` | Attention warranted — triggers auto switch if Auto Mode is active |
| `critical` | Immediate action needed — triggers auto switch, takes priority over `error` |

### AutoCoordinator switching rules

The coordinator subscribes to all three data sources. On each incoming event:

1. Updates the badge count for the source's view.
2. If severity is `error` or `critical` and Auto Mode is active:
   - `critical` always triggers a switch.
   - `error` triggers a switch unless the currently visible view already has an active `error` or `critical` event.
3. On switch: record the current home view, show the new view, start the 10s revert timer.
4. On timer expiry: revert to home view, clear the countdown banner.

---

## View: Git Status

### Data source behavior

- Polls `git status --porcelain=v2 --branch` every 2s.
- Emits `warning` when the branch falls behind remote.
- Emits `info` on any other working-tree change.

### Display

| Region | Content |
|---|---|
| Header | Repo name, branch, ahead/behind counts, last-updated time |
| File list | Status flag (M / A / D / ? / R), staging state, file path |
| Footer | Result of last git operation; error message if git unavailable; overflow count |

File rows truncate to terminal height; overflow count shown in footer.

### Key bindings

| Key | Action |
|---|---|
| `p` | `git push` — confirm prompt if branch has diverged |
| `u` | `git pull` — fast-forward only |
| `r` | `git pull --rebase` onto remote branch |
| `o` | Open repo in external git tool (if `tool` is configured) |

All git operations run in a background task; the view refreshes when the operation completes. Output or errors from the operation appear in the footer. The `o` binding launches the configured `tool` command with `{dir}` replaced by the resolved repo path; if no `tool` is configured the key does nothing.

### Acceptance criteria

1. Shows modified, staged, untracked, and deleted files with status codes.
2. Shows ahead/behind count; handles no remote or no upstream gracefully.
3. `p`, `u`, `r` run in background; view refreshes on completion; errors surface in footer.
4. Non-git directory or missing `git` binary shows a clear error without crashing the app.

---

## View: Crashes

### Data source behavior

- Watches `~/Library/Logs/DiagnosticReports/` and `/Library/Logs/DiagnosticReports/` via filesystem events (falls back to ≤5s polling).
- New file matching app filter (case-insensitive prefix): emits `critical`.
- Any other new file: emits `info`.

### Display

| Region | Content |
|---|---|
| Matched reports | Filename, crash date, process, exception type; newest first; highlighted |
| Unmatched reports | Same columns, dimmed, separated by a divider |
| Detail pane | For selected report: signal, exception type, first lines of backtrace |
| Footer | Extraction confirmation; error messages; overflow count |

### Key bindings

| Key | Action |
|---|---|
| `↑` / `↓` | Move selection |
| `e` | Extract selected crash to output directory |
| `E` | Extract all matched crashes |

### Acceptance criteria

1. Detects existing crash logs at launch; picks up new files while running.
2. New app-matched file emits `critical` and increments the badge in auto mode.
3. Extraction creates output directory if absent; confirms path in footer.
4. Works when one or both watched directories are absent.
5. No `app` configured: view shows "not configured" prompt; data source emits no events.

---

## View: Logs

### Data source behavior

- Launches `log stream --style ndjson --subsystem <value>` with optional category/process/level flags.
- Parses each JSON line for timestamp, level, category, and message.
- Emits `info` for `debug` / `info` / `notice` lines.
- Emits `warning` for `warning` lines.
- Emits `error` for `error` / `fault` / `critical` lines; debounced — at most one `error` event per 10s.

### Display

| Region | Content |
|---|---|
| Log lines | Timestamp, level badge, category, message; newest at bottom; ring-buffer |
| Footer | Pause/live indicator; active filter summary; error messages |

Color scheme:

| Level | Color |
|---|---|
| `debug` | Dim/gray |
| `info` | Default |
| `notice` | Cyan |
| `warning` | Yellow |
| `error` | Red |
| `fault` / `critical` | Red, bold |

Lines truncate to terminal width. Ring buffer retains the most recent N lines that fit on screen.

### Key bindings

| Key | Action |
|---|---|
| `Space` | Toggle pause / resume |
| `c` | Clear buffer |

### Acceptance criteria

1. `log stream` subprocess launched with correct filter arguments.
2. New lines appear within ~1s of emission.
3. Pause freezes the display; resume re-attaches the live stream.
4. No `subsystem` configured: view shows "not configured" prompt; data source emits no events.
5. Missing `log` binary: clear error in view content area.
6. Subprocess terminated cleanly on quit.

---

## Shared Conventions

- Terminal resize re-renders all regions immediately.
- `q` / Ctrl-C exits cleanly; all background tasks and subprocesses are terminated.
- No scrolling — content truncates to fit terminal height; overflow row count shown in footer.
- Errors in a data source appear in that view's content area and do not crash the app.
- **Footers show status only** — operation results, errors, overflow counts, and auto-mode banners. No persistent key hints. Shortcuts are discoverable via Cmd+H.

---

## Package Structure (target)

```
TerminalDashboard/
├── .tuidash.toml                       # project config (generated by tuidash config)
├── Package.swift
└── Sources/
    └── tuidash/
        ├── main.swift
        ├── Config.swift                # .tuidash.toml parsing and precedence
        ├── Commands/
        │   ├── AutoCommand.swift
        │   ├── GitCommand.swift
        │   ├── CrashesCommand.swift
        │   ├── LogsCommand.swift
        │   └── ConfigCommand.swift     # interactive setup wizard
        ├── DataSources/
        │   ├── DashboardEvent.swift    # severity enum + event struct
        │   ├── GitDataSource.swift
        │   ├── CrashesDataSource.swift
        │   └── LogsDataSource.swift
        ├── Coordinator/
        │   └── AutoCoordinator.swift   # event routing, badge counts, view switching
        └── Views/
            ├── HelpOverlay.swift       # modal help overlay
            ├── TabBar.swift            # auto mode only
            ├── GitView.swift
            ├── CrashesView.swift
            └── LogsView.swift
```

---

## Out of Scope (v1)

- Scrolling within any view.
- Mouse support.
- Non-macOS platforms.
- More than three views.
- Audio or system notification alerts on significant events.
- Remote (SSH) repository support for Git view.
