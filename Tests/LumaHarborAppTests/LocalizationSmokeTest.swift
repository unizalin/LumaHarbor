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
}
