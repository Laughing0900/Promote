import SwiftUI
import AppKit

// ⌘, overlay: app shortcuts + common tmux keys
struct CheatSheetView: View {
    let dismiss: () -> Void
    @State private var escMonitor: Any?

    // ponytail: static table; update manually when keybindings change
    private let sections: [(String, [(String, String)])] = [
        ("App", [
            ("⌘N", "New tmux session"),
            ("⌘\\", "Split pane right"),
            ("⌘W", "Close current pane"),
            ("⌘1–9", "Jump to session (sidebar order)"),
            ("⌘=", "Increase font size"),
            ("⌘−", "Decrease font size"),
            ("⌘0", "Reset font size"),
            ("⌘,", "Toggle this cheat sheet"),
        ]),
        ("tmux (after your Prefix)", [
            ("d", "Detach from session"),
            ("c", "New window"),
            ("n / p", "Next / previous window"),
            ("0–9", "Jump to window"),
            ("%", "Split pane left/right"),
            ("\"", "Split pane top/bottom"),
            ("← ↑ ↓ →", "Move between panes"),
            ("z", "Zoom / unzoom pane"),
            ("x", "Kill pane"),
            ("[", "Scroll & copy mode (q exits)"),
            (",", "Rename window"),
            ("$", "Rename session"),
        ]),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(.title3.bold())
                    Spacer()
                    Button(action: dismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                ForEach(sections, id: \.0) { title, rows in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.caption.smallCaps().weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(rows, id: \.0) { key, description in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(key)
                                    .font(.system(.body, design: .monospaced).weight(.medium))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .frame(width: 110, alignment: .leading)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                                Text(description)
                            }
                        }
                    }
                }

                Text("Press Esc, ⌘, or click outside to close")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 20)
            .frame(maxWidth: 560)
            .padding(20)
        }
        // Esc closes; local monitor because terminal NSView usually owns key focus.
        .onAppear {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { // Esc
                    dismiss()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let escMonitor {
                NSEvent.removeMonitor(escMonitor)
                self.escMonitor = nil
            }
        }
    }
}
