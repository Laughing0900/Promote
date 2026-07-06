import Foundation

let TMUX = "/opt/homebrew/bin/tmux"
let GIT = "/usr/bin/git"
let GH = "/opt/homebrew/bin/gh"

struct Shell {
    @discardableResult
    static func run(_ executable: String, _ args: [String], cwd: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        // Finder-launched apps can miss locale env vars; tmux -F parsing relies on UTF-8 output.
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        process.environment = env

        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    static func tmux(_ args: String...) -> String? {
        run(TMUX, args)
    }

    static func tmux(_ args: [String]) -> String? {
        run(TMUX, args)
    }
}
