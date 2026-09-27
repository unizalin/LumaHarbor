import XCTest
@testable import RawProcessingCore

final class CameraProfileCalibrationTests: XCTestCase {
    func testCalibrationSampleDecodingFailsClosedWhenColorDomainIsMissing() throws {
        let legacyJSON = Data(#"{"rawID":"legacy","sourceRGB":[0.1,0.2,0.3],"targetRGB":[0.2,0.3,0.4]}"#.utf8)

        XCTAssertThrowsError(
            try JSONDecoder().decode(CameraProfileCalibrationSample.self, from: legacyJSON)
        )
    }

    func testEncodedSRGBSamplesAreRejectedBeforeMatrixFit() throws {
        let matrix: [Float] = [
            1.08, 0.02, 0.01,
            0.01, 0.96, 0.03,
            0.02, 0.01, 1.04
        ]
        func target(for source: [Float]) -> [Float] {
            [
                matrix[0] * source[0] + matrix[1] * source[1] + matrix[2] * source[2],
                matrix[3] * source[0] + matrix[4] * source[1] + matrix[5] * source[2],
                matrix[6] * source[0] + matrix[7] * source[1] + matrix[8] * source[2]
            ]
        }
        func sampleData(id: String, source: [Float], target: [Float]) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "rawID": id,
                "sourceRGB": source,
                "targetRGB": target,
                "colorDomain": "encoded-srgb-v1"
            ])
        }

        let decoder = JSONDecoder()
        let sources: [[Float]] = [
            [0.1, 0.2, 0.3], [0.8, 0.1, 0.2], [0.2, 0.9, 0.4],
            [0.4, 0.3, 0.8], [0.7, 0.6, 0.2], [0.9, 0.8, 0.7]
        ]
        let training = try sources.enumerated().map { index, source in
            try decoder.decode(
                CameraProfileCalibrationSample.self,
                from: sampleData(id: "train-\(index)", source: source, target: target(for: source))
            )
        }
        let holdout = try sources.prefix(3).enumerated().map { index, source in
            try decoder.decode(
                CameraProfileCalibrationSample.self,
                from: sampleData(id: "holdout-\(index)", source: source, target: target(for: source))
            )
        }

        XCTAssertThrowsError(try CameraProfileCalibrator.fit(
            id: "encoded-srgb-must-not-fit",
            cameraMatch: CameraMatch(make: "Synthetic", model: "Test"),
            sourceProfileName: "Adobe Color",
            training: training,
            holdout: holdout,
            provenance: "synthetic fixture"
        ))
    }

    func testSyntheticTrainingSamplesReconstructKnownMatrixOnHoldout() throws {
        let matrix: [Float] = [
            1.08, 0.02, 0.01,
            0.01, 0.96, 0.03,
            0.02, 0.01, 1.04
        ]
        let training = samples(matrix: matrix, ids: ["train-a", "train-b", "train-c", "train-d", "train-e", "train-f"])
        let holdout = samples(matrix: matrix, ids: ["holdout-a", "holdout-b", "holdout-c"])

        let result = try CameraProfileCalibrator.fit(
            id: "adobe-color-synthetic-v1",
            cameraMatch: CameraMatch(make: "Synthetic", model: "Test"),
            sourceProfileName: "Adobe Color",
            training: training,
            holdout: holdout,
            provenance: "synthetic fixture"
        )

        XCTAssertEqual(result.fallback.matrix3x3.count, 9)
        XCTAssertLessThan(result.holdoutMetrics.rmse, 0.0001)
        XCTAssertLessThan(result.holdoutMetrics.rmse, result.baselineHoldoutMetrics.rmse)
        XCTAssertEqual(result, try CameraProfileCalibrator.fit(
            id: "adobe-color-synthetic-v1",
            cameraMatch: CameraMatch(make: "Synthetic", model: "Test"),
            sourceProfileName: "Adobe Color",
            training: training,
            holdout: holdout,
            provenance: "synthetic fixture"
        ))
    }

    func testHoldoutRegressionFailsWhenFitDoesNotImproveIt() {
        let training = samples(matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1], ids: ["train-a", "train-b", "train-c"])
        let holdout = [
            CameraProfileCalibrationSample(rawID: "holdout-a", sourceRGB: [0.2, 0.3, 0.4], targetRGB: [0.5, 0.2, 0.1])
        ]

        XCTAssertThrowsError(try CameraProfileCalibrator.fit(
            id: "unstable-v1",
            cameraMatch: CameraMatch(make: "Synthetic", model: "Test"),
            sourceProfileName: "Adobe Color",
            training: training,
            holdout: holdout,
            provenance: "synthetic fixture"
        )) { error in
            XCTAssertEqual(error as? CameraProfileCalibrationError, .holdoutDidNotImprove)
        }
    }

    func testTrainingAndHoldoutIDsMustBeDisjoint() {
        let sample = CameraProfileCalibrationSample(rawID: "same", sourceRGB: [0.1, 0.2, 0.3], targetRGB: [0.1, 0.2, 0.3])
        XCTAssertThrowsError(try CameraProfileCalibrator.fit(
            id: "duplicate-v1",
            cameraMatch: CameraMatch(make: "Synthetic", model: "Test"),
            sourceProfileName: "Adobe Color",
            training: [sample],
            holdout: [sample],
            provenance: "synthetic fixture"
        )) { error in
            XCTAssertEqual(error as? CameraProfileCalibrationError, .overlappingSampleIDs)
        }
    }

    private func samples(matrix: [Float], ids: [String]) -> [CameraProfileCalibrationSample] {
        let sources: [[Float]] = [
            [0.1, 0.2, 0.3], [0.8, 0.1, 0.2], [0.2, 0.9, 0.4],
            [0.4, 0.3, 0.8], [0.7, 0.6, 0.2], [0.9, 0.8, 0.7]
        ]
        return ids.enumerated().map { index, id in
            let source = sources[index % sources.count]
            let target = [
                matrix[0] * source[0] + matrix[1] * source[1] + matrix[2] * source[2],
                matrix[3] * source[0] + matrix[4] * source[1] + matrix[5] * source[2],
                matrix[6] * source[0] + matrix[7] * source[1] + matrix[8] * source[2]
            ]
            return CameraProfileCalibrationSample(rawID: id, sourceRGB: source, targetRGB: target)
        }
    }
}
