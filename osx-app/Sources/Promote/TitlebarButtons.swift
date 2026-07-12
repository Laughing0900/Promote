import SwiftUI
import AppKit

private struct TitlebarIcon: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 25, height: 25)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering ? Color.primary.opacity(0.1) : .clear)
                )
        }
        .buttonStyle(.borderless)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct TitlebarButtons: View {
    let store: SessionStore

    var body: some View {
        HStack(spacing: 2) {
            TitlebarIcon(systemName: "plus", help: "New Session") {
                store.newSession()
            }
            TitlebarIcon(systemName: "arrow.clockwise", help: "Refresh") {
                store.forceRefresh()
            }
            TitlebarIcon(systemName: "sidebar.left", help: "Toggle Sidebar") {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            }
        }
        .padding(.leading, 4)
    }
}

private var titlebarInstalled = false

func installTitlebarButtons(store: SessionStore) {
    guard !titlebarInstalled else { return }

    // window might not be ready at first onAppear frame; retry quickly.
    guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && !($0 is NSPanel) }) else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            installTitlebarButtons(store: store)
        }
        return
    }

    titlebarInstalled = true

    let accessory = NSTitlebarAccessoryViewController()
    accessory.layoutAttribute = .leading

    let host = NSHostingView(rootView: TitlebarButtons(store: store))
    host.setFrameSize(host.fittingSize)
    accessory.view = host

    window.addTitlebarAccessoryViewController(accessory)
}
