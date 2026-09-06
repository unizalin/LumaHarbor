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

    /// Every language this module ships a `.lproj` for -- `Bundle.module`'s
    /// own `.localizations`, independent of `Locale.preferredLanguages`
    /// -based resolution (which `resolveBundle` above uses and which always
    /// returns exactly one best-matching language, silently falling back to
    /// English for one that isn't shipped). Public so headless diagnostics
    /// (roadmap Phase 5 Task 5.5) can report which languages actually ship
    /// without needing `@testable import` from outside this module.
    public static var availableLanguageCodes: [String] {
        Bundle.module.localizations
    }

    /// Number of keys in `languageCode`'s own `Localizable.strings`, or
    /// `nil` if this module has no `.lproj` for it, or its table couldn't be
    /// parsed. Case-insensitive: SwiftPM lowercases `.lproj` directory names
    /// when it copies them into the built resource bundle, so an exact-case
    /// lookup for e.g. "zh-Hant" would miss the "zh-hant" it actually
    /// shipped as -- this matches against `availableLanguageCodes` first to
    /// find the real on-disk name before resolving a path from it.
    public static func keyCount(for languageCode: String) -> Int? {
        guard let actualName = Bundle.module.localizations.first(where: { $0.caseInsensitiveCompare(languageCode) == .orderedSame }),
              let path = Bundle.module.path(forResource: actualName, ofType: "lproj"),
              let languageBundle = Bundle(path: path),
              let stringsURL = languageBundle.url(forResource: "Localizable", withExtension: "strings"),
              let data = try? Data(contentsOf: stringsURL) else {
            return nil
        }
        var format = PropertyListSerialization.PropertyListFormat.openStep
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
              let table = plist as? [String: String] else {
            return nil
        }
        return table.count
    }
}
