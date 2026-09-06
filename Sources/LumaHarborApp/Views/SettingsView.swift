import SwiftUI
import Localization

/// Roadmap Phase 5 Task 5.3: reachable through the standard macOS
/// Preferences/Settings menu item (⌘,) via the `Settings` scene declared in
/// `LumaHarborMainApp`. Binds the same `@AppStorage("appTheme")` key
/// `RootView` reads for `.preferredColorScheme(_:)`, so a change here is
/// visible in the main window (and every sheet) immediately -- and applies
/// it to its own window too, so this window never disagrees with the
/// choice it just collected.
struct SettingsView: View {
    @AppStorage("appTheme") private var theme: AppTheme = .default

    var body: some View {
        Form {
            Picker(L10n.t("Appearance"), selection: $theme) {
                ForEach(AppTheme.allCases, id: \.self) { candidate in
                    Text(candidate.displayName).tag(candidate)
                }
            }
            .pickerStyle(.inline)
        }
        .padding(20)
        .frame(width: 320)
        // Integration hardening review finding: this window let the user
        // pick a theme but never applied it to itself, so it stayed on the
        // system appearance regardless of the choice -- the one window
        // that could visibly disagree with its own setting.
        .preferredColorScheme(theme.colorScheme)
    }
}
