import AppKit

/// The interface language chosen in Settings → General: "system", "en" or "it". Applied at launch through
/// AppleLanguages (macOS picks the matching .lproj), so a change takes effect after a relaunch.
enum AppLanguage {
    static let key = "appLanguage"
    static let supported = ["en", "it"]

    static var current: String { UserDefaults.standard.string(forKey: key) ?? "system" }

    /// Call first thing at launch.
    static func apply() {
        let c = current
        if supported.contains(c) {
            UserDefaults.standard.set([c], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }
}

/// Localized interface text (AppKit menus and window titles; SwiftUI literals are looked up on their own).
func L(_ s: String) -> String { NSLocalizedString(s, comment: "") }

extension AppLanguage {
    /// Names shown in the picker, each in its own language.
    static let choices: [(String, String)] = [("system", "System"), ("en", "English"), ("it", "Italiano")]
    /// The language MusicAmp shows now ("en" or "it").
    /// Quits and opens MusicAmp again (to switch language).
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
    static var effective: String { Bundle.main.preferredLocalizations.first == "it" ? "it" : "en" }
}
