import Foundation

let TMUX = "/opt/homebrew/bin/tmux"
let GIT = "/usr/bin/git"
let GH = "/opt/homebrew/bin/gh"

@discardableResult
func run(_ exe: String, _ args: [String], cwd: String? = nil) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    // Finder-launched apps have no LANG; in C locale tmux sanitizes the \t
    // separator in -F output to "_", breaking session parsing
    var env = ProcessInfo.processInfo.environment
    env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
    p.environment = env
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

@discardableResult
func tmux(_ args: String...) -> String? { run(TMUX, args) }
