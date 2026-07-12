import SwiftUI
import AppKit

private struct ShortcutRow: Identifiable {
    let keys: [String]
    let description: String
    var id: String { keys.joined(separator: "+") + "|" + description }
}

private struct ShortcutSection: Identifiable {
    let title: String
    let subtitle: String?
    let rows: [ShortcutRow]
    var id: String { title }
}

// ⌘, overlay: app shortcuts + common tmux keys
struct CheatSheetView: View {
    let dismiss: () -> Void
    @State private var escMonitor: Any?

    // ponytail: static table; update manually when keybindings change
    private let sections: [ShortcutSection] = [
        ShortcutSection(title: "App", subtitle: nil, rows: [
            ShortcutRow(keys: ["⌘", "N"], description: "New tmux session"),
            ShortcutRow(keys: ["⌘", "\\"], description: "Split pane right"),
            ShortcutRow(keys: ["⌘", "⇧", "\\"], description: "Split pane down"),
            ShortcutRow(keys: ["⌘", "W"], description: "Close current pane"),
            ShortcutRow(keys: ["⌘", "⇧", "R"], description: "Force refresh (reload PR / branch / agent status)"),
            ShortcutRow(keys: ["⌘", "1-9"], description: "Jump to session (sidebar order)"),
            ShortcutRow(keys: ["⌘", "="], description: "Increase font size"),
            ShortcutRow(keys: ["⌘", "−"], description: "Decrease font size"),
            ShortcutRow(keys: ["⌘", "0"], description: "Reset font size"),
            ShortcutRow(keys: ["⌘", "/"], description: "Toggle this cheat sheet"),
        ]),
        ShortcutSection(title: "tmux", subtitle: "After your Prefix", rows: [
            ShortcutRow(keys: ["d"], description: "Detach from session"),
            ShortcutRow(keys: ["c"], description: "New window"),
            ShortcutRow(keys: ["n"], description: "Next window"),
            ShortcutRow(keys: ["p"], description: "Previous window"),
            ShortcutRow(keys: ["0-9"], description: "Jump to window"),
            ShortcutRow(keys: ["%"], description: "Split pane left/right"),
            ShortcutRow(keys: ["\""], description: "Split pane top/bottom"),
            ShortcutRow(keys: ["←", "↑", "↓", "→"], description: "Move between panes"),
            ShortcutRow(keys: ["z"], description: "Zoom / unzoom pane"),
            ShortcutRow(keys: ["x"], description: "Kill pane"),
            ShortcutRow(keys: ["["], description: "Scroll & copy mode (q exits)"),
            ShortcutRow(keys: [","], description: "Rename window"),
            ShortcutRow(keys: ["$"], description: "Rename session"),
        ]),
    ]

    private let sectionColumns = [GridItem(.adaptive(minimum: 260), spacing: 14, alignment: .top)]

    var body: some View {
        ZStack {
            Color.black.opacity(0.36)
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

                LazyVGrid(columns: sectionColumns, alignment: .leading, spacing: 14) {
                    ForEach(sections) { section in
                        sectionCard(section)
                    }
                }

                Text("Press Esc, ⌘, or click outside to close")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(22)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.20), radius: 20, y: 8)
            .frame(maxWidth: 680)
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

    private func sectionCard(_ section: ShortcutSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(section.title)
                    .font(.headline.weight(.semibold))
                if let subtitle = section.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(section.rows) { row in
                    shortcutRow(row)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }

    private func shortcutRow(_ row: ShortcutRow) -> some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 5) {
                ForEach(Array(row.keys.enumerated()), id: \.offset) { _, key in
                    keyCap(key)
                }
            }
            .frame(width: 112, alignment: .leading)

            Text(row.description)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
    }

    private func keyCap(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.7)
            )
    }
}
