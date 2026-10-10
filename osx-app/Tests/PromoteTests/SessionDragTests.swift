import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Promote

@Suite struct SessionDragTests {
    private func load(_ provider: NSItemProvider, plainText: Bool = false) async -> String? {
        await withCheckedContinuation { continuation in
            SessionDrag.loadName(from: provider, plainText: plainText) { continuation.resume(returning: $0) }
        }
    }

    // SwiftUI resolves onDrop identifiers through UTType; an undeclared id matches nothing.
    @Test func sessionTypeIsDeclared() {
        #expect(SessionDrag.utType.isDeclared)
        #expect(SessionDrag.utType.identifier == SessionDrag.type)
        #expect(SessionDrag.acceptedTypes.first == SessionDrag.utType)
    }

    @Test func customPayloadWinsOverText() async {
        #expect(await load(SessionDrag.provider("api", text: "api")) == "api")
        #expect(await load(SessionDrag.provider("api", text: SessionDrag.tabPrefix + "api")) == "api")
    }

    @Test func textFallbackNeedsTabPrefixUnlessPlainTextAllowed() async {
        let tab = NSItemProvider(object: (SessionDrag.tabPrefix + "api") as NSString)
        #expect(await load(tab) == "api")
        #expect(await load(tab, plainText: true) == "api")
        let sidebar = NSItemProvider(object: "api" as NSString)
        #expect(await load(sidebar) == nil)
        #expect(await load(sidebar, plainText: true) == "api")
        #expect(await load(NSItemProvider(object: "" as NSString), plainText: true) == nil)
        #expect(await load(NSItemProvider(object: "ls\n" as NSString), plainText: true) == nil)
    }
}
