import Foundation

/// Editing events, not formatted-string comparisons, determine whether a
/// draft can be committed. Native controls and pure tests share this state.
struct AdjustmentInputState {
    enum ValidationError: Equatable { case invalidNumber, outOfRange }
    private(set) var value: Double
    private(set) var identity: AnyHashable
    private(set) var revision: UInt64
    private(set) var draft: String
    private(set) var startingText: String = ""
    private(set) var isEditing = false
    private(set) var error: ValidationError?
    var range: ClosedRange<Double>
    var fractionDigits: Int

    init(value: Double, range: ClosedRange<Double>, fractionDigits: Int, identity: AnyHashable, revision: UInt64) {
        self.value = value
        self.range = range
        self.fractionDigits = fractionDigits
        self.identity = identity
        self.revision = revision
        self.draft = PadAdjustmentPolicy.formatted(value, fractionDigits: fractionDigits)
    }

    mutating func focus() {
        isEditing = true
        startingText = String(value)
        draft = startingText
    }

    mutating func edit(_ text: String) {
        if !isEditing { focus() }
        draft = text
    }

    mutating func synchronize(value: Double, identity: AnyHashable, revision: UInt64) {
        guard self.value != value || self.identity != identity || self.revision != revision else { return }
        self.value = value
        self.identity = identity
        self.revision = revision
        cancel()
    }

    mutating func cancel() {
        isEditing = false
        error = nil
        draft = PadAdjustmentPolicy.formatted(value, fractionDigits: fractionDigits)
    }

    mutating func submit() -> Double? {
        guard isEditing else { return nil }
        isEditing = false // Terminal before parsing, including rejection.
        let submitted = draft
        draft = PadAdjustmentPolicy.formatted(value, fractionDigits: fractionDigits)
        guard submitted != startingText else { return nil }
        let normalized = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let parsed = Double(normalized), parsed.isFinite else {
            error = .invalidNumber
            return nil
        }
        guard range.contains(parsed) else { error = .outOfRange; return nil }
        return accept(parsed)
    }

    mutating func nudge(by delta: Double) -> Double? {
        let base = isEditing ? (PadAdjustmentPolicy.parseExact(draft, range: range) ?? value) : value
        guard base.isFinite, delta.isFinite else { cancel(); return nil }
        return accept(min(max(base + delta, range.lowerBound), range.upperBound))
    }

    private mutating func accept(_ candidate: Double) -> Double? {
        let changed = candidate != value
        value = candidate
        cancel()
        return changed ? candidate : nil
    }
}
