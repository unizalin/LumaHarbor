import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// Vignette and grain (design spec §6.3 "Effects" group). Every row edits
/// through `EditorSession.updateAdjustments(_:)`, since neither `Vignette`
/// nor `Grain` has an `AdjustmentKind` case of its own.
public struct EffectsAdjustmentPanel: View {
    @ObservedObject private var editor: EditorSession

    public init(editor: EditorSession) {
        self.editor = editor
    }

    public var body: some View {
        DisclosureGroup(L10n.t("Vignette")) {
            AdjustmentSliderRow(
                label: L10n.t("Amount"), value: editor.adjustments.vignette.amount,
                range: -100...100, fractionDigits: 0,
                onChange: { newValue in editor.updateAdjustments { $0.vignette.amount = newValue } },
                onReset: { editor.updateAdjustments { $0.vignette.amount = Vignette.neutral.amount } }
            )
            AdjustmentSliderRow(
                label: L10n.t("Midpoint"), value: editor.adjustments.vignette.midpoint,
                range: 0...100, fractionDigits: 0,
                onChange: { newValue in editor.updateAdjustments { $0.vignette.midpoint = newValue } },
                onReset: { editor.updateAdjustments { $0.vignette.midpoint = Vignette.neutral.midpoint } }
            )
            AdjustmentSliderRow(
                label: L10n.t("Roundness"), value: editor.adjustments.vignette.roundness,
                range: -100...100, fractionDigits: 0,
                onChange: { newValue in editor.updateAdjustments { $0.vignette.roundness = newValue } },
                onReset: { editor.updateAdjustments { $0.vignette.roundness = Vignette.neutral.roundness } }
            )
            AdjustmentSliderRow(
                label: L10n.t("Feather"), value: editor.adjustments.vignette.feather,
                range: 0...100, fractionDigits: 0,
                onChange: { newValue in editor.updateAdjustments { $0.vignette.feather = newValue } },
                onReset: { editor.updateAdjustments { $0.vignette.feather = Vignette.neutral.feather } }
            )
        }
        DisclosureGroup(L10n.t("Grain")) {
            AdjustmentSliderRow(
                label: L10n.t("Amount"), value: editor.adjustments.grain.amount,
                range: 0...100, fractionDigits: 0,
                onChange: { newValue in editor.updateAdjustments { $0.grain.amount = newValue } },
                onReset: { editor.updateAdjustments { $0.grain.amount = Grain.neutral.amount } }
            )
            AdjustmentSliderRow(
                label: L10n.t("Size"), value: editor.adjustments.grain.size,
                range: 0...100, fractionDigits: 0,
                onChange: { newValue in editor.updateAdjustments { $0.grain.size = newValue } },
                onReset: { editor.updateAdjustments { $0.grain.size = Grain.neutral.size } }
            )
            AdjustmentSliderRow(
                label: L10n.t("Roughness"), value: editor.adjustments.grain.roughness,
                range: 0...100, fractionDigits: 0,
                onChange: { newValue in editor.updateAdjustments { $0.grain.roughness = newValue } },
                onReset: { editor.updateAdjustments { $0.grain.roughness = Grain.neutral.roughness } }
            )
        }
    }
}
