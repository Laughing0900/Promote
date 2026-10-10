import AppKit
import UniformTypeIdentifiers

// A private type separates session moves from terminal text/file drops and sidebar dividers.
enum SessionDrag {
    static let type = "com.laughing.promote.session"
    // ponytail: an SPM executable has no Info.plist to declare the type in, so declare it
    // at runtime and hand SwiftUI UTTypes, never identifier strings: UTType(type) is nil
    // for an undeclared id, so a string-based onDrop can silently accept nothing.
    static let utType = UTType(exportedAs: type)
    static let acceptedTypes: [UTType] = [utType, .utf8PlainText, .plainText]
    static let tabPrefix = "§tab:"
    static let pasteboardType = NSPasteboard.PasteboardType(type)

    static func provider(_ name: String, text: String) -> NSItemProvider {
        let provider = NSItemProvider(object: text as NSString)
        provider.registerDataRepresentation(for: utType, visibility: .all) { completion in
            completion(Data(name.utf8), nil)
            return nil
        }
        return provider
    }

    // plainText: also accept a bare session name (the sidebar's payload). Only safe where
    // dropped text has no other meaning, e.g. an empty pane; a terminal would paste it.
    static func loadName(from provider: NSItemProvider, plainText: Bool = false,
                         completion: @escaping (String?) -> Void) {
        func loadText() {
            guard provider.canLoadObject(ofClass: NSString.self) else { completion(nil); return }
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                completion((object as? String).flatMap { nameFromText($0, plainText: plainText) })
            }
        }
        guard provider.hasItemConformingToTypeIdentifier(type) else { loadText(); return }
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            if let data, let name = String(data: data, encoding: .utf8), !name.isEmpty {
                completion(name)
            } else {
                loadText()
            }
        }
    }

    private static func nameFromTabText(_ text: String) -> String? {
        guard text.hasPrefix(tabPrefix) else { return nil }
        let name = String(text.dropFirst(tabPrefix.count))
        return name.isEmpty ? nil : name
    }

    private static func nameFromText(_ text: String, plainText: Bool) -> String? {
        if let name = nameFromTabText(text) { return name }
        guard plainText, !text.isEmpty, !text.contains(where: \.isNewline) else { return nil }
        return text
    }

    static func name(from pasteboard: NSPasteboard) -> String? {
        if let data = pasteboard.data(forType: pasteboardType),
           let name = String(data: data, encoding: .utf8), !name.isEmpty {
            return name
        }
        // SwiftUI may bridge the NSString representation to AppKit's pasteboard.
        // Only our tagged tab payload is a session; ordinary terminal text is not.
        return pasteboard.string(forType: .string).flatMap(nameFromTabText)
    }
}

// Resolve against the current order after the drag payload finishes loading.
enum TabDropAnchor: Equatable {
    case before(String)
    case end

    func index(in tabs: [String]) -> Int? {
        switch self {
        case .before(let name): return tabs.firstIndex(of: name)
        case .end: return tabs.count
        }
    }
}

// Both frames and pointer coordinates belong to the scroll content, not its viewport.
enum TabDropPosition {
    static func index(x: CGFloat, tabs: [String], frames: [String: CGRect]) -> Int? {
        guard !tabs.isEmpty, x.isFinite,
              tabs.allSatisfy({ name in
                  guard let frame = frames[name] else { return false }
                  return frame.width > 0 && frame.midX.isFinite
              }) else { return nil }
        return tabs.firstIndex { name in x < frames[name]!.midX } ?? tabs.count
    }

    static func anchor(at index: Int, in tabs: [String]) -> TabDropAnchor? {
        guard index >= 0, index <= tabs.count else { return nil }
        return index == tabs.count ? .end : .before(tabs[index])
    }
}
