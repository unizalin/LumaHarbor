import Localization
import SwiftUI

/// A compact, keyboard-friendly numeric editor for one adjustment value.
/// Invalid input is never sent to the editor; committing it restores the last
/// valid value. Slider changes update the field once editing has ended so a
/// partially typed decimal is not destroyed mid-entry.
public struct AdjustmentValueInput: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let fractionDigits: Int
    private let step: Double
    private let label: String
    private let onReset: () -> Void
    @State private var text: String
    @State private var isEditing = false

    public init(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        fractionDigits: Int,
        step: Double = 0.1,
        onReset: @escaping () -> Void
    ) {
        self.label = label
        self._value = value
        self.range = range
        self.fractionDigits = fractionDigits
        self.step = step.isFinite && step > 0 ? step : 0.1
        self.onReset = onReset
        self._text = State(initialValue: PadAdjustmentPolicy.formatted(value.wrappedValue, fractionDigits: fractionDigits))
    }

    public var body: some View {
        HStack(spacing: 6) {
            stepButton(
                systemName: "minus",
                accessibilityKey: "Decrease",
                action: { adjust(by: -step) }
            )

            TextField(label, text: $text, onEditingChanged: { editing in
                isEditing = editing
                if !editing { commit() }
            }, onCommit: commit)
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.plain)
            .font(.body.monospacedDigit())
            .padding(.horizontal, 10)
            .frame(minWidth: 56, idealWidth: 72, maxWidth: 72, minHeight: 36, idealHeight: 36, maxHeight: 36)
            .background(
                Color.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            #if os(iOS)
            .keyboardType(.numbersAndPunctuation)
            #endif
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(text))

            stepButton(
                systemName: "plus",
                accessibilityKey: "Increase",
                action: { adjust(by: step) }
            )

            Button {
                onReset()
                text = PadAdjustmentPolicy.formatted(value, fractionDigits: fractionDigits)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(Text("\(label) \(L10n.t("Reset"))"))
        }
        .onChange(of: value) { _, newValue in
            guard !isEditing else { return }
            text = PadAdjustmentPolicy.formatted(newValue, fractionDigits: fractionDigits)
        }
    }

    private func commit() {
        guard let parsed = PadAdjustmentPolicy.parse(text, range: range, fractionDigits: fractionDigits) else {
            text = PadAdjustmentPolicy.formatted(value, fractionDigits: fractionDigits)
            return
        }
        value = parsed
        text = PadAdjustmentPolicy.formatted(parsed, fractionDigits: fractionDigits)
    }

    private func adjust(by delta: Double) {
        // Commit a partially typed value first, so a nudge always starts from
        // what the user sees instead of the last slider tick.
        if isEditing { commit() }
        let adjusted = PadAdjustmentPolicy.adjusted(
            value,
            by: delta,
            range: range,
            fractionDigits: fractionDigits
        )
        value = adjusted
        text = PadAdjustmentPolicy.formatted(adjusted, fractionDigits: fractionDigits)
    }

    @ViewBuilder
    private func stepButton(
        systemName: String,
        accessibilityKey: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(Text("\(L10n.t(accessibilityKey)) \(label)"))
        .help("\(L10n.t(accessibilityKey)) \(label)")
    }
}
