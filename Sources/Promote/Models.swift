import SwiftUI
import AppKit

struct Session: Identifiable, Equatable, Hashable {
    let name: String
    let path: String
    var serving: Bool = false

    var id: String { name }
}

enum PRState: String, CaseIterable {
    case draft, open, merged, closed

    var label: String { rawValue.capitalized }

    var color: SwiftUI.Color {
        switch self {
        case .draft: return .gray
        case .open: return .blue
        case .merged: return colorFromHex("#05472A") ?? .green
        case .closed: return colorFromHex("#DA2C43") ?? .red
        }
    }
}

struct PRInfo: Equatable, Hashable {
    let state: PRState
    let number: Int
    let url: String
}

struct SessionDetails: Equatable {
    var branch: String?
    var pr: PRInfo?
}

enum AgentStatus: String, CaseIterable {
    case working, idle, blocked, done

    var title: String { rawValue.capitalized }

    var color: SwiftUI.Color {
        switch self {
        case .working: return .yellow
        case .idle: return .gray
        case .blocked: return colorFromHex("#DA2C43") ?? .red
        case .done: return .blue
        }
    }
}

// A tmux pane that appears to be running an agent CLI.
struct AgentInfo: Identifiable, Equatable, Hashable {
    let paneId: String
    let session: String
    let tool: String
    let status: AgentStatus

    var id: String { paneId }
}

struct PaletteColor: Identifiable {
    let id: String
    let hex: String

    var color: SwiftUI.Color { colorFromHex(hex) ?? .gray }
}

let palette: [PaletteColor] = [
    .init(id: "Red", hex: "#E74C3C"), .init(id: "Crimson", hex: "#B03A2E"),
    .init(id: "Orange", hex: "#E67E22"), .init(id: "Amber", hex: "#D4A017"),
    .init(id: "Olive", hex: "#A2B86C"), .init(id: "Green", hex: "#27AE60"),
    .init(id: "Teal", hex: "#16A085"), .init(id: "Aqua", hex: "#2E9CCA"),
    .init(id: "Blue", hex: "#2A7DE1"), .init(id: "Navy", hex: "#34568B"),
    .init(id: "Indigo", hex: "#4B4FCE"), .init(id: "Purple", hex: "#8E44AD"),
    .init(id: "Magenta", hex: "#D6336C"), .init(id: "Rose", hex: "#C2185B"),
    .init(id: "Brown", hex: "#A0632A"), .init(id: "Charcoal", hex: "#7F8C9B"),
]

func colorFromHex(_ value: String) -> SwiftUI.Color? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("#") else { return nil }

    let hex = String(trimmed.dropFirst())
    if hex.count == 3,
       let v = UInt16(hex, radix: 16) {
        let r = Double((v >> 8) & 0xF) / 15
        let g = Double((v >> 4) & 0xF) / 15
        let b = Double(v & 0xF) / 15
        return SwiftUI.Color(red: r, green: g, blue: b)
    }

    guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
    return SwiftUI.Color(
        red: Double((v >> 16) & 0xFF) / 255,
        green: Double((v >> 8) & 0xFF) / 255,
        blue: Double(v & 0xFF) / 255
    )
}

func hexString(_ color: NSColor) -> String {
    let c = color.usingColorSpace(.sRGB) ?? color
    return String(
        format: "#%02X%02X%02X",
        Int(round(c.redComponent * 255)),
        Int(round(c.greenComponent * 255)),
        Int(round(c.blueComponent * 255))
    )
}
