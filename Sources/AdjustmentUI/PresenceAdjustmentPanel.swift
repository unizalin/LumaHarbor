import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// Texture, Clarity, Dehaze (P4, design spec §6.3 "Presence"). None has an
/// `AdjustmentKind` case of its own, same convention as `EffectsAdjustmentPanel`.
public struct PresenceAdjustmentPanel: View {
    @ObservedObject private var editor: EditorSession

    public init(editor: EditorSession) {
        self.editor = editor
    }

    public var body: some View {
        AdjustmentSliderRow(
            label: L10n.t("Texture"), value: editor.adjustments.presence.texture,
            range: -100...100, fractionDigits: 0,
            onChange: { newValue in editor.updateAdjustments { $0.presence.texture = newValue } },
            onReset: { editor.updateAdjustments { $0.presence.texture = PresenceAdjustments.neutral.texture } }
        )
        AdjustmentSliderRow(
            label: L10n.t("Clarity"), value: editor.adjustments.presence.clarity,
            range: -100...100, fractionDigits: 0,
            onChange: { newValue in editor.updateAdjustments { $0.presence.clarity = newValue } },
            onReset: { editor.updateAdjustments { $0.presence.clarity = PresenceAdjustments.neutral.clarity } }
        )
        AdjustmentSliderRow(
            label: L10n.t("Dehaze"), value: editor.adjustments.presence.dehaze,
            range: -100...100, fractionDigits: 0,
            onChange: { newValue in editor.updateAdjustments { $0.presence.dehaze = newValue } },
            onReset: { editor.updateAdjustments { $0.presence.dehaze = PresenceAdjustments.neutral.dehaze } }
        )
    }
}
