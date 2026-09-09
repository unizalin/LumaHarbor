import Foundation
import XCTest
@testable import AdjustmentUI

/// Source-contract tests for `PadInspectorDomain`, `PadAdjustSubmode`, and
/// `PadAdjustSubmodeKinds` — the AdjustmentUI vocabulary types that the
/// app-layer `PadInspectorCoordinator` is built on top of.
///
/// The coordinator class itself lives in the app target (not AdjustmentUI)
/// and is therefore not directly testable here; these tests verify the
/// stable contracts that both the coordinator and its callers depend on.
final class PadInspectorCoordinatorTests: XCTestCase {

    // MARK: - Domain contract

    func testAllFiveDomainCasesExist() {
        let all = PadInspectorDomain.allCases
        XCTAssertTrue(all.contains(.adjust))
        XCTAssertTrue(all.contains(.preset))
        XCTAssertTrue(all.contains(.geometry))
        XCTAssertTrue(all.contains(.local))
        XCTAssertTrue(all.contains(.info))
        XCTAssertEqual(all.count, 5, "exactly five domains must exist — adding or removing one is a breaking contract change")
    }

    func testDomainRawValuesMatchExpectedStrings() {
        XCTAssertEqual(PadInspectorDomain.adjust.rawValue, "adjust")
        XCTAssertEqual(PadInspectorDomain.preset.rawValue, "preset")
        XCTAssertEqual(PadInspectorDomain.geometry.rawValue, "geometry")
        XCTAssertEqual(PadInspectorDomain.local.rawValue, "local")
        XCTAssertEqual(PadInspectorDomain.info.rawValue, "info")
    }

    func testDomainEquality() {
        XCTAssertEqual(PadInspectorDomain.adjust, PadInspectorDomain.adjust)
        XCTAssertNotEqual(PadInspectorDomain.adjust, PadInspectorDomain.preset)
    }

    // MARK: - Adjust submode contract

    func testAllThreeAdjustSubmodesMustExist() {
        let all = PadAdjustSubmode.allCases
        XCTAssertTrue(all.contains(.light))
        XCTAssertTrue(all.contains(.color))
        XCTAssertTrue(all.contains(.detail))
        XCTAssertEqual(all.count, 3, "exactly three Adjust submodes must exist")
    }

    func testAdjustSubmodeRawValues() {
        XCTAssertEqual(PadAdjustSubmode.light.rawValue, "light")
        XCTAssertEqual(PadAdjustSubmode.color.rawValue, "color")
        XCTAssertEqual(PadAdjustSubmode.detail.rawValue, "detail")
    }

    // MARK: - PadAdjustSubmodeKinds — Light

    func testLightContainsCoreTonerFields() {
        let light = Set(PadAdjustSubmodeKinds.light)
        XCTAssertTrue(light.contains("exposure"))
        XCTAssertTrue(light.contains("contrast"))
        XCTAssertTrue(light.contains("highlights"))
        XCTAssertTrue(light.contains("shadows"))
        XCTAssertTrue(light.contains("whites"))
        XCTAssertTrue(light.contains("blacks"))
    }

    func testLightContainsCurveField() {
        XCTAssertTrue(PadAdjustSubmodeKinds.light.contains("advancedToneCurve"),
                      "parametric curve panel belongs to the Light submode")
    }

    func testLightDoesNotContainTemperature() {
        XCTAssertFalse(PadAdjustSubmodeKinds.light.contains("basic.temperature"),
                       "temperature belongs to color, not light")
    }

    // MARK: - PadAdjustSubmodeKinds — Color

    func testColorContainsWhiteBalanceFields() {
        let color = Set(PadAdjustSubmodeKinds.color)
        XCTAssertTrue(color.contains("basic.temperature"))
        XCTAssertTrue(color.contains("basic.tint"))
    }

    func testColorContainsVibranceAndSaturation() {
        let color = Set(PadAdjustSubmodeKinds.color)
        XCTAssertTrue(color.contains("basic.vibrance"))
        XCTAssertTrue(color.contains("basic.saturation"))
    }

    func testColorContainsHSLFields() {
        let color = Set(PadAdjustSubmodeKinds.color)
        XCTAssertTrue(color.contains("hsl.red.hue"))
        XCTAssertTrue(color.contains("hsl.red.saturation"))
        XCTAssertTrue(color.contains("hsl.red.luminance"))
    }

    // MARK: - PadAdjustSubmodeKinds — Detail

    func testDetailContainsSharpeningFields() {
        let detail = Set(PadAdjustSubmodeKinds.detail)
        XCTAssertTrue(detail.contains("sharpening.amount"))
        XCTAssertTrue(detail.contains("sharpening.radius"))
        XCTAssertTrue(detail.contains("sharpening.detail"))
        XCTAssertTrue(detail.contains("sharpening.masking"))
    }

    func testDetailContainsNoiseReductionFields() {
        let detail = Set(PadAdjustSubmodeKinds.detail)
        XCTAssertTrue(detail.contains("noiseReduction.luminanceAmount"))
        XCTAssertTrue(detail.contains("noiseReduction.colorAmount"))
    }

    func testDetailContainsVignetteFields() {
        let detail = Set(PadAdjustSubmodeKinds.detail)
        XCTAssertTrue(detail.contains("vignette.amount"))
        XCTAssertTrue(detail.contains("vignette.midpoint"))
    }

    func testDetailContainsGrainFields() {
        let detail = Set(PadAdjustSubmodeKinds.detail)
        XCTAssertTrue(detail.contains("grain.amount"))
        XCTAssertTrue(detail.contains("grain.size"))
        XCTAssertTrue(detail.contains("grain.roughness"))
    }

    // MARK: - Inspector presentation contract

    func testAllThreePresentationCasesExist() {
        // Compile-time exhaustive switch — adding or removing a case without updating
        // this switch will produce a compiler error, catching the contract break early.
        func exhaustive(_ p: PadInspectorPresentation) {
            switch p {
            case .trailingDock: break
            case .bottomDrawer: break
            case .floating:     break
            }
        }
        exhaustive(.trailingDock)
        exhaustive(.bottomDrawer)
        exhaustive(.floating)
    }

    func testPresentationRawValues() {
        XCTAssertEqual(PadInspectorPresentation.trailingDock.rawValue, "trailingDock")
        XCTAssertEqual(PadInspectorPresentation.bottomDrawer.rawValue, "bottomDrawer")
        XCTAssertEqual(PadInspectorPresentation.floating.rawValue, "floating")
    }

    func testPresentationEquality() {
        XCTAssertEqual(PadInspectorPresentation.trailingDock, .trailingDock)
        XCTAssertNotEqual(PadInspectorPresentation.trailingDock, .bottomDrawer)
        XCTAssertNotEqual(PadInspectorPresentation.trailingDock, .floating)
        XCTAssertNotEqual(PadInspectorPresentation.bottomDrawer, .floating)
    }

    // MARK: - Non-overlap invariant

    func testAllThreeSubmodesAreDisjoint() {
        let light = Set(PadAdjustSubmodeKinds.light)
        let color = Set(PadAdjustSubmodeKinds.color)
        let detail = Set(PadAdjustSubmodeKinds.detail)
        XCTAssertTrue(light.isDisjoint(with: color),
                      "a field key must not appear in more than one submode (light ∩ color)")
        XCTAssertTrue(light.isDisjoint(with: detail),
                      "a field key must not appear in more than one submode (light ∩ detail)")
        XCTAssertTrue(color.isDisjoint(with: detail),
                      "a field key must not appear in more than one submode (color ∩ detail)")
    }
}
