import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// The eight-band HSL editor (design spec §6.3 "Color" group), presented as
/// one adaptive color-band selector plus a single active band editor
/// (inspector hierarchy/typography spec §5.2) rather than eight nested
/// `DisclosureGroup`s. Selecting a band is pure UI state -- it never
/// renders, writes history, or touches the sidecar. Kelvin white balance and
/// tint already live in `BasicAdjustmentPanel` (spec lists them under
/// "Color" too, but they are two of the ten `AdjustmentKind` sliders
/// `BasicAdjustmentPanel` already covers end to end), so they are left there
/// rather than duplicated here under a second panel.
public struct ColorAdjustmentPanel: View {
    @ObservedObject private var editor: EditorSession
    @State private var selectedBand: HSLBandID = .red
    @State private var selectedMonochromeBand: HSLBandID = .red

    public init(editor: EditorSession) {
        self.editor = editor
    }

    public var body: some View {
        Level2DisclosureGroup(L10n.t("HSL"), initiallyExpanded: true) {
            HSLBandGridSelector(
                selection: $selectedBand,
                isModified: { HSLBandSelectorModel.isModified($0, in: editor.adjustments.hsl) }
            )
            bandEditor(selectedBand)
        }

        Level2Section(L10n.t("Black & White"), trailing: {
            Toggle("", isOn: monochromeEnabledBinding)
                .labelsHidden()
        }) {
            if editor.adjustments.monochrome.isEnabled {
                HSLBandGridSelector(
                    selection: $selectedMonochromeBand,
                    isModified: { editor.adjustments.monochrome[keyPath: $0.monochromeKeyPath] != 0 }
                )
                monochromeRow(selectedMonochromeBand)
            }
        }
    }

    private var monochromeEnabledBinding: Binding<Bool> {
        Binding(
            get: { editor.adjustments.monochrome.isEnabled },
            set: { newValue in editor.updateAdjustments { $0.monochrome.isEnabled = newValue } }
        )
    }

    /// The selected band's Hue/Saturation/Luminance rows -- Level 3 controls
    /// under the Level 2 "HSL" subsection, headed by the band's own swatch
    /// and full name (spec §5.1's hierarchy table).
    private func bandEditor(_ band: HSLBandID) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(band.displayColor)
                    .frame(width: 10, height: 10)
                Text(L10n.t(band.labelKey))
                    .font(.callout.weight(.semibold))
            }
            bandFieldRow(band, fieldKey: "Hue") { $0.hue }
            bandFieldRow(band, fieldKey: "Saturation") { $0.saturation }
            bandFieldRow(band, fieldKey: "Luminance") { $0.luminance }
        }
    }

    private func bandFieldRow(
        _ band: HSLBandID,
        fieldKey: String,
        _ field: @escaping (HSLBand) -> Double
    ) -> some View {
        let keyPath = band.keyPath
        return AdjustmentSliderRow(
            label: L10n.t(fieldKey),
            value: field(editor.displayedAdjustments.hsl[keyPath: keyPath]),
            range: -100...100,
            fractionDigits: 1,
            onChange: { newValue in
                editor.updateAdjustments { adjustments in
                    Self.set(fieldKey, on: &adjustments.hsl[keyPath: keyPath], to: newValue)
                }
            },
            onReset: {
                editor.updateAdjustments { adjustments in
                    Self.set(fieldKey, on: &adjustments.hsl[keyPath: keyPath], to: 0)
                }
            },
            onPreview: { newValue in
                editor.previewContinuousEdit { adjustments in
                    Self.set(fieldKey, on: &adjustments.hsl[keyPath: keyPath], to: newValue)
                }
            },
            onCommitPreview: { editor.commitContinuousEdit() }
        )
    }

    private func monochromeRow(_ band: HSLBandID) -> some View {
        let keyPath = band.monochromeKeyPath
        return AdjustmentSliderRow(
            label: L10n.t(band.labelKey),
            value: editor.displayedAdjustments.monochrome[keyPath: keyPath],
            range: -100...100, fractionDigits: 1,
            onChange: { newValue in
                editor.updateAdjustments { $0.monochrome[keyPath: keyPath] = newValue }
            },
            onReset: { editor.updateAdjustments { $0.monochrome[keyPath: keyPath] = 0 } },
            onPreview: { newValue in
                editor.previewContinuousEdit { $0.monochrome[keyPath: keyPath] = newValue }
            },
            onCommitPreview: { editor.commitContinuousEdit() }
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

extension HSLBandID {
    /// The matching field in the black-and-white mixer -- same eight color
    /// identities, one slider each instead of HSL's three.
    var monochromeKeyPath: WritableKeyPath<MonochromeAdjustments, Double> {
        switch self {
        case .red: return \.red
        case .orange: return \.orange
        case .yellow: return \.yellow
        case .green: return \.green
        case .aqua: return \.aqua
        case .blue: return \.blue
        case .purple: return \.purple
        case .magenta: return \.magenta
        }
    }
}
