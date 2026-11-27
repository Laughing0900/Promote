import Foundation
import Testing
@testable import Promote

// serialized: the installer tests share one stand-in home
@Suite(.serialized) struct AgentHooksTests {
    private func resolve(_ raw: String?, age: Double = 0, registry: AgentStatus? = nil,
                         scrape: AgentStatus = .idle) -> AgentStatus {
        let hook = raw.map { HookReport(status: HookStatus(rawValue: $0)!, at: 1000 - age) }
        return AgentHooks.resolve(hook: hook, registry: registry, now: 1000) { scrape }
    }

    @Test func parsesPaneOption() {
        #expect(HookReport.parse("claude working 1700000000", tool: "claude") == HookReport(status: .working, at: 1_700_000_000))
        // left behind by another agent that ran in this pane
        #expect(HookReport.parse("pi done 1700000000", tool: "opencode") == nil)
        #expect(HookReport.parse("", tool: "claude") == nil)
        #expect(HookReport.parse("claude napping 1700000000", tool: "claude") == nil)
        #expect(HookReport.parse("claude done", tool: "claude") == nil)
    }

    @Test func noHookFallsBackToRegistryThenScrape() {
        #expect(resolve(nil, registry: .blocked, scrape: .idle) == .blocked)
        #expect(resolve(nil, scrape: .working) == .working)
    }

    @Test func stopHookIsDoneWithoutScraping() {
        var scraped = false
        let status = AgentHooks.resolve(hook: HookReport(status: .done, at: 0), registry: nil, now: 1000) {
            scraped = true
            return .working
        }
        #expect(status == .done)
        #expect(!scraped)
    }

    @Test func failureNeedsYou() {
        #expect(resolve("failed", scrape: .idle) == .blocked)
        // the registry has no word for it: stays until work resumes
        #expect(resolve("failed", age: 60, registry: .done) == .blocked)
        #expect(resolve("failed", age: 60, registry: .working) == .working)
    }

    @Test func permissionRequestStaysBlockedWhateverTheScreenMisses() {
        #expect(resolve("blocked", age: 600, scrape: .done) == .blocked)
        #expect(resolve("blocked", age: 600, scrape: .idle) == .blocked)
        // just asked: a stale cached "working" verdict must not hide it
        #expect(resolve("blocked", age: 1, scrape: .working) == .blocked)
        // answered with no hook since (denied, or a subagent's tool): the live counter is back
        #expect(resolve("blocked", age: 5, scrape: .working) == .working)
    }

    @Test func workingHoldsWhileFreshOrConfirmed() {
        #expect(resolve("working", age: 2, scrape: .done) == .working)
        #expect(resolve("working", age: 300, scrape: .working) == .working)
        #expect(resolve("working", age: 2, scrape: .blocked) == .blocked)
        // Esc sends no hook: a quiet screen after the grace period means the turn stopped
        #expect(resolve("working", age: 30, scrape: .done) == .done)
    }

    @Test func registrySettlesWhatHooksCannotSee() {
        // fresh report wins: an async hook can land just after the registry flips
        #expect(resolve("done", age: 1, registry: .working) == .done)
        // background work woke a finished turn: no UserPromptSubmit
        #expect(resolve("done", age: 5, registry: .working) == .working)
        // prompt denied, turn over: no hook
        #expect(resolve("blocked", age: 5, registry: .done) == .done)
        // Esc: no hook
        #expect(resolve("working", age: 5, registry: .done) == .done)
        // a prompt the hooks did not report
        #expect(resolve("working", age: 1, registry: .blocked) == .blocked)
    }

    @Test func registryRecordParses() {
        func entry(_ json: String) -> ClaudeRegistry.Entry? { ClaudeRegistry.parse(Data(json.utf8)) }
        #expect(entry(#"{"pid":42,"status":"busy","tmux":"7:@7.%16","updatedAt":5}"#)
                == ClaudeRegistry.Entry(pane: "%16", pid: 42, status: .working, at: 5))
        #expect(entry(#"{"pid":42,"status":"waiting","waitingFor":"dialog open","tmux":"7:@7.%16"}"#)?.status == .blocked)
        #expect(entry(#"{"pid":42,"status":"idle","tmux":"7:@7.%16"}"#)?.status == .idle)
        // not in tmux, an older Claude that writes no status, a status this build does not know
        #expect(entry(#"{"pid":42,"status":"busy"}"#) == nil)
        #expect(entry(#"{"pid":42,"tmux":"7:@7.%16"}"#) == nil)
        #expect(entry(#"{"pid":42,"status":"dreaming","tmux":"7:@7.%16"}"#) == nil)
    }

    @Test func registrySkipsDeadSessionsAndKeepsNewestPerPane() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("promote-registry-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, _ json: String) throws {
            try json.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let me = getpid()
        try write("a.json", #"{"pid":\#(me),"status":"idle","tmux":"1:@1.%1","updatedAt":1}"#)
        try write("b.json", #"{"pid":\#(me),"status":"busy","tmux":"1:@1.%1","updatedAt":2}"#)
        try write("dead.json", #"{"pid":2147483646,"status":"waiting","tmux":"1:@1.%2","updatedAt":9}"#)
        try write("junk.json", "not json")
        #expect(ClaudeRegistry.statuses(in: dir) == ["%1": .working])
    }

    // drives the real scripts from /extension against a throwaway pane of the running tmux server
    @Test func hookScriptsWritePaneOption() throws {
        guard FileManager.default.isExecutableFile(atPath: TMUX),
              let pane = Shell.tmux("new-session", "-d", "-P", "-F", "#{pane_id}", "-s", "promote-hook-test-\(getpid())") else { return }
        defer { Shell.tmux("kill-session", "-t", "=promote-hook-test-\(getpid())") }

        func fire(_ agent: AgentHooks.Agent, _ event: String, stdin: String = "{}") -> HookStatus? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [agent.source.path, event]
            var env = ProcessInfo.processInfo.environment
            env["TMUX_PANE"] = pane
            env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin"
            env["TMUX"] = nil   // outside tmux here: the default socket reaches the same server
            process.environment = env
            let input = Pipe()
            process.standardInput = input
            try? process.run()
            input.fileHandleForWriting.write(Data(stdin.utf8))
            input.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            let raw = Shell.tmux("display-message", "-p", "-t", pane, "#{@promote-status}") ?? ""
            return HookReport.parse(raw, tool: agent.rawValue)?.status
        }

        #expect(fire(.claude, "UserPromptSubmit") == .working)
        #expect(fire(.claude, "PermissionRequest") == .blocked)
        // a subagent's tool call does not settle the session's own request
        #expect(fire(.claude, "PostToolUse", stdin: #"{"agent_id":"a1","tool_name":"Bash"}"#) == .blocked)
        #expect(fire(.claude, "PostToolUse", stdin: #"{"tool_name":"Bash"}"#) == .working)
        #expect(fire(.claude, "PreToolUse") == .blocked)
        #expect(fire(.claude, "Stop") == .done)
        #expect(fire(.claude, "StopFailure") == .failed)
        #expect(fire(.claude, "SessionStart") == nil)

        #expect(fire(.codex, "UserPromptSubmit") == .working)
        #expect(fire(.codex, "PermissionRequest") == .blocked)
        #expect(fire(.codex, "PostToolUse") == .working)
        #expect(fire(.codex, "Stop") == .done)
        #expect(fire(.codex, "UserPromptSubmit") == .working)
        #expect(fire(.codex, "Interrupt") == .done)
        // a claude pane never reads codex's report
        #expect(HookReport.parse(Shell.tmux("display-message", "-p", "-t", pane, "#{@promote-status}") ?? "", tool: "claude") == nil)
        #expect(fire(.codex, "SessionStart") == nil)
    }

    @Test func everyExtensionShips() {
        for agent in AgentHooks.Agent.allCases {
            #expect(FileManager.default.fileExists(atPath: agent.source.path))
        }
        #expect((try? String(contentsOf: AgentHooks.Agent.pi.source, encoding: .utf8))?.hasPrefix(AgentHooks.fileMark) == true)
    }

    // only against a stand-in home: PROMOTE_HOME=$(mktemp -d) swift test
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROMOTE_HOME"] != nil))
    func installKeepsOtherHooksAndUninstallRemovesOnlyOurs() throws {
        let fm = FileManager.default
        for agent in [AgentHooks.Agent.claude, .codex] {
            let url = agent.config!
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let theirs = #"{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/true"}]}]}}"#
            try theirs.write(to: url, atomically: true, encoding: .utf8)

            #expect(!AgentHooks.isInstalled(agent))
            try AgentHooks.install(agent)
            try AgentHooks.install(agent)   // twice: no duplicate entries
            #expect(AgentHooks.isInstalled(agent))
            #expect(fm.isExecutableFile(atPath: agent.installed.path))
            var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            #expect(((root["hooks"] as! [String: Any])["Stop"] as! [Any]).count == 2)
            #expect(try String(contentsOf: url.appendingPathExtension("before-promote"), encoding: .utf8) == theirs)

            try AgentHooks.uninstall(agent)
            #expect(!AgentHooks.isInstalled(agent))
            root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            #expect(root["model"] as? String == "x")
            #expect((root["hooks"] as! [String: Any]).keys.sorted() == ["Stop"])
            #expect(!fm.fileExists(atPath: agent.installed.path))
        }
        // one agent's install never claims another's entries
        try AgentHooks.install(.claude)
        #expect(!AgentHooks.isInstalled(.codex))
        try AgentHooks.uninstall(.claude)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROMOTE_HOME"] != nil))
    func installLeavesYourConfigAsItFoundIt() throws {
        let fm = FileManager.default, agent = AgentHooks.Agent.claude, link = agent.config!
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        // settings.json kept in a dotfiles repo: a symlink
        let real = AgentHooks.home.appendingPathComponent("dotfiles-settings.json")
        try? fm.removeItem(at: link)
        try #"{"hooks":["oops"]}"#.write(to: real, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        // "hooks" of a shape Promote does not know is refused, not replaced
        #expect(throws: (any Error).self) { try AgentHooks.install(agent) }

        try "{}".write(to: real, atomically: true, encoding: .utf8)
        try AgentHooks.install(agent)
        #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil)
        #expect(AgentHooks.isInstalled(agent))

        // a command of yours sharing a group with Promote's survives a reinstall and an uninstall
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: real)) as! [String: Any]
        var hooks = root["hooks"] as! [String: Any]
        var group = (hooks["Stop"] as! [[String: Any]])[0]
        group["hooks"] = (group["hooks"] as! [[String: Any]]) + [["type": "command", "command": "/bin/true"]]
        hooks["Stop"] = [group]
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root).write(to: real)
        try AgentHooks.install(agent)

        // launch (upgrade) with nothing to change leaves the file byte-identical
        let settled = try Data(contentsOf: real)
        AgentHooks.upgrade()
        #expect(try Data(contentsOf: real) == settled)

        try AgentHooks.uninstall(agent)
        root = try JSONSerialization.jsonObject(with: Data(contentsOf: real)) as! [String: Any]
        let left = (root["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        #expect((left[0]["hooks"] as! [[String: Any]]).map { $0["command"] as! String } == ["/bin/true"])
        try fm.removeItem(at: link)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROMOTE_HOME"] != nil))
    func piExtensionIsAFileOfOurOwn() throws {
        let fm = FileManager.default, file = AgentHooks.Agent.pi.installed
        try? fm.removeItem(at: file)
        try AgentHooks.install(.pi)
        #expect(AgentHooks.isInstalled(.pi))
        try AgentHooks.uninstall(.pi)
        #expect(!fm.fileExists(atPath: file.path))

        // someone else's file by that name is neither overwritten nor removed
        try "export default () => {}".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try AgentHooks.install(.pi) }
        try AgentHooks.uninstall(.pi)
        #expect(fm.fileExists(atPath: file.path))
    }
}
