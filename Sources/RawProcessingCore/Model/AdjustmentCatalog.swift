import Foundation

/// The authoritative range, default and step for one adjustment.
///
/// Spec §8.2: the real UI range and Core Image mapping must be defined in one
/// place and pinned by tests, never scattered across views.
public struct AdjustmentDefinition: Equatable, Sendable {
    public let kind: AdjustmentKind
    public let defaultValue: Double
    public let minimumValue: Double
    public let maximumValue: Double
    /// Suggested slider increment for the inspector.
    public let step: Double
    /// Number of fraction digits the inspector should show.
    public let fractionDigits: Int

    public init(
        kind: AdjustmentKind,
        defaultValue: Double,
        minimumValue: Double,
        maximumValue: Double,
        step: Double,
        fractionDigits: Int
    ) {
        self.kind = kind
        self.defaultValue = defaultValue
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.step = step
        self.fractionDigits = fractionDigits
    }

    public var range: ClosedRange<Double> { minimumValue...maximumValue }

    /// Clamps into range. Non-finite input collapses to the default so a corrupt
    /// sidecar can never inject NaN into the render pipeline.
    public func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return Swift.min(Swift.max(value, minimumValue), maximumValue)
    }

    public func contains(_ value: Double) -> Bool {
        value.isFinite && value >= minimumValue && value <= maximumValue
    }
}

/// Single source of truth for adjustment ranges.
public enum AdjustmentCatalog {
    /// Inspector order, top to bottom.
    public static let ordered: [AdjustmentDefinition] = [
        // Exposure is in real EV so the value carries photographic meaning.
        AdjustmentDefinition(
            kind: .exposure, defaultValue: 0, minimumValue: -5, maximumValue: 5,
            step: 0.01, fractionDigits: 2
        ),
        // Every other slider is a neutral-at-zero, ±100 percentage-style control.
        AdjustmentDefinition(
            kind: .temperature, defaultValue: 0, minimumValue: -100, maximumValue: 100,
            step: 1, fractionDigits: 0
        ),
        AdjustmentDefinition(
            kind: .tint, defaultValue: 0, minimumValue: -100, maximumValue: 100,
            step: 1, fractionDigits: 0
        ),
        AdjustmentDefinition(
            kind: .contrast, defaultValue: 0, minimumValue: -100, maximumValue: 100,
            step: 1, fractionDigits: 0
        ),
        AdjustmentDefinition(
            kind: .highlights, defaultValue: 0, minimumValue: -100, maximumValue: 100,
            step: 1, fractionDigits: 0
        ),
        AdjustmentDefinition(
            kind: .shadows, defaultValue: 0, minimumValue: -100, maximumValue: 100,
            step: 1, fractionDigits: 0
        ),
        AdjustmentDefinition(
            kind: .whites, defaultValue: 0, minimumValue: -100, maximumValue: 100,
            step: 1, fractionDigits: 0
        ),
        AdjustmentDefinition(
            kind: .blacks, defaultValue: 0, minimumValue: -100, maximumValue: 100,
            step: 1, fractionDigits: 0
        ),
        AdjustmentDefinition(
            kind: .vibrance, defaultValue: 0, minimumValue: -100, maximumValue: 100,
            step: 1, fractionDigits: 0
        ),
        AdjustmentDefinition(
            kind: .saturation, defaultValue: 0, minimumValue: -100, maximumValue: 100,
            step: 1, fractionDigits: 0
        )
    ]

    private static let byKind: [AdjustmentKind: AdjustmentDefinition] =
        Dictionary(uniqueKeysWithValues: ordered.map { ($0.kind, $0) })

    /// Never traps: an unlisted kind falls back to the neutral ±100 shape, which
    /// is also what the test suite asserts can't happen.
    public static func definition(for kind: AdjustmentKind) -> AdjustmentDefinition {
        byKind[kind] ?? AdjustmentDefinition(
            kind: kind, defaultValue: 0, minimumValue: -100, maximumValue: 100,
            step: 1, fractionDigits: 0
        )
    }

    public static func definitions(in group: AdjustmentGroup) -> [AdjustmentDefinition] {
        ordered.filter { $0.kind.group == group }
    }
}
