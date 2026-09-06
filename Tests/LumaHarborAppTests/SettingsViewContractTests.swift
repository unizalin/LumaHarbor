import Foundation
import XCTest

/// Same source-parsing approach as `ExportSheetContractTests` -- see that
/// file's own header comment for why. Roadmap Phase 5 Task 5.3: the Mac app
/// must offer a System/Light/Dark appearance picker, reachable through a
/// `Settings` scene (design spec §6.13: "跟隨系統與手動切換"), and the
/// choice must actually reach the main window and every sheet so none of
/// them can drift out of sync with each other.
final class SettingsViewContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SettingsViewContractTests.swift
            .deletingLastPathComponent() // LumaHarborAppTests
            .deletingLastPathComponent() // Tests
    }()

    private static func loadSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRootURL.appendingPathComponent(relativePath, isDirectory: false),
            encoding: .utf8
        )
    }

    private static func settingsViewSource() throws -> String {
        try loadSource("Sources/LumaHarborApp/Views/SettingsView.swift")
    }

    // MARK: - Picker

    func testSettingsViewOffersAnAppearancePickerCoveringEveryTheme() throws {
        let source = try Self.settingsViewSource()
        XCTAssertTrue(source.contains("L10n.t(\"Appearance\")"))
        XCTAssertTrue(
            source.contains("ForEach(AppTheme.allCases"),
            "the picker must be driven by AppTheme.allCases, not a hand-picked subset"
        )
    }

    func testSettingsViewBindsThePickerToThePersistedTheme() throws {
        let source = try Self.settingsViewSource()
        XCTAssertTrue(
            source.contains("@AppStorage(\"appTheme\")"),
            "the settings picker must read/write the same appTheme AppStorage key the rest of the app uses"
        )
    }

    // MARK: - App-level wiring

    func testMainAppDeclaresASettingsScene() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/LumaHarborMainApp.swift")
        XCTAssertTrue(
            source.contains("Settings {") || source.contains("Settings{"),
            "the app must declare a Settings scene so the theme picker is reachable through the standard macOS Preferences/Settings menu item"
        )
        XCTAssertTrue(source.contains("SettingsView()"))
    }

    // MARK: - Main window and sheets stay in sync

    func testRootViewAppliesThePreferredColorSchemeToTheMainWindow() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/RootView.swift")
        XCTAssertTrue(source.contains("@AppStorage(\"appTheme\")"))
        XCTAssertTrue(source.contains(".preferredColorScheme(theme.colorScheme)"))
    }

    /// The bug this pins: applying `.preferredColorScheme` only to the main
    /// window's own content, with no matching modifier on `ExportSheet`/
    /// `BatchExportSheet`, would leave either sheet free to fall back to
    /// its own (possibly stale) appearance the instant it's presented --
    /// exactly the "sheet 與主視窗狀態不同步" failure mode the task calls
    /// out explicitly.
    func testExportAndBatchExportSheetsAlsoReceiveThePreferredColorScheme() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/RootView.swift")
        let occurrences = source.components(separatedBy: ".preferredColorScheme(theme.colorScheme)").count - 1
        XCTAssertGreaterThanOrEqual(
            occurrences, 3,
            "expected the preferred color scheme applied to the main window, ExportSheet, and BatchExportSheet (3 call sites), found \(occurrences)"
        )
    }

    /// Integration hardening review finding: the Settings window itself
    /// bound `theme` (to drive its own picker) but never applied
    /// `.preferredColorScheme` to its own content, so it stayed on the
    /// system appearance regardless of what the user picked -- the one
    /// window in the app that could visibly disagree with its own setting.
    func testSettingsViewAppliesThePreferredColorSchemeToItself() throws {
        let source = try Self.settingsViewSource()
        XCTAssertTrue(
            source.contains(".preferredColorScheme(theme.colorScheme)"),
            "the Settings window must follow the theme it lets the user choose, not stay on the system appearance"
        )
    }
}
