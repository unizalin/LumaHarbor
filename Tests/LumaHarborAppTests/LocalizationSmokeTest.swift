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
            "This preset's preview couldn't be rendered right now.",
            "Toggle favorite", "Tone Curve", "Vignette", "Yellow"
        ]
        for key in keys {
            let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            XCTAssertNotEqual(value, key, "\"\(key)\" has no Traditional Chinese translation")
        }
    }

    /// AwayPhotoRawEditor parity Phase 2 Task 2.3: every new user-facing
    /// string the Mac crop/rotate/straighten tool introduces must have
    /// landed in both `.lproj` directories, not just `en`. "Reset" and
    /// "Your RAW original was not changed." are deliberately reused from
    /// existing keys rather than duplicated, so they aren't repeated here.
    func testEveryGeometryToolStringHasAChineseTranslation() {
        let bundle = L10n.resolveBundle(preferences: ["zh-Hant-TW"])
        let keys = [
            "Geometry", "Rotate & Flip", "Rotate Left", "Rotate Right",
            "Flip Horizontal", "Flip Vertical", "Straighten", "Crop",
            "Edit Crop", "Done", "Aspect Ratio", "Freeform", "Square",
            "Reset Crop", "Geometry adjustments are non-destructive."
        ]
        for key in keys {
            let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            XCTAssertNotEqual(value, key, "\"\(key)\" has no Traditional Chinese translation")
        }
    }

    /// AwayPhotoRawEditor parity Phase 2 Task 2.4: every new user-facing
    /// string the white balance eyedropper introduces must have landed in
    /// both `.lproj` directories.
    func testEveryEyedropperStringHasAChineseTranslation() {
        let bundle = L10n.resolveBundle(preferences: ["zh-Hant-TW"])
        let keys = [
            "White Balance Eyedropper", "Cancel Eyedropper", "Click a point that should be neutral gray"
        ]
        for key in keys {
            let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            XCTAssertNotEqual(value, key, "\"\(key)\" has no Traditional Chinese translation")
        }
    }

    /// Phase 3 Task 3.1: every new user-facing string built-in presets and
    /// editing an existing preset introduce must have landed in both
    /// `.lproj` directories. Does NOT include `PresetError.builtInPresetIsReadOnly`'s
    /// own `errorDescription`/`recoverySuggestion`, or the ad-hoc "That
    /// destination isn't available right now." alert body -- those sit in a
    /// pre-existing, systemic gap (the whole `PresetError` family, and some
    /// `UserAlert` bodies distinct from their titles, have never had
    /// `.strings` entries at all) that predates this task and is out of its
    /// scope; see `docs/coordination/CURRENT.md`.
    func testEveryPresetEditAndBuiltInStringHasAChineseTranslation() {
        let bundle = L10n.resolveBundle(preferences: ["zh-Hant-TW"])
        let keys = [
            "Built-In", "Imported", "Edit…", "Edit Preset", "Fields in this preset",
            "Uncheck a field to remove it from this preset. New fields can only be added by creating a preset from an open photo.",
            "Couldn't update this preset"
        ]
        for key in keys {
            let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            XCTAssertNotEqual(value, key, "\"\(key)\" has no Traditional Chinese translation")
        }
    }

    /// Phase 3 Task 3.2: every new user-facing string backup/restore and
    /// `.lhpreset` import introduce must have landed in both `.lproj`
    /// directories.
    func testEveryPresetBackupRestoreStringHasAChineseTranslation() {
        let bundle = L10n.resolveBundle(preferences: ["zh-Hant-TW"])
        let keys = [
            "Backup My Presets…", "Backup This Library's Presets…", "Restore Presets…",
            "Backup or restore presets", "Backup Presets", "Restore Presets",
            "Couldn't back up presets", "Couldn't restore this backup", "That file couldn't be read.",
            "Restore complete", "Nothing to restore.", "added", "kept as a copy", "already present", "failed",
            "Choose one or more .xmp or .lhpreset files to see what LumaHarbor can import."
        ]
        for key in keys {
            let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            XCTAssertNotEqual(value, key, "\"\(key)\" has no Traditional Chinese translation")
        }
    }

    /// Phase 3 Task 3.3: the one new user-facing string thumbnail
    /// multi-select introduces.
    func testTheBatchSelectionIndicatorStringHasAChineseTranslation() {
        let bundle = L10n.resolveBundle(preferences: ["zh-Hant-TW"])
        let value = bundle.localizedString(forKey: "Included in the current batch selection", value: nil, table: "Localizable")
        XCTAssertNotEqual(value, "Included in the current batch selection", "has no Traditional Chinese translation")
    }

    /// Phase 3 Task 3.4: every new user-facing string "Undo Batch Sync" and
    /// its report copy introduce.
    func testEveryBatchUndoStringHasAChineseTranslation() {
        let bundle = L10n.resolveBundle(preferences: ["zh-Hant-TW"])
        let keys = ["Undo Batch Sync", "Batch Sync Undone", "reverted", "failed to revert", "Nothing to undo."]
        for key in keys {
            let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            XCTAssertNotEqual(value, key, "\"\(key)\" has no Traditional Chinese translation")
        }
    }

    /// Phase 3 Task 3.5: every new user-facing string virtual copies
    /// introduce (badge, context menu actions, error alerts).
    func testEveryVirtualCopyStringHasAChineseTranslation() {
        let bundle = L10n.resolveBundle(preferences: ["zh-Hant-TW"])
        let keys = [
            "Virtual copy", "Duplicate as Virtual Copy", "Delete Virtual Copy",
            "Couldn't create a virtual copy", "Couldn't delete this virtual copy",
            "This photo isn't a virtual copy."
        ]
        for key in keys {
            let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            XCTAssertNotEqual(value, key, "\"\(key)\" has no Traditional Chinese translation")
        }
    }
}
