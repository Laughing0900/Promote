import SwiftUI

struct Session: Identifiable, Equatable {
    let name: String
    let path: String
    var id: String { name }
}

enum PRState: String {
    case draft, open, merged, closed
    var color: SwiftUI.Color {
        switch self {
        case .draft: return .gray
        case .open: return .blue
        case .merged: return colorFromHex("#05472A") ?? .green
        case .closed: return colorFromHex("#DA2C43") ?? .red
        }
    }
}

struct PRInfo: Equatable {
    let state: PRState
    let number: Int
    let url: String
}

struct Details: Equatable {
    var branch: String?
    var pr: PRInfo?
}

func colorFromHex(_ s: String) -> SwiftUI.Color? {
    guard s.hasPrefix("#"), let v = UInt32(s.dropFirst(), radix: 16) else { return nil }
    return SwiftUI.Color(red: Double((v >> 16) & 0xFF) / 255,
                         green: Double((v >> 8) & 0xFF) / 255,
                         blue: Double(v & 0xFF) / 255)
}

func hexString(_ c: NSColor) -> String {
    let c = c.usingColorSpace(.sRGB) ?? c
    return String(format: "#%02X%02X%02X",
                  Int(round(c.redComponent * 255)),
                  Int(round(c.greenComponent * 255)),
                  Int(round(c.blueComponent * 255)))
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
