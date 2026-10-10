import AppKit
import Testing
@testable import Promote

@Suite(.serialized) @MainActor struct SessionDropTests {
    @Test func nativeSessionDropRoutesEdgesAndCleansPreview() async {
        _ = NSApplication.shared
        let view = DroppableTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        let drag = SessionDraggingInfo(window: window)
        defer { drag.draggingPasteboard.releaseGlobally() }
        drag.draggingPasteboard.setData(Data("source".utf8), forType: SessionDrag.pasteboardType)
        view.canDropSession = { $0 == "source" }
        for (point, expected) in [(NSPoint(x: 5, y: 200), SplitDirection.left),
                                  (NSPoint(x: 795, y: 200), .right),
                                  (NSPoint(x: 400, y: 5), .up),
                                  (NSPoint(x: 400, y: 395), .down)] {
            let local = NSPoint(x: point.x, y: view.isFlipped ? point.y : 400 - point.y)
            drag.draggingLocation = view.convert(local, to: nil)
            #expect(view.draggingEntered(drag) == .move)
            #expect(view.subviews.last is SessionDropPreviewView)
            let preview = view.subviews.compactMap { $0 as? SessionDropPreviewView }.first
            #expect(preview?.message == "Split " + expected.title)
            #expect(preview?.hitTest(.zero) == nil)
            var result: SplitDirection?
            view.onDropSession = { name, edge in
                #expect(name == "source")
                result = edge
            }
            #expect(view.performDragOperation(drag))
            // The drop schedules a layout mutation after AppKit's callback returns.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect(result == expected)
            #expect(!view.subviews.contains { $0 is SessionDropPreviewView })
        }
        drag.draggingLocation = view.convert(NSPoint(x: 400, y: 200), to: nil)
        var grouped = false
        view.onDropSession = { _, edge in grouped = edge == nil }
        #expect(view.draggingUpdated(drag) == .move)
        #expect((view.subviews.last as? SessionDropPreviewView)?.message == "Merge as tabs")
        #expect(view.performDragOperation(drag))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(grouped)
        #expect(view.draggingEntered(drag) == .move)
        view.draggingExited(drag)
        #expect(!view.subviews.contains { $0 is SessionDropPreviewView })
        view.canDropSession = { _ in false }
        #expect(view.draggingEntered(drag).isEmpty)
        #expect(!view.performDragOperation(drag))
    }

    @Test func bridgedTabPayloadMergesWithCopyOnlySource() async {
        _ = NSApplication.shared
        let view = DroppableTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        let drag = SessionDraggingInfo(window: window)
        defer { drag.draggingPasteboard.releaseGlobally() }
        drag.draggingSourceOperationMask = .copy
        drag.draggingLocation = view.convert(NSPoint(x: 400, y: 200), to: nil)
        drag.draggingPasteboard.setString(SessionDrag.tabPrefix + "source", forType: .string)
        view.canDropSession = { $0 == "source" }
        var merged = false
        view.onDropSession = { name, edge in merged = name == "source" && edge == nil }
        #expect(view.registeredDraggedTypes.contains(.string))
        #expect(view.draggingEntered(drag) == .copy)
        #expect((view.subviews.last as? SessionDropPreviewView)?.message == "Merge as tabs")
        #expect(view.performDragOperation(drag))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(merged)
        #expect(!view.subviews.contains { $0 is SessionDropPreviewView })

        drag.draggingSourceOperationMask = .link
        #expect(view.draggingUpdated(drag).isEmpty)
        #expect(!view.performDragOperation(drag))
        drag.draggingSourceOperationMask = .copy
        view.canDropSession = { _ in false }
        #expect(view.draggingUpdated(drag).isEmpty)
        #expect(!view.performDragOperation(drag))
        drag.draggingPasteboard.clearContents()
        drag.draggingPasteboard.setString(SessionDrag.tabPrefix, forType: .string)
        #expect(SessionDrag.name(from: drag.draggingPasteboard) == nil)
    }

    @Test func itemProviderLoadsCustomAndBridgedTabPayloads() async {
        let providers = [SessionDrag.provider("source", text: SessionDrag.tabPrefix + "source"),
                         NSItemProvider(object: (SessionDrag.tabPrefix + "source") as NSString)]
        for provider in providers {
            let name = await withCheckedContinuation { continuation in
                SessionDrag.loadName(from: provider) { continuation.resume(returning: $0) }
            }
            #expect(name == "source")
        }
        for text in ["source", SessionDrag.tabPrefix, ""] {
            let provider = NSItemProvider(object: text as NSString)
            let name = await withCheckedContinuation { continuation in
                SessionDrag.loadName(from: provider) { continuation.resume(returning: $0) }
            }
            #expect(name == nil)
        }
    }

    @Test func plainTextIsNotASessionAndFileDropsStillAccepted() {
        _ = NSApplication.shared
        let view = DroppableTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let drag = SessionDraggingInfo(window: nil)
        defer { drag.draggingPasteboard.releaseGlobally() }
        drag.draggingPasteboard.setString("source", forType: .string)
        view.canDropSession = { _ in true }
        #expect(SessionDrag.name(from: drag.draggingPasteboard) == nil)
        #expect(view.draggingEntered(drag).isEmpty)
        #expect(!view.performDragOperation(drag))
        drag.draggingPasteboard.clearContents()
        drag.draggingPasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a file.txt") as NSURL])
        #expect(view.draggingEntered(drag) == .copy)
    }
}

private final class SessionDraggingInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = [.copy, .move]
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(window: NSWindow?) { draggingDestinationWindow = window }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
