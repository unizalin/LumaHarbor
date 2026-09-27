import CoreGraphics
import Foundation

public enum ReferenceComparisonError: Error, Equatable, Hashable, Sendable {
    case invalidDimensions
    case sampleCountMismatch
    case nonFiniteSample
    case sampleOutOfRange
}

public enum ReferenceComparisonMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case neutralDirect
    case presetEffect
    case finalDirect
}

public struct ReferenceComparisonResult: Codable, Equatable, Sendable {
    public let meanAbsoluteEffectError: Double
    public let p95AbsoluteEffectError: Double
    public let luminanceEffectSSIM: Double
    public let highlightClippingFractionDelta: Double
    public let shadowClippingFractionDelta: Double
    public let sampleCount: Int

    public var meanAbsoluteError: Double { meanAbsoluteEffectError }
    public var p95AbsoluteError: Double { p95AbsoluteEffectError }
    public var luminanceSSIM: Double { luminanceEffectSSIM }

    public init(
        meanAbsoluteEffectError: Double,
        p95AbsoluteEffectError: Double,
        luminanceEffectSSIM: Double,
        highlightClippingFractionDelta: Double = 0,
        shadowClippingFractionDelta: Double = 0,
        sampleCount: Int
    ) {
        self.meanAbsoluteEffectError = meanAbsoluteEffectError
        self.p95AbsoluteEffectError = p95AbsoluteEffectError
        self.luminanceEffectSSIM = luminanceEffectSSIM
        self.highlightClippingFractionDelta = highlightClippingFractionDelta
        self.shadowClippingFractionDelta = shadowClippingFractionDelta
        self.sampleCount = sampleCount
    }

    private enum CodingKeys: String, CodingKey {
        case meanAbsoluteEffectError
        case p95AbsoluteEffectError
        case luminanceEffectSSIM
        case highlightClippingFractionDelta
        case shadowClippingFractionDelta
        case sampleCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meanAbsoluteEffectError = try container.decode(Double.self, forKey: .meanAbsoluteEffectError)
        p95AbsoluteEffectError = try container.decode(Double.self, forKey: .p95AbsoluteEffectError)
        luminanceEffectSSIM = try container.decode(Double.self, forKey: .luminanceEffectSSIM)
        highlightClippingFractionDelta = try container.decodeIfPresent(
            Double.self,
            forKey: .highlightClippingFractionDelta
        ) ?? 0
        shadowClippingFractionDelta = try container.decodeIfPresent(
            Double.self,
            forKey: .shadowClippingFractionDelta
        ) ?? 0
        sampleCount = try container.decode(Int.self, forKey: .sampleCount)
    }
}

/// Compares Lightroom and LumaHarbor reference renders, independent of any image framework.
public enum ReferenceComparisonMetrics {
    private static let luminanceCoefficients = SIMD3<Double>(0.2126, 0.7152, 0.0722)
    private static let ssimWindowRadius = 5
    private static let ssimC1 = 0.01 * 0.01
    private static let ssimC2 = 0.03 * 0.03

    public static func compare(
        mode: ReferenceComparisonMode = .presetEffect,
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
        for samples in allSamples {
            for sample in samples {
                try validate(sample)
            }
        }

        // A fixed 16-bit histogram gives an exact bounded-memory mean and a
        // conservative p95 without materializing one Double per channel.
        var errorHistogram = [Int](repeating: 0, count: 65_536)
        var bucketMaximum = [Double](repeating: 0, count: 65_536)
        var absoluteErrorSum = 0.0
        var clippingHighlightLR = 0
        var clippingHighlightLH = 0
        var clippingShadowLR = 0
        var clippingShadowLH = 0
        var lrLuminance = [Double](repeating: 0, count: sampleCount)
        var lhLuminance = [Double](repeating: 0, count: sampleCount)

        for index in 0..<sampleCount {
            let lrComparison: SIMD3<Double>
            let lhComparison: SIMD3<Double>
            switch mode {
            case .neutralDirect:
                lrComparison = rgb(lrNeutral[index])
                lhComparison = rgb(lhNeutral[index])
            case .presetEffect:
                lrComparison = rgbEffect(neutral: lrNeutral[index], preset: lrPreset[index])
                lhComparison = rgbEffect(neutral: lhNeutral[index], preset: lhPreset[index])
            case .finalDirect:
                lrComparison = rgb(lrPreset[index])
                lhComparison = rgb(lhPreset[index])
            }
            for channel in 0..<3 {
                let error = abs(lrComparison[channel] - lhComparison[channel])
                absoluteErrorSum += error
                let bucket = min(65_535, max(0, Int(error * 65_535)))
                errorHistogram[bucket] += 1
                bucketMaximum[bucket] = max(bucketMaximum[bucket], error)
            }
            lrLuminance[index] = luminance(lrComparison)
            lhLuminance[index] = luminance(lhComparison)

            let lrDirect = directSample(mode: mode, neutral: lrNeutral[index], preset: lrPreset[index])
            let lhDirect = directSample(mode: mode, neutral: lhNeutral[index], preset: lhPreset[index])
            if max(lrDirect.x, lrDirect.y, lrDirect.z) >= 0.99 { clippingHighlightLR += 1 }
            if max(lhDirect.x, lhDirect.y, lhDirect.z) >= 0.99 { clippingHighlightLH += 1 }
            if max(lrDirect.x, lrDirect.y, lrDirect.z) <= 0.01 { clippingShadowLR += 1 }
            if max(lhDirect.x, lhDirect.y, lhDirect.z) <= 0.01 { clippingShadowLH += 1 }
        }

        let errorCount = sampleCount * 3
        let mean = absoluteErrorSum / Double(errorCount)
        let p95Rank = max(1, Int(ceil(Double(errorCount) * 0.95)))
        var cumulative = 0
        var p95 = 0.0
        for index in errorHistogram.indices {
            cumulative += errorHistogram[index]
            if cumulative >= p95Rank {
                p95 = bucketMaximum[index]
                break
            }
        }
        let ssim = luminanceSSIM(
            width: width,
            height: height,
            lhs: lrLuminance,
            rhs: lhLuminance
        )
        let highlightClippingFractionDelta = abs(
            Double(clippingHighlightLR) / Double(sampleCount)
                - Double(clippingHighlightLH) / Double(sampleCount)
        )
        let shadowClippingFractionDelta = abs(
            Double(clippingShadowLR) / Double(sampleCount)
                - Double(clippingShadowLH) / Double(sampleCount)
        )

        return ReferenceComparisonResult(
            meanAbsoluteEffectError: mean,
            p95AbsoluteEffectError: p95,
            luminanceEffectSSIM: ssim,
            highlightClippingFractionDelta: highlightClippingFractionDelta,
            shadowClippingFractionDelta: shadowClippingFractionDelta,
            sampleCount: sampleCount
        )
    }

    /// Compares paired references a row tile at a time. This is the production
    /// path for original-size TIFFs; only the current four tiles and the
    /// rolling SSIM rows are retained.
    public static func compareStreaming(
        mode: ReferenceComparisonMode = .presetEffect,
        lrNeutral: ReferenceImageTileReader,
        lrPreset: ReferenceImageTileReader,
        lhNeutral: ReferenceImageTileReader,
        lhPreset: ReferenceImageTileReader,
        tileHeight: Int = 64
    ) throws -> ReferenceComparisonResult {
        let readers = [lrNeutral, lrPreset, lhNeutral, lhPreset]
        guard readers.allSatisfy({ $0.width == lrNeutral.width && $0.height == lrNeutral.height }),
              readers.allSatisfy({ $0.bitsPerComponent == 16 }),
              readers.allSatisfy({ $0.colorSpaceIdentifier == (CGColorSpace.sRGB as String) }),
              Set(readers.map(\.hasAlpha)).count == 1,
              tileHeight > 0 else {
            throw ReferenceComparisonError.invalidDimensions
        }

        let width = lrNeutral.width
        let height = lrNeutral.height
        let sampleCount = width * height
        var errorHistogram = [Int](repeating: 0, count: 65_536)
        var bucketMaximum = [Double](repeating: 0, count: 65_536)
        var absoluteErrorSum = 0.0
        var clippingHighlightLR = 0
        var clippingHighlightLH = 0
        var clippingShadowLR = 0
        var clippingShadowLH = 0
        var ssim = try SlidingWindowSSIMAccumulator(width: width, height: height)

        for startRow in stride(from: 0, to: height, by: tileHeight) {
            let rowCount = min(tileHeight, height - startRow)
            let tiles = try readers.map { try $0.tile(startRow: startRow, rowCount: rowCount) }
            guard tiles.dropFirst().allSatisfy({ $0.originY == startRow && $0.width == width && $0.height == rowCount }) else {
                throw ReferenceComparisonError.sampleCountMismatch
            }

            for row in 0..<rowCount {
                var lrLuminance = [Double](repeating: 0, count: width)
                var lhLuminance = [Double](repeating: 0, count: width)
                for x in 0..<width {
                    let index = (row * width + x) * 4
                    let lrNeutralSample = sample(from: tiles[0].rgba16, at: index)
                    let lrPresetSample = sample(from: tiles[1].rgba16, at: index)
                    let lhNeutralSample = sample(from: tiles[2].rgba16, at: index)
                    let lhPresetSample = sample(from: tiles[3].rgba16, at: index)
                    let lrComparison: SIMD3<Double>
                    let lhComparison: SIMD3<Double>
                    switch mode {
                    case .neutralDirect:
                        lrComparison = rgb(lrNeutralSample)
                        lhComparison = rgb(lhNeutralSample)
                    case .presetEffect:
                        lrComparison = rgbEffect(neutral: lrNeutralSample, preset: lrPresetSample)
                        lhComparison = rgbEffect(neutral: lhNeutralSample, preset: lhPresetSample)
                    case .finalDirect:
                        lrComparison = rgb(lrPresetSample)
                        lhComparison = rgb(lhPresetSample)
                    }
                    for channel in 0..<3 {
                        let error = abs(lrComparison[channel] - lhComparison[channel])
                        absoluteErrorSum += error
                        let bucket = min(65_535, max(0, Int(error * 65_535)))
                        errorHistogram[bucket] += 1
                        bucketMaximum[bucket] = max(bucketMaximum[bucket], error)
                    }
                    lrLuminance[x] = luminance(lrComparison)
                    lhLuminance[x] = luminance(lhComparison)

                    let lrDirect = directSample(mode: mode, neutral: lrNeutralSample, preset: lrPresetSample)
                    let lhDirect = directSample(mode: mode, neutral: lhNeutralSample, preset: lhPresetSample)
                    if max(lrDirect.x, lrDirect.y, lrDirect.z) >= 0.99 { clippingHighlightLR += 1 }
                    if max(lhDirect.x, lhDirect.y, lhDirect.z) >= 0.99 { clippingHighlightLH += 1 }
                    if max(lrDirect.x, lrDirect.y, lrDirect.z) <= 0.01 { clippingShadowLR += 1 }
                    if max(lhDirect.x, lhDirect.y, lhDirect.z) <= 0.01 { clippingShadowLH += 1 }
                }
                try ssim.append(lhs: lrLuminance, rhs: lhLuminance)
            }
        }

        let errorCount = sampleCount * 3
        let mean = absoluteErrorSum / Double(errorCount)
        let p95Rank = max(1, Int(ceil(Double(errorCount) * 0.95)))
        var cumulative = 0
        var p95 = 0.0
        for index in errorHistogram.indices {
            cumulative += errorHistogram[index]
            if cumulative >= p95Rank {
                p95 = bucketMaximum[index]
                break
            }
        }
        let highlightClippingFractionDelta = abs(
            Double(clippingHighlightLR) / Double(sampleCount)
                - Double(clippingHighlightLH) / Double(sampleCount)
        )
        let shadowClippingFractionDelta = abs(
            Double(clippingShadowLR) / Double(sampleCount)
                - Double(clippingShadowLH) / Double(sampleCount)
        )
        return ReferenceComparisonResult(
            meanAbsoluteEffectError: mean,
            p95AbsoluteEffectError: p95,
            luminanceEffectSSIM: try ssim.finish(),
            highlightClippingFractionDelta: highlightClippingFractionDelta,
            shadowClippingFractionDelta: shadowClippingFractionDelta,
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

    private static func sample(from rgba16: [UInt16], at index: Int) -> SIMD4<Float> {
        let alpha = Float(rgba16[index + 3]) / Float(UInt16.max)
        guard alpha > 0 else {
            return SIMD4<Float>(0, 0, 0, alpha)
        }
        let red = min(1, max(0, (Float(rgba16[index]) / Float(UInt16.max)) / alpha))
        let green = min(1, max(0, (Float(rgba16[index + 1]) / Float(UInt16.max)) / alpha))
        let blue = min(1, max(0, (Float(rgba16[index + 2]) / Float(UInt16.max)) / alpha))
        return SIMD4<Float>(red, green, blue, alpha)
    }

    private static func rgbEffect(neutral: SIMD4<Float>, preset: SIMD4<Float>) -> SIMD3<Double> {
        SIMD3(
            Double(preset.x) - Double(neutral.x),
            Double(preset.y) - Double(neutral.y),
            Double(preset.z) - Double(neutral.z)
        )
    }

    private static func rgb(_ sample: SIMD4<Float>) -> SIMD3<Double> {
        SIMD3(Double(sample.x), Double(sample.y), Double(sample.z))
    }

    private static func directSample(
        mode: ReferenceComparisonMode,
        neutral: SIMD4<Float>,
        preset: SIMD4<Float>
    ) -> SIMD4<Float> {
        switch mode {
        case .neutralDirect: return neutral
        case .presetEffect, .finalDirect: return preset
        }
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
                var count = 0.0
                var lhsSum = 0.0
                var rhsSum = 0.0
                for windowY in minY...maxY {
                    for windowX in minX...maxX {
                        let index = windowY * width + windowX
                        lhsSum += lhs[index]
                        rhsSum += rhs[index]
                        count += 1
                    }
                }

                let lhsMean = lhsSum / count
                let rhsMean = rhsSum / count
                var lhsVariance = 0.0
                var rhsVariance = 0.0
                var covariance = 0.0
                for windowY in minY...maxY {
                    for windowX in minX...maxX {
                        let index = windowY * width + windowX
                        let lhsDelta = lhs[index] - lhsMean
                        let rhsDelta = rhs[index] - rhsMean
                        lhsVariance += lhsDelta * lhsDelta
                        rhsVariance += rhsDelta * rhsDelta
                        covariance += lhsDelta * rhsDelta
                    }
                }
                lhsVariance /= count
                rhsVariance /= count
                covariance /= count

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
