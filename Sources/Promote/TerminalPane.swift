import SwiftUI
import SwiftTerm

// embeds a SwiftTerm terminal attached to one tmux session
struct TerminalPane: NSViewRepresentable {
    let session: String
    @AppStorage("fontSize") private var fontSize = 13.0

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: .zero)
        term.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("LANG=en_US.UTF-8")
        // "=name" forces exact-match attach
        term.startProcess(executable: TMUX,
                          args: ["attach-session", "-t", "=" + session],
                          environment: env)
        return term
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        if view.font.pointSize != fontSize {
            view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }
}
