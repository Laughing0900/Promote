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
    }

    @objc
    private func colorChanged(_ sender: NSColorPanel) {
        onPick?(sender.color)
    }
}
