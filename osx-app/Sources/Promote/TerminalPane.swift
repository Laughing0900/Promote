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
        // .hover fires on mouseUp, which is also how a drag-selection ends —
        // releasing a selection over a link would otherwise open it.
        if source.selectionActive { return }
        if link.contains("://"), let url = URL(string: link) {
            NSWorkspace.shared.open(url)
            return
        }
        var path = (link as NSString).expandingTildeInPath
        if !path.hasPrefix("/"), let session,
           // ponytail: resolves against the session's *active* pane cwd; wrong if the
           // click lands in a non-active split whose shell sits elsewhere
           // trailing ":" is required — display-message with a bare "=name" target
           // silently resolves to no pane and prints nothing (tmux 3.6)
           let cwd = Shell.run(TMUX, ["display-message", "-p", "-t", "=" + session + ":", "#{pane_current_path}"])?
               .trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            path = cwd + "/" + path
        }
        // SwiftTerm's implicit path regex keeps sentence punctuation ("spec.md." at end
        // of a sentence) — URLs have a no-trailing-punctuation guard, bare paths don't.
        // Strip trailing punctuation until the file actually exists.
        while !FileManager.default.fileExists(atPath: path),
              let last = path.last, ".,;:)]".contains(last) {
            path.removeLast()
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

// SwiftTerm has no drop support; files and folders paste shell-escaped paths.
// Opening a folder as a session is the sidebar's job.
final class DroppableTerminalView: LocalProcessTerminalView {
    let linkRouter = TerminalLinkRouter()
    private var scrollMonitor: Any?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // SwiftTerm installs an NSScroller in super.init. Hiding it also makes
        // SwiftTerm use the full view width for terminal columns.
        subviews.compactMap { $0 as? NSScroller }.forEach { $0.isHidden = true }
        registerForDraggedTypes([.fileURL])
        // Keep highlighting local even when tmux enables terminal mouse reporting.
        // This also preserves the selection when new terminal output arrives.
        allowMouseReporting = false
        // ⌘-click opens links; underline shows only while ⌘ is held.
        linkHighlightMode = .hoverWithModifier
        linkRouter.term = self
        terminalDelegate = linkRouter
        // SwiftTerm's scrollWheel is public but not open, so route wheel events
        // through a scoped monitor to preserve tmux scrollback with local selection.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            let previous = self.allowMouseReporting
            self.allowMouseReporting = true
            defer { self.allowMouseReporting = previous }
            self.scrollWheel(with: event)
            return nil
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    var onFocus: (() -> Void)?

    // becomeFirstResponder is public-not-open in SwiftTerm; a click is the only way focus
    // lands here that doesn't already go through store.selected (sidebar, ⌘1–9, tab keys)
    private var forwardsMouseGesture = false
    private var selectionMouseDown: NSEvent?

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        window?.makeFirstResponder(self)
        // Latch at mouse-down so changing modifiers mid-drag cannot send an
        // unmatched mouse-up to tmux or turn a local selection into copy-mode.
        forwardsMouseGesture = event.modifierFlags.contains(.option)
        allowMouseReporting = forwardsMouseGesture
        super.mouseDown(with: event)
        selectionMouseDown = forwardsMouseGesture || selectionActive ? nil : event
    }

    override func mouseDragged(with event: NSEvent) {
        allowMouseReporting = forwardsMouseGesture
        if !forwardsMouseGesture, let start = selectionMouseDown {
            // SwiftTerm otherwise anchors at the first drag event, skipping the
            // characters between the initial press and the first mouse movement.
            super.mouseDragged(with: start)
            selectionMouseDown = nil
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        allowMouseReporting = forwardsMouseGesture
        defer {
            forwardsMouseGesture = false
            selectionMouseDown = nil
            allowMouseReporting = false
        }
        super.mouseUp(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard window?.firstResponder === self,
              modifiers == .command,
              event.charactersIgnoringModifiers?.lowercased() == "c" else {
            return super.performKeyEquivalent(with: event)
        }
        // Handle before SwiftTerm.keyDown clears the highlight, including when
        // a terminal app enables enhanced keyboard reporting.
        copy(self)
        return true
    }

    override func copy(_ sender: Any) {
        guard selectionActive else { return }
        super.copy(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        let text = urls.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "' " }.joined()
        send(txt: text)
        return true
    }
}

// SwiftTerm wrapper that attaches to one tmux session
struct TerminalPane: NSViewRepresentable {
    let session: String
    // grid leaf: take key focus when this becomes the selected session; report clicks back
    var isFocused = false
    var onFocus: (() -> Void)? = nil
    @AppStorage(Settings.fontSizeKey) private var fontSize = 13.0

    final class Coordinator { var wasFocused = false }
    func makeCoordinator() -> Coordinator { Coordinator() }

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
        term.onFocus = onFocus
        context.coordinator.wasFocused = isFocused
        if isFocused {
            DispatchQueue.main.async { term.window?.makeFirstResponder(term) }
        }
        return term
    }

    // SwiftTerm's LocalProcess.deinit closes the pty but deliberately never signals the
    // child, and terminate() cancels the exit monitor before anything waitpid()s it. Without
    // both here, every session switch/close leaks a live `tmux attach-session` client plus a
    // zombie — they pile up until tmux size negotiation blanks the pane and the app wedges.
    static func dismantleNSView(_ view: DroppableTerminalView, coordinator: Coordinator) {
        let pid = view.process.shellPid
        view.terminate()
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }

    func updateNSView(_ view: DroppableTerminalView, context: Context) {
        let currentSize = view.font.pointSize
        if abs(currentSize - fontSize) > 0.001 {
            view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        view.onFocus = onFocus
        // only on false→true: updateNSView runs every refresh, and grabbing focus each time
        // would steal it from the sidebar (rename field) every 2s
        if isFocused && !context.coordinator.wasFocused, let window = view.window, window.firstResponder !== view {
            DispatchQueue.main.async { window.makeFirstResponder(view) }
        }
        context.coordinator.wasFocused = isFocused
    }
}
