import SwiftUI
import AppKit

// app shell: split layout + refresh loop + keyboard commands
struct RootView: View {
    @ObservedObject var store: SessionStore
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    // ponytail: poll tmux every 2s; move to hooks/control-mode only if needed
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            DetailPane(store: store)
                .navigationTitle(store.selected ?? "Promote")
        }
        .ignoresSafeArea(edges: .bottom)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .overlay {
            if store.showCheatSheet {
                CheatSheetView { store.showCheatSheet = false }
                    .transition(.opacity)
            }
        }
        .onAppear {
            store.refresh()
            DispatchQueue.main.async {
                installTitlebarButtons(store: store)
            }
        }
        .onReceive(timer) { _ in
            store.refresh()
        }
    }
}

private struct DetailPane: View {
    @ObservedObject var store: SessionStore

    private var selectedSession: Session? {
        guard let name = store.selected else { return nil }
        return store.sessions.first { $0.name == name }
    }

    var body: some View {
        Group {
            if let session = selectedSession {
                activeSessionView(session)
            } else {
                EmptyDetailState(newSession: store.newSession)
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    @ViewBuilder
    private func activeSessionView(_ session: Session) -> some View {
        TerminalPane(session: session.name)
            .id(session.name)
    }
}

private struct EmptyDetailState: View {
    let newSession: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("No session selected")
                .font(.title3.bold())
            Text("Create a tmux session or pick one from the sidebar.")
                .foregroundStyle(.secondary)
            Button("New Session", action: newSession)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct PromoteApp: App {
    @StateObject private var store = SessionStore()
    @AppStorage(Settings.fontSizeKey) private var fontSize = 13.0

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { store.newSession() }
                    .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Keyboard Shortcuts") {
                    store.showCheatSheet.toggle()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandMenu("View") {
                Button("Refresh Sessions") { store.refresh() }
                    .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button("Increase Font Size") { fontSize += 1 }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Decrease Font Size") { fontSize = max(8, fontSize - 1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Reset Font Size") { fontSize = 13 }
                    .keyboardShortcut("0", modifiers: .command)
            }

            CommandMenu("Session") {
                ForEach(1..<10, id: \.self) { index in
                    Button("Jump to Session \(index)") {
                        store.jumpToHotkeyIndex(index)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(index)")),
                        modifiers: .command
                    )
                }
            }
        }
    }
}

// SPM executable: promote to foreground GUI app
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.activate(ignoringOtherApps: true)
PromoteApp.main()
