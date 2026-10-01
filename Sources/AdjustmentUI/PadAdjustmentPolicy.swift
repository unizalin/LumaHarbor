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
        guard range.contains(value) else {
            return nil
        }

        let scale = pow(10.0, Double(max(0, fractionDigits)))
        let rounded = (value * scale).rounded() / scale
        guard range.contains(rounded) else {
            return nil
        }
        return rounded
    }

    /// Parses a submitted value without applying display-only rounding.
    /// The inspector may show fewer digits when idle, but a valid edit must
    /// not silently quantize the stored value to that presentation precision.
    public static func parseExact(
        _ text: String,
        range: ClosedRange<Double>
    ) -> Double? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty, let value = Double(normalized), value.isFinite else {
            return nil
        }
        return range.contains(value) ? value : nil
    }

    public static func formatted(_ value: Double, fractionDigits: Int) -> String {
        String(format: "%.*f", max(0, fractionDigits), value)
    }

    /// Applies a small, deterministic nudge while respecting the editor's
    /// range and the precision shown in the inspector.
    public static func adjusted(
        _ value: Double,
        by delta: Double,
        range: ClosedRange<Double>,
        fractionDigits: Int
    ) -> Double {
        guard delta.isFinite else { return clamp(value, to: range) }
        let candidate = clamp(value + delta, to: range)
        let scale = pow(10.0, Double(max(0, fractionDigits)))
        let rounded = (candidate * scale).rounded() / scale
        // Avoid exposing a signed zero after a decrement crosses zero.
        return clamp(rounded == 0 ? 0 : rounded, to: range)
    }

    /// Nudge from the exact value currently in the field.  Display rounding
    /// belongs to the idle formatter; applying it here would make a precise
    /// typed value jump before the user has asked for a rounded presentation.
    public static func adjustedExact(
        _ value: Double,
        by delta: Double,
        range: ClosedRange<Double>,
        fractionDigits: Int
    ) -> Double {
        guard delta.isFinite else { return clamp(value, to: range) }
        let candidate = clamp(value + delta, to: range)
        return candidate == 0 ? 0 : candidate
    }
}
