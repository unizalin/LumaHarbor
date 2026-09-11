import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// Shadows/Midtones/Highlights/Global three-zone colour grading (P4, design
/// spec §6.3), plus Balance and Blending. Slider-based, same convention as
/// every other non-`AdjustmentKind` group panel (`EffectsAdjustmentPanel`,
/// `ColorAdjustmentPanel`) -- Split Toning, this feature's simpler
/// predecessor, has no dedicated colour-wheel UI either.
public struct ColorGradingAdjustmentPanel: View {
    @ObservedObject private var editor: EditorSession

    public init(editor: EditorSession) {
        self.editor = editor
    }

    private static let zones: [(keyPath: WritableKeyPath<ColorGradingAdjustments, ColorGradeBand>, labelKey: String)] = [
        (\.shadows, "Shadows"), (\.midtones, "Midtones"), (\.highlights, "Highlights"), (\.global, "Global")
    ]

    public var body: some View {
        ForEach(Array(Self.zones.enumerated()), id: \.offset) { _, zone in
            DisclosureGroup(L10n.t(zone.labelKey)) {
                zoneRow(zone.keyPath, fieldKey: "Hue", range: 0...360) { $0.hue }
                zoneRow(zone.keyPath, fieldKey: "Saturation", range: 0...100) { $0.saturation }
                zoneRow(zone.keyPath, fieldKey: "Luminance", range: -100...100) { $0.luminance }
            }
        }
        AdjustmentSliderRow(
            label: L10n.t("Balance"), value: editor.adjustments.colorGrading.balance,
            range: -100...100, fractionDigits: 0,
            onChange: { newValue in editor.updateAdjustments { $0.colorGrading.balance = newValue } },
            onReset: { editor.updateAdjustments { $0.colorGrading.balance = ColorGradingAdjustments.neutral.balance } }
        )
        AdjustmentSliderRow(
            label: L10n.t("Blending"), value: editor.adjustments.colorGrading.blending,
            range: 0...100, fractionDigits: 0,
            onChange: { newValue in editor.updateAdjustments { $0.colorGrading.blending = newValue } },
            onReset: { editor.updateAdjustments { $0.colorGrading.blending = ColorGradingAdjustments.neutral.blending } }
        )
    }

    private func zoneRow(
        _ keyPath: WritableKeyPath<ColorGradingAdjustments, ColorGradeBand>,
        fieldKey: String,
        range: ClosedRange<Double>,
        _ field: @escaping (ColorGradeBand) -> Double
    ) -> some View {
        AdjustmentSliderRow(
            label: L10n.t(fieldKey),
            value: field(editor.adjustments.colorGrading[keyPath: keyPath]),
            range: range,
            fractionDigits: 0,
            onChange: { newValue in
                editor.updateAdjustments { adjustments in
                    Self.set(fieldKey, on: &adjustments.colorGrading[keyPath: keyPath], to: newValue)
                }
            },
            onReset: {
                editor.updateAdjustments { adjustments in
                    Self.set(fieldKey, on: &adjustments.colorGrading[keyPath: keyPath], to: 0)
                }
            }
        )
    }

    private static func set(_ fieldKey: String, on band: inout ColorGradeBand, to value: Double) {
        switch fieldKey {
        case "Hue": band.hue = value
        case "Saturation": band.saturation = value
        case "Luminance": band.luminance = value
        default: break
        }
    }
}
