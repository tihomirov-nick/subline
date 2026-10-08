import Foundation

/// Subline was called Subtits before version 2.0. On the first launch under the new name it takes over the old
/// settings and files: presets, downloaded models and fonts, saved transcripts.
public enum FormerName {
    /// The settings domain of Subtits.
    static let bundleIdentifier = "com.subtits.app"
    /// ~/Library/Application Support/Subtits
    static let folderName = "Subtits"
    /// The language picked in the settings of Subtits ("automatic", "ru" or "en").
    static let languageKey = "SubtitsLanguage"
    /// The language Subtits last wrote into its own AppleLanguages.
    static let appliedLanguageKey = "SubtitsAppliedLanguage"
    private static let adoptedKey = "adoptedSubtitsSettings"

    /// Copies the settings of Subtits once. The interface language now follows macOS, so the language Subtits chose
    /// by itself is left behind; one picked by hand comes along.
    public static func adoptSettings() {
        let defaults = UserDefaults.standard
        guard let id = Bundle.main.bundleIdentifier, id != bundleIdentifier,
              defaults.object(forKey: adoptedKey) == nil else { return }
        defaults.set(true, forKey: adoptedKey)
        guard let old = defaults.persistentDomain(forName: bundleIdentifier) else { return }
        let own = defaults.persistentDomain(forName: id) ?? [:]
        let picked = (old[languageKey] as? String).flatMap { $0 == "ru" || $0 == "en" ? $0 : nil }
        for (key, value) in old where own[key] == nil {
            switch key {
            case languageKey, appliedLanguageKey:
                continue
            case "AppleLanguages":
                if let picked { defaults.set([picked], forKey: key) }
            default:
                defaults.set(value, forKey: key)
            }
        }
        // Otherwise System Settings → Language & Region would keep listing Subtits with the language it chose.
        for key in ["AppleLanguages", languageKey, appliedLanguageKey] {
            CFPreferencesSetAppValue(key as CFString, nil, bundleIdentifier as CFString)
        }
        CFPreferencesAppSynchronize(bundleIdentifier as CFString)
    }
}
