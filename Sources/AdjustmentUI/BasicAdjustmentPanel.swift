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
                        let message = BasicAdjustmentPanelModel.unavailableWhiteBalanceMessage(
                            for: editor.whiteBalanceCapability
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(Text(message))
                        }
                    }
                } else {
                    row(definition)
                }
            }
        }
        .adjustmentEditingContext(editor)
    }

    private func row(_ definition: AdjustmentDefinition) -> some View {
        let valueBinding = Binding(
            get: { editor.adjustments[definition.kind] },
            set: { editor.setAdjustment(definition.kind, to: $0) }
        )

        return macOSResetGesture(
            Group {
                #if os(macOS)
                HStack(alignment: .center, spacing: 8) {
                    Text(definition.kind.displayName)
                        .lineLimit(1)
                        .frame(minWidth: 92, alignment: .leading)
                    slider(for: definition, binding: valueBinding)
                    AdjustmentValueInput(
                        label: definition.kind.displayName,
                        value: valueBinding,
                        range: definition.range,
                        fractionDigits: definition.fractionDigits,
                        step: definition.step,
                        onReset: { editor.resetAdjustment(definition.kind) },
                        identity: AnyHashable(editor.photo?.id.rawValue.uuidString ?? "")
                    )
                }
                #else
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(definition.kind.displayName)
                        Spacer()
                        AdjustmentValueInput(
                            label: definition.kind.displayName,
                            value: valueBinding,
                            range: definition.range,
                        fractionDigits: definition.fractionDigits,
                        step: definition.step,
                        onReset: { editor.resetAdjustment(definition.kind) },
                        identity: AnyHashable(editor.photo?.id.rawValue.uuidString ?? "")
                        )
                    }
                    slider(for: definition, binding: valueBinding)
                }
                #endif
            }
            .contextMenu {
                Button("\(L10n.t("Reset")) \(definition.kind.displayName)") {
                    editor.resetAdjustment(definition.kind)
                }
            },
            definition: definition
        )
    }

    private func slider(
        for definition: AdjustmentDefinition,
        binding: Binding<Double>
    ) -> some View {
        Slider(
            value: binding,
            in: definition.range,
            step: definition.step,
            onEditingChanged: { isEditing in
                if isEditing {
                    editor.beginAdjustmentGesture()
                } else {
                    editor.endAdjustmentGesture()
                }
            }
        )
        .accessibilityLabel(Text(definition.kind.displayName))
        .accessibilityValue(Text(BasicAdjustmentPanelModel.formatted(
            editor.adjustments[definition.kind],
            fractionDigits: definition.fractionDigits
        )))
    }

    /// RAW temperature follows Lightroom's absolute Kelvin presentation. The
    /// sidecar still stores a baseline-relative offset, so this row is the one
    /// intentional exception to the generic signed-value input used by the
    /// other nine basic controls.
    private func temperatureRow(
        _ definition: AdjustmentDefinition,
        baselineKelvin: Double
    ) -> some View {
        let kelvinBinding = Binding<Double>(
            get: {
                WhiteBalancePresentation.kelvinIfResolvable(
                    forStoredOffset: editor.adjustments.temperature,
                    baselineKelvin: baselineKelvin
                ) ?? baselineKelvin
            },
            set: { kelvin in
                guard let storedOffset = WhiteBalancePresentation.storedOffsetIfResolvable(
                    forKelvin: kelvin,
                    baselineKelvin: baselineKelvin
                ) else { return }
                editor.setAdjustment(.temperature, to: storedOffset)
            }
        )
        let sliderBinding = Binding<Double>(
            get: {
                WhiteBalancePresentation.sliderValue(forKelvin: kelvinBinding.wrappedValue)
            },
            set: { sliderValue in
                kelvinBinding.wrappedValue = WhiteBalancePresentation.kelvin(forSliderValue: sliderValue)
            }
        )

        let content = Group {
            if editor.whiteBalanceDiagnostic == .clamped {
                Text(L10n.t("The temperature adjustment limit has been reached."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(L10n.t("The temperature adjustment limit has been reached.")))
            }
            temperatureControls(
                definition,
                kelvinBinding: kelvinBinding,
                sliderBinding: sliderBinding,
                baselineKelvin: baselineKelvin
            )
        }

        return macOSResetGesture(
            content
            .contextMenu {
                Button("\(L10n.t("Reset")) \(definition.kind.displayName)") {
                    editor.resetAdjustment(.temperature)
                }
            },
            definition: definition
        )
    }

    @ViewBuilder
    private func temperatureControls(
        _ definition: AdjustmentDefinition,
        kelvinBinding: Binding<Double>,
        sliderBinding: Binding<Double>,
        baselineKelvin: Double
    ) -> some View {
        #if os(macOS)
        HStack(alignment: .center, spacing: 8) {
            Text(definition.kind.displayName)
                .lineLimit(1)
                .frame(minWidth: 92, alignment: .leading)
            temperatureSlider(
                sliderBinding,
                label: definition.kind.displayName,
                displayedKelvin: kelvinBinding.wrappedValue,
                range: WhiteBalancePresentation.sliderRange(baselineKelvin: baselineKelvin)
            )
            AdjustmentValueInput(
                label: "\(definition.kind.displayName) (K)",
                value: kelvinBinding,
                range: WhiteBalancePresentation.minimumKelvin...WhiteBalancePresentation.maximumKelvin,
                fractionDigits: 0,
                step: 50,
                onReset: { editor.resetAdjustment(.temperature) },
                identity: AnyHashable(editor.photo?.id.rawValue.uuidString ?? ""),
                unit: "K"
            )
        }
        #else
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(definition.kind.displayName)
                Spacer()
                AdjustmentValueInput(
                    label: "\(definition.kind.displayName) (K)",
                    value: kelvinBinding,
                    range: WhiteBalancePresentation.minimumKelvin...WhiteBalancePresentation.maximumKelvin,
                    fractionDigits: 0,
                    step: 50,
                    onReset: { editor.resetAdjustment(.temperature) },
                    identity: AnyHashable(editor.photo?.id.rawValue.uuidString ?? ""),
                    unit: "K"
                )
            }
            temperatureSlider(
                sliderBinding,
                label: definition.kind.displayName,
                displayedKelvin: kelvinBinding.wrappedValue,
                range: WhiteBalancePresentation.sliderRange(baselineKelvin: baselineKelvin)
            )
        }
        #endif
    }

    private func temperatureSlider(
        _ binding: Binding<Double>,
        label: String,
        displayedKelvin: Double,
        range: ClosedRange<Double>
    ) -> some View {
        Slider(
            value: binding,
            in: range,
            step: 1,
            onEditingChanged: { isEditing in
                if isEditing {
                    editor.beginAdjustmentGesture()
                } else {
                    editor.endAdjustmentGesture()
                }
            }
        )
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text("\(Int(displayedKelvin.rounded())) K"))
    }

    private func macOSResetGesture<Content: View>(
        _ content: Content,
        definition: AdjustmentDefinition
    ) -> some View {
        #if os(macOS)
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                editor.resetAdjustment(definition.kind)
            }
            .help(L10n.t("Double-click the row to reset"))
        #else
        content
        #endif
    }
}
