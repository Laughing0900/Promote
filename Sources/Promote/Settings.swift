import Foundation

// ponytail: thin UserDefaults wrapper — every persisted key lives here.
// Views still bind fontSize via @AppStorage(Settings.fontSizeKey) for reactivity;
// this is the non-view access point and the single list of keys.
enum Settings {
    static let fontSizeKey = "fontSize"

    private static let d = UserDefaults.standard

    // session name → hex color (or legacy palette id)
    static var colors: [String: String] {
        get { d.dictionary(forKey: "sessionColors") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "sessionColors") }
    }

    // session name → group name
    static var groups: [String: String] {
        get { d.dictionary(forKey: "sessionGroups") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "sessionGroups") }
    }

    // manual sidebar order, session names
    static var order: [String] {
        get { d.stringArray(forKey: "sessionOrder") ?? [] }
        set { d.set(newValue, forKey: "sessionOrder") }
    }

    static var fontSize: Double {
        get { d.object(forKey: fontSizeKey) as? Double ?? 13 }
        set { d.set(newValue, forKey: fontSizeKey) }
    }
}
