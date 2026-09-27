import XCTest
@testable import RawProcessingCore

final class ProfileCalibrationCommandContractTests: XCTestCase {
    func testSanitizedOutputContainsNoPrivatePathsOrInputBasenames() throws {
        let matrix: [Float] = [1.05, 0.01, 0, 0, 0.98, 0.02, 0.01, 0, 1.03]
        let samples = [
            sample(id: "private-raw-001", source: [0.1, 0.2, 0.3], matrix: matrix),
            sample(id: "private-raw-002", source: [0.7, 0.5, 0.2], matrix: matrix),
            sample(id: "private-raw-003", source: [0.3, 0.8, 0.4], matrix: matrix)
        ]
        let result = try CameraProfileCalibrator.fit(
            id: "adobe-color-synthetic-v1",
            cameraMatch: CameraMatch(make: "Synthetic", model: "Test"),
            sourceProfileName: "Adobe Color",
            training: samples,
            holdout: [
                sample(id: "holdout-private-raw", source: [0.5, 0.4, 0.6], matrix: matrix)
            ],
            provenance: "private paired reference; sanitized"
        )

        let output = try ProfileCalibrationCommand.sanitizedOutput(for: result)
        XCTAssertFalse(output.contains("/Users/"))
        XCTAssertFalse(output.contains("/Volumes/"))
        XCTAssertFalse(output.contains("file://"))
        XCTAssertFalse(output.contains("private-raw-001"))
        XCTAssertFalse(output.contains("holdout-private-raw"))
        XCTAssertTrue(output.contains("adobe-color-synthetic-v1"))
    }

    private func sample(id: String, source: [Float], matrix: [Float]) -> CameraProfileCalibrationSample {
        CameraProfileCalibrationSample(
            rawID: id,
            sourceRGB: source,
            targetRGB: [
                matrix[0] * source[0] + matrix[1] * source[1] + matrix[2] * source[2],
                matrix[3] * source[0] + matrix[4] * source[1] + matrix[5] * source[2],
                matrix[6] * source[0] + matrix[7] * source[1] + matrix[8] * source[2]
            ]
        )
    }

    func testHelpDoesNotReadOrPrintInputData() {
        XCTAssertTrue(ProfileCalibrationCommand.help.contains("training"))
        XCTAssertTrue(ProfileCalibrationCommand.help.contains("hold-out"))
        XCTAssertFalse(ProfileCalibrationCommand.help.contains("/Users/"))
        XCTAssertFalse(ProfileCalibrationCommand.help.contains("/Volumes/"))
    }
}
