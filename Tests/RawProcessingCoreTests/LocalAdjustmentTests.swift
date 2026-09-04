import XCTest
@testable import RawProcessingCore

final class LocalAdjustmentTests: XCTestCase {
    // MARK: - Construction / defaults

    func testDefaultLocalAdjustmentIsEnabledWithNeutralGeometryAndEmptyPatch() {
        let gradient = LocalAdjustment(kind: .linearGradient)
        XCTAssertTrue(gradient.isEnabled)
        XCTAssertEqual(gradient.geometry, .neutral)
        XCTAssertTrue(gradient.adjustments.isEmpty)
    }

    func testEachInstanceGetsAFreshID() {
        let first = LocalAdjustment(kind: .linearGradient)
        let second = LocalAdjustment(kind: .linearGradient)
        XCTAssertNotEqual(first.id, second.id)
    }

    // MARK: - Enable / disable / delete (schema-level: Task 4.1 has no render/UI/service yet)

    func testDisablingLeavesEverythingElseUnchanged() {
        var gradient = LocalAdjustment(kind: .linearGradient, adjustments: LocalAdjustmentPatch(exposure: 0.5))
        gradient.isEnabled = false
        XCTAssertFalse(gradient.isEnabled)
        XCTAssertEqual(gradient.kind, .linearGradient)
        XCTAssertEqual(gradient.adjustments.exposure, 0.5)
    }

    func testDeletingOneEntryFromAnArrayLeavesTheOthersInOrder() {
        let first = LocalAdjustment(kind: .linearGradient)
        let second = LocalAdjustment(kind: .spotHeal)
        let third = LocalAdjustment(kind: .linearGradient)
        var list = [first, second, third]
        list.removeAll { $0.id == second.id }
        XCTAssertEqual(list.map(\.id), [first.id, third.id])
    }

    // MARK: - Codable / sidecar compatibility

    func testEncodesEveryDocumentedKey() throws {
        let gradient = LocalAdjustment(kind: .linearGradient)
        let data = try JSONEncoder().encode(gradient)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "kind", "isEnabled", "geometry", "adjustments"])
    }

    func testRoundTripsThroughJSON() throws {
        let original = LocalAdjustment(
            kind: .spotHeal,
            isEnabled: false,
            geometry: LocalAdjustmentGeometry(
                x: 0.3, y: 0.4, angleDegrees: 45, range: 0.2,
                sourceX: 0.1, sourceY: 0.15, radius: 0.08, feather: 60, healMode: .clone
            ),
            adjustments: LocalAdjustmentPatch(exposure: -0.4, contrast: 12)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LocalAdjustment.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMissingOptionalKeysFallBackToDefaults() throws {
        // Only the two keys this codebase treats as non-negotiable (id, kind)
        // are present -- everything else must still open.
        let id = UUID()
        let json = Data(#"{"id": "\#(id.uuidString)", "kind": "linearGradient"}"#.utf8)
        let decoded = try JSONDecoder().decode(LocalAdjustment.self, from: json)
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.kind, .linearGradient)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.geometry, .neutral)
        XCTAssertTrue(decoded.adjustments.isEmpty)
    }

    func testMissingIDThrowsRatherThanInventingOne() {
        // A local adjustment with no `id` isn't "an older schema version" the
        // way a missing `feather` is -- it's a corrupt entry, and inventing a
        // fresh UUID here would silently detach it from anything (undo
        // history, a hit-tested selection) that already referenced the real
        // one. Same reasoning for `kind` below.
        let json = Data(#"{"kind": "linearGradient"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LocalAdjustment.self, from: json))
    }

    func testMissingKindThrowsRatherThanGuessingOne() {
        let json = Data(#"{"id": "\#(UUID().uuidString)"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LocalAdjustment.self, from: json))
    }
}

final class LocalAdjustmentGeometryTests: XCTestCase {
    func testNeutralIsACenteredPivotWithNoSource() {
        let geometry = LocalAdjustmentGeometry.neutral
        XCTAssertEqual(geometry.x, 0.5)
        XCTAssertEqual(geometry.y, 0.5)
        XCTAssertNil(geometry.sourceX)
        XCTAssertNil(geometry.sourceY)
        XCTAssertEqual(geometry.healMode, .heal)
    }

    func testPositionAndSourceClampToTheUnitSquare() {
        let geometry = LocalAdjustmentGeometry(x: 1.5, y: -0.5, sourceX: 2.0, sourceY: -1.0)
        XCTAssertEqual(geometry.x, 1)
        XCTAssertEqual(geometry.y, 0)
        XCTAssertEqual(geometry.sourceX, 1)
        XCTAssertEqual(geometry.sourceY, 0)
    }

    func testRangeAndRadiusClampToTheUnitSquare() {
        let geometry = LocalAdjustmentGeometry(range: 5, radius: -1)
        XCTAssertEqual(geometry.range, 1)
        XCTAssertEqual(geometry.radius, 0)
    }

    func testFeatherClampsToZeroToOneHundred() {
        XCTAssertEqual(LocalAdjustmentGeometry(feather: 500).feather, 100)
        XCTAssertEqual(LocalAdjustmentGeometry(feather: -10).feather, 0)
    }

    func testNonFiniteInputFallsBackSafelyRatherThanPropagatingNaN() {
        let geometry = LocalAdjustmentGeometry(x: .nan, y: .infinity, angleDegrees: .nan, range: .nan, radius: .infinity, feather: .nan)
        XCTAssertTrue(geometry.x.isFinite)
        XCTAssertTrue(geometry.y.isFinite)
        XCTAssertTrue(geometry.angleDegrees.isFinite)
        XCTAssertTrue(geometry.range.isFinite)
        XCTAssertTrue(geometry.radius.isFinite)
        XCTAssertTrue(geometry.feather.isFinite)
    }

    func testSourcePointIsOmittedFromJSONWhenNilRatherThanEncodingNull() throws {
        let data = try JSONEncoder().encode(LocalAdjustmentGeometry.neutral)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["sourceX"])
        XCTAssertNil(object["sourceY"])
    }

    func testEmptyJSONObjectDecodesToNeutral() throws {
        let decoded = try JSONDecoder().decode(LocalAdjustmentGeometry.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, .neutral)
    }

    func testOutOfRangeValuesInJSONAreClampedNotRejected() throws {
        let json = Data(#"{"x": 9, "feather": 999, "healMode": "clone"}"#.utf8)
        let decoded = try JSONDecoder().decode(LocalAdjustmentGeometry.self, from: json)
        XCTAssertEqual(decoded.x, 1)
        XCTAssertEqual(decoded.feather, 100)
        XCTAssertEqual(decoded.healMode, .clone)
    }
}

final class LocalAdjustmentPatchTests: XCTestCase {
    func testDefaultPatchIsEmpty() {
        XCTAssertTrue(LocalAdjustmentPatch().isEmpty)
    }

    func testAnySetFieldMakesItNonEmpty() {
        XCTAssertFalse(LocalAdjustmentPatch(exposure: 0).isEmpty, "explicitly set to 0 is still a set field")
        XCTAssertFalse(LocalAdjustmentPatch(tint: 5).isEmpty)
    }

    func testOnlySetFieldsAreEncoded() throws {
        let data = try JSONEncoder().encode(LocalAdjustmentPatch(exposure: 0.5, saturation: -10))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["exposure", "saturation"])
    }

    func testEmptyPatchRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(LocalAdjustmentPatch())
        let decoded = try JSONDecoder().decode(LocalAdjustmentPatch.self, from: data)
        XCTAssertTrue(decoded.isEmpty)
    }

    func testCoversExactlyTheNineFieldsTheDesignSpecLists() throws {
        // Design spec §6.6: 曝光、對比、高光、陰影、白色、黑色、飽和度、色溫、色調
        // -- deliberately no `vibrance`, unlike `AdjustmentCatalog`'s ten basic
        // sliders.
        var patch = LocalAdjustmentPatch()
        patch.exposure = 1
        patch.contrast = 1
        patch.highlights = 1
        patch.shadows = 1
        patch.whites = 1
        patch.blacks = 1
        patch.saturation = 1
        patch.temperature = 1
        patch.tint = 1
        let data = try JSONEncoder().encode(patch)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["exposure", "contrast", "highlights", "shadows", "whites", "blacks", "saturation", "temperature", "tint"]
        )
    }
}
