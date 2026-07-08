import SwiftUI
import SwiftTerm

// SwiftTerm's default requestOpenLink does URL(string:) + open, which fails with
// Finder error -50 on bare file paths. LocalProcessTerminalView is its own
// terminalDelegate and satisfies requestOpenLink via a protocol-extension default,
// so a subclass override never dispatches — wrap the delegate instead: forward the
// five required methods back to the view, intercept only link opens.
final class TerminalLinkRouter: TerminalViewDelegate {
    weak var term: LocalProcessTerminalView?
    var session: String?

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if link.contains("://"), let url = URL(string: link) {
            NSWorkspace.shared.open(url)
            return
        }
        var path = (link as NSString).expandingTildeInPath
        if !path.hasPrefix("/"), let session,
           // ponytail: resolves against the session's *active* pane cwd; wrong if the
           // click lands in a non-active split whose shell sits elsewhere
           let cwd = Shell.run(TMUX, ["display-message", "-p", "-t", "=" + session, "#{pane_current_path}"])?
               .trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            path = cwd + "/" + path
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { term?.sizeChanged(source: source, newCols: newCols, newRows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) { term?.setTerminalTitle(source: source, title: title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { term?.hostCurrentDirectoryUpdate(source: source, directory: directory) }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { term?.send(source: source, data: data) }
    func scrolled(source: TerminalView, position: Double) { term?.scrolled(source: source, position: position) }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { term?.rangeChanged(source: source, startY: startY, endY: endY) }
}

// SwiftTerm has no drop support; register for file drops and paste shell-escaped paths
final class DroppableTerminalView: LocalProcessTerminalView {
    let linkRouter = TerminalLinkRouter()

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        linkRouter.term = self
        terminalDelegate = linkRouter
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        let text = urls.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "' " }.joined()
        send(txt: text)
        return true
    }
}

// SwiftTerm wrapper that attaches to one tmux session
struct TerminalPane: NSViewRepresentable {
    let session: String
    @AppStorage(Settings.fontSizeKey) private var fontSize = 13.0

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> DroppableTerminalView {
        let term = DroppableTerminalView(frame: .zero)
        term.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // debug builds print "Info: Unhandled DECSET ..." for escape codes
        // SwiftTerm doesn't know (2031 color-scheme, 7727 app-escape); silence
        term.getTerminal().silentLog = true

        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("LANG=en_US.UTF-8")

        // "=name" forces exact session match in tmux target lookup
        term.startProcess(
            executable: TMUX,
            args: ["attach-session", "-t", "=" + session],
            environment: env
        )

        term.linkRouter.session = session
        context.coordinator.sessionName = session
        return term
    }

    func updateNSView(_ view: DroppableTerminalView, context: Context) {
        let currentSize = view.font.pointSize
        if abs(currentSize - fontSize) > 0.001 {
            view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }

        // If SwiftUI reuses a view unexpectedly, make sure target session is fresh.
        if context.coordinator.sessionName != session {
            context.coordinator.sessionName = session
            view.linkRouter.session = session

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
