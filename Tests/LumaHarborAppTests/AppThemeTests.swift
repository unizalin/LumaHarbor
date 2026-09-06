import SwiftUI
import XCTest
@testable import LumaHarborApp

/// Roadmap Phase 5 Task 5.3: Mac appearance preference -- System, Light, or
/// Dark, persisted the same `@AppStorage` way `ExportSheet`/`BatchExportSheet`
/// already persist their own options (see those views' own `@AppStorage`
/// declarations), and mapped to SwiftUI's `ColorScheme` for
/// `.preferredColorScheme(_:)`.
final class AppThemeTests: XCTestCase {
    // MARK: - Default

    func testDefaultThemeIsSystem() {
        XCTAssertEqual(AppTheme.default, .system)
    }

    // MARK: - Color scheme mapping

    func testSystemMapsToNilColorSchemeSoItFollowsTheOSAppearance() {
        XCTAssertNil(AppTheme.system.colorScheme)
    }

    func testLightMapsToTheLightColorScheme() {
        XCTAssertEqual(AppTheme.light.colorScheme, .light)
    }

    func testDarkMapsToTheDarkColorScheme() {
        XCTAssertEqual(AppTheme.dark.colorScheme, .dark)
    }

    // MARK: - Coverage

    func testEveryThemeHasAVisibleDisplayName() {
        for theme in AppTheme.allCases {
            XCTAssertFalse(theme.displayName.isEmpty, "\(theme) has no display name")
        }
    }

    func testThereAreExactlyThreeThemes() {
        XCTAssertEqual(Set(AppTheme.allCases), [.system, .light, .dark])
    }

    // MARK: - Codable

    func testThemeRoundTripsThroughCodable() throws {
        for theme in AppTheme.allCases {
            let data = try JSONEncoder().encode(theme)
            let decoded = try JSONDecoder().decode(AppTheme.self, from: data)
            XCTAssertEqual(decoded, theme)
        }
    }

    // MARK: - Persistence round trip

    /// Simulates an app relaunch: a fresh `AppStorage` reading the same key
    /// from the same `UserDefaults` suite must see whatever the previous
    /// instance last wrote, not fall back to the default.
    func testThemeChoicePersistsAcrossAppStorageInstancesLikeAnAppRelaunch() throws {
        let suiteName = "AppThemeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstLaunch = AppStorage(wrappedValue: AppTheme.system, "appTheme", store: defaults)
        XCTAssertEqual(firstLaunch.wrappedValue, .system, "a fresh key must read back the default")

        firstLaunch.wrappedValue = .dark

        let secondLaunch = AppStorage(wrappedValue: AppTheme.system, "appTheme", store: defaults)
        XCTAssertEqual(secondLaunch.wrappedValue, .dark, "a later AppStorage instance on the same key/store must see the persisted choice")
    }
}
