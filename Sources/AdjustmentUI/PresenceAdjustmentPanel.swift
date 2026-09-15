import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// Texture, Clarity, Dehaze (P4, design spec §6.3 "Presence"). None has an
/// `AdjustmentKind` case of its own, same convention as `EffectsAdjustmentPanel`.
/// Drag previews through the shared continuous-edit transaction (inspector
/// hierarchy/preview spec §5.6) so a whole drag becomes exactly one Undo entry.
public struct PresenceAdjustmentPanel: View {
    @ObservedObject private var editor: EditorSession

    public init(editor: EditorSession) {
        self.editor = editor
    }

    public var body: some View {
        row(L10n.t("Texture"), value: \.presence.texture, reset: PresenceAdjustments.neutral.texture)
        row(L10n.t("Clarity"), value: \.presence.clarity, reset: PresenceAdjustments.neutral.clarity)
        row(L10n.t("Dehaze"), value: \.presence.dehaze, reset: PresenceAdjustments.neutral.dehaze)
    }

    private func row(
        _ label: String,
        value keyPath: WritableKeyPath<PhotoAdjustments, Double>,
        reset defaultValue: Double
    ) -> some View {
        AdjustmentSliderRow(
            label: label,
            value: editor.displayedAdjustments[keyPath: keyPath],
            range: -100...100,
            fractionDigits: 1,
            onChange: { newValue in editor.updateAdjustments { $0[keyPath: keyPath] = newValue } },
            onReset: { editor.updateAdjustments { $0[keyPath: keyPath] = defaultValue } },
            onPreview: { newValue in editor.previewContinuousEdit { $0[keyPath: keyPath] = newValue } },
            onCommitPreview: { editor.commitContinuousEdit() }
        )
    }
}
