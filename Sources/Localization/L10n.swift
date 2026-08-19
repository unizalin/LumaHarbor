import Foundation

/// Looks up `Localizable.strings` translations directly, bypassing both
/// `Bundle.preferredLocalizations` (the instance property) and
/// `String(localized:)`'s default bundle resolution.
///
/// Both were confirmed by hand not to work for this bundle: with the Mac's
/// real system language set to Traditional Chinese (`Locale.preferredLanguages
/// == ["zh-Hant-TW", "en-TW"]`), `Bundle.module.preferredLocalizations` still
/// returned `["en"]` -- it never picked up the system preference for this
/// resource bundle, regardless of the `.lproj` directory's case. Separately,
/// `String(localized:)` defaults its `bundle:` parameter to `.main`, which
/// under `swift run` is just the raw executable's directory and carries no
/// `.lproj` resources at all -- so a bare `String(localized: "key")` call
/// anywhere in the app always fell back to returning the key itself (which
/// happens to read as English), independent of system language.
///
/// What *does* work, confirmed by hand: the static utility
/// `Bundle.preferredLocalizations(from:forPreferences:)`, given the same
/// bundle's `localizations` and `Locale.preferredLanguages` explicitly,
/// correctly picks `"zh-Hant"`. This type routes every lookup through that
/// instead, then loads the matched language's `.lproj` directly. Do not
/// "simplify" this back to `String(localized:)` or `Bundle.module
/// .localizedString` without re-verifying against a real run -- see
/// `docs/testing/reports/2026-08-16-mvp-acceptance-progress.md` for how this
/// was diagnosed.
public enum L10n {
    /// The bundle for whichever language actually matches the user's
    /// preferences, resolved once at first use.
    public static let bundle: Bundle = resolveBundle()

    static func resolveBundle(
        preferences: [String] = Locale.preferredLanguages,
        in moduleBundle: Bundle = Bundle.module
    ) -> Bundle {
        let preferred = Bundle.preferredLocalizations(
            from: moduleBundle.localizations,
            forPreferences: preferences
        ).first ?? "en"
        guard let path = moduleBundle.path(forResource: preferred, ofType: "lproj"),
              let languageBundle = Bundle(path: path) else {
            return moduleBundle
        }
        return languageBundle
    }

    /// Looks up `key` in `Localizable.strings`. Falls back to `key` itself
    /// (i.e. the English source text, since keys are the English strings) if
    /// nothing matches.
    public static func t(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }
}
