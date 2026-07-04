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
            applyOverlayScrollers()
            DispatchQueue.main.async { installTitlebarButtons(store: store) }
        }
        .onReceive(timer) { _ in
            store.refresh()
            applyOverlayScrollers() // re-apply for newly created scroll views
        }
    }
}

struct TmuxApp: App {
    @StateObject private var store = SessionStore()
    @AppStorage("fontSize") private var fontSize = 13.0

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

// titlebar icon button with hover highlight
struct TitlebarIcon: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15))
                .frame(width: 24, height: 24)
                .background(hovering ? Color.primary.opacity(0.1) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .padding(2)
        }
        .buttonStyle(.borderless)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// buttons pinned in title bar next to traffic lights, independent of split-view toolbar sections
struct TitlebarButtons: View {
    let store: SessionStore

    var body: some View {
        HStack(spacing: 2) {
            TitlebarIcon(systemName: "square.and.pencil", help: "New Session") {
                store.newSession()
            }
            TitlebarIcon(systemName: "sidebar.left", help: "Toggle Sidebar") {
                // native action; NavigationSplitView picks it up and syncs its binding
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            }
        }
        .padding(.leading, 4)
    }
}

private var titlebarInstalled = false

func installTitlebarButtons(store: SessionStore) {
    guard !titlebarInstalled, let w = NSApp.windows.first else { return }
    titlebarInstalled = true
    let vc = NSTitlebarAccessoryViewController()
    vc.layoutAttribute = .leading
    vc.view = NSHostingView(rootView: TitlebarButtons(store: store))
    w.addTitlebarAccessoryViewController(vc)
    // legacy scrollers steal layout width; force overlay the moment scrolling starts
    NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { ev in
        applyOverlayScrollers()
        return ev
    }
}

// self-drawn scroller: slim rounded knob, no track
final class SlimScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnob() {
        let r = rect(for: .knob).insetBy(dx: 3, dy: 2)
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.width / 2, yRadius: r.width / 2).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {} // no track
}

// overlay scrollers: absolute position over content, visible only while scrolling
func applyOverlayScrollers() {
    for w in NSApp.windows {
        if let root = w.contentView { styleScrollers(in: root) }
    }
}

private func styleScrollers(in v: NSView) {
    if let sv = v as? NSScrollView {
        // sidebar List (table-backed): replace native scroller with SlimScroller
        if sv.documentView?.className.contains("Table") == true,
           !(sv.verticalScroller is SlimScroller) {
            let s = SlimScroller()
            s.controlSize = .small
            sv.verticalScroller = s
            sv.hasHorizontalScroller = false // sidebar never scrolls sideways
        }
        sv.scrollerStyle = .overlay
        sv.autohidesScrollers = true
    }
    v.subviews.forEach { styleScrollers(in: $0) }
}

// SPM executable: make it a real foreground app
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.activate(ignoringOtherApps: true)
TmuxApp.main()
