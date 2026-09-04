import Foundation
import XCTest

/// Same source-parsing approach as `CropOverlayContractTests`/
/// `EyedropperOverlayContractTests` -- see either file's own header comment
/// for why. Phase 3 Task 3.1: built-in presets must be visibly distinct and
/// non-destructively editable/deletable from the browser UI, and editing an
/// existing preset must actually be reachable, not merely exist as an
/// unused `PresetLibraryViewModel` method.
final class PresetBrowserFoundationContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PresetBrowserFoundationContractTests.swift
            .deletingLastPathComponent() // LumaHarborAppTests
            .deletingLastPathComponent() // Tests
    }()

    private static func loadSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRootURL.appendingPathComponent(relativePath, isDirectory: false),
            encoding: .utf8
        )
    }

    // MARK: - PresetBrowserView / PresetRow

    func testBuiltInPresetsCannotBeRenamedEditedOrDeletedFromTheRowMenu() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/PresetBrowserView.swift")
        XCTAssertTrue(
            source.contains("item.scope != .builtIn"),
            "the row menu must gate rename/edit/delete on the item not being built-in"
        )
    }

    func testPresetRowOffersAnEditEntryPointThatOpensEditPresetSheet() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/PresetBrowserView.swift")
        XCTAssertTrue(source.contains("L10n.t(\"Edit…\")"), "the row menu must offer an explicit Edit action, distinct from Rename")
        XCTAssertTrue(source.contains("onEdit"), "the row must expose an edit callback the browser wires to the sheet")
        XCTAssertTrue(source.contains("EditPresetSheet("), "PresetBrowserView must actually present EditPresetSheet, not just define the callback")
    }

    /// Design spec §9.1 ("顯示群組、相容性 badge 與來源"): every row must show
    /// something distinguishing a built-in preset and an imported-XMP one
    /// from an ordinary native user preset.
    func testPresetRowShowsASourceOrScopeBadge() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/PresetBrowserView.swift")
        XCTAssertTrue(
            source.contains("item.scope == .builtIn") || source.contains(".builtIn:"),
            "the row must visually distinguish a built-in preset from a user one"
        )
        XCTAssertTrue(
            source.contains(".adobeXMP"),
            "the row must visually distinguish an imported Adobe/XMP-sourced preset from a native one"
        )
    }

    func testCopyDestinationNeverOffersBuiltInAsATarget() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/PresetBrowserView.swift")
        // PresetCopyDestination.destination(for:hasLibraryScope:) must map
        // .builtIn's own case to .mine (a valid duplicate-out target), and
        // must never return .builtIn for any source scope -- pinned more
        // precisely by PresetBrowserPresentationTests; this just confirms
        // the .builtIn case is handled at all (exhaustive switch), which a
        // missing case would fail to compile, not just fail a test.
        XCTAssertTrue(source.contains("case .builtIn: return .mine"))
    }

    // MARK: - EditPresetSheet

    func testEditPresetSheetExistsAndOffersFieldRemoval() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditPresetSheet.swift")
        XCTAssertTrue(source.contains("struct EditPresetSheet"))
        XCTAssertTrue(source.contains("model.presetLibrary.updatePreset("), "saving must go through the sparse-removal-aware updatePreset(_:...), not createPreset")
        XCTAssertTrue(source.contains("PresetFieldGroup"), "must reuse the same field-group checklist CreatePresetSheet already established, not a second one")
    }

    func testEditPresetSheetOnlyOffersFieldsAlreadyInThePatch() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditPresetSheet.swift")
        XCTAssertTrue(
            source.contains("presentFields"),
            "the sheet must restrict itself to fields the preset's own patch already has -- there is no photo open here to source a newly-added field's value from"
        )
    }

    // MARK: - PresetFieldGroup shared between Create and Edit

    func testPresetFieldGroupIsSharedNotDuplicated() throws {
        let createSource = try Self.loadSource("Sources/LumaHarborApp/Views/CreatePresetSheet.swift")
        XCTAssertFalse(
            createSource.contains("private enum PresetFieldGroup"),
            "PresetFieldGroup must be shared with EditPresetSheet, not kept file-private to CreatePresetSheet"
        )
        XCTAssertTrue(createSource.contains("enum PresetFieldGroup"))
    }

    // MARK: - .lhpreset import (Phase 3 Task 3.2: "Add UI for import/export .lhpreset and .xmp")

    func testImportPresetSheetAcceptsLHPresetFilesNotOnlyXMP() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/ImportPresetSheet.swift")
        XCTAssertTrue(
            source.contains("lhpreset"),
            "the file picker must accept LumaHarbor's own .lhpreset files, not just .xmp"
        )
    }

    // MARK: - Backup / restore (Phase 3 Task 3.2)

    func testPresetBrowserOffersBackupAndRestoreEntryPoints() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/PresetBrowserView.swift")
        XCTAssertTrue(source.contains("presetLibrary.exportBackup("), "there must be a reachable UI path to back up presets")
        XCTAssertTrue(
            source.contains("presetLibrary.restoreBackupAndPresentSummary("),
            "there must be a reachable UI path that restores presets and presents its completion summary"
        )
    }
}
