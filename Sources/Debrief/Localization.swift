import Foundation
import RecorderCore

/// The app's UI language. Defaults to Simplified Chinese no matter what the system language is.
/// The `.lproj` folders live in `Resources/` and `build-app.sh` copies them into the bundle.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en
    case ja

    static let storageKey = "appLanguage"
    static let `default`: AppLanguage = .zhHans
    /// Shipped localizations. The first one is the fallback when "Follow System" finds no match.
    static let shippedCodes = ["zh-Hans", "zh-Hant", "en", "ja"]

    var id: String { rawValue }

    static var current: AppLanguage {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AppLanguage.init) ?? .default
    }

    /// Language names are written in their own language and never translated.
    var displayName: String {
        switch self {
        case .system: L10n.tr("language.system")
        case .zhHans: "简体中文"
        case .zhHant: "繁體中文"
        case .en: "English"
        case .ja: "日本語"
        }
    }

    /// The `.lproj` that's actually used.
    var resolvedCode: String {
        guard self == .system else { return rawValue }
        // Read the user's global list, not this app's AppleLanguages override (see applyToSystemUI).
        let global = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
        let preferences = global ?? Locale.preferredLanguages
        // preferredLocalizations falls back to English when nothing matches (e.g. Korean, French).
        // Only accept its pick if one of the user's languages really shares that base language;
        // otherwise use Chinese, the app default.
        guard let match = Bundle.preferredLocalizations(from: Self.shippedCodes, forPreferences: preferences).first,
              let base = Locale(identifier: match).language.languageCode,
              preferences.contains(where: { Locale(identifier: $0).language.languageCode == base })
        else { return Self.default.rawValue }
        return match
    }

    /// Sets this app's AppleLanguages so system-drawn UI (open panel, standard buttons,
    /// permission prompts) uses the same language. Takes effect on the next launch.
    func applyToSystemUI() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

enum L10n {
    private static let missing = "\u{0}"

    /// Looks up `key` in the selected language, falls back to English, then to the key itself.
    /// Placeholders are `%@` (use `%1$@`, `%2$@` to reorder).
    static func tr(_ key: String, _ args: [String] = []) -> String {
        let code = AppLanguage.current.resolvedCode
        var format = bundle(code)?.localizedString(forKey: key, value: missing, table: nil) ?? missing
        if format == missing {
            format = bundle("en")?.localizedString(forKey: key, value: key, table: nil) ?? key
        }
        guard !args.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: code), arguments: args.map { $0 as CVarArg })
    }

    static var locale: Locale { Locale(identifier: AppLanguage.current.resolvedCode) }

    private static func bundle(_ code: String) -> Bundle? {
        Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
    }
}

/// A status message stored as a key plus arguments and translated when rendered,
/// so it follows a language change.
struct Notice: Equatable {
    var key: String
    var args: [String] = []
    /// Detail from the system (already localized by macOS). Shown as-is.
    var detail: String?

    init(_ key: String, _ args: [String] = [], detail: String? = nil) {
        self.key = key
        self.args = args
        self.detail = detail
    }

    init(error: Error) {
        switch error {
        case let e as PermissionError:
            self.init(e == .microphone ? "error.micPermission" : "error.screenPermission")
        case let e as RecorderError:
            switch e {
            case .noSourcesEnabled: self.init("error.noSources")
            case .noDisplay: self.init("error.noDisplay")
            case .writerSetupFailed(let u): self.init("error.writerSetup", detail: u?.localizedDescription)
            case .noAudioCaptured: self.init("error.noAudio")
            case .writeFailed(let u): self.init("error.writeFailed", detail: u?.localizedDescription)
            case .noAudioTracks: self.init("error.noTracks")
            case .exportFailed(let u): self.init("error.exportFailed", detail: u?.localizedDescription)
            }
        default:
            self.init("error.generic", [error.localizedDescription])
        }
    }

    var text: String {
        let base = L10n.tr(key, args)
        guard let detail, !detail.isEmpty else { return base }
        return base + "\n" + detail
    }
}
