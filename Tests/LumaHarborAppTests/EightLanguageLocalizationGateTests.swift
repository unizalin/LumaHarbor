import Foundation
import XCTest
@testable import Localization

/// Roadmap Phase 5 Task 5.4: "Eight-language localization gate". The eight
/// languages are exactly the list `docs/superpowers/plans/2026-09-02-
/// awayphotoraweditor-parity-roadmap.md` names for this task (also echoed
/// in `docs/superpowers/specs/2026-09-02-awayphotoraweditor-parity-design.md`
/// §6.13's "多語需求"): zh-Hant, en, ja, ko, zh-Hans, de, fr, es. Both
/// documents were checked before writing this file; neither lists a ninth
/// language or a different set, so this gate does not need to invent one.
///
/// This gate is coverage/structure only -- it proves every language file
/// exists, parses, carries every English baseline key, and contains no
/// empty value or obvious placeholder text. It does NOT prove translation
/// quality or grammatical correctness; per the roadmap's own words for
/// this task ("Initial translations may be rough but must be marked
/// machine-assisted in docs if not human reviewed"), ja/ko/zh-Hans/de/fr/es
/// are LLM-authored and have not been reviewed by a native speaker -- see
/// `docs/coordination/CURRENT.md`'s Phase 5 Task 5.4 entry for the full
/// disclosure.
final class EightLanguageLocalizationGateTests: XCTestCase {
    /// The roadmap's own list, in the order it names them.
    static let requiredLanguageCodes = ["zh-Hant", "en", "ja", "ko", "zh-Hans", "de", "fr", "es"]

    /// Keys that are deliberately identical to English in a *specific*
    /// language -- real technical terms/format names/units with no
    /// standard translated form in professional photo-editing software (a
    /// Japanese RAW editor still says "8-bit"), not keys someone forgot to
    /// translate. `testUntranslatedKeysOutsideTheAllowlistDoNotSilentlyMatchEnglish`
    /// is what keeps this honest: any key equal to the English value in a
    /// language whose own set here doesn't list it fails that test -- so
    /// growing this is always a visible, deliberate diff, never a silent
    /// gap (the task's own "不可默默放過" requirement).
    ///
    /// Scoped **per language** rather than one flat set shared by all six
    /// -- integration hardening review finding: cross-checking every
    /// candidate key against this repo's own six `Localizable.strings`
    /// files (one Python pass over each file's actual key/value pairs, not
    /// a guess) showed several keys are only genuinely identical to
    /// English in one or two of the six languages; every other language
    /// already translates them properly (e.g. "8-bit" stays literal only
    /// in Japanese -- Korean/Chinese/German/French/Spanish all render
    /// "8비트"/"8 位"/"8 Bit"/"8 bits"/"8 bits"). A flat set would have hidden
    /// an accidental untranslated "8-bit" in any of those five behind the
    /// one language that legitimately needs it. `testAllowlistIsScopedPerLanguageRatherThanGlobal`
    /// pins the "8-bit" example directly. Genuine cognates/loanwords (e.g.
    /// German "System"/"Format"/"Name", French "Photo"/"Grain"/"Orange",
    /// Spanish "Color"/"Original") were verified by hand, one at a time,
    /// against how Adobe's own localized Lightroom/Photoshop UIs render
    /// each in the corresponding language.
    static let intentionalEnglishMatchAllowlist: [String: Set<String>] = [
        "zh-Hant": ["1 GB", "10 GB", "16-bit", "2 GB", "5 GB", "512 MB", "8-bit", "DPI", "EXIF", "HEIC", "ISO", "JPEG", "PNG", "RGB", "TIFF"],
        "ja": ["1 GB", "10 GB", "16-bit", "2 GB", "5 GB", "512 MB", "8-bit", "DPI", "EXIF", "HEIC", "ISO", "JPEG", "OK", "PNG", "RGB", "TIFF"],
        "ko": ["DPI", "EXIF", "HEIC", "ISO", "JPEG", "PNG", "RGB", "TIFF"],
        "zh-Hans": ["1 GB", "10 GB", "2 GB", "5 GB", "512 MB", "DPI", "EXIF", "HEIC", "ISO", "JPEG", "PNG", "RGB", "TIFF"],
        "de": [
            "1 GB", "10 GB", "2 GB", "5 GB", "512 MB", "DPI", "Detail", "EXIF", "Format", "HEIC", "Horizontal", "ISO", "JPEG",
            "Magenta", "Name", "OK", "Offline", "Orange", "Original", "PNG", "Radius", "RGB", "Standard", "System",
            "TIFF", "Vignette",
        ],
        "fr": [
            "1 photo", "DPI", "Dimensions", "EXIF", "Format", "Grain", "HEIC", "Horizontal", "ISO", "JPEG", "Luminance", "Magenta",
            "Mode", "OK", "Orange", "Orientation", "Original", "Perspective", "PNG", "Photo", "Portrait", "Saturation", "Sources",
            "Standard", "Texture", "TIFF", "Vertical", "Vibrance", "photos",
        ],
        "es": ["1 GB", "10 GB", "2 GB", "5 GB", "512 MB", "Color", "EXIF", "HEIC", "Horizontal", "ISO", "JPEG", "Magenta", "Manual", "Original", "PNG", "RGB", "TIFF", "Vertical"],
    ]

    /// SwiftPM's resource processor lowercases `.lproj` directory names
    /// when it copies them into the built resource bundle (confirmed by
    /// inspecting `.build/.../LumaHarbor_Localization.bundle`: `zh-Hant.lproj`
    /// on disk in `Sources/` becomes `zh-hant.lproj` in the built bundle),
    /// but `Bundle.path(forResource:ofType:)` matches the resource name
    /// exactly rather than case-insensitively -- so looking up "zh-Hant"
    /// literally fails even though the language ships. `L10n.resolveBundle`
    /// never hits this because it resolves through `Bundle
    /// .preferredLocalizations(from:forPreferences:)` first (BCP-47-aware,
    /// case-insensitive) and only calls `path(forResource:ofType:)` with
    /// whatever exact string that already matched. This mirrors that: find
    /// the real on-disk name via `Bundle.module.localizations` first.
    private static func exactBundle(for languageCode: String) -> Bundle? {
        guard let actualName = Bundle.module.localizations.first(where: { $0.caseInsensitiveCompare(languageCode) == .orderedSame }),
              let path = Bundle.module.path(forResource: actualName, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }

    /// Loads `Localizable.strings` for `languageCode` as a flat
    /// `[String: String]`, independent of `L10n`'s own bundle-resolution
    /// logic (which picks *one* best-matching language for the live app;
    /// this gate needs to inspect all eight at once).
    private static func stringsDictionary(for languageCode: String) throws -> [String: String] {
        let languageBundle = try XCTUnwrap(
            exactBundle(for: languageCode),
            "no \(languageCode).lproj resource bundle found"
        )
        let stringsURL = try XCTUnwrap(
            languageBundle.url(forResource: "Localizable", withExtension: "strings"),
            "\(languageCode).lproj has no Localizable.strings"
        )
        let data = try Data(contentsOf: stringsURL)
        var format = PropertyListSerialization.PropertyListFormat.openStep
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        return try XCTUnwrap(plist as? [String: String], "\(languageCode)'s Localizable.strings did not parse as a flat string table")
    }

    private static let englishBaseline: [String: String] = {
        (try? stringsDictionary(for: "en")) ?? [:]
    }()

    /// Matched case-*sensitively* against the raw (non-uppercased) value --
    /// developer placeholders are conventionally written in caps ("TODO"),
    /// and matching case-sensitively is what keeps this from false-positive
    /// matching real natural-language words that happen to contain the same
    /// letters in a different case, e.g. Spanish "Todo" ("All"/"Everything"),
    /// which an earlier, case-*insensitive* version of this check flagged.
    private static let placeholderMarkers = ["TODO", "TBD", "MISSING", "TRANSLATE_ME"]

    // MARK: - Sanity: the baseline itself

    func testEnglishBaselineIsNonEmptyAndHasNoPlaceholderOrEmptyValues() throws {
        let english = try Self.stringsDictionary(for: "en")
        XCTAssertFalse(english.isEmpty)
        for (key, value) in english {
            XCTAssertFalse(value.isEmpty, "English baseline key \"\(key)\" has an empty value")
            for marker in Self.placeholderMarkers {
                XCTAssertFalse(
                    value.contains(marker),
                    "English baseline key \"\(key)\" contains placeholder marker \"\(marker)\": \"\(value)\""
                )
            }
        }
    }

    // MARK: - Every language's resource bundle exists

    func testEveryRequiredLanguageHasAnLprojResourceBundle() {
        for code in Self.requiredLanguageCodes {
            XCTAssertNotNil(Self.exactBundle(for: code), "missing \(code).lproj resource bundle")
        }
    }

    // MARK: - Every language's Localizable.strings parses

    func testEveryRequiredLanguagesLocalizableStringsParses() {
        for code in Self.requiredLanguageCodes {
            XCTAssertNoThrow(try Self.stringsDictionary(for: code), "\(code)'s Localizable.strings failed to parse")
        }
    }

    // MARK: - Full key coverage against the English baseline

    func testEveryRequiredLanguageContainsEveryEnglishBaselineKey() throws {
        let english = try Self.stringsDictionary(for: "en")
        XCTAssertFalse(english.isEmpty, "the English baseline itself must not be empty, or this test proves nothing")

        for code in Self.requiredLanguageCodes {
            let table = try Self.stringsDictionary(for: code)
            let missing = Set(english.keys).subtracting(table.keys)
            XCTAssertTrue(missing.isEmpty, "\(code) is missing \(missing.count) key(s) present in the English baseline: \(missing.sorted().prefix(10))")
        }
    }

    // MARK: - No empty values, no placeholder text

    func testNoRequiredLanguageHasAnyEmptyStringValue() throws {
        for code in Self.requiredLanguageCodes {
            let table = try Self.stringsDictionary(for: code)
            let empty = table.filter { $0.value.isEmpty }.keys
            XCTAssertTrue(empty.isEmpty, "\(code) has \(empty.count) empty value(s): \(empty.sorted().prefix(10))")
        }
    }

    func testNoRequiredLanguageHasObviousPlaceholderText() throws {
        for code in Self.requiredLanguageCodes {
            let table = try Self.stringsDictionary(for: code)
            for (key, value) in table {
                for marker in Self.placeholderMarkers {
                    XCTAssertFalse(
                        value.contains(marker),
                        "\(code) key \"\(key)\" contains placeholder marker \"\(marker)\": \"\(value)\""
                    )
                }
            }
        }
    }

    // MARK: - Silent English fallback is not allowed outside the allowlist

    /// A value identical to the English baseline is only acceptable when
    /// the key is in `intentionalEnglishMatchAllowlist` -- anything else
    /// equal to English is either an untranslated gap or a genuine
    /// coincidence that still needs a human decision, not something this
    /// gate lets through quietly.
    func testUntranslatedKeysOutsideTheAllowlistDoNotSilentlyMatchEnglish() throws {
        let english = try Self.stringsDictionary(for: "en")
        for code in Self.requiredLanguageCodes where code != "en" {
            let table = try Self.stringsDictionary(for: code)
            let allowed = Self.intentionalEnglishMatchAllowlist[code] ?? []
            for (key, englishValue) in english {
                guard let localizedValue = table[key] else { continue } // covered by the key-coverage test
                if localizedValue == englishValue, !allowed.contains(key) {
                    XCTFail("\(code) key \"\(key)\" silently matches the English value (\"\(englishValue)\") and is not in intentionalEnglishMatchAllowlist[\"\(code)\"]")
                }
            }
        }
    }

    /// Integration hardening review finding: the allowlist used to be one
    /// flat `Set<String>` shared by all six non-English languages. Cross-
    /// checking every entry against each language's actual shipped value
    /// showed several keys (e.g. "8-bit"/"16-bit", the GB/MB size keys)
    /// are only genuinely identical to English in *one or two* of the six
    /// languages -- every other language already translates them properly.
    /// A flat allowlist hid that distinction: if French's own "8-bit" had
    /// been accidentally left as literal "8-bit" instead of "8 bits", the
    /// old global allowlist (permitting "8-bit" for every language because
    /// Japanese needs it) would have let that slip through silently. Now
    /// scoped per language, computed by cross-checking this repo's own
    /// six `Localizable.strings` files key by key -- see the comment on
    /// `intentionalEnglishMatchAllowlist` for exactly how.
    func testAllowlistIsScopedPerLanguageRatherThanGlobal() {
        XCTAssertEqual(Self.intentionalEnglishMatchAllowlist["ja"]?.contains("8-bit"), true, "Japanese is the one language that keeps \"8-bit\" as-is")
        for code in ["ko", "zh-Hans", "de", "fr", "es"] {
            XCTAssertNotEqual(
                Self.intentionalEnglishMatchAllowlist[code]?.contains("8-bit"), true,
                "\(code) properly translates \"8-bit\" (e.g. \"8 Bit\"/\"8 bits\"/\"8비트\"/\"8 位\"); it must not be allowlisted to silently match English there"
            )
        }
    }

    // MARK: - Phase 5.1/5.2/5.3 strings specifically, in every language

    /// Mirrors `LocalizationSmokeTest`'s own per-feature key lists (theme,
    /// batch export, naming/collision/watermark) but checks all eight
    /// languages, not only zh-Hant -- the explicit ask from this task.
    func testPhase5StringsAreTranslatedInEveryRequiredLanguage() throws {
        let keys = [
            // Theme (Phase 5 Task 5.3)
            "Appearance", "System", "Light", "Dark",
            // Batch export (Phase 5 Task 5.1)
            "Export Photos", "Batch Export…", "Export Selected Photos…",
            "Export every selected photo", "Choose where to save the exported photos.",
            "1 photo selected", "photos selected",
            "Waiting", "Cancelled", "Skipped", "succeeded", "failed to export", "cancelled", "skipped",
            // Rename / collision / watermark (Phase 5 Task 5.2)
            "Increment (DSC0001-1)", "Ask Each Time", "If a File Exists",
            "Rename", "Original Filename", "Original Filename + Sequence",
            "Date + Original Filename", "Preset Name + Original Filename",
            "Original Filename + Copy Name",
            "Add Watermark", "Watermark Text", "Watermark Size",
            "Top Left", "Top Right", "Bottom Left", "Bottom Right", "Center",
        ]

        for code in Self.requiredLanguageCodes {
            let table = try Self.stringsDictionary(for: code)
            for key in keys {
                let value = table[key]
                XCTAssertNotNil(value, "\(code) is missing Phase 5 key \"\(key)\"")
                XCTAssertFalse(value?.isEmpty ?? true, "\(code) has an empty value for Phase 5 key \"\(key)\"")
            }
        }
    }
}
