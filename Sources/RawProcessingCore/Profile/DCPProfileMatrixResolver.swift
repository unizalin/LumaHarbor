import Foundation

public enum DCPMatrixSource: String, Equatable, Sendable {
    case forwardMatrix
    case colorMatrixAdaptedToD50
}

public struct DCPResolvedMatrix: Equatable, Sendable {
    public let values: [Double]
    public let source: DCPMatrixSource
    public let interpolationWeight: Double

    public init(values: [Double], source: DCPMatrixSource, interpolationWeight: Double) {
        self.values = values
        self.source = source
        self.interpolationWeight = interpolationWeight
    }
}

public enum DCPProfileMatrixResolver {
    public enum Error: Swift.Error, Equatable, Sendable {
        case cameraMismatch
        case invalidTemperature
        case temperatureOutOfRange
        case unsupportedIlluminant(UInt16)
        case missingIlluminant
        case incompleteDualIlluminant
        case missingMatrix
        case invalidMatrix
        case singularMatrix
    }

    private struct Illuminant {
        let code: UInt16
        let kelvin: Double
        let whitePoint: [Double]
    }

    private struct MatrixPair {
        let first: [Double]
        let second: [Double]?
        let firstIlluminant: Illuminant
        let secondIlluminant: Illuminant?
        let interpolationWeight: Double
    }

    private static let d50WhitePoint = [0.96422, 1.0, 0.82521]

    private static let bradford = [
        0.8951, 0.2664, -0.1614,
        -0.7502, 1.7135, 0.0367,
        0.0389, -0.0685, 1.0296
    ]

    private static let bradfordInverse = [
        0.9869929, -0.1470543, 0.1599627,
        0.4323053, 0.5183603, 0.0492912,
        -0.0085287, 0.0400427, 0.9684867
    ]

    public static func resolve(
        document: DCPProfileDocument,
        cameraModel: String,
        captureTemperatureKelvin: Double
    ) throws -> DCPResolvedMatrix {
        guard captureTemperatureKelvin.isFinite, captureTemperatureKelvin > 0 else {
            throw Error.invalidTemperature
        }

        guard let profileCameraModel = asciiValue(
            document.value(for: DCPProfileTag.uniqueCameraModel)
        ), profileCameraModel == cameraModel else {
            throw Error.cameraMismatch
        }

        let usesForwardMatrix = document.value(for: DCPProfileTag.forwardMatrix1) != nil
            || document.value(for: DCPProfileTag.forwardMatrix2) != nil
        let matrixTags = usesForwardMatrix
            ? (DCPProfileTag.forwardMatrix1, DCPProfileTag.forwardMatrix2)
            : (DCPProfileTag.colorMatrix1, DCPProfileTag.colorMatrix2)

        let pair = try resolvePair(
            document: document,
            firstMatrixTag: matrixTags.0,
            secondMatrixTag: matrixTags.1,
            captureTemperatureKelvin: captureTemperatureKelvin
        )

        let matrix = interpolate(pair.first, pair.second, weight: pair.interpolationWeight)
        let source: DCPMatrixSource = usesForwardMatrix
            ? .forwardMatrix
            : .colorMatrixAdaptedToD50

        let resolvedValues: [Double]
        if usesForwardMatrix {
            resolvedValues = matrix
        } else {
            let sourceWhite = interpolate(
                pair.firstIlluminant.whitePoint,
                pair.secondIlluminant?.whitePoint,
                weight: pair.interpolationWeight
            )
            resolvedValues = chromaticallyAdaptToD50(matrix, sourceWhite: sourceWhite)
        }

        guard resolvedValues.allSatisfy({ $0.isFinite }) else {
            throw Error.invalidMatrix
        }
        return DCPResolvedMatrix(
            values: resolvedValues,
            source: source,
            interpolationWeight: pair.interpolationWeight
        )
    }

    private static func resolvePair(
        document: DCPProfileDocument,
        firstMatrixTag: DCPTagID,
        secondMatrixTag: DCPTagID,
        captureTemperatureKelvin: Double
    ) throws -> MatrixPair {
        let firstIlluminant = try illuminant(
            from: document.value(for: DCPProfileTag.calibrationIlluminant1)
        )
        let firstMatrix = try matrix(from: document.value(for: firstMatrixTag))

        let secondMatrixValue = document.value(for: secondMatrixTag)
        let secondIlluminantValue = document.value(for: DCPProfileTag.calibrationIlluminant2)
        guard (secondMatrixValue == nil) == (secondIlluminantValue == nil) else {
            throw Error.incompleteDualIlluminant
        }

        guard let secondMatrixValue, let secondIlluminantValue else {
            return MatrixPair(
                first: firstMatrix,
                second: nil,
                firstIlluminant: firstIlluminant,
                secondIlluminant: nil,
                interpolationWeight: 0
            )
        }

        let secondMatrix = try matrix(from: secondMatrixValue)
        let secondIlluminant = try illuminant(from: secondIlluminantValue)
        let reciprocalStart = 1.0 / firstIlluminant.kelvin
        let reciprocalEnd = 1.0 / secondIlluminant.kelvin
        let reciprocalCapture = 1.0 / captureTemperatureKelvin
        let lower = min(reciprocalStart, reciprocalEnd)
        let upper = max(reciprocalStart, reciprocalEnd)
        guard reciprocalCapture >= lower, reciprocalCapture <= upper else {
            throw Error.temperatureOutOfRange
        }

        let denominator = reciprocalEnd - reciprocalStart
        guard denominator.isFinite, abs(denominator) > .ulpOfOne else {
            throw Error.invalidTemperature
        }
        let weight = (reciprocalCapture - reciprocalStart) / denominator
        guard weight.isFinite, weight >= 0, weight <= 1 else {
            throw Error.temperatureOutOfRange
        }

        return MatrixPair(
            first: firstMatrix,
            second: secondMatrix,
            firstIlluminant: firstIlluminant,
            secondIlluminant: secondIlluminant,
            interpolationWeight: weight
        )
    }

    private static func illuminant(from value: DCPTagValue?) throws -> Illuminant {
        guard let code = unsignedInteger(from: value) else {
            throw Error.missingIlluminant
        }

        switch code {
        case 17:
            return Illuminant(code: code, kelvin: 2_856, whitePoint: [1.09850, 1.0, 0.35585])
        case 20:
            return Illuminant(code: code, kelvin: 5_500, whitePoint: [0.95682, 1.0, 0.92149])
        case 21:
            return Illuminant(code: code, kelvin: 6_504, whitePoint: [0.95047, 1.0, 1.08883])
        case 22:
            return Illuminant(code: code, kelvin: 7_500, whitePoint: [0.94972, 1.0, 1.22638])
        case 23:
            return Illuminant(code: code, kelvin: 5_003, whitePoint: d50WhitePoint)
        default:
            throw Error.unsupportedIlluminant(code)
        }
    }

    private static func matrix(from value: DCPTagValue?) throws -> [Double] {
        guard let value else {
            throw Error.missingMatrix
        }

        let values: [Double]
        switch value {
        case let .rational(rationals):
            values = try rationals.map { rational in
                guard rational.denominator != 0 else {
                    throw Error.invalidMatrix
                }
                return Double(rational.numerator) / Double(rational.denominator)
            }
        case let .signedRational(rationals):
            values = try rationals.map { rational in
                guard rational.denominator != 0 else {
                    throw Error.invalidMatrix
                }
                return Double(rational.numerator) / Double(rational.denominator)
            }
        case let .float(floatValues):
            values = floatValues.map { Double($0) }
        case let .double(doubleValues):
            values = doubleValues
        default:
            throw Error.invalidMatrix
        }

        guard values.count == 9, values.allSatisfy({ $0.isFinite }) else {
            throw Error.invalidMatrix
        }
        guard abs(determinant(values)) > 1e-12 else {
            throw Error.singularMatrix
        }
        return values
    }

    private static func asciiValue(_ value: DCPTagValue?) -> String? {
        guard case let .ascii(string) = value else {
            return nil
        }
        return string
    }

    private static func unsignedInteger(from value: DCPTagValue?) -> UInt16? {
        switch value {
        case let .unsignedShort(values):
            return values.first
        case let .unsignedLong(values):
            guard let first = values.first, first <= UInt32(UInt16.max) else {
                return nil
            }
            return UInt16(first)
        default:
            return nil
        }
    }

    private static func interpolate(
        _ first: [Double],
        _ second: [Double]?,
        weight: Double
    ) -> [Double] {
        guard let second else {
            return first
        }
        return zip(first, second).map { firstValue, secondValue in
            firstValue + (secondValue - firstValue) * weight
        }
    }

    private static func chromaticallyAdaptToD50(
        _ matrix: [Double],
        sourceWhite: [Double]
    ) -> [Double] {
        let sourceConeResponse = multiplyVector(bradford, sourceWhite)
        let destinationConeResponse = multiplyVector(bradford, d50WhitePoint)
        let scale = zip(destinationConeResponse, sourceConeResponse).map { destination, source in
            source == 0 ? 1 : destination / source
        }
        let diagonal = [
            scale[0], 0, 0,
            0, scale[1], 0,
            0, 0, scale[2]
        ]
        let adaptation = multiplyMatrices(multiplyMatrices(bradfordInverse, diagonal), bradford)
        return multiplyMatrices(adaptation, matrix)
    }

    private static func multiplyMatrices(_ lhs: [Double], _ rhs: [Double]) -> [Double] {
        var result = Array(repeating: 0.0, count: 9)
        for row in 0..<3 {
            for column in 0..<3 {
                result[row * 3 + column] = (0..<3).reduce(0.0) { partial, index in
                    partial + lhs[row * 3 + index] * rhs[index * 3 + column]
                }
            }
        }
        return result
    }

    private static func multiplyVector(_ matrix: [Double], _ vector: [Double]) -> [Double] {
        (0..<3).map { row in
            (0..<3).reduce(0.0) { partial, column in
                partial + matrix[row * 3 + column] * vector[column]
            }
        }
    }

    private static func determinant(_ matrix: [Double]) -> Double {
        matrix[0] * (matrix[4] * matrix[8] - matrix[5] * matrix[7])
            - matrix[1] * (matrix[3] * matrix[8] - matrix[5] * matrix[6])
            + matrix[2] * (matrix[3] * matrix[7] - matrix[4] * matrix[6])
    }
}
