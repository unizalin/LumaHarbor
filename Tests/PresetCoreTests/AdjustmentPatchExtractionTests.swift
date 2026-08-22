import XCTest
@testable import PresetCore
import RawProcessingCore

/// Spec §9.2: creating a preset from a photo needs to go from a full
/// `PhotoAdjustments` to a caller-selected subset, and to default that
/// selection to "whatever differs from neutral".
final class AdjustmentPatchExtractionTests: XCTestCase {
    func testModifiedFieldsFindsEveryChangedLeaf() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.exposure = 1.0
        adjustments.hsl.red.hue = -20
        adjustments.splitToning.balance = 10
        adjustments.sharpening.amount = 40

        let modified = AdjustmentPatch.modifiedFields(in: adjustments)
        XCTAssertEqual(modified, [.basicExposure, .hslRedHue, .splitToningBalance, .sharpeningAmount])
    }

    func testModifiedFieldsIsEmptyForNeutral() {
        XCTAssertTrue(AdjustmentPatch.modifiedFields(in: .neutral).isEmpty)
    }

    func testModifiedFieldsIncludesToneCurveWhenNotIdentity() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.advancedToneCurve = AdvancedToneCurve(points: [ToneCurvePoint(x: 0.5, y: 0.6)])
        XCTAssertTrue(AdjustmentPatch.modifiedFields(in: adjustments).contains(.advancedToneCurve))
    }

    func testExtractingOnlyIncludesSelectedFields() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.exposure = 1.0
        adjustments.contrast = 20 // not selected below

        let patch = AdjustmentPatch.extracting([.basicExposure], from: adjustments)
        XCTAssertEqual(patch.basic?.exposure, 1.0)
        XCTAssertNil(patch.basic?.contrast, "Only the selected field should be present")
    }

    func testExtractingCanIncludeAFieldStillAtItsDefaultValue() {
        // Spec §9.2: the user may deliberately include a field that's still
        // at its default -- that's different from the field being absent.
        let patch = AdjustmentPatch.extracting([.basicContrast], from: .neutral)
        XCTAssertEqual(patch.basic?.contrast, 0)
        XCTAssertTrue(patch.contains(.basicContrast))
    }

    func testExtractingToneCurve() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.advancedToneCurve = AdvancedToneCurve(points: [ToneCurvePoint(x: 0.25, y: 0.75)])
        let patch = AdjustmentPatch.extracting([.advancedToneCurve], from: adjustments)
        XCTAssertEqual(patch.advancedToneCurve, adjustments.advancedToneCurve)
    }

    func testExcludingRemovesOnlyTheGivenFields() {
        let patch = AdjustmentPatch(
            basic: BasicAdjustmentPatch(exposure: 1.0, contrast: 20),
            splitToning: SplitToningPatch(balance: 5)
        )
        let filtered = patch.excluding([.basicContrast])
        XCTAssertEqual(filtered.basic?.exposure, 1.0)
        XCTAssertNil(filtered.basic?.contrast)
        XCTAssertEqual(filtered.splitToning?.balance, 5, "Unrelated leaves must survive untouched")
    }

    func testExcludingToneCurve() {
        let curve = AdvancedToneCurve(points: [ToneCurvePoint(x: 0.5, y: 0.5)])
        let patch = AdjustmentPatch(basic: BasicAdjustmentPatch(exposure: 1.0), advancedToneCurve: curve)
        let filtered = patch.excluding([.advancedToneCurve])
        XCTAssertNil(filtered.advancedToneCurve)
        XCTAssertEqual(filtered.basic?.exposure, 1.0)
    }

    func testExcludingWithEmptySetReturnsEquivalentPatch() {
        let patch = AdjustmentPatch(basic: BasicAdjustmentPatch(exposure: 1.0))
        XCTAssertEqual(patch.excluding([]), patch)
    }

    func testExtractingEveryFieldRoundTripsThroughApplication() throws {
        var adjustments = PhotoAdjustments.neutral
        adjustments.exposure = 1.2
        adjustments.hsl.blue.saturation = 30
        adjustments.vignette.amount = -15
        adjustments.grain.roughness = 60

        let allFields = Set(AdjustmentFieldID.allCases)
        let patch = AdjustmentPatch.extracting(allFields, from: adjustments)
        let result = PresetApplicator().apply(patch, to: .neutral, mode: .replace, context: .none)
        XCTAssertEqual(result.adjustments, adjustments)
    }
}
