import CryptoKit
import Foundation

/// A distributable, camera-scoped approximation of an Adobe Camera Raw
/// profile. It deliberately contains only public numeric coefficients; no
/// Adobe DCP table or per-photo exception is allowed in this value.
public struct CameraProfileFallback: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let version: Int
    public let cameraMatch: CameraMatch
    public let sourceProfileName: String
    public let matrix3x3: [Float]
    public let redToneLUT: [Float]
    public let greenToneLUT: [Float]
    public let blueToneLUT: [Float]
    public let provenance: String

    public enum ValidationError: Error, Equatable, Sendable {
        case emptyIdentifier
        case invalidVersion
        case invalidMatrixCount
        case nonFiniteMatrix
        case invalidLUTCount
        case nonFiniteLUT
        case nonMonotonicLUT
        case invalidLUTEndpoints
        case emptySourceProfileName
        case emptyProvenance
    }

    public init(
        id: String,
        version: Int,
        cameraMatch: CameraMatch,
        sourceProfileName: String,
        matrix3x3: [Float],
        redToneLUT: [Float],
        greenToneLUT: [Float],
        blueToneLUT: [Float],
        provenance: String
    ) throws {
        self.id = id
        self.version = version
        self.cameraMatch = cameraMatch
        self.sourceProfileName = sourceProfileName
        self.matrix3x3 = matrix3x3
        self.redToneLUT = redToneLUT
        self.greenToneLUT = greenToneLUT
        self.blueToneLUT = blueToneLUT
        self.provenance = provenance
        try validate()
    }

    /// Codable must reject malformed generated data before it can reach Core
    /// Image. This also keeps a hand-edited sidecar from injecting NaN values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.version = try container.decode(Int.self, forKey: .version)
        self.cameraMatch = try container.decode(CameraMatch.self, forKey: .cameraMatch)
        self.sourceProfileName = try container.decode(String.self, forKey: .sourceProfileName)
        self.matrix3x3 = try container.decode([Float].self, forKey: .matrix3x3)
        self.redToneLUT = try container.decode([Float].self, forKey: .redToneLUT)
        self.greenToneLUT = try container.decode([Float].self, forKey: .greenToneLUT)
        self.blueToneLUT = try container.decode([Float].self, forKey: .blueToneLUT)
        self.provenance = try container.decode(String.self, forKey: .provenance)
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case id, version, cameraMatch, sourceProfileName, matrix3x3
        case redToneLUT, greenToneLUT, blueToneLUT, provenance
    }

    public func validate() throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyIdentifier
        }
        guard version > 0 else { throw ValidationError.invalidVersion }
        guard !sourceProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptySourceProfileName
        }
        guard !provenance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyProvenance
        }
        guard matrix3x3.count == 9 else { throw ValidationError.invalidMatrixCount }
        guard matrix3x3.allSatisfy(\.isFinite) else { throw ValidationError.nonFiniteMatrix }
        try Self.validateLUT(redToneLUT)
        try Self.validateLUT(greenToneLUT)
        try Self.validateLUT(blueToneLUT)
    }

    public var isIdentity: Bool {
        matrix3x3 == [1, 0, 0, 0, 1, 0, 0, 0, 1]
            && redToneLUT == Self.identityLUT
            && greenToneLUT == Self.identityLUT
            && blueToneLUT == Self.identityLUT
    }

    /// Stable digest for artifact admission. It covers only the public
    /// coefficient payload and never includes a source path or image bytes.
    public var coefficientDigest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static let identityLUT: [Float] = [0, 1]

    private static func validateLUT(_ values: [Float]) throws {
        guard values.count >= 2, values.count <= 256 else {
            throw ValidationError.invalidLUTCount
        }
        guard values.allSatisfy(\.isFinite) else { throw ValidationError.nonFiniteLUT }
        guard values.first == 0, values.last == 1 else {
            throw ValidationError.invalidLUTEndpoints
        }
        guard zip(values, values.dropFirst()).allSatisfy({ $0 <= $1 }) else {
            throw ValidationError.nonMonotonicLUT
        }
    }
}

public enum CameraProfileCalibrationColorDomain: String, Codable, Equatable, Hashable, Sendable {
    case linearDisplayP3V1 = "linear-display-p3-v1"
    case encodedSRGBV1 = "encoded-srgb-v1"
}

public struct CameraProfileCalibrationSample: Codable, Equatable, Hashable, Sendable {
    public let rawID: String
    public let sourceRGB: [Float]
    public let targetRGB: [Float]
    public let colorDomain: CameraProfileCalibrationColorDomain

    public init(
        rawID: String,
        sourceRGB: [Float],
        targetRGB: [Float],
        colorDomain: CameraProfileCalibrationColorDomain = .linearDisplayP3V1
    ) {
        self.rawID = rawID
        self.sourceRGB = sourceRGB
        self.targetRGB = targetRGB
        self.colorDomain = colorDomain
    }
}

public struct CameraProfileCalibrationMetrics: Codable, Equatable, Hashable, Sendable {
    public let sampleCount: Int
    public let rmse: Double
    public let maxAbsoluteError: Double

    public init(sampleCount: Int, rmse: Double, maxAbsoluteError: Double) {
        self.sampleCount = sampleCount
        self.rmse = rmse
        self.maxAbsoluteError = maxAbsoluteError
    }
}

public struct CameraProfileCalibrationResult: Codable, Equatable, Hashable, Sendable {
    public let fallback: CameraProfileFallback
    public let manifest: ProfileCalibrationArtifactManifest
    public let trainingMetrics: CameraProfileCalibrationMetrics
    public let holdoutMetrics: CameraProfileCalibrationMetrics
    public let baselineHoldoutMetrics: CameraProfileCalibrationMetrics

    public init(
        fallback: CameraProfileFallback,
        manifest: ProfileCalibrationArtifactManifest,
        trainingMetrics: CameraProfileCalibrationMetrics,
        holdoutMetrics: CameraProfileCalibrationMetrics,
        baselineHoldoutMetrics: CameraProfileCalibrationMetrics
    ) {
        self.fallback = fallback
        self.manifest = manifest
        self.trainingMetrics = trainingMetrics
        self.holdoutMetrics = holdoutMetrics
        self.baselineHoldoutMetrics = baselineHoldoutMetrics
    }
}

public enum CameraProfileCalibrationError: Error, Equatable, Sendable {
    case emptyTrainingSet
    case emptyHoldoutSet
    case invalidSample(String)
    case unsupportedColorDomain(String)
    case overlappingSampleIDs
    case singularTrainingMatrix
    case holdoutDidNotImprove
}

/// Deterministic least-squares fitter for the public v1 fallback format.
/// Training samples are the only inputs to the fit; hold-out samples are read
/// after fitting and can only accept or reject the result.
public enum CameraProfileCalibrator {
    public static func fit(
        id: String,
        cameraMatch: CameraMatch,
        sourceProfileName: String,
        training: [CameraProfileCalibrationSample],
        holdout: [CameraProfileCalibrationSample],
        provenance: String
    ) throws -> CameraProfileCalibrationResult {
        guard !training.isEmpty else { throw CameraProfileCalibrationError.emptyTrainingSet }
        guard !holdout.isEmpty else { throw CameraProfileCalibrationError.emptyHoldoutSet }
        let trainingIDs = Set(training.map(\.rawID))
        guard trainingIDs.count == training.count,
              trainingIDs.isDisjoint(with: Set(holdout.map(\.rawID))) else {
            throw CameraProfileCalibrationError.overlappingSampleIDs
        }
        try validate(training)
        try validate(holdout)

        let matrix = try solveMatrix(training)
        let fallback = try CameraProfileFallback(
            id: id,
            version: 1,
            cameraMatch: cameraMatch,
            sourceProfileName: sourceProfileName,
            matrix3x3: matrix,
            redToneLUT: CameraProfileFallback.identityLUT,
            greenToneLUT: CameraProfileFallback.identityLUT,
            blueToneLUT: CameraProfileFallback.identityLUT,
            provenance: provenance
        )
        let manifest = ProfileCalibrationArtifactManifest(
            policy: .adobeProcess2012V1,
            cameraMatch: cameraMatch,
            canonicalProfileName: sourceProfileName,
            artifactID: id,
            artifactVersion: 1,
            decoderOptionVectorID: CoreImageRawPolicy.optionVector(for: .adobeProcess2012V1)?.id
                ?? "adobe-process-2012-v1-preserve-defaults-v1",
            workingColorSpaceID: RawWorkingColorSpaceID.adobeCompatibleLinearWideGamutV1.rawValue,
            outputTransformID: RawOutputTransformID.displaySRGBV1.rawValue,
            provenance: provenance,
            coefficientDigest: fallback.coefficientDigest
        )
        try manifest.validate(fallback: fallback)
        let trainingMetrics = metrics(for: training, matrix: matrix)
        let holdoutMetrics = metrics(for: holdout, matrix: matrix)
        let baselineHoldoutMetrics = metrics(
            for: holdout,
            matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1]
        )
        guard holdoutMetrics.rmse < baselineHoldoutMetrics.rmse else {
            throw CameraProfileCalibrationError.holdoutDidNotImprove
        }
        return CameraProfileCalibrationResult(
            fallback: fallback,
            manifest: manifest,
            trainingMetrics: trainingMetrics,
            holdoutMetrics: holdoutMetrics,
            baselineHoldoutMetrics: baselineHoldoutMetrics
        )
    }

    private static func validate(_ samples: [CameraProfileCalibrationSample]) throws {
        for sample in samples {
            guard sample.colorDomain == .linearDisplayP3V1 else {
                throw CameraProfileCalibrationError.unsupportedColorDomain(sample.colorDomain.rawValue)
            }
            guard sample.sourceRGB.count == 3,
                  sample.targetRGB.count == 3,
                  sample.sourceRGB.allSatisfy(\.isFinite),
                  sample.targetRGB.allSatisfy(\.isFinite) else {
                throw CameraProfileCalibrationError.invalidSample(sample.rawID)
            }
        }
    }

    private static func solveMatrix(_ samples: [CameraProfileCalibrationSample]) throws -> [Float] {
        var normal = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        var right = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        for sample in samples {
            let x = sample.sourceRGB.map(Double.init)
            let y = sample.targetRGB.map(Double.init)
            for row in 0..<3 {
                for column in 0..<3 {
                    normal[row][column] += x[row] * x[column]
                    right[row][column] += y[row] * x[column]
                }
            }
        }

        let inverse = try invert3x3(normal)
        var matrix = Array(repeating: Float.zero, count: 9)
        for row in 0..<3 {
            for column in 0..<3 {
                matrix[row * 3 + column] = Float((0..<3).reduce(0.0) {
                    $0 + right[row][$1] * inverse[$1][column]
                })
            }
        }
        return matrix
    }

    private static func invert3x3(_ input: [[Double]]) throws -> [[Double]] {
        var a = input
        var inverse = [[1.0, 0, 0], [0, 1, 0], [0, 0, 1]]
        for pivot in 0..<3 {
            guard let pivotRow = (pivot..<3).max(by: { abs(a[$0][pivot]) < abs(a[$1][pivot]) }),
                  abs(a[pivotRow][pivot]) > 1e-9 else {
                throw CameraProfileCalibrationError.singularTrainingMatrix
            }
            if pivotRow != pivot {
                a.swapAt(pivot, pivotRow)
                inverse.swapAt(pivot, pivotRow)
            }
            let divisor = a[pivot][pivot]
            for column in 0..<3 {
                a[pivot][column] /= divisor
                inverse[pivot][column] /= divisor
            }
            for row in 0..<3 where row != pivot {
                let factor = a[row][pivot]
                for column in 0..<3 {
                    a[row][column] -= factor * a[pivot][column]
                    inverse[row][column] -= factor * inverse[pivot][column]
                }
            }
        }
        return inverse
    }

    private static func metrics(
        for samples: [CameraProfileCalibrationSample],
        matrix: [Float]
    ) -> CameraProfileCalibrationMetrics {
        var squaredError = 0.0
        var maxAbsoluteError = 0.0
        for sample in samples {
            let source = sample.sourceRGB
            let predicted = [
                matrix[0] * source[0] + matrix[1] * source[1] + matrix[2] * source[2],
                matrix[3] * source[0] + matrix[4] * source[1] + matrix[5] * source[2],
                matrix[6] * source[0] + matrix[7] * source[1] + matrix[8] * source[2]
            ]
            for channel in 0..<3 {
                let error = Double(predicted[channel] - sample.targetRGB[channel])
                squaredError += error * error
                maxAbsoluteError = max(maxAbsoluteError, abs(error))
            }
        }
        let denominator = Double(max(samples.count * 3, 1))
        return CameraProfileCalibrationMetrics(
            sampleCount: samples.count,
            rmse: (squaredError / denominator).squareRoot(),
            maxAbsoluteError: maxAbsoluteError
        )
    }
}

/// The CLI-facing serializer intentionally excludes every sample ID and every
/// source path. The generated report can therefore be committed or attached
/// to a build without leaking the private corpus layout.
public enum ProfileCalibrationCommand {
    public static let help = """
    Usage: LumaHarborProfileCalibrate
      Reads JSON paired samples from LUMAHARBOR_PROFILE_TRAINING_JSON and
      LUMAHARBOR_PROFILE_HOLDOUT_JSON, then prints sanitized coefficients and
      aggregate training/hold-out metrics. Every sample must declare
      colorDomain=linear-display-p3-v1. No input path or raw ID is emitted.
    """

    public static func sanitizedOutput(for result: CameraProfileCalibrationResult) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(result), as: UTF8.self)
    }
}
