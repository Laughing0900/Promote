# Session Grid — multiple tmux sessions in one panel

Date: 2026-09-30
Project: `osx-app/` (Promote)
Status: design approved in chat, pending spec review

## Goal

Show several tmux sessions side by side (and as tabs) in Promote's detail panel, like cmux —
e.g. two agents working on two PRs visible at once. tmux stays the backend: every cell is an
ordinary, independent tmux session that keeps running when Promote quits and can still be
attached from a plain terminal.

## Decisions (from brainstorming)

| Topic | Decision |
|---|---|
| Group membership | tmux user option `@promote-group <gid>` on each member session |
| Layout | Free grid: nested binary splits (H/V), each leaf holds tabs |
| Layout storage | `UserDefaults` keyed by gid; reconciled against tmux tags every refresh |
| Sidebar | Flat, unchanged: every member keeps its own row; clicking one opens the group grid with that tab focused |
| Joining a group | Split / new tab from inside the panel creates a new tagged session in the focused cwd |
| Split shortcuts | Existing `splitPaneRight`/`splitPaneDown` shortcuts now do app-level grid splits (tmux-native splits still reachable via tmux prefix) |
| ⌘W on a grouped tab | `kill-session`; confirm dialog only if an agent is detected; locked sessions refuse |
| ⌘W on a solo session | Unchanged (closes tmux pane; confirm on last pane) |
| Verification | Swift Testing target for pure layout-tree code + `swift build` + manual checklist |

## Out of scope (v1)

Dragging tabs between leaves, dragging sidebar rows into the grid, keyboard focus movement
between leaves (⌥⌘ arrows), zooming a leaf, grouped/aggregated sidebar rows.

## Verified tmux behavior (tmux 3.7b)

- `#{@promote-group}` expands in `list-panes -a -F` (empty when unset) — no extra subprocess.
- The tag survives `rename-session`.
- `set-option` / `show-options` / `set-option -u` take a **pane** target: must use `=name:`
  (trailing colon). `-t =name` alone fails with `no such session`.

## Data model — `Layout.swift` (new, pure, no tmux/AppKit)

```swift
enum SplitAxis: String, Codable { case horizontal, vertical }   // horizontal = left|right

indirect enum LayoutNode: Codable, Equatable {
    case leaf(tabs: [String], active: Int)                          // session names, non-empty
    case split(axis: SplitAxis, ratio: Double, first: LayoutNode, second: LayoutNode)
}
```

Pure operations (all return a new tree; `nil` = tree became empty):

- `contains(_ name:) -> Bool`, `allSessions -> [String]` (in-order)
- `insertTab(_ name:, into focused:) -> LayoutNode` — append to the leaf containing `focused`, make it active
- `split(_ name:, beside focused:, axis:) -> LayoutNode` — replace the focused leaf with
  `.split(axis, 0.5, oldLeaf, .leaf([name], 0))`
- `removing(_ name:) -> LayoutNode?` — drop the tab; empty leaf removed; a split with one
  surviving child collapses into that child; `active` clamped
- `renaming(_ old:, to new:) -> LayoutNode`
- `activating(_ name:) -> LayoutNode` — set `active` in the leaf containing `name`
- `settingRatio(at path: [Bool], _ ratio:) -> LayoutNode` — path addresses a split (false = first)
- `reconcile(layout: LayoutNode?, members: [String], prunable: Set<String>) -> LayoutNode?`
  0. `layout == nil` with ≥ 2 members (tags set by hand, or layout lost) → `.leaf(members, 0)`
  1. drop tabs not in `members` **only if** in `prunable` (see below)
  2. append members missing from the tree as tabs of the first leaf
  3. return `nil` when fewer than 2 members remain in the tree
- `nextFreeName(base:, taken:) -> String` — strip a trailing `-N` from base, return lowest free
  `base-N` with N ≥ 2 (`api` → `api-2`; `api-2` with `api-2` taken → `api-3`)

Ratios clamped to `0.1...0.9`.

## Store changes — `SessionStore.swift`

New state (main-only):

- `groupOf: [String: String]` — session → gid, from the `#{@promote-group}` column of the
  existing `list-panes -a` query (first pane per session, same rule as path).
- `@Published layouts: [String: LayoutNode]` — persisted via `Settings.layouts` (JSON `Data`).
- `pendingTags: [String: String]` — name → gid for every tag write still in flight: the new
  session **and** the focused session on a first split (neither is tagged in tmux yet).

Reconciliation, inside `applySnapshot` on main, per gid in `groupOf ∪ layouts.keys`:

- Snapshot `groupOf` is merged with `pendingTags` (pending wins) before anything else.
- `members` = live sessions tagged with gid ∪ pending names for gid.
- `prunable` = tree names in `seenLive` and not in `pendingTags` (mirrors the existing
  reboot-safe pruning: never prune a name that was never seen alive this run).
- Result `nil` → delete layout; if exactly one live member still carries the tag, clear it
  (`set-option -u -t =name: @promote-group`, on `actionQueue`) so it is solo again.
- A pending name that the snapshot shows tagged with its gid is removed from `pendingTags`.

`rename()` additionally rewrites the name in every layout (`renaming`) and in `pendingTags`.

## Actions

Split right / split down / new tab (`splitPaneRight`, `splitPaneDown`, new `newTab`):

```
main:   focused = selected (must exist, not nil)
        gid     = groupOf[focused] ?? short random id (UUID prefix 8)
        name    = nextFreeName(base: focused, taken: live names ∪ pendingTags.keys)
action: cwd = display-message -p -t =focused: #{pane_current_path}
        new-session -d -s name -c cwd
        failure → refresh(), done (nothing to roll back)
main:   layouts[gid] = split/insertTab on (layouts[gid] ?? .leaf([focused], 0))
        pendingTags[name] = gid; if groupOf[focused] == nil { pendingTags[focused] = gid }
        sessions.append(Session(name: name, path: cwd))   (optimistic, like newSession())
        orderTokens: insert name right after focused (persist Settings.order), so members
                     sit together in the flat sidebar
        selected = name
action: set-option -t =name:    @promote-group gid
        set-option -t =focused: @promote-group gid     (idempotent)
        failure → main: layouts[gid] = removing(name) (nil → delete, first split),
                        drop both names from pendingTags, selected = focused;
                        action: kill-session =name
        refresh()
```

The session is created **before** `selected` changes, so the mounted `TerminalPane` never
attaches to a session that doesn't exist yet (same ordering as `newSession()`). The optimistic
`sessions` append keeps `DetailPane` from flashing the empty state until the next refresh.
A refresh landing between `new-session` and `set-option` sees the new name live but untagged;
it is in `pendingTags`, so it counts as a member and is not prunable — it stays in its leaf.

`closeActivePane()` (⌘W):

- selected is solo → unchanged behavior.
- selected is grouped → if locked: no-op. If an agent is detected for it (`agents(for:)`
  non-empty) → set `pendingCloseLastPane` (existing confirm dialog → `kill`). Otherwise
  `kill` directly.
- Focus move happens **inside `kill()`**, only when the kill actually runs (so cancelling the
  confirm dialog leaves focus untouched): if the killed session is `selected` and grouped,
  set `selected` to the next tab in its leaf, else the first session of the remaining tree.

`kill()` from the sidebar on a grouped session gets the same focus move for free.

Tab cycling: `cycleTab(forward:)` — change `active` in the focused leaf and set `selected`.

## UI

`GridView.swift` (new):

- `GridView(node:path:)` recursive: `.split` → `SplitContainer`; `.leaf` → `VStack { TabStrip; TerminalPane(activeTab) }`.
- `SplitContainer(axis:ratio:onRatio:)` — `GeometryReader`, two children, 1pt divider with a
  wider invisible drag handle and resize cursor; updates ratio live, persists on drag end.
- `TabStrip` — one chip per tab: color dot, agent status dot, name, × (= close that tab).
  Click chip → activate + select. Focused leaf gets an accent top border.
- Only the **active** tab of each leaf is mounted: `TerminalPane(session:)` with
  `.id("\(name)#\(store.terminalEpoch)")`. `// ponytail:` inactive tabs are unmounted (no
  tmux client, no size tug); upgrade path = keep all mounted in a ZStack if switching feels slow.

`main.swift`:

- `DetailPane`: selected solo → today's single `TerminalPane`; selected grouped →
  `GridView(layouts[gid])`.
- Shortcuts: ⌘T new tab, ⌘⇧] / ⌘⇧[ cycle tabs. Existing split shortcuts now call the
  grid split. ⌘1–9, title, rename, color, lock, copy-path keep using `selected`.

`TerminalPane.swift`: `DroppableTerminalView.becomeFirstResponder` override calls an
`onFocus` closure → `store.selected = session` (and `activating`). When `selected` changes
from the sidebar, the matching terminal is made first responder.

`Settings.swift`: `layouts` key (`[String: LayoutNode]` as JSON `Data`).

`CheatSheetView.swift`: list ⌘T, ⌘⇧[ ], and the new meaning of the split shortcuts.

## Error handling

Same convention as the app: shell failures return nil, never throw. Failed actions roll back
their optimistic layout change. Reconciliation is the safety net — the layout always
converges to tmux truth within one refresh (2s). Manual `set-option @promote-group` edits from a
terminal are picked up the same way. A tmux server restart drops all tags → everything goes
solo; layouts for sessions never seen alive this run are not pruned.

## Testing

`Package.swift`: add `.testTarget(name: "PromoteTests", dependencies: ["Promote"])` using
Swift Testing (`import Testing`, `@testable import Promote`). If linking the executable
target into tests fails, fallback: move `Layout.swift` into a `PromoteCore` library target
that `Promote` depends on.

`Tests/PromoteTests/LayoutTests.swift` covers: insertTab, split, removing (tab / leaf /
split collapse / last-to-nil), active clamping, renaming, activating, settingRatio + clamp,
reconcile (nil layout + ≥2 members → single leaf, add missing, prune only prunable, keep pending incl. untagged focused on first
split, nil under 2 members), Codable
round-trip, nextFreeName.

Manual checklist (`swift run Promote`):

1. Solo session: ⌘W, rendering unchanged.
2. Split right on solo `x` → `x-2` appears right, focused; both tagged (`tmux list-panes -a -F '#S #{@promote-group}'`).
3. Split down in `x-2`, ⌘T in a leaf → correct placement; ⌘⇧[ ] cycles.
4. Click sidebar member → its tab focused in grid; click a terminal → sidebar selection follows.
5. Drag divider, relaunch app → layout and ratios restored.
6. ⌘W on grouped tab with agent → confirm; without → closes; locked → refused. Last-but-one
   member closed → survivor is solo, tag cleared.
7. Rename a member from sidebar → stays in its cell.
8. Kill a member from a plain terminal → cell disappears within 2s, split collapses.
