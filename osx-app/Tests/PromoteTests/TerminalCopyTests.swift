import AppKit
import SwiftTerm
import Testing
@testable import Promote

@Suite(.serialized) @MainActor struct TerminalCopyTests {
    private func terminal() -> (DroppableTerminalView, NSWindow, MouseRecorder) {
        _ = NSApplication.shared
        let view = DroppableTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
        let recorder = MouseRecorder()
        view.terminalDelegate = recorder
        view.feed(text: "hello world\u{1b}[?1002h\u{1b}[?1006h")
        return (view, window, recorder)
    }

    private func mouse(_ type: NSEvent.EventType, in window: NSWindow,
                       x: CGFloat = 5, modifiers: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 395), modifierFlags: modifiers,
                           timestamp: 0, windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    @Test func localSelectionCopiesAndSurvivesOutput() throws {
        let (view, window, recorder) = terminal()
        defer { window.close() }
        view.mouseDown(with: mouse(.leftMouseDown, in: window, clicks: 2))
        view.mouseUp(with: mouse(.leftMouseUp, in: window, clicks: 2))
        #expect(view.getSelection() == "hello")
        #expect(recorder.bytes.isEmpty)
        view.feed(text: "\r\nnew output")
        #expect(view.getSelection() == "hello")

        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                               characters: "c", charactersIgnoringModifiers: "c",
                                               isARepeat: false, keyCode: 8))
        let clipboard = NSPasteboard.general
        let saved = clipboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            clipboard.clearContents()
            let items = saved.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            clipboard.writeObjects(items)
        }
        #expect(view.performKeyEquivalent(with: key))
        #expect(clipboard.string(forType: .string) == "hello")
        #expect(view.selectionActive)
        view.selectNone()
        #expect(view.performKeyEquivalent(with: key))
        #expect(clipboard.string(forType: .string) == "hello")
        #expect(recorder.bytes.isEmpty)
    }

    @Test func dragStaysLocalAndOptionGestureReachesTmux() {
        let (view, window, recorder) = terminal()
        defer { window.close() }
        view.mouseDown(with: mouse(.leftMouseDown, in: window))
        view.mouseDragged(with: mouse(.leftMouseDragged, in: window, x: 15))
        view.mouseDragged(with: mouse(.leftMouseDragged, in: window, x: 70, modifiers: .option))
        view.mouseUp(with: mouse(.leftMouseUp, in: window, x: 70, modifiers: .option))
        #expect(view.selectionActive)
        #expect(view.getSelection()?.hasPrefix("hello") == true)
        #expect(recorder.bytes.isEmpty)
        #expect(!view.allowMouseReporting)

        view.selectNone()
        view.mouseDown(with: mouse(.leftMouseDown, in: window, modifiers: .option))
        view.mouseDragged(with: mouse(.leftMouseDragged, in: window, x: 70))
        view.mouseUp(with: mouse(.leftMouseUp, in: window, x: 70))
        #expect(!view.selectionActive)
        #expect(!recorder.bytes.isEmpty)
        #expect(!view.allowMouseReporting)
    }
}

private final class MouseRecorder: TerminalViewDelegate {
    var bytes: [UInt8] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
