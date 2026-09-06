import Localization
import SwiftUI

/// Mac app appearance preference (design spec §6.13: "跟隨系統與手動切換";
/// roadmap Phase 5 Task 5.3). Persisted via `@AppStorage("appTheme")` --
/// `RootView` and `SettingsView` both declare an `@AppStorage` binding on
/// that same key, so a choice made in Settings is visible in the main
/// window (and vice versa) the moment it changes, the same pattern
/// `ExportSheet`/`BatchExportSheet` already use for their own shared
/// `@AppStorage("export.*")` keys.
enum AppTheme: String, CaseIterable, Codable, Equatable, Sendable {
    case system
    case light
    case dark

    static let `default`: AppTheme = .system

    var displayName: String {
        switch self {
        case .system: return L10n.t("System")
        case .light: return L10n.t("Light")
        case .dark: return L10n.t("Dark")
        }
    }

    /// `nil` for `.system` lets SwiftUI follow the OS appearance, exactly
    /// like every view that never sets `.preferredColorScheme` at all.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
