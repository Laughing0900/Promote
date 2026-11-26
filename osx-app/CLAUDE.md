# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Promote is a macOS (14+) SwiftUI app that manages tmux sessions: a sidebar lists sessions with git/PR metadata, and selecting one attaches an embedded SwiftTerm terminal to it. Single SPM executable target, one dependency (SwiftTerm). Layout tree has Swift Testing tests (`swift test`).

## Commands

Run from `osx-app/` (the SPM package root):

```sh
swift build          # build
swift run Promote    # build + launch the app
swift test           # layout tree tests
```

Runtime requirements on the machine: `tmux` and `gh` at `/opt/homebrew/bin`, git at `/usr/bin/git` — paths are hardcoded in `Sources/Promote/Shell.swift`. PR badges silently disappear if `gh` is missing or unauthenticated (all shell failures return nil, never throw).

## Architecture

All code in `Sources/Promote/`, one file per concern:

- `main.swift` — app entry + `ContentView` (NavigationSplitView), 2s refresh timer, keyboard shortcuts (⌘N new session, ⌘1–9 jump by sidebar order, ⌘+/−/0 font size), titlebar accessory buttons installed via AppKit.
- `SessionStore.swift` — the only state owner (`ObservableObject`). All tmux/git/gh calls live here. Everything else renders from it.
- `SidebarView.swift` — session list UI: groups, drag-reorder, rename, color, context menu.
- `TerminalPane.swift` — `NSViewRepresentable` wrapping SwiftTerm's `LocalProcessTerminalView`; runs `tmux attach-session -t =<name>` (`=` forces exact match — this convention is used for all tmux `-t` targets). Keyed by `.id(name)` so each session gets a fresh terminal.
- `Layout.swift` — pure `LayoutNode` tree (binary splits, tab leaves) for session groups; unit-tested in `Tests/PromoteTests` (`swift test`).
- `GridView.swift` — renders a group's layout: `SplitContainer` (draggable divider), tab strip, one `TerminalPane` per leaf (active tab only).
- `AgentHooks.swift` — live agent status (approach from asafofer/perch): `HookReport` (the `@promote-status` pane option), `ClaudeRegistry` (Claude Code's own `~/.claude/sessions/<pid>.json`), `resolve()` which merges both with the screen scrape, and the installer for the repo's `/extension` pieces (menu: Promote > Live Agent Status > Claude Code / Codex / pi).
- `Shell.swift` — `run()` helper: sync Process wrapper, nil on any failure, stderr discarded.
- `Models.swift` — `Session`, `PRState`, `Details`, color helpers, palette.

### Data flow

Timer (2s) → `store.refresh()` → `tmux list-panes -a -F "#{session_name}\t#{pane_current_path}"` builds the session list (sidebar path = the session's active pane in its active window, so `cd` in any window/split shows up; falls back to first pane) → per session, `fetchDetails` on a private serial queue runs `git branch --show-current` and `gh pr view` (cached 60s per path in `prCache`) → publishes to `details` on main. Don't use `#{session_path}` — it's the stale session start dir.

Agent status, three sources in order (`AgentHooks.resolve`): (1) the agent's extension from `/extension` (Claude Code and Codex hook scripts, a pi extension) writes the pane option `@promote-status` (`<tool> <working|blocked|done|failed> <epoch>`), read as a column of the same `list-panes -a` call; a report only counts for the tool now in the pane. (2) Claude only: its session registry `~/.claude/sessions/<pid>.json` (`status` busy/idle/waiting, `tmux` pane id) — nothing to install, but an internal file. A hook report older than 3s yields to it, because hooks are blind to Esc, a denied prompt and a turn woken by background work. (3) `classifyAgentStatus`, the capture-pane scrape, for everything else (hooks off, opencode, cursor). The app finds `/extension` in its bundle's Resources (`install.sh` copies it) or, under `swift run`/`swift test`, in the checkout via `#filePath`.

Session groups: membership is the tmux session option `@promote-group <gid>` (read as a column of the same `list-panes -a` call); the arrangement is `layouts[gid]` in UserDefaults (`gridLayouts`). `reconcileGroups` converges layouts onto tags every refresh; in-flight tag writes live in `pendingTags` (expire after 5s if never live), just-killed members in `pendingKills` (never re-added from a stale snapshot). Layout names are prunable once seen alive this run, or for any non-live name after 3 reconciled snapshots. ⌘\ / ⇧⌘\ / ⌘T create a new tagged session in the focused cwd. Option commands need `-t =name:` (trailing colon). The sidebar shows one row per group (its first member in sidebar order, `groupRow(of:)`); hidden members ride right after it in `orderTokens` (`expandingGroups`). Tabs drag between cells (`§tab:` payload → `moveTab`).

Per-session metadata (colors, groups, manual sort order, font size) persists in `UserDefaults`, keyed by session *name* — renames must migrate them all, including grid layouts (see `rename()`).

Concurrency model: `prCache` is touched only on `detailsQueue` (serial queue instead of a lock); `@Published` mutations only on main.

## Conventions

- Deliberate simplifications are marked with `// ponytail:` comments naming the ceiling and upgrade path (e.g. 2s polling instead of tmux control-mode). Keep the style: laziest working solution, fewest files, no speculative abstraction.
- `todo.md` tracks feature state; update it when completing items from it.
