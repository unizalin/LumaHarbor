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
    /// The value to display -- the caller's live/previewed value, not
    /// necessarily the committed one, so the row reflects an in-progress
    /// drag (inspector hierarchy/preview spec §5.6).
    let value: Double
    let range: ClosedRange<Double>
    let fractionDigits: Int
    /// Fine-grained nudge and slider increment. All inspector controls use a
    /// tenth-step so the displayed one-decimal value is also the edit value.
    var step: Double = 0.1
    /// Writes an immediate, discrete commit -- used by the numeric field's
    /// nudge buttons and typed entry, where SwiftUI already reports exactly
    /// one call per user action (spec §5.6: "a single plus or minus click is
    /// one discrete commit").
    let onChange: (Double) -> Void
    let onReset: () -> Void
    /// Reports drag start (`true`) / drag end (`false`) -- distinct from
    /// `onChange`, which fires on every value tick during a drag. Phase 3
    /// Task 3.3: this is what a caller wires to
    /// `EditorSession.beginAdjustmentGesture()`/`.endAdjustmentGesture()`
    /// for batch sync. Defaults to a no-op so every existing caller keeps
    /// compiling unchanged.
    var onEditingChanged: (Bool) -> Void = { _ in }
    /// Continuous-drag preview write, called on every `Slider` tick.
    /// Defaults to `onChange` so a caller that has not migrated to the
    /// preview/commit transaction lifecycle keeps compiling and behaving
    /// exactly as before (each tick still its own commit). A migrated
    /// caller instead passes `EditorSession.previewContinuousEdit(_:)` here.
    var onPreview: ((Double) -> Void)?
    /// Fires once, after the final `onPreview` tick, when a slider drag ends
    /// -- wired to `EditorSession.commitContinuousEdit()` so a whole drag
    /// (however many ticks it reported) becomes exactly one Undo entry and
    /// one autosave (spec §5.6: "one gesture, one edit"). No-op by default.
    var onCommitPreview: () -> Void = {}

    var body: some View {
        AdaptiveRowContainer { composition in
            VStack(alignment: .leading, spacing: 4) {
                switch composition {
                case .inline:
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        titleText
                        Spacer(minLength: 8)
                        valueInput
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .stacked:
                    titleText
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Spacer(minLength: 0)
                        valueInput
                    }
                }
                slider
            }
        }
        .contextMenu {
            Button("\(L10n.t("Reset")) \(label)") { onReset() }
        }
    }

    private var titleText: some View {
        Text(label)
            // Long localized labels (for example Chromatic Aberration) must
            // wrap before they are replaced by an ellipsis. The adaptive row
            // already reserves a stacked composition below 340pt; allowing
            // two lines here also keeps the inline composition honest at its
            // wider boundary.
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .layoutPriority(1)
    }

    private var valueInput: some View {
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

    private var slider: some View {
        Slider(
                value: Binding(
                    get: { value },
                    set: { newValue in
                        let snapped = PadAdjustmentPolicy.snapped(
                            newValue,
                            step: step,
                            range: range,
                            fractionDigits: fractionDigits
                        )
                        (onPreview ?? onChange)(snapped)
                    }
                ),
                in: range,
                onEditingChanged: { isEditing in
                    // The preview must be committed to history *before* the
                    // gesture-end hook fires, so a batch-sync listener reads
                    // the just-committed final value rather than a stale
                    // pre-commit one (spec §5.6: "one gesture, one edit").
                    if !isEditing {
                        onCommitPreview()
                    }
                    onEditingChanged(isEditing)
                }
        )
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(BasicAdjustmentPanelModel.formatted(value, fractionDigits: fractionDigits)))
    }
}
