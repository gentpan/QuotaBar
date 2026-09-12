import Foundation

/// Two-language UI strings, resolved at call sites as `L10n.t("English", "中文")`.
///
/// Deliberately not a `.strings` bundle: `package_app.sh` assembles the app by
/// hand and the dev loop runs the bare binary, so a `Bundle.module` lookup would
/// resolve differently (or trap) between the two paths. An inline table keeps
/// both languages side by side in the source and behaves identically everywhere.
public enum L10n {
    public enum Language: String, Codable, CaseIterable, Sendable, Identifiable {
        case system
        case en
        case zhHans = "zh-Hans"

        public var id: String { rawValue }

        /// Shown in its own language so the option is readable while the app is
        /// still displaying the other one.
        public var displayName: String {
            switch self {
            case .system: L10n.t("Follow system", "跟随系统")
            case .en: "English"
            case .zhHans: "简体中文"
            }
        }
    }

    private static let state = LanguageState()

    /// Explicit override; `.system` follows `Locale.preferredLanguages`.
    public static var override: Language {
        get { state.value }
        set { state.value = newValue }
    }

    public static var isChinese: Bool {
        switch override {
        case .zhHans: return true
        case .en: return false
        case .system: return systemPrefersChinese
        }
    }

    /// Picks the English or Chinese literal for the current language.
    /// The locale dates are formatted in: the interface language, not the
    /// system's, so a Chinese interface on an English Mac reads "9月13日".
    public static var locale: Locale {
        isChinese ? Locale(identifier: "zh_Hans_CN") : Locale(identifier: "en_US")
    }

    public static func t(_ en: String, _ zh: String) -> String {
        isChinese ? zh : en
    }

    private static var systemPrefersChinese: Bool {
        guard let preferred = Locale.preferredLanguages.first else { return false }
        return preferred.hasPrefix("zh-Hans")
            || preferred.hasPrefix("zh-CN")
            || preferred.hasPrefix("zh-SG")
            || preferred == "zh"
    }

    private final class LanguageState: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Language = .system

        var value: Language {
            get {
                lock.lock(); defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                stored = newValue
                lock.unlock()
            }
        }
    }
}
