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

    /// Snaps a slider value to the same increments used by the numeric field.
    /// This keeps discrete editing without asking the macOS native Slider to
    /// render thousands of tick marks below its track.
    public static func snapped(
        _ value: Double,
        step: Double,
        range: ClosedRange<Double>,
        fractionDigits: Int
    ) -> Double {
        guard value.isFinite, step.isFinite, step > 0 else {
            return clamp(value, to: range)
        }

        let origin = range.lowerBound
        let tick = ((value - origin) / step).rounded()
        let candidate = origin + tick * step
        let scale = pow(10.0, Double(max(0, fractionDigits)))
        let rounded = (candidate * scale).rounded() / scale
        return clamp(rounded == 0 ? 0 : rounded, to: range)
    }
}
