import Localization
import SwiftUI

/// A labeled slider row for one sub-struct field (HSL band, sharpening
/// amount, vignette feather, ...) -- the same macOS reset affordances
/// `BasicAdjustmentPanel` established for the ten basic sliders (double-click
/// the row, or a context-menu "Reset <label>" item), reused here so every
/// grouped panel (Color/Detail/Effects) gets identical reset semantics
/// instead of each one inventing its own.
struct AdjustmentSliderRow: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let fractionDigits: Int
    /// Fine-grained nudge and slider increment. All inspector controls use a
    /// tenth-step so the displayed one-decimal value is also the edit value.
    var step: Double = 0.1
    let onChange: (Double) -> Void
    let onReset: () -> Void
    /// Reports drag start (`true`) / drag end (`false`) -- distinct from
    /// `onChange`, which fires on every value tick during a drag. Phase 3
    /// Task 3.3: this is what a caller wires to
    /// `EditorSession.beginAdjustmentGesture()`/`.endAdjustmentGesture()`
    /// for batch sync. Defaults to a no-op so every existing caller keeps
    /// compiling unchanged.
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        macOSResetGesture(
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    AdjustmentValueInput(
                        label: label,
                        value: .init(get: { value }, set: onChange),
                        range: range,
                        fractionDigits: fractionDigits,
                        step: step,
                        onReset: onReset
                    )
                    .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Slider(
                    value: Binding(get: { value }, set: onChange),
                    in: range,
                    step: step,
                    onEditingChanged: onEditingChanged
                )
                    .accessibilityLabel(Text(label))
                    .accessibilityValue(Text(BasicAdjustmentPanelModel.formatted(value, fractionDigits: fractionDigits)))
            }
            .contextMenu {
                Button("\(L10n.t("Reset")) \(label)") { onReset() }
            }
        )
    }

    private func macOSResetGesture<Content: View>(_ content: Content) -> some View {
        #if os(macOS)
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onReset() }
            .help(L10n.t("Double-click the row to reset"))
        #else
        content
        #endif
    }
}
