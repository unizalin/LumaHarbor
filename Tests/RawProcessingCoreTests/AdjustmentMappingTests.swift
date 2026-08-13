import XCTest
@testable import RawProcessingCore

/// Spec §8.2 requires the slider-to-Core-Image mapping to be pinned by tests.
/// These assertions are the pin: changing a constant changes everyone's renders,
/// so it should have to be done deliberately.
final class AdjustmentMappingTests: XCTestCase {
    func testNeutralMapsToACompleteIdentity() {
        let parameters = AdjustmentMapping.renderParameters(for: .neutral)
        XCTAssertTrue(parameters.isExposureIdentity)
        XCTAssertTrue(parameters.isContrastIdentity)
        XCTAssertTrue(parameters.isSaturationIdentity)
        XCTAssertTrue(parameters.isVibranceIdentity)
        XCTAssertTrue(parameters.isToneCurveIdentity)
        XCTAssertTrue(parameters.whiteBalance.isAsShot)
    }

    func testExposureIsPassedThroughAsStops() {
        XCTAssertEqual(
            AdjustmentMapping.renderParameters(for: PhotoAdjustments(exposure: 1.5)).exposureEV,
            1.5
        )
        XCTAssertEqual(
            AdjustmentMapping.renderParameters(for: PhotoAdjustments(exposure: -2)).exposureEV,
            -2
        )
    }

    func testTemperatureSpansPlusMinus4500Kelvin() {
        let warm = AdjustmentMapping.renderParameters(for: PhotoAdjustments(temperature: 100))
        let cool = AdjustmentMapping.renderParameters(for: PhotoAdjustments(temperature: -100))
        XCTAssertEqual(warm.temperatureOffsetKelvin, 4_500)
        XCTAssertEqual(cool.temperatureOffsetKelvin, -4_500)
    }

    func testTintSpansPlusMinus150() {
        let parameters = AdjustmentMapping.renderParameters(for: PhotoAdjustments(tint: 100))
        XCTAssertEqual(parameters.tintOffset, 150)
    }

    func testContrastMapsToHalfToOneAndAHalf() {
        XCTAssertEqual(
            AdjustmentMapping.renderParameters(for: PhotoAdjustments(contrast: 100)).contrast,
            1.5,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            AdjustmentMapping.renderParameters(for: PhotoAdjustments(contrast: -100)).contrast,
            0.5,
            accuracy: 1e-9
        )
    }

    func testSaturationMapsToZeroToTwo() {
        XCTAssertEqual(
            AdjustmentMapping.renderParameters(for: PhotoAdjustments(saturation: -100)).saturation,
            0,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            AdjustmentMapping.renderParameters(for: PhotoAdjustments(saturation: 100)).saturation,
            2,
            accuracy: 1e-9
        )
    }

    func testVibranceMapsToTheFullFilterRange() {
        XCTAssertEqual(
            AdjustmentMapping.renderParameters(for: PhotoAdjustments(vibrance: 100)).vibrance,
            1,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            AdjustmentMapping.renderParameters(for: PhotoAdjustments(vibrance: -100)).vibrance,
            -1,
            accuracy: 1e-9
        )
    }

    func testMappingIsMonotonicAcrossEachSlider() {
        // A slider that isn't monotonic feels broken even when every endpoint is
        // right, so check the middle too.
        let values = stride(from: -100.0, through: 100.0, by: 10).map { value in
            AdjustmentMapping.renderParameters(for: PhotoAdjustments(contrast: value)).contrast
        }
        XCTAssertEqual(values, values.sorted())
    }

    func testMappingClampsHostileInput() {
        var hostile = PhotoAdjustments.neutral
        hostile.exposure = .nan
        let parameters = AdjustmentMapping.renderParameters(for: hostile)
        XCTAssertTrue(parameters.exposureEV.isFinite)
    }

    func testWhiteBalanceIsCarriedToTheDecoder() {
        // Spec §9: white balance belongs to demosaicing, so it has to reach the
        // decoder rather than being applied as a post filter.
        let parameters = AdjustmentMapping.renderParameters(
            for: PhotoAdjustments(temperature: 20, tint: -10)
        )
        XCTAssertEqual(parameters.whiteBalance.temperatureOffsetKelvin, 900)
        XCTAssertEqual(parameters.whiteBalance.tintOffset, -15)
        XCTAssertFalse(parameters.whiteBalance.isAsShot)
    }
}
