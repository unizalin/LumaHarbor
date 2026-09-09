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
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 64, idealWidth: 72)
            #if os(iOS)
            .keyboardType(.numbersAndPunctuation)
            #endif
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(text))

            Button {
                onReset()
                text = PadAdjustmentPolicy.formatted(value, fractionDigits: fractionDigits)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
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
