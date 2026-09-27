import Foundation

public struct LightroomReferenceThresholds: Codable, Equatable, Hashable, Sendable {
    public struct Evaluation: Codable, Equatable, Hashable, Sendable {
        public let meanAbsoluteEffectErrorPassed: Bool
        public let p95AbsoluteEffectErrorPassed: Bool
        public let luminanceEffectSSIMPassed: Bool
        public let highlightClippingFractionDeltaPassed: Bool
        public let shadowClippingFractionDeltaPassed: Bool

        public var isPassing: Bool {
            meanAbsoluteEffectErrorPassed
                && p95AbsoluteEffectErrorPassed
                && luminanceEffectSSIMPassed
                && highlightClippingFractionDeltaPassed
                && shadowClippingFractionDeltaPassed
        }

        public init(
            meanAbsoluteEffectErrorPassed: Bool,
            p95AbsoluteEffectErrorPassed: Bool,
            luminanceEffectSSIMPassed: Bool,
            highlightClippingFractionDeltaPassed: Bool = true,
            shadowClippingFractionDeltaPassed: Bool = true
        ) {
            self.meanAbsoluteEffectErrorPassed = meanAbsoluteEffectErrorPassed
            self.p95AbsoluteEffectErrorPassed = p95AbsoluteEffectErrorPassed
            self.luminanceEffectSSIMPassed = luminanceEffectSSIMPassed
            self.highlightClippingFractionDeltaPassed = highlightClippingFractionDeltaPassed
            self.shadowClippingFractionDeltaPassed = shadowClippingFractionDeltaPassed
        }
    }

    public static let current = LightroomReferenceThresholds(
        version: 2,
        meanAbsoluteEffectError: 0.04,
        p95AbsoluteEffectError: 0.12,
        luminanceEffectSSIM: 0.95,
        highlightClippingFractionDelta: 0.02,
        shadowClippingFractionDelta: 0.02
    )

    public let version: Int
    public let meanAbsoluteEffectError: Double
    public let p95AbsoluteEffectError: Double
    public let luminanceEffectSSIM: Double
    public let highlightClippingFractionDelta: Double
    public let shadowClippingFractionDelta: Double

    public init(
        version: Int,
        meanAbsoluteEffectError: Double,
        p95AbsoluteEffectError: Double,
        luminanceEffectSSIM: Double,
        highlightClippingFractionDelta: Double = 0.02,
        shadowClippingFractionDelta: Double = 0.02
    ) {
        self.version = version
        self.meanAbsoluteEffectError = meanAbsoluteEffectError
        self.p95AbsoluteEffectError = p95AbsoluteEffectError
        self.luminanceEffectSSIM = luminanceEffectSSIM
        self.highlightClippingFractionDelta = highlightClippingFractionDelta
        self.shadowClippingFractionDelta = shadowClippingFractionDelta
    }

    public func evaluate(_ result: ReferenceComparisonResult) -> Evaluation {
        Evaluation(
            meanAbsoluteEffectErrorPassed: result.meanAbsoluteError <= meanAbsoluteEffectError,
            p95AbsoluteEffectErrorPassed: result.p95AbsoluteError <= p95AbsoluteEffectError,
            luminanceEffectSSIMPassed: result.luminanceSSIM >= luminanceEffectSSIM,
            highlightClippingFractionDeltaPassed: result.highlightClippingFractionDelta <= highlightClippingFractionDelta,
            shadowClippingFractionDeltaPassed: result.shadowClippingFractionDelta <= shadowClippingFractionDelta
        )
    }
}
