import XCTest
@testable import RawProcessingCore

final class DCPProfileMatrixResolverTests: XCTestCase {
    func testPrefersForwardMatrixOverColorMatrix() throws {
        let forward = matrixValues(startingAt: 1)
        let color = matrixValues(startingAt: 9)
        let document = makeDocument(
            cameraModel: "Synthetic Camera",
            illuminant1: 23,
            colorMatrix1: color,
            forwardMatrix1: forward
        )

        let resolved = try DCPProfileMatrixResolver.resolve(
            document: document,
            cameraModel: "Synthetic Camera",
            captureTemperatureKelvin: 5_000
        )

        XCTAssertEqual(resolved.source, .forwardMatrix)
        XCTAssertEqual(resolved.values, forward)
        XCTAssertEqual(resolved.interpolationWeight, 0, accuracy: 0.000_001)
    }

    func testInterpolatesDualMatricesInReciprocalTemperatureSpace() throws {
        let first = matrixValues(startingAt: 1)
        let second = matrixValues(startingAt: 3)
        let firstTemperature = 2_856.0
        let secondTemperature = 6_504.0
        let midpoint = 2.0 / ((1.0 / firstTemperature) + (1.0 / secondTemperature))
        let document = makeDocument(
            cameraModel: "Synthetic Camera",
            illuminant1: 17,
            illuminant2: 21,
            forwardMatrix1: first,
            forwardMatrix2: second
        )

        let resolved = try DCPProfileMatrixResolver.resolve(
            document: document,
            cameraModel: "Synthetic Camera",
            captureTemperatureKelvin: midpoint
        )

        XCTAssertEqual(resolved.source, .forwardMatrix)
        XCTAssertEqual(resolved.interpolationWeight, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(resolved.values, zip(first, second).map { ($0 + $1) / 2.0 })
    }

    func testRejectsTemperatureOutsideDualIlluminantRange() {
        let document = makeDocument(
            cameraModel: "Synthetic Camera",
            illuminant1: 17,
            illuminant2: 21,
            forwardMatrix1: matrixValues(startingAt: 1),
            forwardMatrix2: matrixValues(startingAt: 3)
        )

        XCTAssertThrowsError(
            try DCPProfileMatrixResolver.resolve(
                document: document,
                cameraModel: "Synthetic Camera",
                captureTemperatureKelvin: 2_000
            )
        ) { error in
            XCTAssertEqual(error as? DCPProfileMatrixResolver.Error, .temperatureOutOfRange)
        }
    }

    func testColorMatrixFallbackAppliesD50Adaptation() throws {
        let identity = identityMatrix()
        let document = makeDocument(
            cameraModel: "Synthetic Camera",
            illuminant1: 21,
            colorMatrix1: identity
        )

        let resolved = try DCPProfileMatrixResolver.resolve(
            document: document,
            cameraModel: "Synthetic Camera",
            captureTemperatureKelvin: 6_504
        )

        XCTAssertEqual(resolved.source, .colorMatrixAdaptedToD50)
        XCTAssertEqual(resolved.values.count, 9)
        XCTAssertTrue(resolved.values.allSatisfy { $0.isFinite })
        XCTAssertNotEqual(resolved.values, identity)
    }

    func testD50ColorMatrixDoesNotReceiveUnnecessaryAdaptation() throws {
        let identity = identityMatrix()
        let document = makeDocument(
            cameraModel: "Synthetic Camera",
            illuminant1: 23,
            colorMatrix1: identity
        )

        let resolved = try DCPProfileMatrixResolver.resolve(
            document: document,
            cameraModel: "Synthetic Camera",
            captureTemperatureKelvin: 5_003
        )

        XCTAssertEqual(resolved.source, .colorMatrixAdaptedToD50)
        XCTAssertEqual(resolved.values.count, identity.count)
        for (actual, expected) in zip(resolved.values, identity) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }
    }

    func testRejectsSingularMatrix() {
        let document = makeDocument(
            cameraModel: "Synthetic Camera",
            illuminant1: 23,
            forwardMatrix1: Array(repeating: 0, count: 9)
        )

        XCTAssertThrowsError(
            try DCPProfileMatrixResolver.resolve(
                document: document,
                cameraModel: "Synthetic Camera",
                captureTemperatureKelvin: 5_003
            )
        ) { error in
            XCTAssertEqual(error as? DCPProfileMatrixResolver.Error, .singularMatrix)
        }
    }

    func testRejectsCameraModelMismatch() {
        let document = makeDocument(
            cameraModel: "Synthetic Camera",
            illuminant1: 23,
            forwardMatrix1: identityMatrix()
        )

        XCTAssertThrowsError(
            try DCPProfileMatrixResolver.resolve(
                document: document,
                cameraModel: "Other Camera",
                captureTemperatureKelvin: 5_003
            )
        ) { error in
            XCTAssertEqual(error as? DCPProfileMatrixResolver.Error, .cameraMismatch)
        }
    }

    func testRejectsIncompleteIlluminantMatrixPair() {
        let document = makeDocument(
            cameraModel: "Synthetic Camera",
            illuminant1: 17,
            illuminant2: 21,
            forwardMatrix1: identityMatrix()
        )

        XCTAssertThrowsError(
            try DCPProfileMatrixResolver.resolve(
                document: document,
                cameraModel: "Synthetic Camera",
                captureTemperatureKelvin: 5_000
            )
        ) { error in
            XCTAssertEqual(error as? DCPProfileMatrixResolver.Error, .incompleteDualIlluminant)
        }
    }

    private func makeDocument(
        cameraModel: String,
        illuminant1: UInt16,
        illuminant2: UInt16? = nil,
        colorMatrix1: [Double]? = nil,
        colorMatrix2: [Double]? = nil,
        forwardMatrix1: [Double]? = nil,
        forwardMatrix2: [Double]? = nil
    ) -> DCPProfileDocument {
        var tags: [DCPTagID: DCPTagValue] = [
            DCPProfileTag.uniqueCameraModel: .ascii(cameraModel),
            DCPProfileTag.calibrationIlluminant1: .unsignedShort([illuminant1])
        ]
        if let illuminant2 {
            tags[DCPProfileTag.calibrationIlluminant2] = .unsignedShort([illuminant2])
        }
        if let colorMatrix1 {
            tags[DCPProfileTag.colorMatrix1] = .signedRational(colorMatrix1.map(rational))
        }
        if let colorMatrix2 {
            tags[DCPProfileTag.colorMatrix2] = .signedRational(colorMatrix2.map(rational))
        }
        if let forwardMatrix1 {
            tags[DCPProfileTag.forwardMatrix1] = .signedRational(forwardMatrix1.map(rational))
        }
        if let forwardMatrix2 {
            tags[DCPProfileTag.forwardMatrix2] = .signedRational(forwardMatrix2.map(rational))
        }
        return DCPProfileDocument(byteOrder: .littleEndian, tags: tags)
    }

    private func rational(_ value: Double) -> DCPSignedRational {
        DCPSignedRational(numerator: Int32((value * 1_000).rounded()), denominator: 1_000)
    }

    private func matrixValues(startingAt start: Double) -> [Double] {
        [
            start, 0.1, 0.2,
            0.3, start + 1, 0.4,
            0.5, 0.6, start + 2
        ]
    }

    private func identityMatrix() -> [Double] {
        [
            1, 0, 0,
            0, 1, 0,
            0, 0, 1
        ]
    }
}
