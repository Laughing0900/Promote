# Promote

A macOS agent multiplexer built on tmux. Promote lists your tmux sessions in a sidebar with git branch and PR status, embeds a terminal attached to the selected session, and tracks AI coding agents (claude, pi, cursor, opencode, codex) running in any pane — showing whether each one is working, waiting for input, or done.

## Requirements

- macOS 14+
- `tmux` and `gh` installed at `/opt/homebrew/bin` (Homebrew)
- `git` at `/usr/bin/git` (ships with Xcode Command Line Tools)

`gh` must be authenticated (`gh auth login`) for PR badges; without it they silently disappear.

## Install

```sh
./install.sh
```

Builds the release binary, packages `Promote.app`, and installs it to `/Applications`.

## Run from source

```sh
swift run Promote
```

## Usage

- Sessions appear in the sidebar automatically (refreshes every 2s); select one to attach.
- Each row shows branch, PR status, and agent/service state — see [Sidebar session display](#sidebar-session-display) below.
- Activity panel appears at the bottom when any pane runs an agent CLI; click a row to jump to that session.
- Dev servers (node, npm, bun, yarn, pnpm, deno, turbo, …) show as a teal **Running** row in the same panel, and a teal dot appears left of the session name.

![Usage](assets/manual.jpeg)

## Sidebar session display

Each session row shows, top to bottom: the session **name** (preceded by a teal dot when a dev server is running, and a lock icon when locked), the **repo path**, and a **PR badge** linking to the pull request for the current branch. A cluster of status dots on the right reflects the agent(s) running in that session; hold ⌘ (or hover) to reveal the session's jump-number badge. The current **branch** is available via right-click → *Copy Branch Name*.

![PR status badges](assets/pr-status.jpg)

PR badges follow `gh pr view` for the session's branch:

| Badge | State |
|-------|-------|
| 🔵 Open | PR is open |
| 🔴 Closed | Closed without merging |
| 🟢 Merged | PR was merged |
| ⚪ Draft | Open draft PR |

Right-click a session for the full menu:

- **Rename**, **Copy Name**, **Copy Path**, **Copy Branch Name**
- **Reveal in Finder**, **Open in VS Code**
- **Color** (palette / custom / none), **Group** (assign / new group)
- **Lock** (protect from ⌘W and Kill), **Kill Session**

## Keyboard shortcuts

![Keyboard shortcuts](assets/shortcut-keys.jpg)

| Shortcut | Action |
|----------|--------|
| Hold ⌘ | Reveal jump-number badges in the sidebar and a shortcuts hint |
| ⌘N | New session |
| ⌘1–9 | Jump to session (sidebar order) |
| ⌘\ | Split pane right |
| ⌘⇧\ | Split pane down |
| ⌘W | Close current pane |
| ⌘⇧R | Force refresh (reload PR / branch / agent status) |
| ⌘+ / ⌘− / ⌘0 | Terminal font size bigger / smaller / reset |
| ⌘/ | Keyboard shortcuts cheat sheet |

## Agent status colors

| Icon | Color | Status | Meaning |
|------|-------|--------|---------|
| <img src="assets/loading.svg" width="20"> | Yellow | Working | Agent is actively running |
| <img src="assets/blocked.svg" width="20"> | Red | Blocked | Waiting for your input (permission prompt / y-n question) |
| <img src="assets/done.svg" width="20"> | Blue | Done | Finished working since you last looked |
| <img src="assets/idle.svg" width="20"> | Gray | Idle | Agent open but nothing happening |
| <img src="assets/running.svg" width="20"> | Green | Running | Dev server / service is up (shown as a **Running** row and a dot left of the session name) |
