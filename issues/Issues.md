# TerminalDashboard

A Swift CLI tool (`tuidash`) built with SwiftTUI that provides multiple live terminal dashboard views — Git Status, Crashes, and Logs — with an auto mode that surfaces the most relevant view based on event severity.

This file is the local guide for managing issues in this project. The companion Mac app (Issues.app) watches the `issues/` folder and renders the current state. Markdown files (and `project.json`) are the source of truth — there is no generated artifact or index to keep in sync.

## Folder layout

```
issues/
├── project.json       # canonical project name + repo URL
├── Issues.md          # this file
├── 0001.md            # one file per issue
└── …
```

## Status values

| File value | Display name | Meaning |
|---|---|---|
| `open` | Open | Filed but not yet started |
| `in-progress` | In Progress | Actively being worked on |
| `resolved` | Resolved | Work is done; awaiting user confirmation |
| `closed` | Closed | User has confirmed the fix |
| `wontfix` | Won't Fix | Acknowledged but won't be addressed |

## Critical rule: never close without explicit confirmation

An issue must **never** be marked `resolved`, `closed`, or `wontfix` based on inference. Only when the user has said so in plain language.

## Build / verify command

```bash
./build.sh clean build run
```

## Module conventions

- `Package` — Package.swift, build configuration
- `Config` — `.tuidash.toml` parsing and precedence
- `Commands` — ArgumentParser subcommands
- `DataSources` — Git, Crashes, Logs data source actors
- `Coordinator` — AutoCoordinator, event routing, view switching
- `Views` — SwiftTUI views (Git, Crashes, Logs, TabBar, HelpOverlay)
