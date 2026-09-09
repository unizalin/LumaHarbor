import Foundation
import XCTest

/// Contract tests for the iPad Preset domain vertical slice (spec §7.3, §9.1, §5.3).
/// Source-parsed only — no device, network, or private paths required.
final class PadPresetContractTests: XCTestCase {

    // MARK: - Helpers

    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    private static let padAppSourceURL = repositoryRootURL
        .appendingPathComponent("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp", isDirectory: true)

    private static func loadAppSource(_ filename: String) throws -> String {
        try String(contentsOf: padAppSourceURL.appendingPathComponent(filename), encoding: .utf8)
    }

    // MARK: - Package.swift: PresetCore dependency

    func testIPadPackageIncludesPresetCoreProduct() throws {
        let packageURL = Self.padAppSourceURL
            .deletingLastPathComponent() // Sources/LumaHarborPadApp -> Sources
            .deletingLastPathComponent() // Sources -> LumaHarborPad.swiftpm
            .appendingPathComponent("Package.swift")
        let source = try String(contentsOf: packageURL, encoding: .utf8)
        XCTAssertTrue(
            source.contains("\"PresetCore\""),
            "LumaHarborPad/Package.swift must list PresetCore as a product dependency"
        )
    }

    // MARK: - PadPresetLibrary

    func testPadPresetLibraryExistsWithBothScopes() throws {
        let source = try Self.loadAppSource("PadPresetLibrary.swift")
        XCTAssertTrue(source.contains("BuiltInPresetRepository"), "must load built-in presets")
        XCTAssertTrue(source.contains("FilePresetRepository"), "must load user My Presets")
        XCTAssertTrue(source.contains("PadPresetScope"), "must expose scope enum")
    }

    func testPadPresetLibraryScopesContainBuiltInAndMyPresets() throws {
        let source = try Self.loadAppSource("PadPresetLibrary.swift")
        XCTAssertTrue(source.contains(".builtIn") || source.contains("case builtIn"), "builtIn scope required")
        XCTAssertTrue(source.contains(".myPresets") || source.contains("case myPresets"), "myPresets scope required")
    }

    func testPadPresetLibraryFiltersAreNonDestructive() throws {
        let source = try Self.loadAppSource("PadPresetLibrary.swift")
        // filteredPresets is a computed property (no mutation on allPresets)
        XCTAssertTrue(source.contains("var filteredPresets"), "must expose filteredPresets as computed view")
        XCTAssertFalse(
            source.contains("allPresets.removeAll") || source.contains("allPresets = []"),
            "allPresets must not be cleared during filtering"
        )
    }

    func testPadPresetLibraryExposesSearchQuery() throws {
        let source = try Self.loadAppSource("PadPresetLibrary.swift")
        XCTAssertTrue(source.contains("searchQuery"), "must expose searchQuery for binding")
    }

    func testPadPresetLibrarySupportsFavoriteEditingAndFilesRoundTrip() throws {
        let source = try Self.loadAppSource("PadPresetLibrary.swift")
        for required in [
            "favoritesOnly", "createPreset(", "updatePreset(", "toggleFavorite(",
            "exportNative(", "exportXMP(", "exportBackup()", "restoreBackup(",
            "importFiles("
        ] {
            XCTAssertTrue(source.contains(required), "PadPresetLibrary must implement \(required)")
        }
    }

    // MARK: - PadAppServices

    func testPadAppServicesOwnsPresetLibraryAndRepository() throws {
        let source = try Self.loadAppSource("PadAppServices.swift")
        XCTAssertTrue(source.contains("let myPresetsRepository: FilePresetRepository"), "must own the repository")
        XCTAssertTrue(source.contains("let presetLibrary: PadPresetLibrary"), "must own the library")
        XCTAssertTrue(source.contains("BuiltInPresetRepository()"), "must construct built-in repo once")
    }

    func testPadAppServicesDoesNotBuildRepositoryInViewBody() throws {
        // The library is a stored property, never built inside content/body.
        let source = try Self.loadAppSource("PadAppServices.swift")
        XCTAssertTrue(
            source.contains("self.presetLibrary = presetLibrary"),
            "presetLibrary must be assigned from a local, not created inline"
        )
    }

    // MARK: - PadRootView

    func testPadRootPassesPresetLibraryIntoEditor() throws {
        let source = try Self.loadAppSource("PadRootView.swift")
        XCTAssertTrue(
            source.contains("presetLibrary: services.presetLibrary"),
            "PadRootView must pass services.presetLibrary to PadEditorView"
        )
    }

    // MARK: - PadEditorView / PadPresetPanel

    func testPresetPlaceholderIsGone() throws {
        let editorSource = try Self.loadAppSource("PadEditorView.swift")
        XCTAssertFalse(
            editorSource.contains("Preset browsing is not yet wired."),
            "The placeholder string must be removed now that the panel is wired"
        )
        let hostSource = try Self.loadAppSource("PadInspectorHost.swift")
        XCTAssertFalse(
            hostSource.contains("Preset browsing is not yet wired."),
            "Standalone PadInspectorHost must not still show the placeholder"
        )
    }

    func testPresetPanelCallsCommitPreset() throws {
        let source = try Self.loadAppSource("PadEditorView.swift")
        XCTAssertTrue(
            source.contains("editor.commitPreset("),
            "Applying a preset must call editor.commitPreset for one-undo-step contract"
        )
    }

    func testPresetPanelCallsPreviewAndCancelPreview() throws {
        let source = try Self.loadAppSource("PadEditorView.swift")
        XCTAssertTrue(source.contains("editor.previewPreset("), "must call previewPreset on tap")
        XCTAssertTrue(source.contains("editor.cancelPresetPreview()"), "must cancel preview on disappear / row change")
    }

    func testMergeAndReplaceModeExposed() throws {
        let source = try Self.loadAppSource("PadEditorView.swift")
        XCTAssertTrue(source.contains("PresetApplicationMode.merge"), "Merge mode must be accessible")
        XCTAssertTrue(source.contains("PresetApplicationMode.replace"), "Replace mode must be accessible")
    }

    func testPresetPanelHasExplicitApplyButton() throws {
        let source = try Self.loadAppSource("PadEditorView.swift")
        // The Apply button must be distinct from the tap-to-preview gesture
        XCTAssertTrue(source.contains("L10n.t(\"Apply\")"), "Apply button label must use L10n")
    }

    func testPresetPanelExposesImportExportAndEditingActions() throws {
        let source = try Self.loadAppSource("PadEditorView.swift")
        for required in [
            "Import preset files", "Restore backup", "Export backup",
            "PadPresetCreateSheet", "PadPresetEditSheet", "exportPreset("
        ] {
            XCTAssertTrue(source.contains(required), "PadPresetPanel must expose \(required)")
        }
    }

    func testPresetPanelNeverModifiesAdjustmentsDirectly() throws {
        let source = try Self.loadAppSource("PadEditorView.swift")
        // Should not reach into editor.adjustments or PhotoAdjustments directly
        XCTAssertFalse(
            source.contains("editor.adjustments =") || source.contains("editor.adjustments."),
            "preset panel must not write to adjustments directly — only through commitPreset"
        )
    }

    // MARK: - No absolute paths in error messages

    func testPresetLibraryErrorsDoNotSurfaceAbsolutePaths() throws {
        let source = try Self.loadAppSource("PadPresetLibrary.swift")
        XCTAssertFalse(
            source.contains("scope.availabilityAnchorURL.path") || source.contains("/Users/"),
            "PadPresetLibrary must not surface absolute paths in error messages"
        )
    }
}
