import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// Vignette and grain (design spec §6.3 "Effects" group). Every row edits
/// through `EditorSession.updateAdjustments(_:)`, since neither `Vignette`
/// nor `Grain` has an `AdjustmentKind` case of its own. Drag previews
/// through the shared continuous-edit transaction (inspector hierarchy/
/// preview spec §5.6) so a whole drag becomes exactly one Undo entry.
public struct EffectsAdjustmentPanel: View {
    @ObservedObject private var editor: EditorSession

    public init(editor: EditorSession) {
        self.editor = editor
    }

    public var body: some View {
        Level2DisclosureGroup(L10n.t("Vignette")) {
            row(L10n.t("Amount"), value: \.vignette.amount, range: -100...100, reset: Vignette.neutral.amount)
            row(L10n.t("Midpoint"), value: \.vignette.midpoint, range: 0...100, reset: Vignette.neutral.midpoint)
            row(L10n.t("Roundness"), value: \.vignette.roundness, range: -100...100, reset: Vignette.neutral.roundness)
            row(L10n.t("Feather"), value: \.vignette.feather, range: 0...100, reset: Vignette.neutral.feather)
        }
        Level2DisclosureGroup(L10n.t("Grain")) {
            row(L10n.t("Amount"), value: \.grain.amount, range: 0...100, reset: Grain.neutral.amount)
            row(L10n.t("Size"), value: \.grain.size, range: 0...100, reset: Grain.neutral.size)
            row(L10n.t("Roughness"), value: \.grain.roughness, range: 0...100, reset: Grain.neutral.roughness)
        }
    }

    private func row(
        _ label: String,
        value keyPath: WritableKeyPath<PhotoAdjustments, Double>,
        range: ClosedRange<Double>,
        reset defaultValue: Double
    ) -> some View {
        AdjustmentSliderRow(
            label: label,
            value: editor.displayedAdjustments[keyPath: keyPath],
            range: range,
            fractionDigits: 1,
            onChange: { newValue in editor.updateAdjustments { $0[keyPath: keyPath] = newValue } },
            onReset: { editor.updateAdjustments { $0[keyPath: keyPath] = defaultValue } },
            onPreview: { newValue in editor.previewContinuousEdit { $0[keyPath: keyPath] = newValue } },
            onCommitPreview: { editor.commitContinuousEdit() }
        )
    }
}
