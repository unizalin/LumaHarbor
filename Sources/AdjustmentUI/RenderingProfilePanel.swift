import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// Picks one of `RenderingProfileCatalog`'s built-in creative styles (P4,
/// design spec §4/§6.3). Mounted at the top of the Basic group on both
/// platforms as the "starting point" filter, ahead of the tone sliders.
public struct RenderingProfilePanel: View {
    @ObservedObject private var editor: EditorSession

    public init(editor: EditorSession) {
        self.editor = editor
    }

    private static let profiles: [(id: String, labelKey: String)] = [
        ("lumaharbor.standard", "Standard"),
        ("lumaharbor.vivid", "Vivid"),
        ("lumaharbor.flat", "Flat"),
        ("lumaharbor.portrait", "Portrait")
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L10n.t("Rendering Profile"), selection: profileIDBinding) {
                Text(L10n.t("None")).tag(Optional<String>.none)
                ForEach(Self.profiles, id: \.id) { profile in
                    Text(L10n.t(profile.labelKey)).tag(Optional(profile.id))
                }
            }
            .pickerStyle(.menu)

            if editor.adjustments.renderingProfile.profileID != nil {
                AdjustmentSliderRow(
                    label: L10n.t("Amount"), value: editor.adjustments.renderingProfile.amount,
                    range: 0...100, fractionDigits: 0,
                    onChange: { newValue in editor.updateAdjustments { $0.renderingProfile.amount = newValue } },
                    onReset: { editor.updateAdjustments { $0.renderingProfile.amount = 100 } }
                )
            }

            if let reason = editor.adjustments.renderingProfile.fallbackReason, reason == "unknownProfile" {
                Text(L10n.t("No Matching Profile"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var profileIDBinding: Binding<String?> {
        Binding(
            get: { editor.adjustments.renderingProfile.profileID },
            set: { newValue in
                editor.updateAdjustments {
                    $0.renderingProfile.profileID = newValue
                    $0.renderingProfile.fallbackReason = nil
                    if newValue != nil, $0.renderingProfile.amount == 0 {
                        $0.renderingProfile.amount = 100
                    }
                }
            }
        )
    }
}
