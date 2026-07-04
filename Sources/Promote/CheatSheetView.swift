import SwiftUI
import AppKit

// ⌘, overlay: app shortcuts + common tmux keys, centered card; click, Esc, or X to dismiss
struct CheatSheetView: View {
    let dismiss: () -> Void
    @State private var escMonitor: Any?

    // ponytail: static list, update by hand when shortcuts change
    private let sections: [(String, [(String, String)])] = [
        ("App", [
            ("⌘N", "New tmux session"),
            ("⌘1–9", "Jump to session (sidebar order)"),
            ("⌘=", "Increase font size"),
            ("⌘−", "Decrease font size"),
            ("⌘0", "Reset font size"),
            ("⌘,", "Toggle this cheat sheet"),
        ]),
        ("tmux — press `Prefix` first, then", [
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
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
            VStack(alignment: .leading, spacing: 14) {
                Text("Keyboard Shortcuts")
                    .font(.title3.bold())
                ForEach(sections, id: \.0) { title, keys in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.caption.smallCaps())
                            .foregroundStyle(.secondary)
                        ForEach(keys, id: \.0) { key, desc in
                            HStack {
                                Text(key)
                                    .font(.system(.body, design: .monospaced))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                                    .frame(width: 90, alignment: .leading)
                                Text(desc)
                            }
                        }
                    }
                }
                Text("Esc, ⌘, or click anywhere to close")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 20)
            .overlay(alignment: .topTrailing) {
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(8)
            }
        }
        // Esc closes; local monitor because the terminal NSView usually owns key focus
        .onAppear {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { dismiss(); return nil } // 53 = Esc
                return event
            }
        }
        .onDisappear {
            if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        }
    }
}
