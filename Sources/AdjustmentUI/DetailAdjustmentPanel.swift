import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// Sharpening and noise reduction (design spec §6.3 "Detail" group). Every
/// row edits through `EditorSession.updateAdjustments(_:)`, since neither
/// `Sharpening` nor `NoiseReduction` has an `AdjustmentKind` case of its own.
public struct DetailAdjustmentPanel: View {
    @ObservedObject private var editor: EditorSession

    public init(editor: EditorSession) {
        self.editor = editor
    }

    public var body: some View {
        DisclosureGroup(L10n.t("Sharpening")) {
            AdjustmentSliderRow(
                label: L10n.t("Amount"), value: editor.adjustments.sharpening.amount,
                range: 0...150, fractionDigits: 0,
                onChange: { newValue in editor.updateAdjustments { $0.sharpening.amount = newValue } },
                onReset: { editor.updateAdjustments { $0.sharpening.amount = Sharpening.neutral.amount } }
            )
            AdjustmentSliderRow(
                label: L10n.t("Radius"), value: editor.adjustments.sharpening.radius,
                range: 0.5...3.0, fractionDigits: 1,
                onChange: { newValue in editor.updateAdjustments { $0.sharpening.radius = newValue } },
                onReset: { editor.updateAdjustments { $0.sharpening.radius = Sharpening.neutral.radius } }
            )
            AdjustmentSliderRow(
                label: L10n.t("Detail"), value: editor.adjustments.sharpening.detail,
                range: 0...100, fractionDigits: 0,
                onChange: { newValue in editor.updateAdjustments { $0.sharpening.detail = newValue } },
                onReset: { editor.updateAdjustments { $0.sharpening.detail = Sharpening.neutral.detail } }
            )
            AdjustmentSliderRow(
                label: L10n.t("Masking"), value: editor.adjustments.sharpening.masking,
                range: 0...100, fractionDigits: 0,
                onChange: { newValue in editor.updateAdjustments { $0.sharpening.masking = newValue } },
                onReset: { editor.updateAdjustments { $0.sharpening.masking = Sharpening.neutral.masking } }
            )
        }
        DisclosureGroup(L10n.t("Noise Reduction")) {
            DisclosureGroup(L10n.t("Luminance")) {
                AdjustmentSliderRow(
                    label: L10n.t("Amount"), value: editor.adjustments.noiseReduction.luminanceAmount,
                    range: 0...100, fractionDigits: 0,
                    onChange: { newValue in editor.updateAdjustments { $0.noiseReduction.luminanceAmount = newValue } },
                    onReset: { editor.updateAdjustments { $0.noiseReduction.luminanceAmount = NoiseReduction.neutral.luminanceAmount } }
                )
                AdjustmentSliderRow(
                    label: L10n.t("Detail"), value: editor.adjustments.noiseReduction.luminanceDetail,
                    range: 0...100, fractionDigits: 0,
                    onChange: { newValue in editor.updateAdjustments { $0.noiseReduction.luminanceDetail = newValue } },
                    onReset: { editor.updateAdjustments { $0.noiseReduction.luminanceDetail = NoiseReduction.neutral.luminanceDetail } }
                )
            }
            DisclosureGroup(L10n.t("Color")) {
                AdjustmentSliderRow(
                    label: L10n.t("Amount"), value: editor.adjustments.noiseReduction.colorAmount,
                    range: 0...100, fractionDigits: 0,
                    onChange: { newValue in editor.updateAdjustments { $0.noiseReduction.colorAmount = newValue } },
                    onReset: { editor.updateAdjustments { $0.noiseReduction.colorAmount = NoiseReduction.neutral.colorAmount } }
                )
                AdjustmentSliderRow(
                    label: L10n.t("Detail"), value: editor.adjustments.noiseReduction.colorDetail,
                    range: 0...100, fractionDigits: 0,
                    onChange: { newValue in editor.updateAdjustments { $0.noiseReduction.colorDetail = newValue } },
                    onReset: { editor.updateAdjustments { $0.noiseReduction.colorDetail = NoiseReduction.neutral.colorDetail } }
                )
            }
        }
    }
}
