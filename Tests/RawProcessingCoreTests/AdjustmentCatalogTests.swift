import XCTest
@testable import RawProcessingCore

final class AdjustmentCatalogTests: XCTestCase {
    func testCatalogCoversEveryAdjustmentKindExactlyOnce() {
        let kinds = AdjustmentCatalog.ordered.map(\.kind)
        XCTAssertEqual(kinds.count, AdjustmentKind.allCases.count)
        XCTAssertEqual(Set(kinds), Set(AdjustmentKind.allCases))
    }

    func testInspectorOrderMatchesTheSpecList() {
        // Spec §6.2 lists the first-release adjustments in this order.
        XCTAssertEqual(
            AdjustmentCatalog.ordered.map(\.kind),
            [
                .exposure, .temperature, .tint, .contrast, .highlights,
                .shadows, .whites, .blacks, .vibrance, .saturation
            ]
        )
    }

    func testEveryDefaultIsNeutralAndInsideItsOwnRange() {
        for definition in AdjustmentCatalog.ordered {
            XCTAssertEqual(definition.defaultValue, 0, "\(definition.kind) should default to neutral")
            XCTAssertTrue(
                definition.contains(definition.defaultValue),
                "\(definition.kind) default sits outside its range"
            )
            XCTAssertLessThan(definition.minimumValue, definition.maximumValue)
            XCTAssertGreaterThan(definition.step, 0)
        }
    }

    func testExposureIsExpressedInStops() {
        let exposure = AdjustmentCatalog.definition(for: .exposure)
        XCTAssertEqual(exposure.minimumValue, -5)
        XCTAssertEqual(exposure.maximumValue, 5)
    }

    func testNonExposureAdjustmentsUsePlusMinusOneHundred() {
        for kind in AdjustmentKind.allCases where kind != .exposure {
            let definition = AdjustmentCatalog.definition(for: kind)
            XCTAssertEqual(definition.minimumValue, -100, "\(kind)")
            XCTAssertEqual(definition.maximumValue, 100, "\(kind)")
        }
    }

    func testClampRejectsNonFiniteValues() {
        let definition = AdjustmentCatalog.definition(for: .contrast)
        XCTAssertEqual(definition.clamp(.nan), definition.defaultValue)
        XCTAssertEqual(definition.clamp(.infinity), definition.defaultValue)
        XCTAssertEqual(definition.clamp(-.infinity), definition.defaultValue)
    }

    func testClampPinsToBounds() {
        let definition = AdjustmentCatalog.definition(for: .shadows)
        XCTAssertEqual(definition.clamp(500), 100)
        XCTAssertEqual(definition.clamp(-500), -100)
        XCTAssertEqual(definition.clamp(42), 42)
    }

    func testGroupsPartitionEveryKind() {
        let grouped = AdjustmentGroup.allCases.flatMap { AdjustmentCatalog.definitions(in: $0) }
        XCTAssertEqual(Set(grouped.map(\.kind)), Set(AdjustmentKind.allCases))
        XCTAssertEqual(grouped.count, AdjustmentKind.allCases.count)
    }
}
