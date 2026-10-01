import Localization
import SwiftUI

/// Owns one native editing session. Updating the native buffer is synchronous
/// and independent of SwiftUI's deferred view reconciliation.
@MainActor
final class AdjustmentInputController: ObservableObject {
    private(set) var state: AdjustmentInputState
    private var binding: Binding<Double>
    private var unit: String
    private var readContext: (() -> (AnyHashable, UInt64))?
    var render: ((String, String?) -> Void)?

    init(value: Binding<Double>, range: ClosedRange<Double>, fractionDigits: Int,
         identity: AnyHashable, revision: UInt64, unit: String) {
        binding = value
        self.unit = unit
        state = AdjustmentInputState(value: value.wrappedValue, range: range,
            fractionDigits: fractionDigits, identity: identity, revision: revision)
    }

    func configure(value: Binding<Double>, range: ClosedRange<Double>, fractionDigits: Int,
                   identity: AnyHashable, revision: UInt64, unit: String,
                   readContext: (() -> (AnyHashable, UInt64))? = nil) {
        binding = value
        self.readContext = readContext
        self.unit = unit
        if state.range != range || state.fractionDigits != fractionDigits {
            state.range = range
            state.fractionDigits = fractionDigits
            state.cancel()
        }
        state.synchronize(value: value.wrappedValue, identity: identity, revision: revision)
        redraw()
    }

    func focus() { synchronize(); state.focus(); redraw() }
    func edit(_ text: String) { state.edit(text) }
    func submit() { synchronize(); commit(state.submit()) }
    func cancel() { synchronize(); state.cancel(); redraw() }
    func nudge(by delta: Double) { synchronize(); commit(state.nudge(by: delta)) }

    private func synchronize() {
        let context = readContext?() ?? (state.identity, state.revision)
        state.synchronize(value: binding.wrappedValue, identity: context.0, revision: context.1)
    }

    private func commit(_ value: Double?) {
        if let value { binding.wrappedValue = value }
        // The model is authoritative, including when it rejects or limits a write.
        synchronize()
        redraw()
    }

    private func redraw() {
        let message: String?
        if let error = state.error {
            let reason = error == .invalidNumber ? L10n.t("Enter a finite number.") : L10n.t("Value out of range.")
            let lower = PadAdjustmentPolicy.formatted(state.range.lowerBound, fractionDigits: state.fractionDigits)
            let upper = PadAdjustmentPolicy.formatted(state.range.upperBound, fractionDigits: state.fractionDigits)
            let limits = String(format: L10n.t("Allowed range: %@–%@ %@."), lower, upper, unit)
            message = reason + " " + limits
        } else { message = nil }
        render?(state.draft, message)
    }
}
