import CoreImage
import XCTest
@testable import RawProcessingCore

final class CoreImageRawPolicyTests: XCTestCase {
    func testAdobeProcess2012OptionVectorPreservesPerRAWDecoderDefaultsUntilCalibrated() {
        let vector = CoreImageRawOptionVector.adobeProcess2012V1

        XCTAssertEqual(vector.id, "adobe-process-2012-v1-preserve-defaults-v1")
        XCTAssertNil(vector.exposure)
        XCTAssertNil(vector.baselineExposure)
        XCTAssertNil(vector.shadowBias)
        XCTAssertNil(vector.boostAmount)
        XCTAssertNil(vector.boostShadowAmount)
        XCTAssertNil(vector.gamutMappingEnabled)
        XCTAssertNil(vector.luminanceNoiseReductionAmount)
        XCTAssertNil(vector.colorNoiseReductionAmount)
        XCTAssertNil(vector.sharpnessAmount)
        XCTAssertNil(vector.contrastAmount)
        XCTAssertNil(vector.detailAmount)
        XCTAssertNil(vector.moireReductionAmount)
        XCTAssertNil(vector.localToneMapAmount)
        XCTAssertNil(vector.extendedDynamicRangeAmount)
        XCTAssertNil(vector.highlightRecoveryEnabled)
    }

    func testNativePolicyDoesNotRequestAnAdobeOptionVector() {
        XCTAssertNil(CoreImageRawPolicy.optionVector(for: .native))
    }

    func testDecoderVersionSelectionUsesTheSameKnownVersionOnEveryPlatform() {
        let result = CoreImageRawPolicy.resolveAdobeProcess2012V1(
            supportedDecoderVersions: ["6", "9", "8"]
        )

        XCTAssertEqual(result.decoderVersion, "9")
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testUnsupportedDecoderVersionFallsBackWithAnHonestDiagnostic() {
        let result = CoreImageRawPolicy.resolveAdobeProcess2012V1(
            supportedDecoderVersions: ["3", "4"]
        )

        XCTAssertNil(result.decoderVersion)
        XCTAssertEqual(result.diagnostics, [.rawDecoderVersionFallback])
    }

    func testOrientationMappingIsExplicitAndInvalidMetadataIsUp() {
        XCTAssertEqual(CoreImageRawPolicy.orientation(for: 6), .right)
        XCTAssertEqual(CoreImageRawPolicy.orientation(for: 8), .left)
        XCTAssertEqual(CoreImageRawPolicy.orientation(for: nil), .up)
        XCTAssertEqual(CoreImageRawPolicy.orientation(for: 99), .up)
    }
}
