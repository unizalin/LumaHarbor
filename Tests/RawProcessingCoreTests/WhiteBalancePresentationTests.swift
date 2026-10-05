import XCTest
@testable import RawProcessingCore

final class WhiteBalancePresentationTests: XCTestCase {
    func testStoredOffsetCanBePresentedAsAbsoluteKelvin() {
        XCTAssertEqual(
            WhiteBalancePresentation.kelvin(forStoredOffset: 20, baselineKelvin: 5_500),
            6_400,
            accuracy: 0.001
        )
    }

    func testAbsoluteKelvinCanBeStoredAsBaselineRelativeOffset() {
        XCTAssertEqual(
            WhiteBalancePresentation.storedOffset(forKelvin: 3_200, baselineKelvin: 5_500),
            -51.1111111111,
            accuracy: 0.000001
        )
    }

    func testKelvinRoundTripUsesMiredSliderSpace() {
        for kelvin in [2_000.0, 3_200.0, 5_500.0, 6_500.0, 10_000.0, 50_000.0] {
            let slider = WhiteBalancePresentation.sliderValue(forKelvin: kelvin)
            let roundTrip = WhiteBalancePresentation.kelvin(forSliderValue: slider)
            XCTAssertEqual(roundTrip, kelvin, accuracy: 0.001)
        }
    }

    func testSliderMovesRightFromCoolToWarm() {
        XCTAssertLessThan(
            WhiteBalancePresentation.sliderValue(forKelvin: 3_200),
            WhiteBalancePresentation.sliderValue(forKelvin: 6_500)
        )
    }

    func testKelvinInputClampsToSupportedRawRange() {
        XCTAssertEqual(WhiteBalancePresentation.clampedKelvin(-1), 2_000)
        XCTAssertEqual(WhiteBalancePresentation.clampedKelvin(100_000), 50_000)
    }

    func testExtremeKelvinInputRemainsRepresentableAgainstALowRawBaseline() {
        let stored = WhiteBalancePresentation.storedOffset(forKelvin: 50_000, baselineKelvin: 3_000)
        XCTAssertLessThanOrEqual(stored, WhiteBalancePresentation.maximumStoredOffset)
        XCTAssertEqual(
            WhiteBalancePresentation.kelvin(forStoredOffset: stored, baselineKelvin: 3_000),
            50_000,
            accuracy: 0.001
        )
    }

    func testResolutionClampsTheStoredOffsetBeforeItReachesTheDecoder() {
        let resolution = WhiteBalancePresentation.resolve(
            storedOffset: -175.79691980772682,
            baselineKelvin: 4_536.72802734375
        )

        XCTAssertEqual(resolution.effectiveKelvin ?? -1, WhiteBalancePresentation.minimumKelvin, accuracy: 0.001)
        XCTAssertEqual(
            resolution.effectiveStoredOffset ?? 0,
            (WhiteBalancePresentation.minimumKelvin - 4_536.72802734375) / WhiteBalancePresentation.kelvinPerStoredUnit,
            accuracy: 0.000001
        )
        XCTAssertTrue(resolution.wasClamped)
    }

    func testResolutionRejectsAnInvalidBaselineInsteadOfInventingOne() {
        let resolution = WhiteBalancePresentation.resolve(storedOffset: 20, baselineKelvin: .nan)

        XCTAssertEqual(resolution.diagnostic, .invalidBaseline)
        XCTAssertNil(resolution.effectiveKelvin)
        XCTAssertNil(
            WhiteBalancePresentation.storedOffsetIfResolvable(
                forKelvin: 3_200,
                baselineKelvin: .nan
            )
        )
    }

    func testInvalidBaselineCannotProduceAPresentableKelvin() {
        XCTAssertNil(WhiteBalancePresentation.kelvinIfResolvable(forStoredOffset: 0, baselineKelvin: .nan))
        XCTAssertNil(WhiteBalancePresentation.kelvinIfResolvable(forStoredOffset: 0, baselineKelvin: .infinity))
        XCTAssertNil(WhiteBalancePresentation.kelvinIfResolvable(forStoredOffset: 0, baselineKelvin: -1))
        XCTAssertEqual(
            WhiteBalancePresentation.kelvinIfResolvable(forStoredOffset: 0, baselineKelvin: 5_500) ?? 0,
            5_500,
            accuracy: 0.000001
        )
    }

    func testResolutionKeepsEverySupportedBaselineAndStoredEndpointLegal() {
        let baselines = [2_000.0, 4_536.72802734375, 5_500.0, 10_000.0, 50_000.0]
        let offsets = [
            WhiteBalancePresentation.minimumStoredOffset,
            0,
            WhiteBalancePresentation.maximumStoredOffset
        ]

        for baseline in baselines {
            for offset in offsets {
                let resolution = WhiteBalancePresentation.resolve(
                    storedOffset: offset,
                    baselineKelvin: baseline
                )
                guard let kelvin = resolution.effectiveKelvin else {
                    XCTFail("missing effective Kelvin for baseline=\(baseline), offset=\(offset)")
                    continue
                }
                XCTAssertTrue(kelvin.isFinite)
                XCTAssertTrue((WhiteBalancePresentation.minimumKelvin...WhiteBalancePresentation.maximumKelvin).contains(kelvin))
            }
        }
    }

    func testDecoderRelativeOffsetUsesTheSameEffectiveKelvinBoundary() {
        let offsetKelvin = (-175.79691980772682) * WhiteBalancePresentation.kelvinPerStoredUnit
        let resolved = WhiteBalancePresentation.resolve(
            offsetKelvin: offsetKelvin,
            baselineKelvin: 4_536.72802734375
        )

        XCTAssertEqual(
            resolved ?? .nan,
            WhiteBalancePresentation.minimumKelvin - 4_536.72802734375,
            accuracy: 0.001
        )
    }
}
