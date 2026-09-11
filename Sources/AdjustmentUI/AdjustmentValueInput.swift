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
    private let label: String
    private let onReset: () -> Void
    @State private var text: String
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    public init(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        fractionDigits: Int,
        onReset: @escaping () -> Void
    ) {
        self.label = label
        self._value = value
        self.range = range
        self.fractionDigits = fractionDigits
        self.onReset = onReset
        self._text = State(initialValue: PadAdjustmentPolicy.formatted(value.wrappedValue, fractionDigits: fractionDigits))
    }

    public var body: some View {
        HStack(spacing: 6) {
            TextField(label, text: $text, onEditingChanged: { editing in
                isEditing = editing
                if !editing { commit() }
            }, onCommit: commit)
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.plain)
            .font(.body.monospacedDigit())
            .padding(.horizontal, 10)
            .frame(width: 88, height: 36)
            .background(
                Color.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    // Focus is shown by a *thicker* ring, not just a color
                    // change, so it does not depend on color perception
                    // (spec §4.2: "焦點狀態不可只靠顏色").
                    .stroke(
                        isFocused ? Color.accentColor : Color.primary.opacity(0.14),
                        lineWidth: isFocused ? 2 : 1
                    )
            )
            #if os(iOS)
            .keyboardType(.numbersAndPunctuation)
            #endif
            .focused($isFocused)
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(text))

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
            // The visible circle stays 30pt, but the tappable/touchable
            // region is the full 44×44 pt minimum (spec §4.2), so the
            // reset control is reliably hittable without inflating the
            // row's visual weight.
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
}
