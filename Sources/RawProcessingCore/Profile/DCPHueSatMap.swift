import Foundation

public enum DCPTableError: Swift.Error, Equatable, Sendable {
    case invalidDimensions
    case dimensionProductOverflow
    case payloadLengthMismatch
    case nonFiniteSample
    case unsupportedPayload
    case invalidRGB
    case invalidBlendWeight
    case incompatibleDimensions
}

public struct DCPTableDimensions: Equatable, Sendable {
    public let hue: Int
    public let saturation: Int
    public let value: Int

    public init(hue: Int, saturation: Int, value: Int) {
        self.hue = hue
        self.saturation = saturation
        self.value = value
    }
}

public struct DCPHueSatSample: Equatable, Sendable {
    public let hueShift: Double
    public let saturationScale: Double
    public let valueScale: Double

    public init(hueShift: Double, saturationScale: Double, valueScale: Double) {
        self.hueShift = hueShift
        self.saturationScale = saturationScale
        self.valueScale = valueScale
    }
}

struct DCPTableGrid: Equatable, Sendable {
    let dimensions: DCPTableDimensions
    let samples: [DCPHueSatSample]

    init(dimensions: DCPTableDimensions, samples: [DCPHueSatSample]) throws {
        guard dimensions.hue > 0, dimensions.saturation > 0, dimensions.value > 0 else {
            throw DCPTableError.invalidDimensions
        }
        let (product, overflow) = dimensions.hue.multipliedReportingOverflow(
            by: dimensions.saturation
        )
        guard !overflow else {
            throw DCPTableError.dimensionProductOverflow
        }
        let (sampleCount, countOverflow) = product.multipliedReportingOverflow(by: dimensions.value)
        guard !countOverflow, sampleCount <= 4_194_304 else {
            throw DCPTableError.dimensionProductOverflow
        }
        guard samples.count == sampleCount else {
            throw DCPTableError.payloadLengthMismatch
        }
        guard samples.allSatisfy({
            $0.hueShift.isFinite && $0.saturationScale.isFinite && $0.valueScale.isFinite
        }) else {
            throw DCPTableError.nonFiniteSample
        }
        self.dimensions = dimensions
        self.samples = samples
    }

    init(document: DCPProfileDocument, dimensionsTag: DCPTagID, dataTag: DCPTagID) throws {
        let dimensions = try Self.readDimensions(document.value(for: dimensionsTag))
        let samples = try Self.readSamples(document.value(for: dataTag))
        try self.init(dimensions: dimensions, samples: samples)
    }

    func sample(hue: Double, saturation: Double, value: Double) -> DCPHueSatSample {
        let hueCoordinate = coordinate(
            hue.isFinite ? hue - floor(hue) : 0,
            divisions: dimensions.hue,
            wraps: true
        )
        let saturationCoordinate = coordinate(
            saturation.isFinite ? saturation : 0,
            divisions: dimensions.saturation,
            wraps: false
        )
        let valueCoordinate = coordinate(
            value.isFinite ? value : 0,
            divisions: dimensions.value,
            wraps: false
        )

        let hueSamples = (0...1).map { hueOffset in
            let saturationSamples = (0...1).map { saturationOffset in
                let valueSamples = (0...1).map { valueOffset in
                    samples[index(
                        hue: hueCoordinate.lower + hueOffset * hueCoordinate.upperOffset,
                        saturation: saturationCoordinate.lower + saturationOffset * saturationCoordinate.upperOffset,
                        value: valueCoordinate.lower + valueOffset * valueCoordinate.upperOffset
                    )]
                }
                return blend(valueSamples[0], valueSamples[1], weight: valueCoordinate.fraction)
            }
            return blend(saturationSamples[0], saturationSamples[1], weight: saturationCoordinate.fraction)
        }
        return blend(hueSamples[0], hueSamples[1], weight: hueCoordinate.fraction)
    }

    func blended(with other: DCPTableGrid, weight: Double) throws -> DCPTableGrid {
        guard weight.isFinite, (0...1).contains(weight) else {
            throw DCPTableError.invalidBlendWeight
        }
        guard dimensions == other.dimensions else {
            throw DCPTableError.incompatibleDimensions
        }
        let blendedSamples = zip(samples, other.samples).map {
            blend($0, $1, weight: weight)
        }
        return try DCPTableGrid(dimensions: dimensions, samples: blendedSamples)
    }

    func apply(to rgb: [Double]) throws -> [Double] {
        guard rgb.count == 3, rgb.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw DCPTableError.invalidRGB
        }
        let hsv = rgbToHSV(rgb)
        let transform = sample(hue: hsv.hue, saturation: hsv.saturation, value: hsv.value)
        let hue = normalizedHue(hsv.hue + transform.hueShift)
        let saturation = min(max(hsv.saturation * transform.saturationScale, 0), 1)
        let value = min(max(hsv.value * transform.valueScale, 0), 1)
        return hsvToRGB(hue: hue, saturation: saturation, value: value)
    }

    private struct Coordinate {
        let lower: Int
        let upperOffset: Int
        let fraction: Double
    }

    private func coordinate(_ input: Double, divisions: Int, wraps: Bool) -> Coordinate {
        guard divisions > 1 else {
            return Coordinate(lower: 0, upperOffset: 0, fraction: 0)
        }
        if wraps {
            let position = input * Double(divisions)
            let lower = floor(position)
            let fraction = position - lower
            return Coordinate(
                lower: ((Int(lower) % divisions) + divisions) % divisions,
                upperOffset: 1,
                fraction: fraction
            )
        }
        let clamped = min(max(input, 0), 1)
        let position = clamped * Double(divisions - 1)
        let lower = min(Int(floor(position)), divisions - 1)
        return Coordinate(
            lower: lower,
            upperOffset: lower == divisions - 1 ? 0 : 1,
            fraction: lower == divisions - 1 ? 0 : position - floor(position)
        )
    }

    private func index(hue: Int, saturation: Int, value: Int) -> Int {
        let wrappedHue = ((hue % dimensions.hue) + dimensions.hue) % dimensions.hue
        return ((wrappedHue * dimensions.saturation) + saturation) * dimensions.value + value
    }

    private static func readDimensions(_ value: DCPTagValue?) throws -> DCPTableDimensions {
        guard case let .unsignedShort(values) = value, values.count == 3 else {
            throw DCPTableError.invalidDimensions
        }
        return DCPTableDimensions(hue: Int(values[0]), saturation: Int(values[1]), value: Int(values[2]))
    }

    private static func readSamples(_ value: DCPTagValue?) throws -> [DCPHueSatSample] {
        let numericValues: [Double]
        switch value {
        case let .signedRational(values):
            numericValues = try values.map {
                guard $0.denominator != 0 else {
                    throw DCPTableError.unsupportedPayload
                }
                return Double($0.numerator) / Double($0.denominator)
            }
        case let .rational(values):
            numericValues = try values.map {
                guard $0.denominator != 0 else {
                    throw DCPTableError.unsupportedPayload
                }
                return Double($0.numerator) / Double($0.denominator)
            }
        case let .float(values):
            numericValues = values.map { Double($0) }
        case let .double(values):
            numericValues = values
        default:
            throw DCPTableError.unsupportedPayload
        }
        guard numericValues.count.isMultiple(of: 3) else {
            throw DCPTableError.payloadLengthMismatch
        }
        var samples: [DCPHueSatSample] = []
        samples.reserveCapacity(numericValues.count / 3)
        for index in stride(from: 0, to: numericValues.count, by: 3) {
            samples.append(
                DCPHueSatSample(
                    hueShift: numericValues[index],
                    saturationScale: numericValues[index + 1],
                    valueScale: numericValues[index + 2]
                )
            )
        }
        return samples
    }

    private func blend(
        _ first: DCPHueSatSample,
        _ second: DCPHueSatSample,
        weight: Double
    ) -> DCPHueSatSample {
        DCPHueSatSample(
            hueShift: circularBlend(first.hueShift, second.hueShift, weight: weight),
            saturationScale: first.saturationScale + (second.saturationScale - first.saturationScale) * weight,
            valueScale: first.valueScale + (second.valueScale - first.valueScale) * weight
        )
    }

    private func circularBlend(_ first: Double, _ second: Double, weight: Double) -> Double {
        var delta = second - first
        while delta > 0.5 { delta -= 1 }
        while delta < -0.5 { delta += 1 }
        return normalizedHue(first + delta * weight)
    }

    private func rgbToHSV(_ rgb: [Double]) -> (hue: Double, saturation: Double, value: Double) {
        let maximum = rgb.max() ?? 0
        let minimum = rgb.min() ?? 0
        let delta = maximum - minimum
        guard delta > 0 else {
            return (0, 0, maximum)
        }
        let hue: Double
        if maximum == rgb[0] {
            hue = ((rgb[1] - rgb[2]) / delta).truncatingRemainder(dividingBy: 6) / 6
        } else if maximum == rgb[1] {
            hue = ((rgb[2] - rgb[0]) / delta + 2) / 6
        } else {
            hue = ((rgb[0] - rgb[1]) / delta + 4) / 6
        }
        return (normalizedHue(hue), delta / maximum, maximum)
    }

    private func hsvToRGB(hue: Double, saturation: Double, value: Double) -> [Double] {
        guard saturation > 0 else {
            return [value, value, value]
        }
        let position = hue * 6
        let index = Int(floor(position))
        let fraction = position - floor(position)
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * fraction)
        let t = value * (1 - saturation * (1 - fraction))
        switch index % 6 {
        case 0: return [value, t, p]
        case 1: return [q, value, p]
        case 2: return [p, value, t]
        case 3: return [p, q, value]
        case 4: return [t, p, value]
        default: return [value, p, q]
        }
    }

    private func normalizedHue(_ hue: Double) -> Double {
        let normalized = hue.truncatingRemainder(dividingBy: 1)
        return normalized < 0 ? normalized + 1 : normalized
    }
}

public struct DCPHueSatMap: Equatable, Sendable {
    private let grid: DCPTableGrid

    public init(dimensions: DCPTableDimensions, samples: [DCPHueSatSample]) throws {
        grid = try DCPTableGrid(dimensions: dimensions, samples: samples)
    }

    public init(document: DCPProfileDocument) throws {
        grid = try DCPTableGrid(
            document: document,
            dimensionsTag: DCPProfileTag.profileHueSatMapDims,
            dataTag: DCPProfileTag.profileHueSatMapData1
        )
    }

    public func sample(hue: Double, saturation: Double, value: Double) -> DCPHueSatSample {
        grid.sample(hue: hue, saturation: saturation, value: value)
    }

    public func apply(to rgb: [Double]) throws -> [Double] {
        try grid.apply(to: rgb)
    }

    public static func blend(
        _ first: DCPHueSatMap,
        _ second: DCPHueSatMap,
        weight: Double
    ) throws -> DCPHueSatMap {
        try DCPHueSatMap(grid: first.grid.blended(with: second.grid, weight: weight))
    }

    private init(grid: DCPTableGrid) throws {
        self.grid = grid
    }
}
