import SwiftUI

// owns session list, selection, per-session metadata, and all tmux/git/gh calls
final class SessionStore: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var selected: String?
    @Published var details: [String: Details] = [:]
    @Published var colors: [String: String] = Settings.colors
    @Published var groups: [String: String] = Settings.groups
    @Published var showCheatSheet = false
    @Published var agents: [AgentInfo] = []

    let defaultGroup = "Sessions"

    // ponytail: serial queue serializes access to prCache, no lock needed
    private let detailsQueue = DispatchQueue(label: "details")
    private var prCache: [String: (Date, PRInfo?)] = [:] // touch only on detailsQueue
    private var agentWorked: Set<String> = [] // pane ids seen working; touch only on detailsQueue
    private let agentTools: Set<String> = ["claude", "pi", "opencode", "codex"]

    var groupNames: [String] { Set(groups.values).sorted() }

    // grouped sections first (alphabetical); ungrouped section always present so drops land there
    var grouped: [(String, [Session])] {
        var out: [(String, [Session])] = []
        for g in groupNames {
            let items = sessions.filter { groups[$0.name] == g }
            if !items.isEmpty { out.append((g, items)) }
        }
        out.append((defaultGroup, sessions.filter { groups[$0.name] == nil }))
        return out
    }

    func color(of name: String) -> SwiftUI.Color? {
        guard let v = colors[name] else { return nil }
        // hex value, or legacy palette id like "red"
        return colorFromHex(v) ?? palette.first { $0.id.lowercased() == v }?.color
    }

    // MARK: - tmux actions

    func refresh() {
        // session_path is the start dir and can be stale; active pane path tracks reality
        let out = tmux("list-sessions", "-F", "#S\t#{pane_current_path}") ?? ""
        var list = out.split(separator: "\n").map { line -> Session in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return Session(name: parts[0], path: parts.count > 1 ? parts[1] : "")
        }
        let order = Settings.order
        let rank = { (s: Session) in order.firstIndex(of: s.name) ?? Int.max }
        list = list.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
        if list != sessions { sessions = list }
        if let sel = selected, !list.contains(where: { $0.name == sel }) { selected = nil }
        for s in list { fetchDetails(s) }
        fetchAgents()
    }

    func newSession() {
        if let name = tmux("new-session", "-d", "-P", "-F", "#S") {
            refresh()
            selected = name
        }
    }

    func rename(_ old: String, to new: String) {
        guard !new.isEmpty, new != old else { return }
        tmux("rename-session", "-t", "=" + old, new)
        if let c = colors.removeValue(forKey: old) {
            colors[new] = c
            saveColors()
        }
        if let g = groups.removeValue(forKey: old) {
            groups[new] = g
            saveGroups()
        }
        var order = Settings.order
        if let i = order.firstIndex(of: old) {
            order[i] = new
            Settings.order = order
        }
        if selected == old { selected = new }
        refresh()
    }

    func kill(_ name: String) {
        tmux("kill-session", "-t", "=" + name)
        refresh()
    }

    // MARK: - metadata

    func setColor(_ name: String, hex: String?) {
        if let hex { colors[name] = hex } else { colors.removeValue(forKey: name) }
        saveColors()
    }

    func setGroup(_ name: String, to group: String?) {
        if let group { groups[name] = group } else { groups.removeValue(forKey: name) }
        saveGroups()
    }

    // drop `name` into `group` (nil = ungrouped) at row `index` of that section
    func handleDrop(name: String, group: String?, at index: Int) {
        guard let cur = sessions.firstIndex(where: { $0.name == name }) else { return }
        let items = sessions.filter { groups[$0.name] == group }
        var insertAt: Int
        if index < items.count {
            insertAt = sessions.firstIndex(of: items[index]) ?? sessions.count
        } else if let last = items.last {
            insertAt = (sessions.firstIndex(of: last) ?? sessions.count - 1) + 1
        } else {
            insertAt = sessions.count
        }
        let s = sessions.remove(at: cur)
        if cur < insertAt { insertAt -= 1 }
        setGroup(name, to: group)
        sessions.insert(s, at: insertAt)
        saveOrder()
    }

    private func saveOrder() { Settings.order = sessions.map(\.name) }

    private func saveColors() { Settings.colors = colors }

    private func saveGroups() { Settings.groups = groups }

    // MARK: - agents (panes running an agent CLI)

    private func fetchAgents() {
        detailsQueue.async { [self] in
            let now = Date().timeIntervalSince1970
            let out = tmux("list-panes", "-a", "-F",
                           "#{session_name}\t#{pane_id}\t#{pane_current_command}\t#{window_activity}") ?? ""
            let found = out.split(separator: "\n").compactMap { line -> AgentInfo? in
                let p = line.split(separator: "\t").map(String.init)
                guard p.count >= 4, let tool = agentTool(p[2]) else { return nil }
                return AgentInfo(paneId: p[1], session: p[0], tool: tool,
                                 status: agentStatus(pane: p[1], activity: Double(p[3]) ?? 0, now: now))
            }
            agentWorked.formIntersection(Set(found.map(\.paneId)))
            DispatchQueue.main.async {
                if self.agents != found { self.agents = found }
            }
        }
    }

    // ponytail: name/pattern match on pane_current_command; agents run via a
    // wrapper (node, sh) go undetected — walk the process tree if it matters
    private func agentTool(_ cmd: String) -> String? {
        if agentTools.contains(cmd) { return cmd }
        // claude code's process name is its version number, e.g. "2.1.201"
        if cmd.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil { return "claude" }
        return nil
    }

    // call only on detailsQueue (touches agentWorked)
    // ponytail: status = sniffing pane tail text + activity age; real fix is
    // agent-side hooks setting a tmux @status option this just reads
    private func agentStatus(pane: String, activity: Double, now: Double) -> AgentStatus {
        let tail = tmux("capture-pane", "-p", "-t", pane, "-S", "-20") ?? ""
        if tail.contains("Do you want") || tail.contains("Allow command")
            || tail.contains("(y/n)") || tail.contains("y/N") {
            return .blocked
        }
        if tail.localizedCaseInsensitiveContains("esc to interrupt") || now - activity < 3 {
            agentWorked.insert(pane)
            return .working
        }
        return agentWorked.contains(pane) ? .done : .idle
    }

    // MARK: - details (git branch + PR status)

    private func fetchDetails(_ s: Session) {
        detailsQueue.async { [self] in
            var d = Details()
            if !s.path.isEmpty {
                d.branch = run(GIT, ["-C", s.path, "branch", "--show-current"])
                if d.branch?.isEmpty == true { d.branch = nil }
                d.pr = prInfo(for: s.path)
            }
            DispatchQueue.main.async {
                if self.details[s.name] != d { self.details[s.name] = d }
            }
        }
    }

    // call only on detailsQueue; 60s cache per repo
    private func prInfo(for path: String) -> PRInfo? {
        if let (t, v) = prCache[path], Date().timeIntervalSince(t) < 60 { return v }
        var result: PRInfo?
        if FileManager.default.isExecutableFile(atPath: GH),
           let out = run(GH, ["pr", "view", "--json", "state,isDraft,number,url"], cwd: path),
           let data = out.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let stateRaw = obj["state"] as? String,
           let number = obj["number"] as? Int,
           let url = obj["url"] as? String {
            let state = (obj["isDraft"] as? Bool == true && stateRaw == "OPEN")
                ? PRState.draft : PRState(rawValue: stateRaw.lowercased())
            if let state { result = PRInfo(state: state, number: number, url: url) }
        }
        prCache[path] = (Date(), result)
        return result
    }
}
