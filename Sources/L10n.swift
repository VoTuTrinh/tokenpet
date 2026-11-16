// Two languages, no string tables: every user-visible string is written once as L("English", "Tiếng Việt").
// English is the default; Vietnamese when it is the Mac's first preferred language, or when chosen in Settings.
import Foundation

enum Lang {
    /// "" = follow the system, "en", "vi". Stored under "lang"; `--lang en|vi` overrides it for one run.
    static var override: String = {
        let a = CommandLine.arguments
        if let k = a.firstIndex(of: "--lang"), k + 1 < a.count { return a[k + 1] }
        return UserDefaults.standard.string(forKey: "lang") ?? ""
    }()
    static var vi: Bool {
        if override == "vi" { return true }
        if override == "en" { return false }
        return Locale.preferredLanguages.first?.hasPrefix("vi") == true
    }
}
func L(_ en: @autoclosure () -> String, _ vi: @autoclosure () -> String) -> String { Lang.vi ? vi() : en() }
