import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// The eight-band HSL editor (design spec §6.3 "Color" group). Every band
/// clamps hue/saturation/luminance to the same -100...100 span
/// (`HSLBand`'s own `clamp`), so all 24 rows share one range/format.
/// Kelvin white balance and tint already live in `BasicAdjustmentPanel`
/// (spec lists them under "Color" too, but they are two of the ten
/// `AdjustmentKind` sliders `BasicAdjustmentPanel` already covers end to
/// end -- including its own locked reset-gesture contract -- so they are
/// left there rather than duplicated here under a second panel).
public struct ColorAdjustmentPanel: View {
    @ObservedObject private var editor: EditorSession

    public init(editor: EditorSession) {
        self.editor = editor
    }

    private static let bands: [(keyPath: WritableKeyPath<HSLAdjustments, HSLBand>, labelKey: String)] = [
        (\.red, "Red"), (\.orange, "Orange"), (\.yellow, "Yellow"), (\.green, "Green"),
        (\.aqua, "Aqua"), (\.blue, "Blue"), (\.purple, "Purple"), (\.magenta, "Magenta")
    ]

    public var body: some View {
        ForEach(Array(Self.bands.enumerated()), id: \.offset) { _, band in
            DisclosureGroup(L10n.t(band.labelKey)) {
                bandRow(band.keyPath, fieldKey: "Hue") { $0.hue }
                bandRow(band.keyPath, fieldKey: "Saturation") { $0.saturation }
                bandRow(band.keyPath, fieldKey: "Luminance") { $0.luminance }
            }
        }
    }

    private func bandRow(
        _ keyPath: WritableKeyPath<HSLAdjustments, HSLBand>,
        fieldKey: String,
        _ field: @escaping (HSLBand) -> Double
    ) -> some View {
        AdjustmentSliderRow(
            label: L10n.t(fieldKey),
            value: field(editor.adjustments.hsl[keyPath: keyPath]),
            range: -100...100,
            fractionDigits: 0,
            onChange: { newValue in
                editor.updateAdjustments { adjustments in
                    Self.set(fieldKey, on: &adjustments.hsl[keyPath: keyPath], to: newValue)
                }
            },
            onReset: {
                editor.updateAdjustments { adjustments in
                    Self.set(fieldKey, on: &adjustments.hsl[keyPath: keyPath], to: 0)
                }
            }
        )
    }

    private static func set(_ fieldKey: String, on band: inout HSLBand, to value: Double) {
        switch fieldKey {
        case "Hue": band.hue = value
        case "Saturation": band.saturation = value
        case "Luminance": band.luminance = value
        default: break
        }
    }
}
