import Foundation

public struct AdobeRGBTable: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        public let red: UInt16
        public let green: UInt16
        public let blue: UInt16

        public init(red: UInt16, green: UInt16, blue: UInt16) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    public let gridSize: Int
    public let samples: [Sample]
    public let colorPrimaries: UInt32
    public let gamma: UInt32
    public let gamut: UInt32
    public let minimumAmount: Double
    public let maximumAmount: Double

    public init(
        gridSize: Int,
        samples: [Sample],
        colorPrimaries: UInt32 = 0,
        gamma: UInt32 = 1,
        gamut: UInt32 = 0,
        minimumAmount: Double = 0,
        maximumAmount: Double = 1
    ) throws {
        guard (1...32).contains(gridSize) else {
            throw AdobeRGBTableCodecError.invalidDimensions
        }
        let (square, squareOverflow) = gridSize.multipliedReportingOverflow(by: gridSize)
        let (expectedCount, cubeOverflow) = square.multipliedReportingOverflow(by: gridSize)
        guard !squareOverflow, !cubeOverflow, samples.count == expectedCount else {
            throw AdobeRGBTableCodecError.invalidDimensions
        }
        guard minimumAmount.isFinite, maximumAmount.isFinite, minimumAmount <= maximumAmount else {
            throw AdobeRGBTableCodecError.invalidFooter
        }
        self.gridSize = gridSize
        self.samples = samples
        self.colorPrimaries = colorPrimaries
        self.gamma = gamma
        self.gamut = gamut
        self.minimumAmount = minimumAmount
        self.maximumAmount = maximumAmount
    }

    public func sample(red: Double, green: Double, blue: Double) throws -> [Double] {
        let input = [red, green, blue]
        guard input.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw AdobeRGBTableCodecError.invalidSample
        }
        let redCoordinate = coordinate(red)
        let greenCoordinate = coordinate(green)
        let blueCoordinate = coordinate(blue)

        let corners: [(Int, Int, Int, Double)] = [
            (redCoordinate.lower, greenCoordinate.lower, blueCoordinate.lower, (1 - redCoordinate.fraction) * (1 - greenCoordinate.fraction) * (1 - blueCoordinate.fraction)),
            (redCoordinate.lower, greenCoordinate.lower, blueCoordinate.upper, (1 - redCoordinate.fraction) * (1 - greenCoordinate.fraction) * blueCoordinate.fraction),
            (redCoordinate.lower, greenCoordinate.upper, blueCoordinate.lower, (1 - redCoordinate.fraction) * greenCoordinate.fraction * (1 - blueCoordinate.fraction)),
            (redCoordinate.lower, greenCoordinate.upper, blueCoordinate.upper, (1 - redCoordinate.fraction) * greenCoordinate.fraction * blueCoordinate.fraction),
            (redCoordinate.upper, greenCoordinate.lower, blueCoordinate.lower, redCoordinate.fraction * (1 - greenCoordinate.fraction) * (1 - blueCoordinate.fraction)),
            (redCoordinate.upper, greenCoordinate.lower, blueCoordinate.upper, redCoordinate.fraction * (1 - greenCoordinate.fraction) * blueCoordinate.fraction),
            (redCoordinate.upper, greenCoordinate.upper, blueCoordinate.lower, redCoordinate.fraction * greenCoordinate.fraction * (1 - blueCoordinate.fraction)),
            (redCoordinate.upper, greenCoordinate.upper, blueCoordinate.upper, redCoordinate.fraction * greenCoordinate.fraction * blueCoordinate.fraction)
        ]

        var output = [Double](repeating: 0, count: 3)
        for (redIndex, greenIndex, blueIndex, weight) in corners {
            let sample = samples[index(red: redIndex, green: greenIndex, blue: blueIndex)]
            output[0] += Double(sample.red) / 65_535 * weight
            output[1] += Double(sample.green) / 65_535 * weight
            output[2] += Double(sample.blue) / 65_535 * weight
        }
        return output
    }

    private struct Coordinate {
        let lower: Int
        let upper: Int
        let fraction: Double
    }

    private func coordinate(_ value: Double) -> Coordinate {
        guard gridSize > 1 else {
            return Coordinate(lower: 0, upper: 0, fraction: 0)
        }
        let position = value * Double(gridSize - 1)
        let lower = min(Int(floor(position)), gridSize - 1)
        let upper = min(lower + 1, gridSize - 1)
        return Coordinate(lower: lower, upper: upper, fraction: upper == lower ? 0 : position - floor(position))
    }

    private func index(red: Int, green: Int, blue: Int) -> Int {
        (red * gridSize + green) * gridSize + blue
    }
}
