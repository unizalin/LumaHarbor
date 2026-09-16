import Foundation

public enum ReferenceComparisonError: Error, Equatable, Hashable, Sendable {
    case invalidDimensions
    case sampleCountMismatch
    case nonFiniteSample
    case sampleOutOfRange
}

public struct ReferenceComparisonResult: Codable, Equatable, Sendable {
    public let meanAbsoluteEffectError: Double
    public let p95AbsoluteEffectError: Double
    public let luminanceEffectSSIM: Double
    public let sampleCount: Int

    public init(
        meanAbsoluteEffectError: Double,
        p95AbsoluteEffectError: Double,
        luminanceEffectSSIM: Double,
        sampleCount: Int
    ) {
        self.meanAbsoluteEffectError = meanAbsoluteEffectError
        self.p95AbsoluteEffectError = p95AbsoluteEffectError
        self.luminanceEffectSSIM = luminanceEffectSSIM
        self.sampleCount = sampleCount
    }
}

/// Compares the effect of a preset against a neutral render, independent of any image framework.
public enum ReferenceComparisonMetrics {
    private static let luminanceCoefficients = SIMD3<Double>(0.2126, 0.7152, 0.0722)
    private static let ssimWindowRadius = 5
    private static let ssimC1 = 0.01 * 0.01
    private static let ssimC2 = 0.03 * 0.03

    public static func compare(
        width: Int,
        height: Int,
        lrNeutral: [SIMD4<Float>],
        lrPreset: [SIMD4<Float>],
        lhNeutral: [SIMD4<Float>],
        lhPreset: [SIMD4<Float>]
    ) throws -> ReferenceComparisonResult {
        guard width > 0, height > 0, width <= Int.max / height else {
            throw ReferenceComparisonError.invalidDimensions
        }

        let sampleCount = width * height
        let allSamples = [lrNeutral, lrPreset, lhNeutral, lhPreset]
        guard allSamples.allSatisfy({ $0.count == sampleCount }) else {
            throw ReferenceComparisonError.sampleCountMismatch
        }
        try allSamples.flatMap { $0 }.forEach(validate)

        var absoluteErrors: [Double] = []
        absoluteErrors.reserveCapacity(sampleCount * 3)
        var lrLuminance = [Double](repeating: 0, count: sampleCount)
        var lhLuminance = [Double](repeating: 0, count: sampleCount)

        for index in 0..<sampleCount {
            let lrEffect = rgbEffect(neutral: lrNeutral[index], preset: lrPreset[index])
            let lhEffect = rgbEffect(neutral: lhNeutral[index], preset: lhPreset[index])
            for channel in 0..<3 {
                absoluteErrors.append(abs(lrEffect[channel] - lhEffect[channel]))
            }
            lrLuminance[index] = luminance(lrEffect)
            lhLuminance[index] = luminance(lhEffect)
        }

        let sortedErrors = absoluteErrors.sorted()
        let mean = sortedErrors.reduce(0, +) / Double(sortedErrors.count)
        let p95Rank = max(1, Int(ceil(Double(sortedErrors.count) * 0.95)))
        let p95 = sortedErrors[p95Rank - 1]
        let ssim = luminanceSSIM(
            width: width,
            height: height,
            lhs: lrLuminance,
            rhs: lhLuminance
        )

        return ReferenceComparisonResult(
            meanAbsoluteEffectError: mean,
            p95AbsoluteEffectError: p95,
            luminanceEffectSSIM: ssim,
            sampleCount: sampleCount
        )
    }

    private static func validate(_ sample: SIMD4<Float>) throws {
        guard sample.x.isFinite, sample.y.isFinite, sample.z.isFinite, sample.w.isFinite else {
            throw ReferenceComparisonError.nonFiniteSample
        }
        guard (0...1).contains(sample.x), (0...1).contains(sample.y),
              (0...1).contains(sample.z), (0...1).contains(sample.w) else {
            throw ReferenceComparisonError.sampleOutOfRange
        }
    }

    private static func rgbEffect(neutral: SIMD4<Float>, preset: SIMD4<Float>) -> SIMD3<Double> {
        SIMD3(
            Double(preset.x) - Double(neutral.x),
            Double(preset.y) - Double(neutral.y),
            Double(preset.z) - Double(neutral.z)
        )
    }

    private static func luminance(_ rgb: SIMD3<Double>) -> Double {
        rgb.x * luminanceCoefficients.x
            + rgb.y * luminanceCoefficients.y
            + rgb.z * luminanceCoefficients.z
    }

    private static func luminanceSSIM(
        width: Int,
        height: Int,
        lhs: [Double],
        rhs: [Double]
    ) -> Double {
        var total = 0.0
        var windowCount = 0

        for y in 0..<height {
            let minY = max(0, y - ssimWindowRadius)
            let maxY = min(height - 1, y + ssimWindowRadius)
            for x in 0..<width {
                let minX = max(0, x - ssimWindowRadius)
                let maxX = min(width - 1, x + ssimWindowRadius)
                var lhsValues: [Double] = []
                var rhsValues: [Double] = []

                for windowY in minY...maxY {
                    for windowX in minX...maxX {
                        let index = windowY * width + windowX
                        lhsValues.append(lhs[index])
                        rhsValues.append(rhs[index])
                    }
                }

                let lhsMean = lhsValues.reduce(0, +) / Double(lhsValues.count)
                let rhsMean = rhsValues.reduce(0, +) / Double(rhsValues.count)
                let lhsVariance = lhsValues.reduce(0) { partial, value in
                    partial + (value - lhsMean) * (value - lhsMean)
                } / Double(lhsValues.count)
                let rhsVariance = rhsValues.reduce(0) { partial, value in
                    partial + (value - rhsMean) * (value - rhsMean)
                } / Double(rhsValues.count)
                let covariance = zip(lhsValues, rhsValues).reduce(0) { partial, pair in
                    partial + (pair.0 - lhsMean) * (pair.1 - rhsMean)
                } / Double(lhsValues.count)

                let numerator = (2 * lhsMean * rhsMean + ssimC1) * (2 * covariance + ssimC2)
                let denominator = (lhsMean * lhsMean + rhsMean * rhsMean + ssimC1)
                    * (lhsVariance + rhsVariance + ssimC2)
                total += denominator == 0 ? 1 : numerator / denominator
                windowCount += 1
            }
        }

        return min(1, max(-1, total / Double(windowCount)))
    }
}
