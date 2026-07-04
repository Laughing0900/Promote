import AppKit

// bridges NSColorPanel (default macOS color picker) to a callback
class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    var onPick: ((NSColor) -> Void)?

    func open(_ handler: @escaping (NSColor) -> Void) {
        onPick = handler
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.isContinuous = true
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func changed(_ sender: NSColorPanel) {
        onPick?(sender.color)
    }
}
