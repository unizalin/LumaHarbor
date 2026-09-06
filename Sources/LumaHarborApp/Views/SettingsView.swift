import SwiftUI
import Localization

/// Roadmap Phase 5 Task 5.3: reachable through the standard macOS
/// Preferences/Settings menu item (⌘,) via the `Settings` scene declared in
/// `LumaHarborMainApp`. Binds the same `@AppStorage("appTheme")` key
/// `RootView` reads for `.preferredColorScheme(_:)`, so a change here is
/// visible in the main window (and every sheet) immediately.
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
    }
}
