import Foundation

enum Settings {
    static let fontSizeKey = "fontSize"

    private static let d = UserDefaults.standard

    // session name -> hex color (or legacy palette id)
    static var colors: [String: String] {
        get { d.dictionary(forKey: "sessionColors") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "sessionColors") }
    }

    // divider uuid -> header title
    static var dividerTitles: [String: String] {
        get { d.dictionary(forKey: "dividerTitles") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "dividerTitles") }
    }

    // session names whose panes can't be closed/killed
    static var locked: [String] {
        get { d.stringArray(forKey: "sessionLocked") ?? [] }
        set { d.set(newValue, forKey: "sessionLocked") }
    }

    // manual sidebar order: session names + divider tokens ("§divider:<uuid>")
    static var order: [String] {
        get { d.stringArray(forKey: "sessionOrder") ?? [] }
        set { d.set(newValue, forKey: "sessionOrder") }
    }

}
