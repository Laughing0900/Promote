import SwiftUI
import AppKit

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
    guard !titlebarInstalled else { return }
    // window may not be registered yet on the onAppear tick; retry until it is.
    // match the titled main window, not panels (e.g. NSColorPanel).
    guard let w = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && !($0 is NSPanel) }) else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { installTitlebarButtons(store: store) }
        return
    }
    titlebarInstalled = true
    let vc = NSTitlebarAccessoryViewController()
    vc.layoutAttribute = .leading
    let host = NSHostingView(rootView: TitlebarButtons(store: store))
    host.setFrameSize(host.fittingSize) // zero frame = invisible accessory
    vc.view = host
    w.addTitlebarAccessoryViewController(vc)
}
