# Session Grid Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show several tmux sessions in one Promote panel as a free grid of splits with tabs, grouped by a tmux `@promote-group` tag.

**Architecture:** Pure `LayoutNode` tree (binary splits, tab leaves) in `Layout.swift`, unit-tested. `SessionStore` reads the tag from the existing `list-panes -a` snapshot, reconciles `layouts[gid]` (persisted in `UserDefaults`) against live tagged members every refresh, and owns split/tab/close actions. `GridView.swift` renders the tree; each leaf mounts one `TerminalPane` for its active tab.

**Tech Stack:** Swift 6.4 toolchain, SwiftPM (tools 5.9), SwiftUI + AppKit, SwiftTerm, tmux 3.7b, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-30-session-grid-design.md`

## Global Constraints

- macOS 14+, single dependency SwiftTerm (no new packages).
- Every tmux `-t` target uses `=name`; option commands (`set-option`, `show-options`, `display-message`) use `=name:` (trailing colon — `=name` alone fails).
- Shell failures return nil, never throw; `@Published` mutations only on main; tmux actions on `actionQueue`.
- Tag name exactly `@promote-group`; UserDefaults key `gridLayouts`.
- Keep repo style: `// ponytail:` comments for deliberate simplifications, fewest files.
- Solo sessions (no tag) must render and behave exactly as today.

## Review Focus

1. Refresh landing between `new-session` and `set-option` must not drop or misplace the new member → covered by `pendingTags` + reconcile test "keeps pending untagged focused".
2. Empty `list-panes` (tmux server down / reboot) must not wipe layouts → reconcile skipped when live list empty; reconcile test "does not prune never-seen names".
3. Session names without a numeric suffix or with dashes (`100`, `v2-nft`, `sha-2911-infra-...`) must name siblings sanely → `nextFreeName` tests.
4. Focus must not be stolen every 2s refresh (e.g. while renaming in the sidebar) → TerminalPane focuses only on false→true transitions (manual checklist item 9).
5. Double-insert of the same name (reconcile appended it before the action's layout write) must not duplicate a tab → `split`/`insertTab` no-op when name already present, tested.

---

### Task 1: Pure layout tree + test target

**Files:**
- Modify: `osx-app/Package.swift`
- Create: `osx-app/Sources/Promote/Layout.swift`
- Test: `osx-app/Tests/PromoteTests/LayoutTests.swift`

**Interfaces:**
- Produces:
  - `enum SplitAxis: String, Codable { case horizontal, vertical }`
  - `indirect enum LayoutNode: Codable, Equatable { case leaf(tabs: [String], active: Int); case split(axis: SplitAxis, ratio: Double, first: LayoutNode, second: LayoutNode) }`
  - `var allSessions: [String]`, `func contains(_:) -> Bool`, `func leafTabs(containing:) -> [String]?`
  - `func insertTab(_ name: String, into focused: String) -> LayoutNode`
  - `func split(_ name: String, beside focused: String, axis: SplitAxis) -> LayoutNode`
  - `func removing(_ name: String) -> LayoutNode?`
  - `func renaming(_ old: String, to new: String) -> LayoutNode`
  - `func activating(_ name: String) -> LayoutNode`
  - `func settingRatio(at path: [Bool], _ ratio: Double) -> LayoutNode`
  - `static func reconcile(_ layout: LayoutNode?, members: [String], prunable: Set<String>) -> LayoutNode?`
  - `static func nextFreeName(base: String, taken: Set<String>) -> String`

- [ ] **Step 1: Add the test target**

`osx-app/Package.swift` targets:

```swift
    targets: [
        .executableTarget(name: "Promote", dependencies: ["SwiftTerm"]),
        .testTarget(name: "PromoteTests", dependencies: ["Promote"]),
    ]
```

- [ ] **Step 2: Write the failing tests** — `osx-app/Tests/PromoteTests/LayoutTests.swift`

```swift
import Foundation
import Testing
@testable import Promote

private func leaf(_ tabs: String..., active: Int = 0) -> LayoutNode { .leaf(tabs: tabs, active: active) }

@Suite struct LayoutTests {
    @Test func insertTabAppendsAndActivates() {
        #expect(leaf("a").insertTab("b", into: "a") == leaf("a", "b", active: 1))
    }

    @Test func insertTabIsNoOpWhenPresent() {
        let t = leaf("a", "b")
        #expect(t.insertTab("b", into: "a") == t)
    }

    @Test func splitReplacesFocusedLeaf() {
        let t = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: leaf("a"), second: leaf("b"))
        let next = t.split("c", beside: "b", axis: .vertical)
        #expect(next == .split(axis: .horizontal, ratio: 0.5, first: leaf("a"),
                               second: .split(axis: .vertical, ratio: 0.5, first: leaf("b"), second: leaf("c"))))
    }

    @Test func splitIsNoOpWhenPresent() {
        let t = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: leaf("a"), second: leaf("b"))
        #expect(t.split("b", beside: "a", axis: .vertical) == t)
    }

    @Test func removingTabClampsActive() {
        #expect(leaf("a", "b", active: 1).removing("b") == leaf("a"))
        #expect(leaf("a", "b", "c", active: 2).removing("a") == leaf("b", "c", active: 1))
        #expect(leaf("a", "b", "c", active: 0).removing("c") == leaf("a", "b", active: 0))
    }

    @Test func removingLastTabCollapsesSplit() {
        let t = LayoutNode.split(axis: .horizontal, ratio: 0.3, first: leaf("a"), second: leaf("b", "c"))
        #expect(t.removing("a") == leaf("b", "c"))
        #expect(leaf("a").removing("a") == nil)
    }

    @Test func renamingAndActivating() {
        let t = LayoutNode.split(axis: .vertical, ratio: 0.5, first: leaf("a", "b"), second: leaf("c"))
        #expect(t.renaming("b", to: "z").allSessions == ["a", "z", "c"])
        #expect(t.activating("b") == .split(axis: .vertical, ratio: 0.5, first: leaf("a", "b", active: 1), second: leaf("c")))
        #expect(t.leafTabs(containing: "c") == ["c"])
        #expect(t.leafTabs(containing: "x") == nil)
    }

    @Test func settingRatioByPathAndClamp() {
        let inner = LayoutNode.split(axis: .vertical, ratio: 0.5, first: leaf("b"), second: leaf("c"))
        let t = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: leaf("a"), second: inner)
        #expect(t.settingRatio(at: [], 0.95) == .split(axis: .horizontal, ratio: 0.9, first: leaf("a"), second: inner))
        #expect(t.settingRatio(at: [true], 0.25) == .split(axis: .horizontal, ratio: 0.5, first: leaf("a"),
            second: .split(axis: .vertical, ratio: 0.25, first: leaf("b"), second: leaf("c"))))
    }

    @Test func reconcileBuildsLeafFromTagsWhenNoLayout() {
        #expect(LayoutNode.reconcile(nil, members: ["a", "b"], prunable: []) == leaf("a", "b"))
        #expect(LayoutNode.reconcile(nil, members: ["a"], prunable: []) == nil)
    }

    @Test func reconcileAddsMissingMembersToFirstLeaf() {
        let t = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: leaf("a"), second: leaf("b"))
        #expect(LayoutNode.reconcile(t, members: ["a", "b", "c"], prunable: ["a", "b"])
                == .split(axis: .horizontal, ratio: 0.5, first: leaf("a", "c"), second: leaf("b")))
    }

    @Test func reconcilePrunesOnlyPrunable() {
        let t = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: leaf("a", "x"), second: leaf("b"))
        // x dead and seen → pruned
        #expect(LayoutNode.reconcile(t, members: ["a", "b"], prunable: ["a", "b", "x"])
                == .split(axis: .horizontal, ratio: 0.5, first: leaf("a"), second: leaf("b")))
        // x never seen alive (reboot, not restored yet) → kept
        #expect(LayoutNode.reconcile(t, members: ["a", "b"], prunable: ["a", "b"]) == t)
    }

    @Test func reconcileKeepsPendingUntaggedFocused() {
        // first split: focused "a" untagged in tmux but pending → caller passes it as member, not prunable
        let t = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: leaf("a"), second: leaf("a-2"))
        #expect(LayoutNode.reconcile(t, members: ["a", "a-2"], prunable: []) == t)
    }

    @Test func reconcileDropsGroupUnderTwoMembers() {
        let t = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: leaf("a"), second: leaf("b"))
        #expect(LayoutNode.reconcile(t, members: ["a"], prunable: ["a", "b"]) == nil)
    }

    @Test func codableRoundTrip() throws {
        let t = LayoutNode.split(axis: .vertical, ratio: 0.4, first: leaf("a", "b", active: 1), second: leaf("c"))
        let data = try JSONEncoder().encode(["g1": t])
        #expect(try JSONDecoder().decode([String: LayoutNode].self, from: data) == ["g1": t])
    }

    @Test func nextFreeName() {
        #expect(LayoutNode.nextFreeName(base: "api", taken: ["api"]) == "api-2")
        #expect(LayoutNode.nextFreeName(base: "api-2", taken: ["api", "api-2"]) == "api-3")
        #expect(LayoutNode.nextFreeName(base: "api", taken: ["api", "api-2", "api-4"]) == "api-3")
        #expect(LayoutNode.nextFreeName(base: "100", taken: ["100"]) == "100-2")
        #expect(LayoutNode.nextFreeName(base: "v2-nft", taken: ["v2-nft"]) == "v2-nft-2")
        #expect(LayoutNode.nextFreeName(base: "-3", taken: []) == "-3-2")
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `cd osx-app && swift test 2>&1 | tail -20`
Expected: compile error `cannot find 'LayoutNode' in scope`. If instead the failure is a link error about `main`/entry point for the executable target, move `Layout.swift` into a new `.target(name: "PromoteCore", path: "Sources/PromoteCore")`, make `Promote` and `PromoteTests` depend on it, and add `public` to the API.

- [ ] **Step 4: Implement** — `osx-app/Sources/Promote/Layout.swift`

```swift
import Foundation

// Grid layout for a session group: binary splits nest into any grid, leaves hold tabs.
// Pure value type — no tmux, no AppKit — so it's unit-tested (Tests/PromoteTests).
enum SplitAxis: String, Codable {
    case horizontal   // first | second
    case vertical     // first over second
}

indirect enum LayoutNode: Codable, Equatable {
    case leaf(tabs: [String], active: Int)   // session names, never empty
    case split(axis: SplitAxis, ratio: Double, first: LayoutNode, second: LayoutNode)

    static let ratioRange = 0.1...0.9

    var allSessions: [String] {
        switch self {
        case .leaf(let tabs, _): return tabs
        case .split(_, _, let a, let b): return a.allSessions + b.allSessions
        }
    }

    func contains(_ name: String) -> Bool { allSessions.contains(name) }

    func leafTabs(containing name: String) -> [String]? {
        switch self {
        case .leaf(let tabs, _): return tabs.contains(name) ? tabs : nil
        case .split(_, _, let a, let b): return a.leafTabs(containing: name) ?? b.leafTabs(containing: name)
        }
    }

    // append as a tab of the leaf holding `focused`, make it active
    func insertTab(_ name: String, into focused: String) -> LayoutNode {
        guard !contains(name) else { return self }
        return mapLeaf(containing: focused) { tabs, _ in .leaf(tabs: tabs + [name], active: tabs.count) }
    }

    // replace the leaf holding `focused` with a split: that leaf first, new tab second
    func split(_ name: String, beside focused: String, axis: SplitAxis) -> LayoutNode {
        guard !contains(name) else { return self }
        return mapLeaf(containing: focused) { tabs, active in
            .split(axis: axis, ratio: 0.5, first: .leaf(tabs: tabs, active: active), second: .leaf(tabs: [name], active: 0))
        }
    }

    // nil = tree empty; a split left with one child collapses into it
    func removing(_ name: String) -> LayoutNode? {
        switch self {
        case .leaf(let tabs, let active):
            guard let i = tabs.firstIndex(of: name) else { return self }
            var rest = tabs
            rest.remove(at: i)
            if rest.isEmpty { return nil }
            return .leaf(tabs: rest, active: i < active ? active - 1 : min(active, rest.count - 1))
        case .split(let axis, let ratio, let a, let b):
            switch (a.removing(name), b.removing(name)) {
            case (nil, nil): return nil
            case (let x?, nil): return x
            case (nil, let y?): return y
            case (let x?, let y?): return .split(axis: axis, ratio: ratio, first: x, second: y)
            }
        }
    }

    func renaming(_ old: String, to new: String) -> LayoutNode {
        switch self {
        case .leaf(let tabs, let active):
            return .leaf(tabs: tabs.map { $0 == old ? new : $0 }, active: active)
        case .split(let axis, let ratio, let a, let b):
            return .split(axis: axis, ratio: ratio, first: a.renaming(old, to: new), second: b.renaming(old, to: new))
        }
    }

    func activating(_ name: String) -> LayoutNode {
        mapLeaf(containing: name) { tabs, _ in .leaf(tabs: tabs, active: tabs.firstIndex(of: name) ?? 0) }
    }

    // path addresses a split from the root: false = first child, true = second; [] = self
    func settingRatio(at path: [Bool], _ ratio: Double) -> LayoutNode {
        guard case .split(let axis, let current, let a, let b) = self else { return self }
        guard let head = path.first else {
            let clamped = min(max(ratio, Self.ratioRange.lowerBound), Self.ratioRange.upperBound)
            return .split(axis: axis, ratio: clamped, first: a, second: b)
        }
        let rest = Array(path.dropFirst())
        return head
            ? .split(axis: axis, ratio: current, first: a, second: b.settingRatio(at: rest, ratio))
            : .split(axis: axis, ratio: current, first: a.settingRatio(at: rest, ratio), second: b)
    }

    // Converge a stored layout onto tmux truth. `members` = live tagged + pending sessions.
    // Only `prunable` names (seen alive this run, not pending) may be dropped, so a partial
    // list after a reboot can't wipe cells. Under two sessions left = no longer a group.
    static func reconcile(_ layout: LayoutNode?, members: [String], prunable: Set<String>) -> LayoutNode? {
        let memberSet = Set(members)
        var tree = layout
        for name in layout?.allSessions ?? [] where !memberSet.contains(name) && prunable.contains(name) {
            tree = tree?.removing(name)
        }
        for name in members where !(tree?.contains(name) ?? false) {
            tree = tree?.appendingToFirstLeaf(name) ?? .leaf(tabs: [name], active: 0)
        }
        guard let tree, tree.allSessions.count >= 2 else { return nil }
        return tree
    }

    // naming only — grouping never parses names. "api" / "api-2" → lowest free "api-N", N ≥ 2
    static func nextFreeName(base: String, taken: Set<String>) -> String {
        var stem = base
        if let dash = base.lastIndex(of: "-"), dash != base.startIndex,
           Int(base[base.index(after: dash)...]) != nil {
            stem = String(base[..<dash])
        }
        var n = 2
        while taken.contains("\(stem)-\(n)") { n += 1 }
        return "\(stem)-\(n)"
    }

    private func appendingToFirstLeaf(_ name: String) -> LayoutNode {
        switch self {
        case .leaf(let tabs, let active): return .leaf(tabs: tabs + [name], active: active)
        case .split(let axis, let ratio, let a, let b):
            return .split(axis: axis, ratio: ratio, first: a.appendingToFirstLeaf(name), second: b)
        }
    }

    private func mapLeaf(containing name: String, _ transform: ([String], Int) -> LayoutNode) -> LayoutNode {
        switch self {
        case .leaf(let tabs, let active):
            return tabs.contains(name) ? transform(tabs, active) : self
        case .split(let axis, let ratio, let a, let b):
            return .split(axis: axis, ratio: ratio,
                          first: a.mapLeaf(containing: name, transform),
                          second: b.mapLeaf(containing: name, transform))
        }
    }
}
```

- [ ] **Step 5: Run tests to verify pass**

Run: `cd osx-app && swift test 2>&1 | tail -20`
Expected: all `LayoutTests` pass; `swift build` still succeeds.

- [ ] **Step 6: Commit**

```bash
git add osx-app/Package.swift osx-app/Sources/Promote/Layout.swift osx-app/Tests docs/superpowers
git commit -m "feat: layout tree model for session grid"
```

---

### Task 2: Store — tag query, reconciliation, persistence, rename

**Files:**
- Modify: `osx-app/Sources/Promote/Settings.swift`
- Modify: `osx-app/Sources/Promote/SessionStore.swift` (state block ~L7-40, `performRefreshPass` ~L138, `applySnapshot` ~L216, `PaneRow`/`queryPaneRows` ~L266-291, `rename` ~L674)

**Interfaces:**
- Consumes: `LayoutNode`, `LayoutNode.reconcile`, `renaming`, `activating` (Task 1)
- Produces:
  - `SessionStore.layouts: [String: LayoutNode]` (`@Published private(set)`)
  - `SessionStore.groupOf: [String: String]` (`@Published private(set)`)
  - `func layoutGroup(containing name: String) -> String?`
  - `private var pendingTags: [String: String]`
  - `selected` `didSet` activates the tab in its leaf
  - `Settings.layouts: [String: LayoutNode]`

- [ ] **Step 1: Settings** — add to `enum Settings`:

```swift
    // session-group gid -> grid layout (JSON; tree doesn't fit plist types)
    static var layouts: [String: LayoutNode] {
        get { d.data(forKey: "gridLayouts").flatMap { try? JSONDecoder().decode([String: LayoutNode].self, from: $0) } ?? [:] }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "gridLayouts") }
    }
```

- [ ] **Step 2: Store state** — replace `@Published var selected: String?` with:

```swift
    @Published var selected: String? {
        // any selection path (sidebar, ⌘1–9, terminal click) shows that tab in its grid leaf
        didSet { if let selected, selected != oldValue { activateTab(selected) } }
    }
```

and add next to the other published state:

```swift
    // session-group gid -> grid layout; membership truth is the tmux @promote-group tag
    @Published private(set) var layouts: [String: LayoutNode] = Settings.layouts
    // session -> gid from the last snapshot, merged with in-flight tag writes
    @Published private(set) var groupOf: [String: String] = [:]
```

and with the main-only private state:

```swift
    // main-only: name -> gid for tag writes still in flight (new member, and the focused
    // session on a group's first split). Counts as a member, never pruned.
    private var pendingTags: [String: String] = [:]
```

- [ ] **Step 3: Tag column** — `PaneRow` gets `let group: String` before `title`; `queryPaneRows`:

```swift
        // title last: pane titles can contain tabs; maxSplits keeps them whole
        let format = "#{session_name}\t#{pane_id}\t#{pane_current_command}\t#{window_activity}\t#{pane_pid}\t#{pane_current_path}\t#{@promote-group}\t#{pane_title}"
        let out = Shell.tmux("list-panes", "-a", "-F", format) ?? ""
        return out.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
            // Shell.run trims trailing whitespace from the whole output, so the LAST row
            // loses its trailing tabs when group/title are empty. Pad instead of dropping.
            guard parts.count >= 6, !parts[0].isEmpty else { return nil }
            let group = parts.count > 6 ? parts[6] : ""
            let title = parts.count > 7 ? parts[7] : ""
            return PaneRow(session: parts[0], pane: parts[1], command: parts[2].lowercased(),
                           activity: Double(parts[3]) ?? 0, pid: parts[4], path: parts[5], group: group, title: title)
        }
```

- [ ] **Step 4: Pass groups to the snapshot** — in `performRefreshPass`, after `let rows = queryPaneRows()`:

```swift
        // first pane per session carries the session's tag (session option, same on every pane)
        var snapshotGroups: [String: String] = [:]
        for row in rows where !row.group.isEmpty && snapshotGroups[row.session] == nil {
            snapshotGroups[row.session] = row.group
        }
```

and change the main-async call to `self.applySnapshot(sessions: snapshotSessions, groups: snapshotGroups, details: self.details, agents: snapshotAgents)`; add `groups nextGroups: [String: String],` to the `applySnapshot` signature.

- [ ] **Step 5: Reconcile in `applySnapshot`** — right after the `if !nextSessions.isEmpty { ... }` prune block, add `reconcileGroups(nextGroups, live: sessionNames)`, and change the selection fallback so a pending member isn't deselected before tmux reports it:

```swift
        if let selected, !sessionNames.contains(selected), pendingTags[selected] == nil {
```

Add the methods (MARK: - Session grid):

```swift
    // MARK: - Session grid

    func layoutGroup(containing name: String) -> String? {
        layouts.first { $0.value.contains(name) }?.key
    }

    private func activateTab(_ name: String) {
        guard let gid = layoutGroup(containing: name), let layout = layouts[gid] else { return }
        let next = layout.activating(name)
        if next != layout { setLayout(next, for: gid) }
    }

    private func setLayout(_ layout: LayoutNode?, for gid: String) {
        layouts[gid] = layout
        Settings.layouts = layouts
    }

    // main-only: converge layouts onto the tmux tags from this snapshot
    private func reconcileGroups(_ snapshot: [String: String], live: Set<String>) {
        for (name, gid) in pendingTags where snapshot[name] == gid {
            pendingTags.removeValue(forKey: name)
        }
        var merged = snapshot
        for (name, gid) in pendingTags { merged[name] = gid }
        if groupOf != merged { groupOf = merged }

        // empty list = server down or query failed; reconciling would dissolve every group
        guard !live.isEmpty else { return }
        let prunable = seenLive.subtracting(pendingTags.keys)
        var next = layouts
        for gid in Set(merged.values).union(layouts.keys) {
            let members = merged
                .filter { $0.value == gid && (live.contains($0.key) || pendingTags[$0.key] != nil) }
                .map(\.key).sorted()
            let result = LayoutNode.reconcile(layouts[gid], members: members, prunable: prunable)
            next[gid] = result
            if result == nil {
                // lone survivor keeps a stale tag: clear it so it's a plain solo session again
                let lone = members.filter { pendingTags[$0] == nil }
                if lone.count == 1 { untag(lone[0]) }
            }
        }
        if next != layouts {
            layouts = next
            Settings.layouts = next
        }
    }

    private func untag(_ name: String) {
        actionQueue.async {
            _ = Shell.tmux("set-option", "-u", "-t", "=" + name + ":", "@promote-group")
        }
    }
```

- [ ] **Step 6: Rename migration** — in `rename()`'s main block, after the `orderTokens` migration:

```swift
                if self.layouts.values.contains(where: { $0.contains(old) }) {
                    self.layouts = self.layouts.mapValues { $0.renaming(old, to: next) }
                    Settings.layouts = self.layouts
                }
                if let gid = self.pendingTags.removeValue(forKey: old) { self.pendingTags[next] = gid }
                if let gid = self.groupOf.removeValue(forKey: old) { self.groupOf[next] = gid }
```

- [ ] **Step 7: Build + tests**

Run: `cd osx-app && swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`
Expected: build succeeds, tests pass. App still behaves as before (no groups exist yet).

- [ ] **Step 8: Commit**

```bash
git add osx-app/Sources/Promote/Settings.swift osx-app/Sources/Promote/SessionStore.swift
git commit -m "feat: read @promote-group tags and reconcile grid layouts"
```

---

### Task 3: Store — split / tab / close / cycle actions

**Files:**
- Modify: `osx-app/Sources/Promote/SessionStore.swift` (`splitPaneRight`/`splitPaneDown` ~L627-647, `closeActivePane` ~L649, `kill` ~L709)
- Modify: `osx-app/Sources/Promote/SidebarView.swift:583` (`summarizedAgentStatus` → store)

**Interfaces:**
- Consumes: Task 2 state + helpers (`layoutGroup`, `setLayout`, `pendingTags`, `groupOf`)
- Produces:
  - `func splitPaneRight()`, `func splitPaneDown()` (now grid splits), `func newTab()`
  - `func cycleTab(forward: Bool)`
  - `func closeGridSession(_ name: String)`
  - `func setRatio(gid: String, path: [Bool], _ ratio: Double)`
  - `func agentStatus(for sessionName: String) -> AgentStatus?`

- [ ] **Step 1: Replace `splitPaneRight`/`splitPaneDown`** with:

```swift
    private enum GridPlacement { case right, down, tab }

    // app-level grid split: new tmux session in the focused cwd, tagged into its group.
    // tmux-native splits stay available via the tmux prefix.
    func splitPaneRight() { addGridMember(.right) }
    func splitPaneDown() { addGridMember(.down) }
    func newTab() { addGridMember(.tab) }

    private func addGridMember(_ placement: GridPlacement) {
        guard let focused = selected else { return }
        // ponytail: gid/name picked on main at key-press; two presses faster than one
        // new-session round trip on a solo session could mint two gids. Not worth a lock.
        let gid = layoutGroup(containing: focused) ?? groupOf[focused]
            ?? String(UUID().uuidString.prefix(8)).lowercased()
        let name = LayoutNode.nextFreeName(base: focused, taken: Set(sessions.map(\.name)).union(pendingTags.keys))
        let focusedWasTagged = groupOf[focused] != nil

        actionQueue.async { [weak self] in
            guard let self else { return }
            let cwd = Shell.tmux("display-message", "-p", "-t", "=" + focused + ":", "#{pane_current_path}")
                ?? NSHomeDirectory()
            // create BEFORE selecting: the mounted TerminalPane attaches immediately
            guard Shell.tmux("new-session", "-d", "-s", name, "-c", cwd) != nil else {
                self.refresh()
                return
            }
            // sync: layout + pendingTags must exist before the tag lands, or a refresh in
            // between would reconcile the new member into the wrong leaf
            DispatchQueue.main.sync {
                let base = self.layouts[gid] ?? .leaf(tabs: [focused], active: 0)
                let next: LayoutNode
                switch placement {
                case .right: next = base.split(name, beside: focused, axis: .horizontal)
                case .down: next = base.split(name, beside: focused, axis: .vertical)
                case .tab: next = base.insertTab(name, into: focused)
                }
                self.setLayout(next, for: gid)
                self.pendingTags[name] = gid
                if !focusedWasTagged { self.pendingTags[focused] = gid }
                if !self.sessions.contains(where: { $0.name == name }) {
                    self.sessions.append(Session(name: name, path: cwd))
                }
                self.insertOrderToken(name, after: focused)
                self.selected = name
            }
            let tagged = Shell.tmux("set-option", "-t", "=" + name + ":", "@promote-group", gid) != nil
                && Shell.tmux("set-option", "-t", "=" + focused + ":", "@promote-group", gid) != nil
            if !tagged {
                _ = Shell.tmux("kill-session", "-t", "=" + name)
                DispatchQueue.main.async {
                    let rest = self.layouts[gid]?.removing(name)
                    self.setLayout((rest?.allSessions.count ?? 0) >= 2 ? rest : nil, for: gid)
                    self.pendingTags.removeValue(forKey: name)
                    if !focusedWasTagged { self.pendingTags.removeValue(forKey: focused) }
                    self.selected = focused
                }
            }
            self.refresh()
        }
    }

    // new member's sidebar row sits right after the session it was split from
    private func insertOrderToken(_ name: String, after anchor: String) {
        var tokens = canonicalTokens().filter { $0 != name }
        let at = tokens.firstIndex(of: anchor).map { $0 + 1 } ?? tokens.count
        tokens.insert(name, at: at)
        orderTokens = tokens
        Settings.order = tokens
    }

    func cycleTab(forward: Bool) {
        guard let selected, let gid = layoutGroup(containing: selected),
              let tabs = layouts[gid]?.leafTabs(containing: selected), tabs.count > 1,
              let i = tabs.firstIndex(of: selected) else { return }
        self.selected = tabs[(i + (forward ? 1 : tabs.count - 1)) % tabs.count]
    }

    func setRatio(gid: String, path: [Bool], _ ratio: Double) {
        guard let layout = layouts[gid] else { return }
        setLayout(layout.settingRatio(at: path, ratio), for: gid)
    }

    // ⌘W / tab ×: a grid tab IS its session — kill it, confirming only if an agent runs there
    func closeGridSession(_ name: String) {
        guard !locked.contains(name) else { return }
        if agents(for: name).contains(where: { !$0.isServer }) {
            pendingCloseLastPane = name
        } else {
            kill(name)
        }
    }

    func agentStatus(for sessionName: String) -> AgentStatus? {
        let statuses = Set(agents(for: sessionName).filter { !$0.isServer }.map(\.status))
        if statuses.contains(.blocked) { return .blocked }
        if statuses.contains(.working) { return .working }
        if statuses.contains(.done) { return .done }
        if statuses.contains(.idle) { return .idle }
        return nil
    }
```

- [ ] **Step 2: `closeActivePane` grouped branch** — first lines become:

```swift
    func closeActivePane() {
        guard let selected, !locked.contains(selected) else { return }
        if layoutGroup(containing: selected) != nil {
            closeGridSession(selected)
            return
        }
```

- [ ] **Step 3: `kill` focus move** — replace `kill`:

```swift
    func kill(_ sessionName: String) {
        guard !locked.contains(sessionName) else { return }
        // grid member: drop its cell now and hand focus to a neighbor. Only here, so a
        // cancelled confirm dialog never moves focus.
        if let gid = layoutGroup(containing: sessionName), let layout = layouts[gid] {
            let rest = layout.removing(sessionName)
            let tabs = layout.leafTabs(containing: sessionName) ?? []
            let neighbor = tabs.firstIndex(of: sessionName).flatMap { i -> String? in
                tabs.count > 1 ? tabs[i + 1 < tabs.count ? i + 1 : i - 1] : nil
            } ?? rest?.allSessions.first
            setLayout((rest?.allSessions.count ?? 0) >= 2 ? rest : nil, for: gid)
            if selected == sessionName, let neighbor { selected = neighbor }
        }
        actionQueue.async { [weak self] in
            guard let self else { return }
            _ = Shell.tmux("kill-session", "-t", "=" + sessionName)
            self.refresh()
        }
    }
```

- [ ] **Step 4: Sidebar uses the shared status helper** — `SidebarView.swift` `summarizedAgentStatus(for:)` body becomes `store.agentStatus(for: sessionName)`.

- [ ] **Step 5: Build + tests**

Run: `cd osx-app && swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`
Expected: success.

- [ ] **Step 6: Commit**

```bash
git add osx-app/Sources/Promote/SessionStore.swift osx-app/Sources/Promote/SidebarView.swift
git commit -m "feat: grid split, tab, cycle and close actions"
```

---

### Task 4: Grid UI, focus wiring, shortcuts, docs

**Files:**
- Create: `osx-app/Sources/Promote/GridView.swift`
- Modify: `osx-app/Sources/Promote/TerminalPane.swift` (`DroppableTerminalView`, `TerminalPane`)
- Modify: `osx-app/Sources/Promote/main.swift` (`DetailPane`, commands)
- Modify: `osx-app/Sources/Promote/CheatSheetView.swift`
- Modify: `osx-app/CLAUDE.md`

**Interfaces:**
- Consumes: `store.layouts`, `layoutGroup(containing:)`, `setRatio`, `closeGridSession`, `agentStatus(for:)`, `newTab`, `cycleTab`, `color(of:)`, `StatusDot`
- Produces: `GridView(store:gid:node:path:)`; `TerminalPane(session:isFocused:onFocus:)`

- [ ] **Step 1: TerminalPane focus** — in `DroppableTerminalView` add:

```swift
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        // async: fires mid view-update when SwiftUI mounts; publishing there is illegal
        if accepted, let onFocus { DispatchQueue.main.async(execute: onFocus) }
        return accepted
    }
```

`TerminalPane` gains `var isFocused = false`, `var onFocus: (() -> Void)? = nil`, a coordinator, and focus-on-transition:

```swift
    final class Coordinator { var wasFocused = false }
    func makeCoordinator() -> Coordinator { Coordinator() }
```

In `makeNSView` after `term.linkRouter.session = session`:

```swift
        term.onFocus = onFocus
        context.coordinator.wasFocused = isFocused
        if isFocused {
            DispatchQueue.main.async { term.window?.makeFirstResponder(term) }
        }
```

`dismantleNSView(_ view: DroppableTerminalView, coordinator: Coordinator)`; `updateNSView` appends:

```swift
        view.onFocus = onFocus
        // only on false→true: updateNSView runs every refresh, and grabbing focus each time
        // would steal it from the sidebar (rename field) every 2s
        if isFocused && !context.coordinator.wasFocused, let window = view.window, window.firstResponder !== view {
            DispatchQueue.main.async { window.makeFirstResponder(view) }
        }
        context.coordinator.wasFocused = isFocused
```

- [ ] **Step 2: GridView** — `osx-app/Sources/Promote/GridView.swift`:

```swift
import SwiftUI
import AppKit

// Renders one session group's layout tree. Each leaf mounts only its active tab.
// ponytail: inactive tabs are unmounted (no tmux client, no window-size tug); switching
// re-attaches. Upgrade path: keep every tab mounted in a ZStack if that feels slow.
// ponytail: a split/collapse moves a leaf in the view tree, so its terminal re-attaches.
struct GridView: View {
    @ObservedObject var store: SessionStore
    let gid: String
    let node: LayoutNode
    var path: [Bool] = []

    var body: some View {
        switch node {
        case .leaf(let tabs, let active):
            LeafView(store: store, tabs: tabs, active: tabs[min(max(active, 0), tabs.count - 1)])
        case .split(let axis, let ratio, let first, let second):
            SplitContainer(axis: axis, ratio: ratio, onCommit: { store.setRatio(gid: gid, path: path, $0) }) {
                GridView(store: store, gid: gid, node: first, path: path + [false])
            } second: {
                GridView(store: store, gid: gid, node: second, path: path + [true])
            }
        }
    }
}

private struct LeafView: View {
    @ObservedObject var store: SessionStore
    let tabs: [String]
    let active: String

    var body: some View {
        let focused = store.selected == active
        VStack(spacing: 0) {
            TabStrip(store: store, tabs: tabs, active: active, focused: focused)
            TerminalPane(session: active, isFocused: focused, onFocus: { [store] in
                if store.selected != active { store.selected = active }
            })
            .id("\(active)#\(store.terminalEpoch)")
        }
    }
}

private struct TabStrip: View {
    @ObservedObject var store: SessionStore
    let tabs: [String]
    let active: String
    let focused: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(tabs, id: \.self) { name in
                    chip(name)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 26)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            // focused leaf marker
            Rectangle().fill(focused ? Color.accentColor : .clear).frame(height: 2)
        }
    }

    private func chip(_ name: String) -> some View {
        let isActive = name == active
        return HStack(spacing: 5) {
            Circle().fill(store.color(of: name) ?? .secondary.opacity(0.4)).frame(width: 7, height: 7)
            if let status = store.agentStatus(for: name) {
                StatusDot(status: status, size: 10)
            }
            Text(name).font(.caption).lineLimit(1)
            Button {
                store.closeGridSession(name)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(store.locked.contains(name) ? "Locked" : "Kill session")
            .disabled(store.locked.contains(name))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isActive ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { store.selected = name }
    }
}

// two children + a draggable 1pt divider; ratio persists on drag end
private struct SplitContainer<First: View, Second: View>: View {
    let axis: SplitAxis
    let ratio: Double
    let onCommit: (Double) -> Void
    let first: First
    let second: Second
    @State private var dragRatio: Double?
    @State private var dragStart: Double?

    init(axis: SplitAxis, ratio: Double, onCommit: @escaping (Double) -> Void,
         @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second) {
        self.axis = axis
        self.ratio = ratio
        self.onCommit = onCommit
        self.first = first()
        self.second = second()
    }

    var body: some View {
        GeometryReader { geo in
            let horizontal = axis == .horizontal
            let total = horizontal ? geo.size.width : geo.size.height
            let firstLength = max(0, (total - 1) * (dragRatio ?? ratio))
            let stack = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            stack {
                first.frame(width: horizontal ? firstLength : nil, height: horizontal ? nil : firstLength)
                divider(total: total, horizontal: horizontal).zIndex(1)
                second.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func divider(total: CGFloat, horizontal: Bool) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
            .overlay {
                // 8pt invisible grab zone straddling the 1pt line
                Color.clear
                    .frame(width: horizontal ? 8 : nil, height: horizontal ? nil : 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        // global space: the handle moves with the drag, local translation would drift
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                guard total > 0 else { return }
                                let start = dragStart ?? ratio
                                dragStart = start
                                let delta = horizontal ? value.translation.width : value.translation.height
                                dragRatio = min(max(start + delta / total, LayoutNode.ratioRange.lowerBound),
                                                LayoutNode.ratioRange.upperBound)
                            }
                            .onEnded { _ in
                                if let dragRatio { onCommit(dragRatio) }
                                dragRatio = nil
                                dragStart = nil
                            }
                    )
            }
    }
}
```

- [ ] **Step 3: DetailPane** — `main.swift` `DetailPane.body` group becomes:

```swift
        Group {
            if let name = store.selected, let gid = store.layoutGroup(containing: name),
               let layout = store.layouts[gid] {
                GridView(store: store, gid: gid, node: layout)
            } else if let session = selectedSession {
                activeSessionView(session)
            } else {
                EmptyDetailState(newSession: store.newSession)
            }
        }
```

- [ ] **Step 4: Commands** — in `CommandMenu("Session")`, rename the split buttons and add tab commands after them:

```swift
                Button("Split Right (New Session)") { store.splitPaneRight() }
                    .keyboardShortcut("\\", modifiers: .command)

                Button("Split Down (New Session)") { store.splitPaneDown() }
                    .keyboardShortcut("\\", modifiers: [.command, .shift])

                Button("New Tab (New Session)") { store.newTab() }
                    .keyboardShortcut("t", modifiers: .command)

                Button("Next Tab") { store.cycleTab(forward: true) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Previous Tab") { store.cycleTab(forward: false) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
```

and rename `Button("Close Pane")` → `Button("Close Pane / Tab")`.

- [ ] **Step 5: Cheat sheet** — App section rows for split/close become:

```swift
            ShortcutRow(keys: ["⌘", "\\"], description: "Split right (new session in same folder)"),
            ShortcutRow(keys: ["⌘", "⇧", "\\"], description: "Split down (new session in same folder)"),
            ShortcutRow(keys: ["⌘", "T"], description: "New tab (new session in same folder)"),
            ShortcutRow(keys: ["⌘", "⇧", "[ ]"], description: "Previous / next tab"),
            ShortcutRow(keys: ["⌘", "W"], description: "Close pane (grid tab: kill its session)"),
```

- [ ] **Step 6: CLAUDE.md** — in `osx-app/CLAUDE.md` Architecture list add:

```markdown
- `Layout.swift` — pure `LayoutNode` tree (binary splits, tab leaves) for session groups; unit-tested in `Tests/PromoteTests` (`swift test`).
- `GridView.swift` — renders a group's layout: `SplitContainer` (draggable divider), tab strip, one `TerminalPane` per leaf (active tab only).
```

and a paragraph under Data flow:

```markdown
Session groups: membership is the tmux session option `@promote-group <gid>` (read as a column of the same `list-panes -a` call); the arrangement is `layouts[gid]` in UserDefaults (`gridLayouts`). `reconcileGroups` converges layouts onto tags every refresh; in-flight tag writes live in `pendingTags`. ⌘\ / ⇧⌘\ / ⌘T create a new tagged session in the focused cwd. Option commands need `-t =name:` (trailing colon).
```

Also change "No tests." in "What this is" to "Layout tree has Swift Testing tests (`swift test`)."

- [ ] **Step 7: Build, test, launch**

Run: `cd osx-app && swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`
Expected: success. Then run the manual checklist from the spec with `swift run Promote`, plus:
9. Start renaming a sidebar row while a grid is shown; wait 5s → rename field keeps focus.

- [ ] **Step 8: Commit**

```bash
git add osx-app/Sources/Promote osx-app/CLAUDE.md
git commit -m "feat: session grid view with splits and tabs"
```
