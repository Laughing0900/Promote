import AppKit

// Thin bridge from NSColorPanel callbacks to Swift closures.
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()

    private var onPick: ((NSColor) -> Void)?

    func open(_ onPick: @escaping (NSColor) -> Void) {
        self.onPick = onPick

        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.isContinuous = true
        panel.orderFrontRegardless()
        panel.makeKey()

        // drop the callback when the panel closes so a later reopen can't
        // recolor the previous session
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: panel
        )
    }

    @objc
    private func panelWillClose(_ note: Notification) {
        onPick = nil
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.willCloseNotification, object: note.object
        )
    }

    @objc
    private func colorChanged(_ sender: NSColorPanel) {
        onPick?(sender.color)
    }
}
