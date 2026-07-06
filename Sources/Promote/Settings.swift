import Foundation

enum Settings {
    static let fontSizeKey = "fontSize"

    private static let d = UserDefaults.standard

    // session name -> hex color (or legacy palette id)
    static var colors: [String: String] {
        get { d.dictionary(forKey: "sessionColors") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "sessionColors") }
    }

    // session name -> group name
    static var groups: [String: String] {
        get { d.dictionary(forKey: "sessionGroups") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "sessionGroups") }
    }

    // session names whose panes can't be closed/killed
    static var locked: [String] {
        get { d.stringArray(forKey: "sessionLocked") ?? [] }
        set { d.set(newValue, forKey: "sessionLocked") }
    }

    // manual sidebar order (session names)
    static var order: [String] {
        get { d.stringArray(forKey: "sessionOrder") ?? [] }
        set { d.set(newValue, forKey: "sessionOrder") }
    }

    static var fontSize: Double {
        get { d.object(forKey: fontSizeKey) as? Double ?? 13 }
        set { d.set(newValue, forKey: fontSizeKey) }
    }

    static var agentsPanelHeight: Double {
        get { d.object(forKey: "agentsPanelHeight") as? Double ?? 160 }
        set { d.set(newValue, forKey: "agentsPanelHeight") }
    }

    static var sidebarWidth: Double {
        get { d.object(forKey: "sidebarWidth") as? Double ?? 260 }
        set { d.set(newValue, forKey: "sidebarWidth") }
    }
}
