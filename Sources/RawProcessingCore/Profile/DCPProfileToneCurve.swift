import Foundation

public enum DCPProfileToneCurveError: Swift.Error, Equatable, Sendable {
    case invalidKnotCount
    case nonFiniteKnot
    case knotOutsideDomain
    case missingDomainEndpoint
    case nonMonotonicInput
    case nonMonotonicOutput
    case inputOutsideDomain
    case invalidRGB
    case nonFiniteMetadata
    case invalidDefaultBlackRender
}

public struct DCPProfileToneCurve: Equatable, Sendable {
    public struct Knot: Equatable, Sendable {
        public let input: Double
        public let output: Double

        public init(input: Double, output: Double) {
            self.input = input
            self.output = output
        }
    }

    public let knots: [Knot]

    public init(knots: [Knot]) throws {
        guard knots.count >= 2 else {
            throw DCPProfileToneCurveError.invalidKnotCount
        }
        guard knots.allSatisfy({ $0.input.isFinite && $0.output.isFinite }) else {
            throw DCPProfileToneCurveError.nonFiniteKnot
        }
        guard knots.allSatisfy({ (0...1).contains($0.input) && (0...1).contains($0.output) }) else {
            throw DCPProfileToneCurveError.knotOutsideDomain
        }
        guard knots.first?.input == 0, knots.last?.input == 1 else {
            throw DCPProfileToneCurveError.missingDomainEndpoint
        }
        for pair in zip(knots, knots.dropFirst()) {
            guard pair.0.input < pair.1.input else {
                throw DCPProfileToneCurveError.nonMonotonicInput
            }
            guard pair.0.output <= pair.1.output else {
                throw DCPProfileToneCurveError.nonMonotonicOutput
            }
        }
        self.knots = knots
    }

    public func apply(to input: Double) throws -> Double {
        guard input.isFinite, (0...1).contains(input) else {
            throw DCPProfileToneCurveError.inputOutsideDomain
        }
        if input == 0 { return knots[0].output }
        if input == 1 { return knots[knots.count - 1].output }

        for pair in zip(knots, knots.dropFirst()) {
            guard input <= pair.1.input else { continue }
            let span = pair.1.input - pair.0.input
            let fraction = (input - pair.0.input) / span
            return pair.0.output + (pair.1.output - pair.0.output) * fraction
        }
        return knots[knots.count - 1].output
    }

    public func applyHuePreserving(to rgb: [Double]) throws -> [Double] {
        guard rgb.count == 3, rgb.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw DCPProfileToneCurveError.invalidRGB
        }
        let hsv = Self.rgbToHSV(rgb)
        let value = try apply(to: hsv.value)
        return Self.hsvToRGB(hue: hsv.hue, saturation: hsv.saturation, value: value)
    }

    private struct HSV {
        let hue: Double
        let saturation: Double
        let value: Double
    }

    private static func rgbToHSV(_ rgb: [Double]) -> HSV {
        let minimum = rgb.min() ?? 0
        let maximum = rgb.max() ?? 0
        let delta = maximum - minimum
        guard delta > 0 else {
            return HSV(hue: 0, saturation: 0, value: maximum)
        }

        let hue: Double
        if maximum == rgb[0] {
            hue = ((rgb[1] - rgb[2]) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == rgb[1] {
            hue = ((rgb[2] - rgb[0]) / delta) + 2
        } else {
            hue = ((rgb[0] - rgb[1]) / delta) + 4
        }
        return HSV(
            hue: hue.isFinite ? normalizedHue(hue / 6) : 0,
            saturation: maximum == 0 ? 0 : delta / maximum,
            value: maximum
        )
    }

    private static func hsvToRGB(hue: Double, saturation: Double, value: Double) -> [Double] {
        guard saturation > 0 else {
            return [value, value, value]
        }
        let position = normalizedHue(hue) * 6
        let sector = Int(floor(position))
        let fraction = position - floor(position)
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * fraction)
        let t = value * (1 - saturation * (1 - fraction))
        switch sector % 6 {
        case 0: return [value, t, p]
        case 1: return [q, value, p]
        case 2: return [p, value, t]
        case 3: return [p, q, value]
        case 4: return [t, p, value]
        default: return [value, p, q]
        }
    }

    private static func normalizedHue(_ hue: Double) -> Double {
        let value = hue - floor(hue)
        return value >= 0 ? value : value + 1
    }
}

public struct DCPProfileMetadata: Equatable, Sendable {
    public let baselineExposureOffset: Double
    public let defaultBlackRender: UInt16

    public init(baselineExposureOffset: Double = 0, defaultBlackRender: UInt16 = 0) {
        self.baselineExposureOffset = baselineExposureOffset
        self.defaultBlackRender = defaultBlackRender
    }

    public func validated() throws -> DCPProfileMetadata {
        guard baselineExposureOffset.isFinite else {
            throw DCPProfileToneCurveError.nonFiniteMetadata
        }
        guard defaultBlackRender <= 1 else {
            throw DCPProfileToneCurveError.invalidDefaultBlackRender
        }
        return self
    }
}
