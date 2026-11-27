# extension

Agent-side pieces of Promote's live agent status. Each one reports what its agent is doing by
writing the tmux pane option `@promote-status` (`<tool> <working|blocked|done|failed> <epoch>`);
the macOS app reads it back in its `list-panes` call. They do nothing outside tmux.

| Folder | Agent | Installed as | Wired into |
|---|---|---|---|
| `claudecode/hook` | Claude Code | `~/.config/promote/claudecode/hook` | hook entries in `~/.claude/settings.json` |
| `codex/hook` | Codex | `~/.config/promote/codex/hook` | hook entries in `~/.codex/hooks.json` |
| `pi/promote.ts` | pi | `~/.pi/agent/extensions/promote.ts` | pi loads every file in that folder |

Install and remove them from the app: Promote > Live Agent Status. The installer
(`osx-app/Sources/Promote/AgentHooks.swift`) only touches its own entries and files, and keeps a
one-time `*.before-promote` backup of each config file it edits. `osx-app/install.sh` copies this
folder into `Promote.app/Contents/Resources/extension`.
