import SwiftUI
import AppKit

// app shell: split view layout, refresh timer
struct ContentView: View {
    @ObservedObject var store: SessionStore
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    // ponytail: 2s poll, switch to tmux hooks/control-mode if it ever matters
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SidebarView(store: store, sidebarVisibility: $sidebarVisibility)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            Group {
                if let name = store.selected {
                    TerminalPane(session: name)
                        .id(name) // new terminal per session
                } else {
                    Text("Select a tmux session")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(.secondary)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(store.selected ?? "Tmux") // session name in title bar
        }
        .ignoresSafeArea(edges: .bottom) // no bottom margin under panes
        .toolbarBackground(.hidden, for: .windowToolbar) // blend title bar into content
        .onAppear {
            store.refresh()
            DispatchQueue.main.async { installTitlebarButtons(store: store) }
        }
        .onReceive(timer) { _ in store.refresh() }
    }
}

struct TmuxApp: App {
    @StateObject private var store = SessionStore()
    @AppStorage(Settings.fontSizeKey) private var fontSize = 13.0

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 900, minHeight: 560)
        }
        // .windowStyle(.hiddenTitleBar) // no title bar header
        .windowToolbarStyle(.unifiedCompact) // thin title bar, shows session name
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { store.newSession() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("View") {
                Button("Increase Font Size") { fontSize += 1 }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Decrease Font Size") { fontSize = max(8, fontSize - 1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Reset Font Size") { fontSize = 13 }
                    .keyboardShortcut("0", modifiers: .command)
            }
            CommandMenu("Session") {
                // cmd+1..9 jump by sidebar order (groups flattened top to bottom)
                ForEach(1..<10, id: \.self) { i in
                    Button("Session \(i)") {
                        let flat = store.grouped.flatMap { $0.1 }
                        if i <= flat.count { store.selected = flat[i - 1].name }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: .command)
                }
            }
        }
    }
}

// SPM executable: make it a real foreground app
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.activate(ignoringOtherApps: true)
TmuxApp.main()
