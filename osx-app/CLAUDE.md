# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Promote is a macOS (14+) SwiftUI app that manages tmux sessions: a sidebar lists sessions with git/PR metadata, and selecting one attaches an embedded SwiftTerm terminal to it. Single SPM executable target, one dependency (SwiftTerm). No tests.

## Commands

Run from `osx-app/` (the SPM package root):

```sh
swift build          # build
swift run Promote    # build + launch the app
```

Runtime requirements on the machine: `tmux` and `gh` at `/opt/homebrew/bin`, git at `/usr/bin/git` — paths are hardcoded in `Sources/Promote/Shell.swift`. PR badges silently disappear if `gh` is missing or unauthenticated (all shell failures return nil, never throw).

## Architecture

All code in `Sources/Promote/`, one file per concern:

- `main.swift` — app entry + `ContentView` (NavigationSplitView), 2s refresh timer, keyboard shortcuts (⌘N new session, ⌘1–9 jump by sidebar order, ⌘+/−/0 font size), titlebar accessory buttons installed via AppKit.
- `SessionStore.swift` — the only state owner (`ObservableObject`). All tmux/git/gh calls live here. Everything else renders from it.
- `SidebarView.swift` — session list UI: groups, drag-reorder, rename, color, context menu.
- `TerminalPane.swift` — `NSViewRepresentable` wrapping SwiftTerm's `LocalProcessTerminalView`; runs `tmux attach-session -t =<name>` (`=` forces exact match — this convention is used for all tmux `-t` targets). Keyed by `.id(name)` so each session gets a fresh terminal.
- `Shell.swift` — `run()` helper: sync Process wrapper, nil on any failure, stderr discarded.
- `Models.swift` — `Session`, `PRState`, `Details`, color helpers, palette.

### Data flow

Timer (2s) → `store.refresh()` → `tmux list-panes -a -F "#{session_name}\t#{pane_current_path}"` builds the session list (first pane per session = leftmost pane wins, so splits don't change the sidebar path) → per session, `fetchDetails` on a private serial queue runs `git branch --show-current` and `gh pr view` (cached 60s per path in `prCache`) → publishes to `details` on main. Don't use `#{session_path}` — it's the stale session start dir.

Per-session metadata (colors, groups, manual sort order, font size) persists in `UserDefaults`, keyed by session *name* — renames must migrate all three (see `rename()`).

Concurrency model: `prCache` is touched only on `detailsQueue` (serial queue instead of a lock); `@Published` mutations only on main.

## Conventions

- Deliberate simplifications are marked with `// ponytail:` comments naming the ceiling and upgrade path (e.g. 2s polling instead of tmux control-mode). Keep the style: laziest working solution, fewest files, no speculative abstraction.
- `todo.md` tracks feature state; update it when completing items from it.
