import AppKit

/// Small, shared localization surface for the menu bar app and its settings window.
/// The value is intentionally stored in UserDefaults so the preference survives app updates.
enum L10n {
    enum Preference: String, Equatable {
        case system
        case japanese
        case english
    }

    private static let preferenceKey = "languagePreference"
    private static var transientPreference: Preference?

    static var preference: Preference {
        transientPreference ?? (Preference(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "system") ?? .system)
    }

    static var isJapanese: Bool {
        switch preference {
        case .japanese: return true
        case .english: return false
        case .system:
            return Locale.preferredLanguages.first?.hasPrefix("ja") == true
        }
    }

    static func text(_ japanese: String, _ english: String) -> String {
        isJapanese ? japanese : english
    }

    static func setPreference(_ value: Preference, persist: Bool = true) {
        if persist {
            transientPreference = nil
            UserDefaults.standard.set(value.rawValue, forKey: preferenceKey)
        } else {
            transientPreference = value
        }
        NotificationCenter.default.post(name: .rainyScreenLanguageDidChange, object: nil)
    }

    static var languageName: String {
        switch preference {
        case .system: return text("システムに従う", "System")
        case .japanese: return "日本語"
        case .english: return "English"
        }
    }
}

extension Notification.Name {
    static let rainyScreenStateDidChange = Notification.Name("RainyScreenStateDidChange")
    static let rainyScreenLanguageDidChange = Notification.Name("RainyScreenLanguageDidChange")
}
