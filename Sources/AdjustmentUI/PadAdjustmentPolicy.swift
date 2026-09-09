import Foundation

/// Pure validation and formatting rules shared by the iPad numeric controls.
/// Keeping this outside SwiftUI makes decimal parsing, clamping, and rounding
/// deterministic in tests and identical on macOS and iPadOS.
public enum PadAdjustmentPolicy {
    public static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }

    public static func parse(
        _ text: String,
        range: ClosedRange<Double>,
        fractionDigits: Int
    ) -> Double? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty, let value = Double(normalized), value.isFinite else {
            return nil
        }

        let scale = pow(10.0, Double(max(0, fractionDigits)))
        let rounded = (value * scale).rounded() / scale
        return clamp(rounded, to: range)
    }

    public static func formatted(_ value: Double, fractionDigits: Int) -> String {
        String(format: "%.*f", max(0, fractionDigits), value)
    }
}
