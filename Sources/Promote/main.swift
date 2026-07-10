import SwiftUI
import AppKit

// app shell: split layout + refresh loop + keyboard commands
struct RootView: View {
    @ObservedObject var store: SessionStore
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var flagsMonitor: Any?
    @State private var pollTick = 0

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
        .overlay(alignment: .bottom) {
            if store.cmdHeld && !store.showCheatSheet {
                Text("⌘ ,  for Shortcuts")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 14)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            store.refresh()
            DispatchQueue.main.async {
                installTitlebarButtons(store: store)
            }
            // local monitor: terminal NSView owns key focus, SwiftUI modifiers don't fire
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                store.cmdHeld = event.modifierFlags.contains(.command)
                return event
            }
        }
        .onDisappear {
            if let flagsMonitor {
                NSEvent.removeMonitor(flagsMonitor)
                self.flagsMonitor = nil
            }
        }
        .onReceive(timer) { _ in
            // ponytail: background app polls at half rate (4s); skip every other tick
            pollTick += 1
            if NSApp.isActive || pollTick.isMultiple(of: 2) {
                store.refresh()
            }
        }
        .confirmationDialog(
            "Kill session \u{201C}\(store.pendingCloseLastPane ?? "")\u{201D}?",
            isPresented: Binding(
                get: { store.pendingCloseLastPane != nil },
                set: { if !$0 { store.pendingCloseLastPane = nil } }
            )
        ) {
            Button("Kill Session", role: .destructive) {
                if let name = store.pendingCloseLastPane {
                    store.kill(name)
                }
                store.pendingCloseLastPane = nil
            }
            Button("Cancel", role: .cancel) {
                store.pendingCloseLastPane = nil
            }
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
            .id("\(session.name)#\(store.terminalEpoch)")
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
                Button("Increase Font Size") { fontSize += 1 }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Decrease Font Size") { fontSize = max(8, fontSize - 1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Reset Font Size") { fontSize = 13 }
                    .keyboardShortcut("0", modifiers: .command)
            }

            // replace the default Close (⌘W closes the window otherwise)
            CommandGroup(replacing: .saveItem) {
                // no .disabled: SwiftUI menu validation goes stale when the AppKit terminal
                // owns focus, leaving the item stuck disabled. closeActivePane guards instead.
                Button("Close Pane") { store.closeActivePane() }
                    .keyboardShortcut("w", modifiers: .command)
            }

            CommandMenu("Session") {
                Button("Split Pane Right") { store.splitPaneRight() }
                    .keyboardShortcut("\\", modifiers: .command)

                Button("Split Pane Down") { store.splitPaneDown() }
                    .keyboardShortcut("\\", modifiers: [.command, .shift])

                // escape hatch for wedged key handling (stuck kitty keyboard flags in SwiftTerm)
                Button("Reattach Terminal") { store.reattachTerminal() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

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
// ponytail: force dark — terminal is dark-only, light-mode sidebar clashes; theme both if light mode ever matters
NSApp.appearance = NSAppearance(named: .darkAqua)
NSApplication.shared.activate(ignoringOtherApps: true)
PromoteApp.main()
