import SwiftUI
import Foundation
import AppKit

// owns app state and runs all tmux/git/gh shell work off the main thread
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published var selected: String? {
        // any selection path (sidebar, ⌘1–9, terminal click) shows that tab in its grid leaf
        didSet {
            guard let selected, selected != oldValue else { return }
            activateTab(selected)
            if let gid = layoutGroup(containing: selected) { lastFocused[gid] = selected }
        }
    }
    @Published private(set) var details: [String: SessionDetails] = [:]
    @Published private(set) var chatNames: [String: String] = Settings.chatNames
    @Published var colors: [String: String] = Settings.colors
    // sidebar order tokens: session names + divider tokens ("§divider:<uuid>")
    @Published private(set) var orderTokens: [String] = Settings.order
    @Published private(set) var dividerTitles: [String: String] = Settings.dividerTitles
    @Published var locked: Set<String> = Set(Settings.locked)
    // set when ⌘W would kill the session (last pane); RootView shows the confirm dialog
    @Published var pendingCloseLastPane: String?
    @Published var showCheatSheet = false
    @Published var cmdHeld = false
    @Published private(set) var agents: [AgentInfo] = []
    // bumped to force-rebuild the terminal view (fresh SwiftTerm state; clears stuck kitty keyboard flags)
    @Published private(set) var terminalEpoch = 0
    // session-group gid -> grid layout; membership truth is the tmux @promote-group tag
    @Published private(set) var layouts: [String: LayoutNode] = Settings.layouts
    // session -> gid from the last snapshot, merged with in-flight tag writes
    @Published private(set) var groupOf: [String: String] = [:]

    // ponytail: one serial queue keeps shell work + caches simple and deterministic
    private let workerQueue = DispatchQueue(label: "session.store.worker", qos: .userInitiated)
    // user-triggered tmux commands (split, etc.) — must not queue behind a slow
    // refresh pass (git/gh work can hold workerQueue for seconds); cache-free only
    private let actionQueue = DispatchQueue(label: "session.store.actions", qos: .userInteractive)
    // slow per-session git/gh badge work; on its own queue so it never blocks the
    // fast tmux snapshot (or the next user action queued behind it)
    private let detailsQueue = DispatchQueue(label: "session.store.details", qos: .utility)
    private var refreshInFlight = false
    private var refreshPending = false
    // main-only: sessions observed alive at least once this app run. Metadata
    // (order/color/lock) is pruned only for names in this set, so a partial list
    // right after a reboot (sessions restored one by one) can't wipe entries for
    // sessions that just haven't come back yet.
    private var seenLive: Set<String> = []
    // main-only: name -> gid for tag writes still in flight (new member, and the focused
    // session on a group's first split). Counts as a member, never pruned.
    private var pendingTags: [String: String] = [:]
    // main-only: when each pendingTags entry was made. A pending name that never shows up
    // live (killed or exited before its tag was confirmed) expires instead of pinning a dead cell.
    private var pendingSince: [String: Date] = [:]
    // main-only: grid members killed but maybe still in an in-flight snapshot; never re-added
    private var pendingKills: Set<String> = []
    // main-only: snapshots reconciled this run. Early ones may be partial (reboot restore),
    // so only seen-alive names are prunable until a few have landed.
    private var reconciledSnapshots = 0
    // main-only: gid -> member last focused, so clicking the group's sidebar row reopens it
    private var lastFocused: [String: String] = [:]
    // detailsQueue-only coalescing state
    private var detailsInFlight = false
    private var detailsPendingSessions: [Session]?

    // detailsQueue-only caches
    private var prCache: [String: (Date, PRInfo?)] = [:]
    private var branchCache: [String: (Date, String?)] = [:]
    private var diffCache: [String: (Date, GitDiff?)] = [:]
    // workerQueue-only caches
    // ponytail: capture-pane is the hot subprocess; reuse each pane's verdict for a few seconds
    private var paneStatusCache: [String: (at: Double, status: AgentStatus, turnEnded: Bool)] = [:]
    private var agentWorked: Set<String> = []
    // ponytail: ps dump reused for 4s; a freshly spawned wrapper-launched agent can
    // read as plain "node" for up to that long
    private var processSnapshotCache: (at: Double, children: [String: [(pid: String, name: String, args: String)]])?

    private let agentTools: Set<String> = ["claude", "pi", "opencode", "codex"]
    private let wrapperCommands: Set<String> = ["node", "bun", "sh"]
    // foreground commands that look like a JS runtime/dev server (green dot, not an agent)
    private let serverCommands = ["node", "npm", "npx", "pnpm", "yarn", "bun", "deno", "next-server", "turbo"]
    // foreground shell that isn't the interactive login shell => running script
    private let scriptShells: Set<String> = ["sh", "bash", "dash"]
    // permission prompts + AskUserQuestion picker footer (matched against lowercased prompt region)
    private let blockedPrompts: [String] = ["do you want", "allow command", "y/n", "enter to select", "esc to cancel"]
    // Only the literal busy footer (claude/cursor). Generic words ("running", "thinking")
    // false-positive on normal transcript text and pin status at working.
    private let workingPrompts: [String] = ["esc to interrupt"]

    // MARK: - Derived state

    // ponytail: "§divider:" prefix can't collide with a sane tmux session name; no escaping
    static let dividerPrefix = "§divider:"
    static func dividerId(_ token: String) -> String? {
        token.hasPrefix(dividerPrefix) ? String(token.dropFirst(dividerPrefix.count)) : nil
    }

    // flat sidebar: live sessions in manual order, dividers interleaved; unknown sessions appended
    var sidebarItems: [SidebarItem] {
        let live = Dictionary(uniqueKeysWithValues: sessions.map { ($0.name, $0) })
        var seen = Set<String>()
        var items: [SidebarItem] = []
        for token in orderTokens {
            if let id = Self.dividerId(token) {
                items.append(.divider(id: id, title: dividerTitles[id] ?? ""))
            } else if let session = live[token], isGroupRow(session.name), seen.insert(token).inserted {
                items.append(.session(session))
            }
        }
        for session in sessions where !seen.contains(session.name) && isGroupRow(session.name) {
            items.append(.session(session))
        }
        return items
    }

    // visible rows only: one number per group
    var hotkeyOrderedSessions: [Session] {
        sidebarItems.compactMap { if case .session(let s) = $0 { return s } else { return nil } }
    }

    // Chat labels never become tmux targets or drag identifiers.
    func chatName(for session: String) -> String { chatNames[session] ?? session }

    func renameChat(_ session: String, to proposed: String) {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        chatNames[session] = name.isEmpty || name == session ? nil : name
        Settings.chatNames = chatNames
    }

    // MARK: - Group rows (one sidebar row per session group)

    // grid members in sidebar order; [name] for a solo session
    func groupMembers(of name: String) -> [String] {
        guard let gid = layoutGroup(containing: name), let layout = layouts[gid] else { return [name] }
        let inTree = Set(layout.allSessions)
        let ordered = sessions.map(\.name).filter { inTree.contains($0) }
        return ordered.isEmpty ? [name] : ordered
    }

    // a group shows as the row of its first member in sidebar order
    func groupRow(of name: String) -> String { groupMembers(of: name).first ?? name }

    private func isGroupRow(_ name: String) -> Bool { groupRow(of: name) == name }

    // sidebar row click / ⌘1–9: a group row reopens the member last focused in it
    func selectRow(_ name: String) {
        if let gid = layoutGroup(containing: name), let last = lastFocused[gid],
           layouts[gid]?.contains(last) == true {
            selected = last
        } else {
            selected = name
        }
    }

    // List selection binding: highlight the group row whichever member is focused
    var rowSelection: Binding<String?> {
        Binding(
            get: { self.selected.map(self.groupRow(of:)) },
            set: { name in
                guard let name else { return }
                if self.selected.map(self.groupRow(of:)) != name { self.selectRow(name) }
            }
        )
    }

    // worst status across the group's members: blocked > working > done > idle
    func groupAgentStatus(for name: String) -> AgentStatus? {
        let statuses = Set(groupMembers(of: name).compactMap(agentStatus(for:)))
        for status in [AgentStatus.blocked, .working, .done, .idle] where statuses.contains(status) {
            return status
        }
        return nil
    }

    // sidebar Kill / bin on a group row kills every unlocked member
    func killRow(_ name: String) {
        for member in groupMembers(of: name) { kill(member) }
    }

    func canDropSession(_ name: String, onto target: String) -> Bool {
        guard sessions.contains(where: { $0.name == name }), sessions.contains(where: { $0.name == target }) else { return false }
        return true
    }

    func moveTab(_ name: String, toLeafOf target: String, anchor: TabDropAnchor) {
        guard canDropSession(name, onto: target) else { return }
        let tabs = layoutGroup(containing: target).flatMap { layouts[$0]?.leafTabs(containing: target) } ?? [target]
        guard let index = anchor.index(in: tabs) else { return }
        moveTab(name, toLeafOf: target, at: index)
    }

    func moveTab(_ name: String, toLeafOf target: String, at index: Int? = nil) {
        if let index, let gid = layoutGroup(containing: target), let layout = layouts[gid],
           layout.leafTabs(containing: target)?.contains(name) == true {
            // Sorting within a pane leaves focus and the mounted terminal unchanged.
            setLayout(layout.reorderingTab(name, inLeafOf: target, at: index), for: gid)
            return
        }
        moveSession(name, beside: target, edge: nil)
        if let index, let gid = layoutGroup(containing: target), let layout = layouts[gid] {
            setLayout(layout.reorderingTab(name, inLeafOf: target, at: index), for: gid)
        }
    }

    func moveTarget(for name: String, direction: SplitDirection) -> String? {
        guard let gid = layoutGroup(containing: name) else { return nil }
        return layouts[gid]?.moveTarget(for: name, direction: direction)
    }

    func moveSession(_ name: String, direction: SplitDirection) {
        guard let target = moveTarget(for: name, direction: direction) else { return }
        moveSession(name, beside: target, edge: direction)
    }

    // Move one session, preserving the other tabs and collapsing its emptied source pane.
    func moveSession(_ name: String, beside destination: String, edge: SplitDirection?) {
        guard canDropSession(name, onto: destination) else { return }
        if name == destination {
            if let edge { splitSession(name, direction: edge) }
            return
        }
        let sourceID = layoutGroup(containing: name)
        let target = destination
        let targetID = layoutGroup(containing: target) ?? UUID().uuidString.lowercased()
        let base = layouts[targetID] ?? .leaf(tabs: [target], active: 0)
        let next = base.placing(name, beside: target, edge: edge)
        if sourceID == targetID {
            setLayout(next.isPersistentLayout ? next : nil, for: targetID)
            if !next.isPersistentLayout { for member in next.allSessions { untag(member) } }
            selected = name
            return
        }

        // Reserve membership before writing tags, so refresh cannot put the tab back.
        for member in [name, target] {
            pendingTags[member] = targetID
            pendingSince[member] = Date()
        }
        if let sourceID, let source = layouts[sourceID] {
            let rest = source.removing(name)
            setLayout(rest?.isPersistentLayout == true ? rest : nil, for: sourceID)
            if let rest, rest.allSessions.count == 1 { untag(rest.allSessions[0]) }
        }
        setLayout(next, for: targetID)
        selected = name
        actionQueue.async { [weak self] in
            guard let self else { return }
            for member in [name, target] {
                let tagged = Shell.tmux("set-option", "-t", "=" + member + ":", "@promote-group", targetID) != nil
                if !tagged {
                    DispatchQueue.main.async {
                        if self.pendingTags[member] == targetID {
                            self.pendingTags.removeValue(forKey: member)
                            self.pendingSince.removeValue(forKey: member)
                        }
                    }
                }
            }
            self.refresh()
        }
    }

    func details(for sessionName: String) -> SessionDetails {
        details[sessionName] ?? SessionDetails()
    }

    func color(of sessionName: String) -> SwiftUI.Color? {
        guard let value = colors[sessionName] else { return nil }
        if let hex = colorFromHex(value) { return hex }
        return palette.first { $0.id.lowercased() == value.lowercased() }?.color
    }

    func agents(for sessionName: String) -> [AgentInfo] {
        agents.filter { $0.session == sessionName }
    }

    // MARK: - Refresh pipeline

    func refresh() {
        workerQueue.async { [weak self] in
            guard let self else { return }
            if self.refreshInFlight {
                self.refreshPending = true
                return
            }
            self.refreshInFlight = true
            self.performRefreshPass()
        }
    }

    // manual refresh (⇧⌘R): drop the read caches so PR, branch, and agent status reload
    // from source now instead of serving values cached from the last pass. The 2s auto-refresh
    // stays on refresh() so it keeps honoring the caches (no gh spam).
    func forceRefresh() {
        workerQueue.async { [weak self] in
            self?.paneStatusCache.removeAll()
        }
        detailsQueue.async { [weak self] in
            guard let self else { return }
            self.prCache.removeAll()
            self.branchCache.removeAll()
            self.diffCache.removeAll()
        }
        refresh()
    }

    private func performRefreshPass() {
        // one list-panes call feeds both the agent scan and the session list
        let rows = queryPaneRows()
        // first pane per session carries the session's tag (session option, same on every pane)
        var snapshotGroups: [String: String] = [:]
        for row in rows where !row.group.isEmpty && snapshotGroups[row.session] == nil {
            snapshotGroups[row.session] = row.group
        }
        // agents first: node-based agent CLIs (pi/opencode) must not count as dev servers
        var snapshotAgents = queryAgents(rows: rows)
        // only real agents suppress the serving flag; server panes ARE the dev servers we want to flag
        let snapshotSessions = querySessions(rows: rows, agentPanes: Set(snapshotAgents.filter { !$0.isServer }.map(\.paneId)))

        // sort here with the fresh snapshot, not published `sessions` (main-owned, racy off-main)
        let sidebarRank = Dictionary(uniqueKeysWithValues: snapshotSessions.enumerated().map { ($0.element.name, $0.offset) })
        snapshotAgents.sort {
            (sidebarRank[$0.session] ?? .max, $0.paneId) < (sidebarRank[$1.session] ?? .max, $1.paneId)
        }

        // publish sessions before the slow git/gh pass so first paint doesn't wait on the network
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applySnapshot(sessions: snapshotSessions, groups: snapshotGroups, details: self.details, agents: snapshotAgents)
        }

        // slow git/gh badge pass on its own queue: never blocks the next snapshot or a user action
        scheduleDetailsPass(for: snapshotSessions)

        workerQueue.async { [weak self] in
            guard let self else { return }
            if self.refreshPending {
                self.refreshPending = false
                self.performRefreshPass()
                return
            }
            self.refreshInFlight = false
        }
    }

    // coalesced like refresh(): 2s ticks fold into one pending pass while gh is slow
    private func scheduleDetailsPass(for sessions: [Session]) {
        detailsQueue.async { [weak self] in
            guard let self else { return }
            if self.detailsInFlight {
                self.detailsPendingSessions = sessions
                return
            }
            self.detailsInFlight = true
            self.performDetailsPass(sessions)
        }
    }

    private func performDetailsPass(_ snapshotSessions: [Session]) {
        for session in snapshotSessions {
            let value = queryDetails(for: session)
            // publish per session: a cold pass (force refresh) costs ~1s of gh per session,
            // serially — one publish at loop end left every badge frozen until the last
            // session finished, so ⇧⌘R looked like it did nothing
            DispatchQueue.main.async { [weak self] in
                self?.details[session.name] = value
            }
        }

        // prune details of dead sessions
        let live = Set(snapshotSessions.map(\.name))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.details.keys.contains(where: { !live.contains($0) }) {
                self.details = self.details.filter { live.contains($0.key) }
            }
        }

        detailsQueue.async { [weak self] in
            guard let self else { return }
            if let pending = self.detailsPendingSessions {
                self.detailsPendingSessions = nil
                self.performDetailsPass(pending)
                return
            }
            self.detailsInFlight = false
        }
    }

    private func applySnapshot(sessions nextSessions: [Session],
                               groups nextGroups: [String: String],
                               details nextDetails: [String: SessionDetails],
                               agents nextAgents: [AgentInfo]) {
        if sessions != nextSessions {
            sessions = nextSessions
        }

        let sessionNames = Set(nextSessions.map(\.name))
        // Keep the old layout long enough to find a neighbor when tmux itself
        // closes the selected session (exit / kill-session outside the app).
        let survivingFocus = selected.flatMap { name -> String? in
            guard !sessionNames.contains(name), let gid = layoutGroup(containing: name) else { return nil }
            return layouts[gid]?.survivingSession(afterClosing: name, live: sessionNames.subtracting(pendingKills))
        }

        // drop stored metadata for sessions that no longer exist (closed/killed).
        // only prune names this app run actually saw alive: after a reboot the first
        // refresh with any session would otherwise wipe entries for every session
        // that hasn't been restored yet (non-empty list ≠ complete list).
        // skip when the list is empty: tmux server exits with its last session, so an
        // empty list means the server is down (reboot) or the query failed — pruning
        // then would wipe every group/color/lock/order entry.
        seenLive.formUnion(sessionNames)
        if !nextSessions.isEmpty {
            let dead: (String) -> Bool = { [seenLive] in
                !sessionNames.contains($0) && seenLive.contains($0)
            }
            if chatNames.keys.contains(where: dead) {
                chatNames = chatNames.filter { !dead($0.key) }
                Settings.chatNames = chatNames
            }
            if colors.keys.contains(where: dead) {
                colors = colors.filter { !dead($0.key) }
                saveColors()
            }
            if locked.contains(where: dead) {
                locked = locked.filter { !dead($0) }
                Settings.locked = Array(locked)
            }
            // prune dead session tokens; divider tokens always survive
            if orderTokens.contains(where: { Self.dividerId($0) == nil && dead($0) }) {
                orderTokens = orderTokens.filter { Self.dividerId($0) != nil || !dead($0) }
                Settings.order = orderTokens
            }
        }

        reconcileGroups(nextGroups, live: sessionNames)

        if let selected, !sessionNames.contains(selected), pendingTags[selected] == nil {
            self.selected = survivingFocus ?? nextSessions.first?.name
        } else if selected == nil, let first = nextSessions.first {
            self.selected = first.name
        }

        if details != nextDetails {
            details = nextDetails
        }

        if agents != nextAgents {
            agents = nextAgents
        }
    }

    // one row per pane from the single shared list-panes snapshot
    private struct PaneRow {
        let session: String
        let pane: String
        let command: String   // lowercased
        let activity: Double
        let pid: String
        let path: String
        let group: String     // @promote-group tag, "" = solo
        let title: String
    }

    private func queryPaneRows() -> [PaneRow] {
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
    }

    private func querySessions(rows: [PaneRow], agentPanes: Set<String>) -> [Session] {
        // path comes from the FIRST pane (leftmost), not the active one

        // ponytail: "server" = any pane whose foreground command looks like a JS runtime/runner.
        // No port, no listen check; upgrade path is lsof -sTCP:LISTEN against pane pids.
        // Agent panes are excluded: node-based agent CLIs (pi/opencode) also report "node".
        let serving = Set(rows.filter { row in
            !agentPanes.contains(row.pane) &&
                (serverCommands.contains { row.command.hasPrefix($0) } || scriptShells.contains(row.command))
        }.map(\.session))

        var seen = Set<String>()
        var parsed: [Session] = rows.compactMap { row in
            guard seen.insert(row.session).inserted else { return nil }
            return Session(name: row.session, path: row.path, serving: serving.contains(row.session))
        }

        let manualOrder = Settings.order
        let rank: (Session) -> Int = { session in
            manualOrder.firstIndex(of: session.name) ?? Int.max
        }

        parsed = parsed.enumerated().sorted {
            (rank($0.element), $0.offset) < (rank($1.element), $1.offset)
        }
        .map(\.element)

        return parsed
    }

    private func queryDetails(for session: Session) -> SessionDetails {
        guard !session.path.isEmpty else { return SessionDetails() }

        var next = SessionDetails()
        next.branch = queryBranch(for: session.path)
        next.pr = queryPRInfo(for: session.path)
        next.diff = queryDiff(for: session.path)
        return next
    }

    private func queryDiff(for path: String) -> GitDiff? {
        if let (cachedAt, cachedValue) = diffCache[path], Date().timeIntervalSince(cachedAt) < 10 {
            return cachedValue
        }

        // ponytail: numstat vs HEAD covers staged+unstaged lines; untracked files not counted.
        // Count them via ls-files --others + wc if it matters.
        var resolved: GitDiff?
        if let out = Shell.run(GIT, ["-C", path, "diff", "--numstat", "HEAD"]) {
            var added = 0, deleted = 0
            for line in out.split(whereSeparator: \.isNewline) {
                let cols = line.split(separator: "\t")
                // binary files report "-\t-"; skip
                guard cols.count >= 2, let a = Int(cols[0]), let d = Int(cols[1]) else { continue }
                added += a
                deleted += d
            }
            resolved = (added == 0 && deleted == 0) ? nil : GitDiff(added: added, deleted: deleted)
        }

        diffCache[path] = (Date(), resolved)
        return resolved
    }

    private func queryBranch(for path: String) -> String? {
        if let (cachedAt, cachedValue) = branchCache[path], Date().timeIntervalSince(cachedAt) < 10 {
            return cachedValue
        }
        var branch = Shell.run(GIT, ["-C", path, "branch", "--show-current"])
        if branch?.isEmpty == true { branch = nil }
        branchCache[path] = (Date(), branch)
        return branch
    }

    private func queryPRInfo(for path: String) -> PRInfo? {
        if let (cachedAt, cachedValue) = prCache[path], Date().timeIntervalSince(cachedAt) < 60 {
            return cachedValue
        }

        var resolved: PRInfo?

        if FileManager.default.isExecutableFile(atPath: GH),
           let out = Shell.run(GH, ["pr", "view", "--json", "state,isDraft,number,url"], cwd: path),
           let data = out.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let stateRaw = object["state"] as? String,
           let number = object["number"] as? Int,
           let url = object["url"] as? String {
            let mappedState = (object["isDraft"] as? Bool == true && stateRaw == "OPEN")
                ? PRState.draft
                : PRState(rawValue: stateRaw.lowercased())

            if let mappedState {
                resolved = PRInfo(state: mappedState, number: number, url: url)
            }
        }

        prCache[path] = (Date(), resolved)
        return resolved
    }

    // MARK: - Agent scan

    private func queryAgents(rows: [PaneRow]) -> [AgentInfo] {
        if rows.isEmpty {
            agentWorked.removeAll()
            paneStatusCache.removeAll()
            return []
        }

        let now = Date().timeIntervalSince1970
        let needsProcessSnapshot = rows.contains { wrapperCommands.contains($0.command) }
        let childrenByPpid = needsProcessSnapshot ? cachedProcessSnapshot(now: now) : [:]

        var found: [AgentInfo] = []
        found.reserveCapacity(rows.count)

        for row in rows {
            if let tool = resolveAgentTool(command: row.command, panePid: row.pid, children: childrenByPpid) {
                let status = classifyAgentStatus(pane: row.pane, title: row.title, activity: row.activity, now: now)
                found.append(AgentInfo(paneId: row.pane, session: row.session, tool: tool, status: status))
            } else if serverCommands.contains(where: { row.command.hasPrefix($0) }) {
                // dev server: show in the panel with a green "running" dot (status unused, rendered green)
                found.append(AgentInfo(paneId: row.pane, session: row.session, tool: row.command, status: .idle, isServer: true))
            } else if scriptShells.contains(row.command) {
                // pane's foreground process is a non-login shell => a script is running.
                // ponytail: can't detect `zsh script.sh` — indistinguishable from the interactive zsh prompt
                found.append(AgentInfo(paneId: row.pane, session: row.session, tool: "script (\(row.command))", status: .idle, isServer: true))
            }
        }

        let livePanes = Set(found.map(\.paneId))
        agentWorked.formIntersection(livePanes)
        paneStatusCache = paneStatusCache.filter { livePanes.contains($0.key) }

        // caller sorts against the fresh session snapshot; published `sessions` is main-owned
        // servers first so running dev servers stay visible above the (often longer) agent list
        return found.filter(\.isServer) + found.filter { !$0.isServer }
    }

    private func resolveAgentTool(command: String,
                                  panePid: String,
                                  children: [String: [(pid: String, name: String, args: String)]]) -> String? {
        if let direct = canonicalTool(from: command) {
            return direct
        }

        guard wrapperCommands.contains(command) else { return nil }

        var queue = [panePid]
        var visited = Set<String>()

        while let pid = queue.popLast() {
            guard visited.insert(pid).inserted else { continue }

            for child in children[pid] ?? [] {
                if let resolved = canonicalTool(from: child.name) {
                    return resolved
                }
                // cursor CLI's argv0 is the generic "agent"; its script path
                // (~/.local/share/cursor-agent/...) is the reliable marker
                if child.args.contains("cursor-agent") { return "cursor" }
                // node-shebang CLIs (pi, opencode) show argv0 "node"; script path is the marker
                if let fromPath = agentTools.first(where: {
                    child.args.range(of: "/\($0)( |$)", options: .regularExpression) != nil
                }) { return fromPath }
                queue.append(child.pid)
            }
        }

        return nil
    }

    private func canonicalTool(from raw: String) -> String? {
        let command = raw.lowercased()
        if agentTools.contains(command) { return command }
        if command.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil { return "claude" }
        if command == "open-code" { return "opencode" }
        if command == "cursor-agent" { return "cursor" }
        return nil
    }

    // full ps dump costs real CPU every 2s pass; reuse for 4s (same lag class as paneStatusCache)
    private func cachedProcessSnapshot(now: Double) -> [String: [(pid: String, name: String, args: String)]] {
        if let cached = processSnapshotCache, now - cached.at < 4 {
            return cached.children
        }
        let children = processSnapshot()
        processSnapshotCache = (now, children)
        return children
    }

    // one ps pass grouped by ppid, so wrapper resolution is a dictionary walk, not repeated array scans
    private func processSnapshot() -> [String: [(pid: String, name: String, args: String)]] {
        let out = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,args="]) ?? ""

        var children: [String: [(pid: String, name: String, args: String)]] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count >= 3 else { continue }
            let args = String(fields[2]).lowercased()
            let argv0 = fields[2]
                .split(separator: " ")[0]
                .split(separator: "/")
                .last
                .map(String.init) ?? ""
            children[String(fields[1]), default: []].append((String(fields[0]), argv0.lowercased(), args))
        }
        return children
    }

    private func classifyAgentStatus(pane: String, title: String, activity: Double, now: Double) -> AgentStatus {
        // claude publishes state via OSC title (tmux tracks it as pane_title):
        // spinner glyph = working — braille U+2800-28FF (≤2.1.22x) or ◐◑◒◓ U+25D0-25D3 (2.1.235).
        // 2.1.241 dropped the title spinner entirely: title stays "✳ <topic>" even mid-turn,
        // so "✳" no longer means finished — only the footer's live counter distinguishes.
        let spinner = title.unicodeScalars.first.map {
            (0x2800...0x28FF).contains($0.value) || (0x25D0...0x25D3).contains($0.value)
        } ?? false

        // ponytail: throttle capture-pane to once per 4s per pane; status can lag up to 4s.
        // The title spinner is live truth and costs no subprocess (pane_title comes with
        // list-panes), so a cached verdict that contradicts it is stale — re-capture instead of
        // serving it. A turn that ended with a background shell keeps spinning, so that verdict
        // stays cached rather than re-capturing every pass.
        if let cached = paneStatusCache[pane], now - cached.at < 4,
           !spinner || cached.status == .working || cached.turnEnded {
            return cached.status
        }

        let lines = Shell.tmux("capture-pane", "-p", "-t", pane, "-S", "-30")?
            .split(whereSeparator: \.isNewline) ?? []
        let region = promptRegion(of: lines).lowercased()
        // status footer sits above the input rule, outside the dialog region
        let footer = footerRegion(of: lines).lowercased()
        // a background shell that outlives the turn keeps the spinner animating and the pane
        // redrawing, so neither the title nor pane activity can be trusted; the footer switches
        // from a live counter ("Spelunking… (3m · ↓ 10k tokens)") to a finished-turn summary
        // ("Worked for 3m 21s · 1 shell still running") and is the only signal that still flips
        let turnEnded = footer.contains("still running")
        // live-counter footer: "✻ Finagling… (6m 6s · ↓ 21.0k tokens · thinking)". The "… ("
        // + "tokens" pair only appears in the counter, never in transcript prose; older builds
        // print "esc to interrupt" instead. Waiting on a backgrounded subagent shows neither —
        // its footer is "✻ Waiting for N background agents to finish" (still a working turn).
        let busyFooter = workingPrompts.contains(where: { footer.contains($0) })
            || (footer.contains("… (") && footer.contains(" tokens"))
            || footer.contains("background agent")

        let status: AgentStatus
        if blockedPrompts.contains(where: { region.contains($0) }) {
            status = .blocked
        } else if (spinner || busyFooter) && !turnEnded {
            agentWorked.insert(pane)
            status = .working
        } else if title.hasPrefix("✳") || spinner {
            status = agentWorked.contains(pane) ? .done : .idle
        } else if !turnEnded && (now - activity) < 2.5 {
            // no title signal (codex/opencode/cursor): pane-activity fallback
            agentWorked.insert(pane)
            status = .working
        } else {
            status = agentWorked.contains(pane) ? .done : .idle
        }

        paneStatusCache[pane] = (now, status, turnEnded)
        return status
    }

    // claude draws its input box and permission dialog under a full-width "─" rule (older builds
    // used a "╭─" box top). Scanning only from the last rule down keeps transcript prose — an agent
    // writing "do you want" — from reading as a permission prompt.
    // ponytail: whole tail when no rule found (codex/opencode draw neither)
    private func promptRegion(of lines: [Substring]) -> String {
        guard let idx = ruleIndex(of: lines) else { return lines.joined(separator: "\n") }
        return lines[idx...].joined(separator: "\n")
    }

    // the status footer sits directly above the input rule, sometimes with a tip line under it;
    // matching busy/idle markers here instead of the whole tail keeps agent prose from scoring
    private func footerRegion(of lines: [Substring]) -> String {
        let end = ruleIndex(of: lines) ?? lines.count
        return lines[max(0, end - 6)..<end].joined(separator: "\n")
    }

    private func ruleIndex(of lines: [Substring]) -> Int? {
        lines.lastIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("╭") || (trimmed.count >= 20 && trimmed.allSatisfy { $0 == "─" })
        }
    }

    // MARK: - User actions

    // Finder can supply multiple URLs; only existing local directories create sessions.
    // tmux assigns unique names, just like ⌘N, so repeated drops never collide.
    @discardableResult
    func openDirectories(_ urls: [URL]) -> Bool {
        let directories = urls.filter {
            $0.isFileURL && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard !directories.isEmpty else { return false }
        for directory in directories {
            newSession(in: directory.path)
        }
        return true
    }

    func newSession() {
        newSession(in: nil)
    }

    private func newSession(in directory: String?) {
        let current = selected
        actionQueue.async { [weak self] in
            guard let self else { return }
            // Explicit directory for Finder drops; otherwise inherit the active pane cwd.
            let cwd = directory ?? current.flatMap {
                Shell.tmux("display-message", "-p", "-t", "=" + $0 + ":", "#{pane_current_path}")
            } ?? NSHomeDirectory()
            let created = Shell.tmux("new-session", "-d", "-c", cwd, "-P", "-F", "#S")
            if let created {
                // optimistic insert: attach terminal now, don't wait a full refresh pass
                DispatchQueue.main.async {
                    if !self.sessions.contains(where: { $0.name == created }) {
                        self.sessions.append(Session(name: created, path: cwd))
                    }
                    self.selected = created
                }
            }
            self.refresh()
        }
    }

    private enum GridPlacement { case split(SplitDirection), tab }

    // app-level grid split: new tmux session in the focused cwd, tagged into its group.
    // tmux-native splits stay available via the tmux prefix.
    func splitPaneRight() { addGridMember(.split(.right)) }
    func splitPaneDown() { addGridMember(.split(.down)) }
    func newTab() { addGridMember(.tab) }
    func newTab(beside name: String) { addGridMember(.tab, beside: name) }

    // Split the clicked tab out of its own pane, leaving an empty pane if it was alone.
    func splitSession(_ name: String, direction: SplitDirection) {
        guard sessions.contains(where: { $0.name == name }) else { return }
        let existingID = layoutGroup(containing: name)
        let gid = existingID ?? groupOf[name] ?? UUID().uuidString.lowercased()
        let previous = layouts[gid]
        let base = previous ?? .leaf(tabs: [name], active: 0)
        let next = base.splittingOff(name, direction: direction)
        setLayout(next, for: gid)
        selected = name
        guard existingID == nil else { return }
        pendingTags[name] = gid
        pendingSince[name] = Date()
        actionQueue.async { [weak self] in
            guard let self else { return }
            let tagged = Shell.tmux("set-option", "-t", "=" + name + ":", "@promote-group", gid) != nil
            if !tagged {
                DispatchQueue.main.async {
                    if self.pendingTags[name] == gid {
                        self.pendingTags.removeValue(forKey: name)
                        self.pendingSince.removeValue(forKey: name)
                        if self.layouts[gid] == next { self.setLayout(previous, for: gid) }
                    }
                }
            }
            self.refresh()
        }
    }

    func fillEmptyPane(gid: String, path: [Bool], with name: String) {
        guard let layout = layouts[gid], layout.isEmptyPane(at: path),
              sessions.contains(where: { $0.name == name }) else { return }
        if layoutGroup(containing: name) != gid {
            guard let anchor = layout.allSessions.first else { return }
            moveSession(name, beside: anchor, edge: nil)
        }
        guard let current = layouts[gid], current.contains(name), current.isEmptyPane(at: path) else { return }
        let next = current.fillingEmptyPane(at: path, with: name)
        setLayout(next.isPersistentLayout ? next : nil, for: gid)
        if !next.isPersistentLayout { for member in next.allSessions { untag(member) } }
        selected = name
    }

    private func addGridMember(_ placement: GridPlacement, beside session: String? = nil) {
        guard let focused = session ?? selected else { return }
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
                case .split(let direction): next = base.split(name, beside: focused, direction: direction)
                case .tab: next = base.insertTab(name, into: focused)
                }
                self.setLayout(next, for: gid)
                // focused is always pending too: a lone-survivor untag queued just before this
                // split must not dissolve the group we're growing
                self.pendingTags[name] = gid
                self.pendingTags[focused] = gid
                self.pendingSince[name] = Date()
                self.pendingSince[focused] = Date()
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
                    self.setLayout(rest?.isPersistentLayout == true ? rest : nil, for: gid)
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
        var tokens = expandingGroups(canonicalTokens()).filter { $0 != name }
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

    func requestKillSession(_ name: String) {
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

    // ⌘W closes only the focused session, leaving sibling tabs and panes running.
    func closeActiveSession() {
        guard let selected else { return }
        requestKillSession(selected)
    }

    // ⌘⌥C: selected session's path, home-abbreviated to ~/…
    func copySelectedRelativePath() {
        guard let name = selected,
              let path = sessions.first(where: { $0.name == name })?.path,
              !path.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((path as NSString).abbreviatingWithTildeInPath, forType: .string)
    }

    func rename(_ old: String, to proposed: String) {
        let next = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty, next != old else { return }

        actionQueue.async { [weak self] in
            guard let self else { return }
            guard Shell.tmux("rename-session", "-t", "=" + old, next) != nil else {
                self.refresh()
                return
            }

            DispatchQueue.main.async {
                if let chatName = self.chatNames.removeValue(forKey: old) {
                    self.chatNames[next] = chatName
                    Settings.chatNames = self.chatNames
                }
                if let color = self.colors.removeValue(forKey: old) {
                    self.colors[next] = color
                    self.saveColors()
                }
                if self.locked.remove(old) != nil {
                    self.locked.insert(next)
                    Settings.locked = Array(self.locked)
                }

                if let idx = self.orderTokens.firstIndex(of: old) {
                    self.orderTokens[idx] = next
                    Settings.order = self.orderTokens
                }
                if self.layouts.values.contains(where: { $0.contains(old) }) {
                    self.layouts = self.layouts.mapValues { $0.renaming(old, to: next) }
                    Settings.layouts = self.layouts
                }
                if let gid = self.pendingTags.removeValue(forKey: old) {
                    self.pendingTags[next] = gid
                    self.pendingSince[next] = self.pendingSince.removeValue(forKey: old)
                }
                if let gid = self.groupOf.removeValue(forKey: old) { self.groupOf[next] = gid }

                if self.selected == old {
                    self.selected = next
                }
            }

            self.refresh()
        }
    }

    func kill(_ sessionName: String) {
        guard !locked.contains(sessionName) else { return }
        // grid member: drop its cell now and hand focus to a neighbor. Only here, so a
        // cancelled confirm dialog never moves focus.
        pendingTags.removeValue(forKey: sessionName)
        pendingSince.removeValue(forKey: sessionName)
        if let gid = layoutGroup(containing: sessionName), let layout = layouts[gid] {
            pendingKills.insert(sessionName)
            let rest = layout.removing(sessionName)
            let neighbor = layout.survivingSession(
                afterClosing: sessionName,
                live: Set(sessions.map(\.name)).subtracting(pendingKills)
            )
            setLayout(rest?.isPersistentLayout == true ? rest : nil, for: gid)
            if selected == sessionName, let neighbor { selected = neighbor }
        }
        actionQueue.async { [weak self] in
            guard let self else { return }
            _ = Shell.tmux("kill-session", "-t", "=" + sessionName)
            self.refresh()
        }
    }

    func setLocked(_ sessionName: String, _ isLocked: Bool) {
        if isLocked {
            locked.insert(sessionName)
        } else {
            locked.remove(sessionName)
        }
        Settings.locked = Array(locked)
    }

    func setColor(_ sessionName: String, hex: String?) {
        if let hex {
            colors[sessionName] = hex
        } else {
            colors.removeValue(forKey: sessionName)
        }
        saveColors()
    }

    // canonical token list matching exactly what the sidebar renders
    private func canonicalTokens() -> [String] {
        sidebarItems.map(\.token)
    }

    // visible tokens -> persisted order: hidden group members ride right after their row,
    // so moving a group row moves the whole group and the row stays the group's first member
    private func expandingGroups(_ tokens: [String]) -> [String] {
        tokens.flatMap { token in
            Self.dividerId(token) == nil ? groupMembers(of: token) : [token]
        }
    }

    func addDivider(after sessionName: String) {
        var tokens = canonicalTokens()
        let token = Self.dividerPrefix + UUID().uuidString
        let at = tokens.firstIndex(of: sessionName).map { $0 + 1 } ?? tokens.count
        tokens.insert(token, at: at)
        orderTokens = expandingGroups(tokens)
        Settings.order = orderTokens
    }

    func removeDivider(_ id: String) {
        orderTokens.removeAll { Self.dividerId($0) == id }
        Settings.order = orderTokens
        dividerTitles.removeValue(forKey: id)
        Settings.dividerTitles = dividerTitles
    }

    func setDividerTitle(_ id: String, _ title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            dividerTitles.removeValue(forKey: id)
        } else {
            dividerTitles[id] = cleaned
        }
        Settings.dividerTitles = dividerTitles
    }

    // Drag-drop reorder. Token is a session name or divider token; index is the
    // gap position in the flat sidebar item list.
    func handleDrop(token: String, at index: Int) {
        var tokens = canonicalTokens()
        guard let from = tokens.firstIndex(of: token) else { return }

        var insertAt = min(max(0, index), tokens.count)
        tokens.remove(at: from)
        if from < insertAt { insertAt -= 1 }
        tokens.insert(token, at: min(insertAt, tokens.count))

        orderTokens = expandingGroups(tokens)
        Settings.order = orderTokens

        // resort published sessions to match
        let rank = Dictionary(uniqueKeysWithValues: orderTokens.enumerated().map { ($0.element, $0.offset) })
        sessions = sessions.sorted { (rank[$0.name] ?? .max) < (rank[$1.name] ?? .max) }
    }

    // escape hatch for wedged terminal key state: rebuild the SwiftTerm view + reattach
    func reattachTerminal() {
        terminalEpoch += 1
    }

    // menu bar: show installed tmux version, warn on known server-crashing releases
    func checkTmuxVersion() {
        workerQueue.async {
            let version = Shell.run(TMUX, ["-V"]) ?? "tmux not found at \(TMUX)"
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = version
                // ponytail: hardcoded known-bad list, no brew/network query; extend if another bad release ships
                if version.contains("3.6") {
                    alert.informativeText = """
                    tmux 3.6–3.6b crashes in copy-mode on Apple Silicon (tmux/tmux#4777), \
                    killing every session — the terminal goes dark.
                    Fix: brew upgrade tmux, then tmux kill-server (drops sessions) and relaunch.
                    """
                }
                alert.runModal()
            }
        }
    }

    func jumpToHotkeyIndex(_ index: Int) {
        let ordered = hotkeyOrderedSessions
        guard index > 0, index <= ordered.count else { return }
        selectRow(ordered[index - 1].name)
    }

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
        let now = Date()
        for (name, gid) in pendingTags where snapshot[name] == gid
            || (!live.isEmpty && !live.contains(name) && now.timeIntervalSince(pendingSince[name] ?? .distantPast) > 5) {
            pendingTags.removeValue(forKey: name)
            pendingSince.removeValue(forKey: name)
        }
        pendingKills.formIntersection(live)
        var merged = snapshot
        for (name, gid) in pendingTags { merged[name] = gid }
        if groupOf != merged { groupOf = merged }

        // empty list = server down or query failed; reconciling would dissolve every group
        guard !live.isEmpty else { return }
        reconciledSnapshots += 1
        // ponytail: 3 snapshots (~6s) is the "restore finished" guess; after that a layout
        // name that isn't live is dead, seen this run or not (killed while the app was closed)
        let known = reconciledSnapshots > 3 ? Set(layouts.values.flatMap(\.allSessions)).union(seenLive) : seenLive
        let prunable = known.union(pendingKills).subtracting(pendingTags.keys)
        var next = layouts
        for gid in Set(merged.values).union(layouts.keys) {
            let members = merged
                .filter { $0.value == gid && !pendingKills.contains($0.key)
                    && (live.contains($0.key) || pendingTags[$0.key] != nil) }
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
        actionQueue.async { [weak self] in
            guard let self else { return }
            // re-check at run time: a split queued ahead of us may have re-grouped it
            let stillLone = DispatchQueue.main.sync {
                self.pendingTags[name] == nil && self.layoutGroup(containing: name) == nil
            }
            if stillLone {
                _ = Shell.tmux("set-option", "-u", "-t", "=" + name + ":", "@promote-group")
            }
        }
    }

    // MARK: - Private helpers

    private func saveColors() {
        Settings.colors = colors
    }
}

enum SidebarItem: Identifiable {
    case divider(id: String, title: String)
    case session(Session)

    var id: String {
        switch self {
        case .divider(let id, _): return "d:" + id
        case .session(let session): return "s:" + session.name
        }
    }

    // drag payload / order-token form
    var token: String {
        switch self {
        case .divider(let id, _): return SessionStore.dividerPrefix + id
        case .session(let session): return session.name
        }
    }
}
