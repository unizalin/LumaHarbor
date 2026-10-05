import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// The ten basic adjustments, usable in a Mac inspector or an iPad editing surface.
public struct BasicAdjustmentPanel: View {
    @ObservedObject private var editor: EditorSession
    private let kinds: [AdjustmentKind]

    public init(editor: EditorSession, kinds: [AdjustmentKind]? = nil) {
        self.editor = editor
        self.kinds = kinds ?? AdjustmentCatalog.ordered.map(\.kind)
    }

    public var body: some View {
        ForEach(BasicAdjustmentPanelModel.rows, id: \.kind) { definition in
            if kinds.contains(definition.kind) {
                if definition.kind == .temperature {
                    if let baseline = editor.whiteBalanceBaseline?.temperatureKelvin,
                       WhiteBalancePresentation.isValidBaseline(baseline) {
                        temperatureRow(definition, baselineKelvin: baseline)
                    } else {
                        Text(BasicAdjustmentPanelModel.unavailableWhiteBalanceMessage(
                            for: editor.whiteBalanceCapability
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    row(definition)
                }
            }
        }
        .adjustmentEditingContext(editor)
    }

    /// Built on the shared `AdjustmentSliderRow` (inspector hierarchy/preview
    /// spec §5.6, §5.4): the numeric field's nudge/typed entry stays a
    /// discrete, immediate commit via `setAdjustment(_:to:)`, while the
    /// slider drag previews through `previewContinuousEdit`/
    /// `commitContinuousEdit` so a whole drag becomes exactly one Undo entry
    /// and one autosave, and the row adopts the same adaptive width
    /// composition every other continuous control uses.
    private func row(_ definition: AdjustmentDefinition) -> some View {
        AdjustmentSliderRow(
            label: definition.kind.displayName,
            value: editor.displayedAdjustments[definition.kind],
            range: definition.range,
            fractionDigits: definition.fractionDigits,
            step: definition.step,
            onChange: { editor.setAdjustment(definition.kind, to: $0) },
            onReset: { editor.resetAdjustment(definition.kind) },
            onEditingChanged: { isEditing in
                if isEditing {
                    editor.beginAdjustmentGesture()
                } else {
                    editor.endAdjustmentGesture()
                }
            },
            onPreview: { newValue in
                editor.previewContinuousEdit { $0[definition.kind] = newValue }
            },
            onCommitPreview: { editor.commitContinuousEdit() }
        )
    }

    /// Temperature is shown as absolute Kelvin while persistence continues to
    /// use the decoder-relative stored offset. The shared resolver supplies the
    /// per-photo legal range and prevents a missing baseline from fabricating a
    /// value during a typed edit.
    private func temperatureRow(
        _ definition: AdjustmentDefinition,
        baselineKelvin: Double
    ) -> some View {
        let kelvinBinding = Binding<Double>(
            get: {
                WhiteBalancePresentation.kelvinIfResolvable(
                    forStoredOffset: editor.displayedAdjustments.temperature,
                    baselineKelvin: baselineKelvin
                ) ?? baselineKelvin
            },
            set: { kelvin in
                guard let stored = WhiteBalancePresentation.storedOffsetIfResolvable(
                    forKelvin: kelvin,
                    baselineKelvin: baselineKelvin
                ) else { return }
                editor.setAdjustment(.temperature, to: stored)
            }
        )
        let sliderBinding = Binding<Double>(
            get: { WhiteBalancePresentation.sliderValue(forKelvin: kelvinBinding.wrappedValue) },
            set: { value in
                let kelvin = WhiteBalancePresentation.kelvin(forSliderValue: value)
                guard let stored = WhiteBalancePresentation.storedOffsetIfResolvable(
                    forKelvin: kelvin,
                    baselineKelvin: baselineKelvin
                ) else { return }
                editor.previewContinuousEdit { $0.temperature = stored }
            }
        )
        let sliderRange = WhiteBalancePresentation.sliderRange(baselineKelvin: baselineKelvin)

        return AdaptiveRowContainer { composition in
            VStack(alignment: .leading, spacing: 4) {
                switch composition {
                case .inline:
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(definition.kind.displayName)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                        Spacer(minLength: 8)
                        AdjustmentValueInput(
                            label: "\(definition.kind.displayName) (K)", value: kelvinBinding,
                            range: WhiteBalancePresentation.minimumKelvin...WhiteBalancePresentation.maximumKelvin,
                            fractionDigits: 0, step: 50,
                            onReset: { editor.resetAdjustment(.temperature) },
                            identity: AnyHashable(editor.photo?.id.rawValue.uuidString ?? ""),
                            revision: editor.adjustmentRevision, unit: "K"
                        )
                    }
                case .stacked:
                    HStack {
                        Text(definition.kind.displayName)
                        Spacer(minLength: 0)
                        AdjustmentValueInput(
                            label: "\(definition.kind.displayName) (K)", value: kelvinBinding,
                            range: WhiteBalancePresentation.minimumKelvin...WhiteBalancePresentation.maximumKelvin,
                            fractionDigits: 0, step: 50,
                            onReset: { editor.resetAdjustment(.temperature) },
                            identity: AnyHashable(editor.photo?.id.rawValue.uuidString ?? ""),
                            revision: editor.adjustmentRevision, unit: "K"
                        )
                    }
                }
                Slider(
                    value: sliderBinding,
                    in: sliderRange,
                    onEditingChanged: { editing in
                        if editing { editor.beginAdjustmentGesture() }
                        else { editor.commitContinuousEdit(); editor.endAdjustmentGesture() }
                    }
                )
                .accessibilityLabel(Text(definition.kind.displayName))
                .accessibilityValue(Text("\(Int(kelvinBinding.wrappedValue.rounded())) K"))
            }
        }
        .contextMenu {
            Button("\(L10n.t("Reset")) \(definition.kind.displayName)") {
                editor.resetAdjustment(.temperature)
            }
        }
    }

}
