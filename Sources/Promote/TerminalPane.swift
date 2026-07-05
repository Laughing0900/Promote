import SwiftUI
import SwiftTerm

// SwiftTerm wrapper that attaches to one tmux session
struct TerminalPane: NSViewRepresentable {
    let session: String
    @AppStorage(Settings.fontSizeKey) private var fontSize = 13.0

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: .zero)
        term.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)

        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("LANG=en_US.UTF-8")

        // "=name" forces exact session match in tmux target lookup
        term.startProcess(
            executable: TMUX,
            args: ["attach-session", "-t", "=" + session],
            environment: env
        )

        context.coordinator.sessionName = session
        return term
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        let currentSize = view.font.pointSize
        if abs(currentSize - fontSize) > 0.001 {
            view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }

        // If SwiftUI reuses a view unexpectedly, make sure target session is fresh.
        if context.coordinator.sessionName != session {
            context.coordinator.sessionName = session

            var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
            env.append("LANG=en_US.UTF-8")
            view.startProcess(
                executable: TMUX,
                args: ["attach-session", "-t", "=" + session],
                environment: env
            )
        }
    }

    final class Coordinator {
        var sessionName: String?
    }
}
