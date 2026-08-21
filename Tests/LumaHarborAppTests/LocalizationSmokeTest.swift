import Foundation
import XCTest
@testable import Localization

/// Proves `L10n` actually picks the right language and the right value, not
/// just that the `.strings` files parse. `Bundle.preferredLocalizations`
/// (the instance property) was found by hand not to reflect the real system
/// language for this bundle, so these tests drive `L10n.resolveBundle(
/// preferences:)` with explicit language lists instead of relying on
/// whatever language the test machine happens to be running -- see
/// `Sources/Localization/L10n.swift` for the full diagnosis.
final class LocalizationSmokeTest: XCTestCase {
    func testEnglishPreferenceResolvesEnglishStrings() {
        let bundle = L10n.resolveBundle(preferences: ["en"])
        XCTAssertEqual(bundle.localizedString(forKey: "Cancel", value: nil, table: "Localizable"), "Cancel")
        XCTAssertEqual(
            bundle.localizedString(forKey: "Add a photo folder", value: nil, table: "Localizable"),
            "Add a photo folder"
        )
    }

    func testTraditionalChinesePreferenceResolvesChineseStrings() {
        let bundle = L10n.resolveBundle(preferences: ["zh-Hant-TW", "en-TW"])
        XCTAssertEqual(bundle.localizedString(forKey: "Cancel", value: nil, table: "Localizable"), "取消")
        XCTAssertEqual(
            bundle.localizedString(forKey: "Add a photo folder", value: nil, table: "Localizable"),
            "加入照片資料夾"
        )
    }

    func testAnUnsupportedPreferenceFallsBackToEnglish() {
        let bundle = L10n.resolveBundle(preferences: ["fr-FR", "de-DE"])
        XCTAssertEqual(bundle.localizedString(forKey: "Cancel", value: nil, table: "Localizable"), "Cancel")
    }

    func testEveryAdjustmentAndGroupNameHasAChineseTranslation() {
        // The Inspector's adjustment names route through L10n.t from
        // RawProcessingCore, not through this bundle directly -- but they
        // share the same table, so a stale/missing key here is the same
        // failure mode as the sidebar text going untranslated.
        let bundle = L10n.resolveBundle(preferences: ["zh-Hant-TW"])
        let keys = [
            "Exposure", "Temperature", "Tint", "Contrast", "Highlights",
            "Shadows", "Whites", "Blacks", "Vibrance", "Saturation",
            "White Balance", "Tone", "Color"
        ]
        for key in keys {
            let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            XCTAssertNotEqual(value, key, "\"\(key)\" has no Traditional Chinese translation")
        }
    }

    /// Phase 1 Preset/XMP UI (Task 7): every new user-facing string introduced
    /// by the Preset browser, create sheet and import sheet must have landed
    /// in both `.lproj` directories, not just `en`.
    func testEveryPresetUIStringHasAChineseTranslation() {
        let bundle = L10n.resolveBundle(preferences: ["zh-Hant-TW"])
        let keys = [
            "All", "Apply mode", "Apply preset", "Approximate: applies, but the algorithm differs from Adobe's",
            "Aqua", "Blue", "Choose Files…", "Choose develop preset files to import",
            "Couldn't copy this preset", "Couldn't create this preset", "Couldn't delete this preset",
            "Couldn't export this preset", "Couldn't rename this preset", "Create Preset",
            "Create a preset from this photo", "Delete", "Export Preset", "Export…", "Favorite", "Favorites",
            "Fields included:", "Filter presets", "Grain", "Green", "Import", "Import Develop Presets",
            "Import develop presets", "Imported %d of %d files.", "Include in this preset", "Magenta", "Merge",
            "More preset actions", "My Presets", "Name", "Native: applies reliably", "No files were selected.",
            "No presets yet", "Noise Reduction", "None of the selected files could be read as develop presets.",
            "Orange", "Preserved: kept but not applied", "Preset group", "Preset name", "Presets", "Purple",
            "Reading files…", "Red", "Rename Preset", "Rename…", "Replace", "Save", "Save to", "Search presets",
            "Sharpening", "Split Toning", "This Library", "This preset has no adjustments LumaHarbor can apply yet.",
            "Toggle favorite", "Tone Curve", "Vignette", "Yellow"
        ]
        for key in keys {
            let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            XCTAssertNotEqual(value, key, "\"\(key)\" has no Traditional Chinese translation")
        }
    }
}
