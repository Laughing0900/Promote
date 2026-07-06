import SwiftUI
import Foundation

// owns app state and runs all tmux/git/gh shell work off the main thread
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published var selected: String?
    @Published private(set) var details: [String: SessionDetails] = [:]
    @Published var colors: [String: String] = Settings.colors
    @Published var groups: [String: String] = Settings.groups
    @Published var locked: Set<String> = Set(Settings.locked)
    // set when ⌘W would kill the session (last pane); RootView shows the confirm dialog
    @Published var pendingCloseLastPane: String?
    @Published var showCheatSheet = false
    @Published private(set) var agents: [AgentInfo] = []

    let defaultGroup = ""

    // ponytail: one serial queue keeps shell work + caches simple and deterministic
    private let workerQueue = DispatchQueue(label: "session.store.worker", qos: .userInitiated)
    private var refreshInFlight = false
    private var refreshPending = false

    // workerQueue-only caches
    private var prCache: [String: (Date, PRInfo?)] = [:]
    private var agentWorked: Set<String> = []

    private let agentTools: Set<String> = ["claude", "pi", "opencode", "codex"]
    private let wrapperCommands: Set<String> = ["node", "bun", "sh"]
    // permission prompts + AskUserQuestion picker footer (matched against lowercased prompt region)
    private let blockedPrompts: [String] = ["do you want", "allow command", "y/n", "enter to select", "esc to cancel"]
    // Only the literal busy footer (claude/cursor). Generic words ("running", "thinking")
    // false-positive on normal transcript text and pin status at working.
    private let workingPrompts: [String] = ["esc to interrupt"]

    // MARK: - Derived state

    var grouped: [(String, [Session])] {
        sections(from: sessions)
    }

    var hotkeyOrderedSessions: [Session] {
        sections(from: sessions).flatMap(\.1)
    }

    var groupNames: [String] {
        let activeNames = Set(sessions.map(\.name))
        let names = groups.compactMap { key, value -> String? in
            guard activeNames.contains(key) else { return nil }
            return normalizedGroupName(value)
        }
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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

    private func performRefreshPass() {
        let snapshotSessions = querySessions()

        // publish sessions before the slow git/gh pass so first paint doesn't wait on the network
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applySnapshot(sessions: snapshotSessions, details: self.details, agents: self.agents)
        }

        var snapshotDetails: [String: SessionDetails] = [:]

        for session in snapshotSessions {
            snapshotDetails[session.name] = queryDetails(for: session)
        }

        let snapshotAgents = queryAgents()

        DispatchQueue.main.async { [weak self] in
            self?.applySnapshot(sessions: snapshotSessions, details: snapshotDetails, agents: snapshotAgents)
        }

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

    private func applySnapshot(sessions nextSessions: [Session],
                               details nextDetails: [String: SessionDetails],
                               agents nextAgents: [AgentInfo]) {
        if sessions != nextSessions {
            sessions = nextSessions
        }

        let sessionNames = Set(nextSessions.map(\.name))
        if let selected, !sessionNames.contains(selected) {
            self.selected = nextSessions.first?.name
        } else if selected == nil {
            self.selected = nextSessions.first?.name
        }

        if details != nextDetails {
            details = nextDetails
        }

        if agents != nextAgents {
            agents = nextAgents
        }
    }

    private func querySessions() -> [Session] {
        // list-panes so path comes from the FIRST pane (leftmost), not the active one
        let out = Shell.tmux("list-panes", "-a", "-F", "#{session_name}\t#{pane_current_path}") ?? ""

        var seen = Set<String>()
        var parsed: [Session] = out
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard let first = parts.first, !first.isEmpty else { return nil }
                let name = String(first)
                guard seen.insert(name).inserted else { return nil }
                let path = parts.count > 1 ? String(parts[1]) : ""
                return Session(name: name, path: path)
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
        next.branch = Shell.run(GIT, ["-C", session.path, "branch", "--show-current"])
        if next.branch?.isEmpty == true { next.branch = nil }
        next.pr = queryPRInfo(for: session.path)
        return next
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

    private func queryAgents() -> [AgentInfo] {
        let format = "#{session_name}\t#{pane_id}\t#{pane_current_command}\t#{window_activity}\t#{pane_pid}\t#{pane_title}"
        let out = Shell.tmux("list-panes", "-a", "-F", format) ?? ""

        let rows: [(session: String, pane: String, command: String, activity: Double, pid: String, title: String)] =
            out.split(whereSeparator: \.isNewline).compactMap { line in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 6 else { return nil }
                return (parts[0], parts[1], parts[2].lowercased(), Double(parts[3]) ?? 0, parts[4], parts[5])
            }

        if rows.isEmpty {
            agentWorked.removeAll()
            return []
        }

        let needsProcessSnapshot = rows.contains { wrapperCommands.contains($0.command) }
        let processes = needsProcessSnapshot ? processSnapshot() : []
        let now = Date().timeIntervalSince1970

        var found: [AgentInfo] = []
        found.reserveCapacity(rows.count)

        for row in rows {
            guard let tool = resolveAgentTool(command: row.command, panePid: row.pid, ps: processes) else {
                continue
            }

            let status = classifyAgentStatus(pane: row.pane, title: row.title, activity: row.activity, now: now)
            found.append(AgentInfo(paneId: row.pane, session: row.session, tool: tool, status: status))
        }

        agentWorked.formIntersection(Set(found.map(\.paneId)))

        let sidebarRank = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($0.element.name, $0.offset) })
        return found.sorted {
            (sidebarRank[$0.session] ?? .max, $0.paneId) < (sidebarRank[$1.session] ?? .max, $1.paneId)
        }
    }

    private func resolveAgentTool(command: String,
                                  panePid: String,
                                  ps: [(pid: String, ppid: String, name: String, args: String)]) -> String? {
        if let direct = canonicalTool(from: command) {
            return direct
        }

        guard wrapperCommands.contains(command) else { return nil }

        var queue = [panePid]
        var visited = Set<String>()

        while let pid = queue.popLast() {
            guard visited.insert(pid).inserted else { continue }

            for child in ps where child.ppid == pid {
                if let resolved = canonicalTool(from: child.name) {
                    return resolved
                }
                // cursor CLI's argv0 is the generic "agent"; its script path
                // (~/.local/share/cursor-agent/...) is the reliable marker
                if child.args.contains("cursor-agent") { return "cursor" }
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

    private func processSnapshot() -> [(pid: String, ppid: String, name: String, args: String)] {
        let out = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,args="]) ?? ""

        return out.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count >= 3 else { return nil }
            let args = String(fields[2]).lowercased()
            let argv0 = fields[2]
                .split(separator: " ")[0]
                .split(separator: "/")
                .last
                .map(String.init) ?? ""
            return (String(fields[0]), String(fields[1]), argv0.lowercased(), args)
        }
    }

    private func classifyAgentStatus(pane: String, title: String, activity: Double, now: Double) -> AgentStatus {
        // claude publishes state via OSC title (tmux tracks it as pane_title):
        // braille spinner U+2800-28FF = working, "✳" = turn finished
        if let first = title.unicodeScalars.first, (0x2800...0x28FF).contains(first.value) {
            agentWorked.insert(pane)
            return .working
        }

        let tail = Shell.tmux("capture-pane", "-p", "-t", pane, "-S", "-30") ?? ""
        let region = promptRegion(of: tail).lowercased()

        if blockedPrompts.contains(where: { region.contains($0) }) {
            return .blocked
        }

        if title.hasPrefix("✳") {
            return agentWorked.contains(pane) ? .done : .idle
        }

        // no title signal (codex/opencode/cursor): activity + busy-footer fallback
        let isRecent = (now - activity) < 2.5
        let hasWorkingPrompt = workingPrompts.contains { token in
            region.contains(token)
        }

        if isRecent || hasWorkingPrompt {
            agentWorked.insert(pane)
            return .working
        }

        return agentWorked.contains(pane) ? .done : .idle
    }

    // claude draws its input/permission UI in a "╭─" box at the bottom; scanning only from the
    // last box top down keeps transcript text (quoted prompts, old dialogs) from false-positiving.
    // ponytail: whole tail when no box found (codex/opencode draw no boxes)
    private func promptRegion(of tail: String) -> String {
        let lines = tail.split(whereSeparator: \.isNewline)
        guard let idx = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("╭") }) else {
            return tail
        }
        return lines[idx...].joined(separator: "\n")
    }

    // MARK: - User actions

    func newSession() {
        let current = selected
        workerQueue.async { [weak self] in
            guard let self else { return }
            // new session starts in the selected session's active pane cwd (home if none)
            let cwd = current.flatMap {
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

    // split the selected session's active window horizontally (new pane on the right)
    func splitPaneRight() {
        guard let selected else { return }
        workerQueue.async { [weak self] in
            guard let self else { return }
            // split-window wants a pane target; "=name:" = exact session, active window
            // -c expands relative to the target pane, so new pane inherits its cwd
            _ = Shell.tmux("split-window", "-h", "-t", "=" + selected + ":", "-c", "#{pane_current_path}")
            self.refresh()
        }
    }

    // split the selected session's active window vertically (new pane below)
    func splitPaneDown() {
        guard let selected else { return }
        workerQueue.async { [weak self] in
            guard let self else { return }
            _ = Shell.tmux("split-window", "-v", "-t", "=" + selected + ":", "-c", "#{pane_current_path}")
            self.refresh()
        }
    }

    // kill the selected session's active pane; tmux kills the session when the last pane dies
    func closeActivePane() {
        guard let selected, !locked.contains(selected) else { return }
        workerQueue.async { [weak self] in
            guard let self else { return }
            let paneCount = Shell.tmux("list-panes", "-t", "=" + selected)?
                .split(separator: "\n").count ?? 0
            if paneCount <= 1 {
                // last pane: closing kills the session — route through the kill confirm dialog
                DispatchQueue.main.async { self.pendingCloseLastPane = selected }
                return
            }
            _ = Shell.tmux("kill-pane", "-t", "=" + selected + ":")
            self.refresh()
        }
    }

    func rename(_ old: String, to proposed: String) {
        let next = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty, next != old else { return }

        workerQueue.async { [weak self] in
            guard let self else { return }
            guard Shell.tmux("rename-session", "-t", "=" + old, next) != nil else {
                self.refresh()
                return
            }

            DispatchQueue.main.async {
                if let color = self.colors.removeValue(forKey: old) {
                    self.colors[next] = color
                    self.saveColors()
                }
                if let group = self.groups.removeValue(forKey: old) {
                    self.groups[next] = group
                    self.saveGroups()
                }
                if self.locked.remove(old) != nil {
                    self.locked.insert(next)
                    Settings.locked = Array(self.locked)
                }

                var order = Settings.order
                if let idx = order.firstIndex(of: old) {
                    order[idx] = next
                    Settings.order = order
                }

                if self.selected == old {
                    self.selected = next
                }
            }

            self.refresh()
        }
    }

    func kill(_ sessionName: String) {
        guard !locked.contains(sessionName) else { return }
        workerQueue.async { [weak self] in
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

    func setGroup(_ sessionName: String, to group: String?) {
        if let normalized = normalizedGroupName(group) {
            groups[sessionName] = normalized
        } else {
            groups.removeValue(forKey: sessionName)
        }
        saveGroups()
    }

    // Drag-drop reorder. Index is within the destination group's visible rows.
    func handleDrop(name: String, group: String?, at index: Int) {
        guard let moving = sessions.first(where: { $0.name == name }) else { return }

        let normalizedGroup = normalizedGroupName(group)
        var ordered = sessions.filter { $0.name != name }

        if let normalizedGroup {
            groups[name] = normalizedGroup
        } else {
            groups.removeValue(forKey: name)
        }
        saveGroups()

        let destinationRows = ordered.filter { normalizedGroupName(groups[$0.name]) == normalizedGroup }

        var insertAt = ordered.count
        if index < destinationRows.count {
            let anchor = destinationRows[index]
            insertAt = ordered.firstIndex(of: anchor) ?? ordered.count
        } else if let last = destinationRows.last {
            insertAt = (ordered.firstIndex(of: last) ?? (ordered.count - 1)) + 1
        }

        insertAt = min(max(0, insertAt), ordered.count)
        ordered.insert(moving, at: insertAt)

        sessions = ordered
        saveOrder()
    }

    func jumpToHotkeyIndex(_ index: Int) {
        let ordered = hotkeyOrderedSessions
        guard index > 0, index <= ordered.count else { return }
        selected = ordered[index - 1].name
    }

    // MARK: - Private helpers

    private func sections(from source: [Session]) -> [(String, [Session])] {
        guard !source.isEmpty else { return [(defaultGroup, [])] }

        var output: [(String, [Session])] = []

        let sortedGroups = Array(Set(source.compactMap { normalizedGroupName(groups[$0.name]) }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        for group in sortedGroups {
            let rows = source.filter { normalizedGroupName(groups[$0.name]) == group }
            if !rows.isEmpty {
                output.append((group, rows))
            }
        }

        let ungrouped = source.filter { normalizedGroupName(groups[$0.name]) == nil }
        output.append((defaultGroup, ungrouped))
        return output.filter { !$0.1.isEmpty || $0.0 == defaultGroup }
    }

    private func normalizedGroupName(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func saveOrder() {
        Settings.order = sessions.map(\.name)
    }

    private func saveColors() {
        Settings.colors = colors
    }

    private func saveGroups() {
        Settings.groups = groups
    }
}
