import Localization
import SwiftUI

/// Shared layout around a native numeric field. Draft ownership and event
/// ordering live in AdjustmentInputState, not deferred SwiftUI onChange hooks.
@MainActor
public struct AdjustmentValueInput: View {
    @Binding private var value: Double
    @Environment(\.adjustmentEditingContext) private var editingContext
    private let range: ClosedRange<Double>
    private let fractionDigits: Int
    private let step: Double
    private let label: String
    private let identity: AnyHashable
    private let revision: UInt64
    private let unit: String
    private let onReset: () -> Void
    @StateObject private var controller: AdjustmentInputController

    public init(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        fractionDigits: Int,
        step: Double = 0.1,
        onReset: @escaping () -> Void,
        identity: AnyHashable = AnyHashable("default"),
        revision: UInt64 = 0,
        unit: String = ""
    ) {
        self.label = label
        self._value = value
        self.range = range
        self.fractionDigits = fractionDigits
        self.step = step.isFinite && step > 0 ? step : 0.1
        self.onReset = onReset
        self.identity = identity
        self.revision = revision
        self.unit = unit
        self._controller = StateObject(wrappedValue: AdjustmentInputController(
            value: value, range: range, fractionDigits: fractionDigits,
            identity: identity, revision: revision, unit: unit))
    }

    public var body: some View {
        HStack(spacing: AdjustmentControlMetrics.actionSpacing) {
            #if os(iOS)
            stepButton(systemName: "minus", accessibilityKey: "Decrease", delta: -step)
            #endif

            AdjustmentNativeTextField(controller: controller, label: label, value: $value,
                range: range, fractionDigits: fractionDigits, identity: identity,
                revision: currentContext().1, unit: unit, readContext: contextReader)
                .padding(.horizontal, 10)
                .frame(width: AdjustmentControlMetrics.numericFieldWidth)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            #if os(iOS)
            stepButton(systemName: "plus", accessibilityKey: "Increase", delta: step)
            #endif

            Button {
                controller.cancel()
                onReset()
                configureController()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: AdjustmentControlMetrics.resetVisualDiameter,
                           height: AdjustmentControlMetrics.resetVisualDiameter)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .frame(width: AdjustmentControlMetrics.resetHitTarget,
                   height: AdjustmentControlMetrics.resetHitTarget)
            .contentShape(Rectangle())
            .accessibilityLabel(Text("\(label) \(L10n.t("Reset"))"))
        }
        #if os(macOS)
        .accessibilityAdjustableAction { direction in
            configureController()
            switch direction {
            case .increment: controller.nudge(by: step)
            case .decrement: controller.nudge(by: -step)
            @unknown default: break
            }
        }
        #endif
    }

    private func configureController() {
        controller.configure(value: $value, range: range, fractionDigits: fractionDigits,
            identity: currentContext().0, revision: currentContext().1, unit: unit,
            readContext: contextReader)
    }

    private func currentContext() -> (AnyHashable, UInt64) {
        contextReader()
    }

    private var contextReader: () -> (AnyHashable, UInt64) {
        // The controller retains this reader. Capture only the context inputs,
        // not the entire View containing its own StateObject controller.
        let identity = identity
        let label = label
        let revision = revision
        let context = editingContext
        return {
            (AnyHashable([identity, AnyHashable(label), AnyHashable(context.identity())]),
             revision &+ context.revision())
        }
    }

    private func stepButton(systemName: String, accessibilityKey: String, delta: Double) -> some View {
        Button {
            configureController()
            controller.nudge(by: delta)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: AdjustmentControlMetrics.nudgeVisualDiameter,
                       height: AdjustmentControlMetrics.nudgeVisualDiameter)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(width: AdjustmentControlMetrics.nudgeHitTarget,
               height: AdjustmentControlMetrics.nudgeHitTarget)
        .contentShape(Rectangle())
        .accessibilityLabel(Text("\(L10n.t(accessibilityKey)) \(label)"))
        .help("\(L10n.t(accessibilityKey)) \(label)")
    }
}
