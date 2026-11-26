import Foundation

// Live agent status. Same idea as asafofer/perch: the agent says exactly what happened (prompt
// sent, tool ran, asks permission, turn stopped) and that wins over the screen scrape. Perch
// posts hook events to a unix socket; Promote is tmux-only, so each agent's extension
// (repo: /extension) writes the pane option `@promote-status` ("<tool> <status> <epoch>") and
// the existing list-panes call reads it back. No server, and the state survives a restart.
// ponytail: status still lands on the 2s refresh tick; a socket (Perch's HookServer) is the
// upgrade if that lag ever matters. opencode/cursor stay on the scrape.

enum HookStatus: String {
    case working, blocked, done, failed
}

struct HookReport: Equatable {
    let status: HookStatus
    let at: Double

    // Only a report from the agent now in the pane counts: one left behind by another agent
    // that ran here earlier (and whose successor has no hooks) must not stick.
    static func parse(_ raw: String, tool: String) -> HookReport? {
        let parts = raw.split(separator: " ")
        guard parts.count == 3, parts[0] == tool, let status = HookStatus(rawValue: String(parts[1])),
              let at = Double(parts[2]) else { return nil }
        return HookReport(status: status, at: at)
    }
}

// Claude Code keeps its own record of every running session in ~/.claude/sessions/<pid>.json:
// `status` (busy | idle | waiting), and `tmux` ("<session>:@<window>.%<pane>") when it runs in
// a pane. Nothing to install, and it sees what hooks cannot (Esc, a denied prompt, a turn that
// carries on when background work reports back).
// ponytail: an internal file, not a documented interface; a release may rename fields or stop
// writing `status`. Then this reads nothing and the hook report / scrape carry on alone.
enum ClaudeRegistry {
    struct Entry: Equatable {
        let pane: String
        let pid: Int32
        let status: AgentStatus   // .idle = quiet; the caller knows whether that means done
        let at: Double
    }

    static func parse(_ data: Data) -> Entry? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = o["pid"] as? Int, let raw = o["status"] as? String,
              let tmux = o["tmux"] as? String, let percent = tmux.lastIndex(of: "%") else { return nil }
        let status: AgentStatus
        switch raw {
        case "busy": status = .working
        case "waiting": status = .blocked
        case "idle": status = .idle
        default: return nil
        }
        return Entry(pane: String(tmux[percent...]), pid: Int32(pid), status: status,
                     at: o["updatedAt"] as? Double ?? 0)
    }

    // pane id -> status, from the sessions whose process is still alive (newest record per pane)
    // ponytail: keyed by pane id alone, which is unique per tmux server; a Claude on a second
    // server (`tmux -L`) with the same pane id can lend its status. Match the socket if it bites.
    static func statuses(in dir: URL = AgentHooks.home.appendingPathComponent(".claude/sessions")) -> [String: AgentStatus] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var newest: [String: Entry] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let entry = parse(data),
                  kill(entry.pid, 0) == 0 || errno == EPERM,
                  entry.at >= newest[entry.pane]?.at ?? -1 else { continue }
            newest[entry.pane] = entry
        }
        return newest.mapValues(\.status)
    }
}

enum AgentHooks {
    // MARK: - Hook vs registry vs scrape

    // A fresh hook report wins. Hooks are blind in places (no hook for Esc or a denied prompt,
    // none when background work wakes a finished turn, and a subagent's tool call is ignored by
    // the script), so a report that has had 3s to settle yields to Claude's own registry where
    // there is one, else to the scrape (lazy: `done` never pays for a capture-pane).
    static func resolve(hook: HookReport?, registry: AgentStatus?, now: Double,
                        scrape: () -> AgentStatus) -> AgentStatus {
        guard let hook else { return registry ?? scrape() }
        let age = now - hook.at
        if let registry, age > 3 {
            // the registry has no word for "stopped on an error": keep it until work resumes
            return hook.status == .failed && registry != .working ? .blocked : registry
        }
        switch hook.status {
        case .done:
            return .done
        case .failed:
            return .blocked   // stopped on an error: needs you
        case .blocked:
            // answered, but nothing has reported since: the live counter is back on screen
            return age > 3 && scrape() == .working ? .working : .blocked
        case .working:
            let seen = registry ?? scrape()
            if seen == .blocked { return .blocked }
            if seen == .working || age < 10 { return .working }
            return seen   // a quiet screen 10s after the last report means stopped
        }
    }

    // MARK: - Installer (only touches entries and files that are Promote's own)

    // PROMOTE_HOME points the installer at a stand-in home, so tests never touch real config
    static let home = ProcessInfo.processInfo.environment["PROMOTE_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser

    // The repo's /extension folder: inside the app bundle (install.sh copies it), else straight
    // from the checkout this binary was built in (`swift run`, tests).
    static let extensions: URL = {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("extension"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../extension").standardizedFileURL
    }()

    struct Hook { let event: String; let matcher: String?; let async: Bool }

    enum Agent: String, CaseIterable, Identifiable {
        case claude, codex, pi

        var id: String { rawValue }
        var title: String { self == .claude ? "Claude Code" : self == .codex ? "Codex" : "pi" }

        // the agent's own config folder: no folder, no agent to install for
        var configDir: URL { AgentHooks.home.appendingPathComponent(self == .pi ? ".pi" : ".\(rawValue)") }

        // what ships in /extension
        var source: URL {
            switch self {
            case .claude: return AgentHooks.extensions.appendingPathComponent("claudecode/hook")
            case .codex: return AgentHooks.extensions.appendingPathComponent("codex/hook")
            case .pi: return AgentHooks.extensions.appendingPathComponent("pi/promote.ts")
            }
        }

        // where it is installed
        var installed: URL {
            switch self {
            case .claude: return AgentHooks.home.appendingPathComponent(".config/promote/claudecode/hook")
            case .codex: return AgentHooks.home.appendingPathComponent(".config/promote/codex/hook")
            // pi loads every file in this folder
            case .pi: return AgentHooks.home.appendingPathComponent(".pi/agent/extensions/promote.ts")
            }
        }

        // the config file whose "hooks" run the script; pi needs none
        var config: URL? {
            switch self {
            case .claude: return AgentHooks.home.appendingPathComponent(".claude/settings.json")
            case .codex: return AgentHooks.home.appendingPathComponent(".codex/hooks.json")
            case .pi: return nil
            }
        }

        var hooks: [Hook] {
            switch self {
            case .claude:
                // The two that precede a prompt run in line (a late write would overwrite what
                // follows); the script exits in milliseconds and prints nothing, so Claude's
                // own prompt still decides.
                return [
                    Hook(event: "SessionStart", matcher: "startup|resume|clear", async: true),
                    Hook(event: "SessionEnd", matcher: nil, async: true),
                    Hook(event: "UserPromptSubmit", matcher: nil, async: true),
                    Hook(event: "PostToolUse", matcher: "*", async: true),
                    Hook(event: "Stop", matcher: nil, async: true),
                    Hook(event: "StopFailure", matcher: nil, async: true),
                    Hook(event: "PermissionRequest", matcher: "*", async: false),
                    // Bypass-permissions mode sends no PermissionRequest for a question.
                    Hook(event: "PreToolUse", matcher: "AskUserQuestion", async: false),
                ]
            case .codex:
                // Codex runs its hooks in line, and asks you to trust a new hook once.
                return [
                    Hook(event: "SessionStart", matcher: nil, async: false),
                    Hook(event: "UserPromptSubmit", matcher: nil, async: false),
                    Hook(event: "PostToolUse", matcher: "*", async: false),
                    Hook(event: "Stop", matcher: nil, async: false),
                    Hook(event: "PermissionRequest", matcher: "*", async: false),
                    Hook(event: "Interrupt", matcher: nil, async: false),
                ]
            case .pi:
                return []
            }
        }
    }

    // first line of the pi extension, which says the file is Promote's
    static let fileMark = "// Promote: "

    static func isInstalled(_ agent: Agent) -> Bool {
        guard let config = agent.config else {
            return (try? String(contentsOf: agent.installed, encoding: .utf8))?.hasPrefix(fileMark) == true
        }
        guard FileManager.default.isExecutableFile(atPath: agent.installed.path),
              let installed = read(config)?["hooks"] as? [String: Any] else { return false }
        return agent.hooks.allSatisfy { hook in
            (installed[hook.event] as? [[String: Any]] ?? []).contains { isOurs($0, agent) }
        }
    }

    static func install(_ agent: Agent) throws {
        let fm = FileManager.default
        // someone else's file by that name is left alone
        if agent.config == nil, fm.fileExists(atPath: agent.installed.path), !isInstalled(agent) {
            throw NSError(domain: "Promote", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "\(agent.installed.path) is not Promote's"])
        }
        try fm.createDirectory(at: agent.installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = try Data(contentsOf: agent.source)
        if (try? Data(contentsOf: agent.installed)) != body { try body.write(to: agent.installed, options: .atomic) }
        guard let config = agent.config else { return }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.installed.path)
        let path = "'" + agent.installed.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try edit(config) { installed in
            for hook in agent.hooks {
                var handler: [String: Any] = ["type": "command", "command": "\(path) \(hook.event)", "timeout": 5]
                if hook.async { handler["async"] = true }
                var group: [String: Any] = ["hooks": [handler]]
                if let matcher = hook.matcher { group["matcher"] = matcher }
                installed[hook.event] = withoutOurs(installed[hook.event], agent) + [group]
            }
        }
    }

    static func uninstall(_ agent: Agent) throws {
        if let config = agent.config {
            try edit(config) { installed in
                for (event, value) in installed where value is [[String: Any]] {
                    let kept = withoutOurs(value, agent)
                    installed[event] = kept.isEmpty ? nil : kept
                }
            }
        } else if !isInstalled(agent) {
            return
        }
        try? FileManager.default.removeItem(at: agent.installed)
    }

    // launch: an earlier build's install gets this build's script and any new entries
    static func upgrade() {
        for agent in Agent.allCases {
            if let config = agent.config {
                guard let installed = read(config)?["hooks"] as? [String: Any],
                      installed.values.contains(where: { ($0 as? [[String: Any]] ?? []).contains { isOurs($0, agent) } })
                else { continue }
            } else if !isInstalled(agent) {
                continue
            }
            try? install(agent)
        }
    }

    private static func isOurs(_ group: [String: Any], _ agent: Agent) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains {
            ($0["command"] as? String)?.contains(agent.installed.path) == true
        }
    }

    // An event's groups minus Promote's own commands: a command of yours that shares a group
    // with ours stays, and a group left with none goes.
    private static func withoutOurs(_ value: Any?, _ agent: Agent) -> [[String: Any]] {
        (value as? [[String: Any]] ?? []).compactMap { group in
            guard isOurs(group, agent), let handlers = group["hooks"] as? [[String: Any]] else { return group }
            let kept = handlers.filter { ($0["command"] as? String)?.contains(agent.installed.path) != true }
            if kept.isEmpty { return nil }
            var group = group
            group["hooks"] = kept
            return group
        }
    }

    private static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // Reads the config, lets `change` edit its "hooks", writes it back only if they changed
    // (launch runs this through upgrade(): an untouched file must stay byte-identical). A file
    // that is not plain JSON is left alone; the first edit keeps a `<name>.before-promote` backup.
    // ponytail: read-modify-write with no lock; the agent saving its config in the same instant
    // loses that save. Only on a toggle or a real upgrade, so the window is one write.
    private static func edit(_ link: URL, _ change: (inout [String: Any]) -> Void) throws {
        let fm = FileManager.default
        // a config kept in a dotfiles repo is a symlink: write through it, never replace it
        let url = link.resolvingSymlinksInPath()
        var root: [String: Any] = [:]
        if fm.fileExists(atPath: url.path) {
            guard let existing = read(url) else {
                throw NSError(domain: "Promote", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "\(url.path) is not plain JSON"])
            }
            root = existing
            let backup = url.appendingPathExtension("before-promote")
            if !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: url, to: backup) }
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        if let hooks = root["hooks"], !(hooks is [String: Any]) {
            throw NSError(domain: "Promote", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "\"hooks\" in \(url.path) is not an object"])
        }
        let before = root["hooks"] as? [String: Any] ?? [:]
        var installed = before
        change(&installed)
        if NSDictionary(dictionary: before).isEqual(to: installed) { return }
        root["hooks"] = installed.isEmpty ? nil : installed
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
