import XCTest
import RawProcessingCore
@testable import AdjustmentUI

/// P2 (design spec §7.1, plan `2026-09-10-shared-professional-inspector-catalog.md`):
/// `InspectorCatalog` is the single declaration point for every Adjust/Geometry/Local
/// inspector section on both platforms. These tests pin the catalog's shape so a
/// future field addition only has to touch one place, and so Mac/iPad staying in
/// sync is a compile-time/test-time guarantee, not a convention.
final class InspectorCatalogTests: XCTestCase {

    // MARK: - Section inventory

    func testAllEightSectionsExist() {
        let ids = Set(InspectorCatalog.allSections.map(\.id))
        XCTAssertEqual(ids, Set(InspectorSectionID.allCases))
        XCTAssertEqual(InspectorCatalog.allSections.count, InspectorSectionID.allCases.count,
                       "no duplicate section descriptors")
    }

    func testEverySectionHasNonEmptyMetadata() {
        for section in InspectorCatalog.allSections {
            XCTAssertFalse(section.titleKey.isEmpty, "\(section.id) needs a title key")
            XCTAssertFalse(section.symbol.isEmpty, "\(section.id) needs a symbol")
            XCTAssertFalse(section.platforms.isEmpty, "\(section.id) must declare at least one platform")
        }
    }

    func testFieldIDsDoNotOverlapAcrossSections() {
        var seen = Set<String>()
        for section in InspectorCatalog.allSections {
            for field in section.fieldIDs {
                XCTAssertFalse(seen.contains(field), "field \(field) appears in more than one section")
                seen.insert(field)
            }
        }
    }

    // MARK: - Domain/submode grouping (design spec §2 table)

    func testAdjustDomainContainsSixFieldSections() {
        let ids = Set(InspectorCatalog.sections(in: .adjust).map(\.id))
        XCTAssertEqual(ids, [.basic, .whiteBalance, .hsl, .curve, .detail, .effects])
    }

    func testGeometryDomainContainsOnlyGeometrySection() {
        XCTAssertEqual(InspectorCatalog.sections(in: .geometry).map(\.id), [.geometry])
    }

    func testLocalDomainContainsOnlyLocalSection() {
        XCTAssertEqual(InspectorCatalog.sections(in: .local).map(\.id), [.local])
    }

    func testLightSubmodeIsBasicAndCurve() {
        XCTAssertEqual(Set(InspectorCatalog.sections(in: .light).map(\.id)), [.basic, .curve])
    }

    func testColorSubmodeIsWhiteBalanceAndHSL() {
        XCTAssertEqual(Set(InspectorCatalog.sections(in: .color).map(\.id)), [.whiteBalance, .hsl])
    }

    func testDetailSubmodeIsDetailAndEffects() {
        XCTAssertEqual(Set(InspectorCatalog.sections(in: .detail).map(\.id)), [.detail, .effects])
    }

    // MARK: - Field vocabulary matches the pre-existing, still-tested convention

    func testBasicSectionCoversAllEightToneKindsIncludingVibranceAndSaturation() {
        let fields = Set(InspectorCatalog.section(.basic).fieldIDs)
        for kind in ["exposure", "contrast", "highlights", "shadows", "whites", "blacks", "vibrance", "saturation"] {
            XCTAssertTrue(fields.contains(kind), "basic must contain \(kind)")
        }
        XCTAssertFalse(fields.contains("temperature"), "temperature belongs to whiteBalance, not basic")
    }

    func testWhiteBalanceSectionCoversTemperatureAndTint() {
        XCTAssertEqual(Set(InspectorCatalog.section(.whiteBalance).fieldIDs), ["basic.temperature", "basic.tint"])
    }

    func testHSLSectionCoversAllTwentyFourBands() {
        XCTAssertEqual(InspectorCatalog.section(.hsl).fieldIDs.count, 24)
        XCTAssertTrue(InspectorCatalog.section(.hsl).fieldIDs.contains("hsl.red.hue"))
        XCTAssertTrue(InspectorCatalog.section(.hsl).fieldIDs.contains("hsl.magenta.luminance"))
    }

    func testCurveSectionCoversAdvancedToneCurve() {
        XCTAssertEqual(InspectorCatalog.section(.curve).fieldIDs, ["advancedToneCurve"])
    }

    // MARK: - adjustmentKinds bridge (Mac/iPad shared BasicAdjustmentPanel kinds)

    func testBasicSectionBridgesToEightAdjustmentKinds() {
        let kinds = Set(InspectorCatalog.section(.basic).adjustmentKinds)
        XCTAssertEqual(kinds, [.exposure, .contrast, .highlights, .shadows, .whites, .blacks, .vibrance, .saturation])
    }

    func testWhiteBalanceSectionBridgesToTemperatureAndTintKinds() {
        XCTAssertEqual(Set(InspectorCatalog.section(.whiteBalance).adjustmentKinds), [.temperature, .tint])
    }

    func testHSLSectionBridgesToNoAdjustmentKinds() {
        // HSL fields use dotted PresetCore-style IDs with no AdjustmentKind counterpart.
        XCTAssertTrue(InspectorCatalog.section(.hsl).adjustmentKinds.isEmpty)
    }

    // MARK: - Reset purity

    func testResettingBasicOnlyTouchesBasicFields() {
        var adjustments = PhotoAdjustments()
        adjustments.exposure = 1.5
        adjustments.contrast = 20
        adjustments.temperature = 4000
        adjustments.hsl.red.hue = 30

        let reset = InspectorCatalog.resetting(.basic, in: adjustments)

        XCTAssertEqual(reset.exposure, PhotoAdjustments().exposure)
        XCTAssertEqual(reset.contrast, PhotoAdjustments().contrast)
        XCTAssertEqual(reset.temperature, 4000, "whiteBalance must be untouched by a basic reset")
        XCTAssertEqual(reset.hsl.red.hue, 30, "hsl must be untouched by a basic reset")
    }

    func testResettingCurveOnlyTouchesCurve() {
        var adjustments = PhotoAdjustments()
        adjustments.exposure = 1.0
        adjustments.advancedToneCurve = AdvancedToneCurve(points: [ToneCurvePoint(x: 0.2, y: 0.4)])

        let reset = InspectorCatalog.resetting(.curve, in: adjustments)

        XCTAssertEqual(reset.advancedToneCurve, .neutral)
        XCTAssertEqual(reset.exposure, 1.0, "exposure must be untouched by a curve reset")
    }

    func testResettingGeometryOnlyTouchesGeometry() {
        var adjustments = PhotoAdjustments()
        adjustments.exposure = 1.0
        adjustments.geometry.straightenDegrees = 5

        let reset = InspectorCatalog.resetting(.geometry, in: adjustments)

        XCTAssertEqual(reset.geometry, .neutral)
        XCTAssertEqual(reset.exposure, 1.0)
    }

    func testResettingLocalOnlyTouchesLocalAdjustments() {
        var adjustments = PhotoAdjustments()
        adjustments.exposure = 1.0
        adjustments.localAdjustments = [LocalAdjustment(kind: .spotHeal)]

        let reset = InspectorCatalog.resetting(.local, in: adjustments)

        XCTAssertTrue(reset.localAdjustments.isEmpty)
        XCTAssertEqual(reset.exposure, 1.0)
    }

    func testResettingAdjustDomainClearsAllSixFieldSectionsButNotGeometryOrLocal() {
        var adjustments = PhotoAdjustments()
        adjustments.exposure = 1.0
        adjustments.temperature = 4000
        adjustments.hsl.red.hue = 30
        adjustments.advancedToneCurve = AdvancedToneCurve(points: [ToneCurvePoint(x: 0.2, y: 0.4)])
        adjustments.sharpening.amount = 50
        adjustments.vignette.amount = 20
        adjustments.geometry.straightenDegrees = 5
        adjustments.localAdjustments = [LocalAdjustment(kind: .spotHeal)]

        let reset = InspectorCatalog.resetting(domain: .adjust, in: adjustments)

        XCTAssertEqual(reset.exposure, PhotoAdjustments().exposure)
        XCTAssertEqual(reset.temperature, PhotoAdjustments().temperature)
        XCTAssertEqual(reset.hsl, .neutral)
        XCTAssertEqual(reset.advancedToneCurve, .neutral)
        XCTAssertEqual(reset.sharpening, .neutral)
        XCTAssertEqual(reset.vignette, .neutral)
        XCTAssertEqual(reset.geometry.straightenDegrees, 5, "geometry domain must be untouched by an adjust-domain reset")
        XCTAssertFalse(reset.localAdjustments.isEmpty, "local must be untouched by an adjust-domain reset")
    }

    // MARK: - isNeutral

    func testIsNeutralTrueForFreshAdjustments() {
        XCTAssertTrue(InspectorCatalog.isNeutral(.basic, in: PhotoAdjustments()))
        XCTAssertTrue(InspectorCatalog.isNeutral(domain: .adjust, in: PhotoAdjustments()))
    }

    func testIsNeutralFalseAfterEditingASectionField() {
        var adjustments = PhotoAdjustments()
        adjustments.exposure = 1.0
        XCTAssertFalse(InspectorCatalog.isNeutral(.basic, in: adjustments))
        XCTAssertFalse(InspectorCatalog.isNeutral(domain: .adjust, in: adjustments))
        XCTAssertTrue(InspectorCatalog.isNeutral(.curve, in: adjustments), "editing basic must not mark curve non-neutral")
    }

    // MARK: - Search

    func testSearchMatchesByFieldID() {
        let results = InspectorCatalog.search("exposure")
        XCTAssertTrue(results.contains(where: { $0.id == .basic }))
    }

    func testSearchMatchesBySynonymToken() {
        let results = InspectorCatalog.search("crop")
        XCTAssertTrue(results.contains(where: { $0.id == .geometry }))
    }

    func testSearchMatchesByTitleKeySubstringCaseInsensitive() {
        let results = InspectorCatalog.search("EFFE")
        XCTAssertTrue(results.contains(where: { $0.id == .effects }))
    }

    func testSearchIsEmptyForBlankQuery() {
        XCTAssertTrue(InspectorCatalog.search("").isEmpty)
        XCTAssertTrue(InspectorCatalog.search("   ").isEmpty)
    }

    func testSearchReturnsNoMatchesForNonsenseQuery() {
        XCTAssertTrue(InspectorCatalog.search("zzz-not-a-real-tool-zzz").isEmpty)
    }
}
