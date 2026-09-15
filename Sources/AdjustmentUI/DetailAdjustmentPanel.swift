import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// Sharpening and noise reduction (design spec §6.3 "Detail" group). Every
/// row edits through `EditorSession.updateAdjustments(_:)`, since neither
/// `Sharpening` nor `NoiseReduction` has an `AdjustmentKind` case of its own.
/// Drag previews through the shared continuous-edit transaction (inspector
/// hierarchy/preview spec §5.6) so a whole drag becomes exactly one Undo
/// entry, while the numeric field's nudge/typed entry keeps committing
/// immediately through `onChange`.
public struct DetailAdjustmentPanel: View {
    @ObservedObject private var editor: EditorSession

    public init(editor: EditorSession) {
        self.editor = editor
    }

    public var body: some View {
        Level2DisclosureGroup(L10n.t("Sharpening")) {
            row(L10n.t("Amount"), value: \.sharpening.amount, range: 0...150, reset: Sharpening.neutral.amount)
            row(L10n.t("Radius"), value: \.sharpening.radius, range: 0.5...3.0, reset: Sharpening.neutral.radius)
            row(L10n.t("Detail"), value: \.sharpening.detail, range: 0...100, reset: Sharpening.neutral.detail)
            row(L10n.t("Masking"), value: \.sharpening.masking, range: 0...100, reset: Sharpening.neutral.masking)
        }
        Level2DisclosureGroup(L10n.t("Noise Reduction")) {
            level3Heading(L10n.t("Luminance"))
            row(L10n.t("Amount"), value: \.noiseReduction.luminanceAmount, range: 0...100, reset: NoiseReduction.neutral.luminanceAmount)
            row(L10n.t("Detail"), value: \.noiseReduction.luminanceDetail, range: 0...100, reset: NoiseReduction.neutral.luminanceDetail)
            Divider().opacity(0.3)
            level3Heading(L10n.t("Color"))
            row(L10n.t("Amount"), value: \.noiseReduction.colorAmount, range: 0...100, reset: NoiseReduction.neutral.colorAmount)
            row(L10n.t("Detail"), value: \.noiseReduction.colorDetail, range: 0...100, reset: NoiseReduction.neutral.colorDetail)
        }
    }

    private func level3Heading(_ title: String) -> some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
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
