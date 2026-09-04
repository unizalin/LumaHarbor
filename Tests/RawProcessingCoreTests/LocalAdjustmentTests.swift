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

/// Model-level copy/delete/select operations on a `[LocalAdjustment]` list
/// (Phase 4 Task 4.2's own "model tests for copy/delete/select" requirement),
/// exercised as plain `Array` extensions -- there is no view model or
/// service yet (that is Task 4.3's job), so this is exactly what the schema
/// itself needs to support to make a future UI's duplicate/delete/select
/// actions a thin wrapper rather than reimplementing list surgery.
final class LocalAdjustmentListOperationsTests: XCTestCase {
    func testDuplicatingInsertsAFreshCopyImmediatelyAfterTheOriginal() {
        let original = LocalAdjustment(kind: .linearGradient, adjustments: LocalAdjustmentPatch(exposure: 1))
        let other = LocalAdjustment(kind: .spotHeal)
        let list = [original, other]

        let duplicated = list.duplicating(original.id)

        XCTAssertEqual(duplicated.count, 3)
        XCTAssertEqual(duplicated[0].id, original.id)
        XCTAssertNotEqual(duplicated[1].id, original.id, "the copy gets a fresh identity, not the original's")
        XCTAssertEqual(duplicated[1].kind, original.kind)
        XCTAssertEqual(duplicated[1].adjustments, original.adjustments)
        XCTAssertEqual(duplicated[1].geometry, original.geometry)
        XCTAssertEqual(duplicated[2].id, other.id, "everything after the original shifts down by one, order otherwise preserved")
    }

    func testDuplicatingAnIDNotInTheListIsANoOp() {
        let list = [LocalAdjustment(kind: .linearGradient)]
        XCTAssertEqual(list.duplicating(UUID()), list)
    }

    func testRemovingDeletesOnlyTheMatchingEntry() {
        let first = LocalAdjustment(kind: .linearGradient)
        let second = LocalAdjustment(kind: .spotHeal)
        let third = LocalAdjustment(kind: .linearGradient)
        let list = [first, second, third]

        let removed = list.removing(second.id)

        XCTAssertEqual(removed.map(\.id), [first.id, third.id])
    }

    func testRemovingAnIDNotInTheListIsANoOp() {
        let list = [LocalAdjustment(kind: .linearGradient)]
        XCTAssertEqual(list.removing(UUID()), list)
    }

    func testSelectingFindsTheMatchingEntryByID() {
        let first = LocalAdjustment(kind: .linearGradient)
        let second = LocalAdjustment(kind: .spotHeal)
        let list = [first, second]

        XCTAssertEqual(list.selecting(second.id)?.id, second.id)
    }

    func testSelectingAnIDNotInTheListReturnsNil() {
        let list = [LocalAdjustment(kind: .linearGradient)]
        XCTAssertNil(list.selecting(UUID()))
    }
}

/// Model-level target/source movement and mode-switch semantics for spot
/// heal (Phase 4 Task 4.4's own "tests for target/source movement" and
/// "tests for mode switch immediately updating selected point"
/// requirements), exercised as in-place mutation of an existing array
/// entry -- the same idiom Task 4.3's Mac UI already uses for linear
/// gradient (`adjustments.localAdjustments[i].geometry.x = newX`), so a
/// future spot heal UI (Task 4.5) can reuse it unchanged. `Local
/// AdjustmentRendererTests` covers the corresponding rendered-pixel
/// behavior; these tests stay at the pure-model layer, with no Core Image
/// involved.
final class LocalAdjustmentSpotHealModelTests: XCTestCase {
    func testMovingTheTargetPointOnAnExistingEntryOnlyChangesXAndY() {
        var list = [LocalAdjustment(
            kind: .spotHeal,
            geometry: LocalAdjustmentGeometry(x: 0.2, y: 0.3, sourceX: 0.7, sourceY: 0.6, radius: 0.08, feather: 40, healMode: .clone)
        )]
        let id = list[0].id

        list[0].geometry.x = 0.9
        list[0].geometry.y = 0.1

        XCTAssertEqual(list[0].id, id, "moving the target must never change identity")
        XCTAssertEqual(list[0].geometry.x, 0.9)
        XCTAssertEqual(list[0].geometry.y, 0.1)
        XCTAssertEqual(list[0].geometry.sourceX, 0.7, "moving the target must not disturb the source point")
        XCTAssertEqual(list[0].geometry.sourceY, 0.6)
        XCTAssertEqual(list[0].geometry.radius, 0.08)
        XCTAssertEqual(list[0].geometry.feather, 40)
        XCTAssertEqual(list[0].geometry.healMode, .clone)
    }

    func testMovingTheSourcePointOnAnExistingEntryOnlyChangesSourceXAndSourceY() {
        var list = [LocalAdjustment(
            kind: .spotHeal,
            geometry: LocalAdjustmentGeometry(x: 0.2, y: 0.3, sourceX: 0.7, sourceY: 0.6, radius: 0.08, feather: 40, healMode: .clone)
        )]

        list[0].geometry.sourceX = 0.15
        list[0].geometry.sourceY = 0.85

        XCTAssertEqual(list[0].geometry.sourceX, 0.15)
        XCTAssertEqual(list[0].geometry.sourceY, 0.85)
        XCTAssertEqual(list[0].geometry.x, 0.2, "moving the source must not disturb the target point")
        XCTAssertEqual(list[0].geometry.y, 0.3)
    }

    func testTargetAndSourceMovementIndependentlyClampToTheUnitSquare() {
        var list = [LocalAdjustment(kind: .spotHeal, geometry: LocalAdjustmentGeometry(x: 0.5, y: 0.5, sourceX: 0.5, sourceY: 0.5))]

        list[0].geometry.x = 3
        list[0].geometry.sourceY = -2

        XCTAssertEqual(list[0].geometry.x, 1, "a target dragged past the edge clamps to the unit square, the same as Task 4.1's linear gradient fields")
        XCTAssertEqual(list[0].geometry.sourceY, 0)
    }

    /// Design spec §6.7: "模式切換時，當前選取點必須立即更新，不只影響下一個
    /// 新點" (switching mode must immediately update the currently selected
    /// point, not only affect the next new point). At the model layer this
    /// means `healMode` is a plain field on the *existing* entry's geometry
    /// -- flipping it is one direct mutation on the already-selected array
    /// element by its own `id`, with every other field (including a
    /// previously-placed source point) left exactly as it was. There is no
    /// separate "next new point's default mode" the schema would need to
    /// keep in sync with it.
    func testSwitchingModeOnAnExistingEntryLeavesEveryOtherFieldUntouched() {
        var list = [LocalAdjustment(
            kind: .spotHeal,
            geometry: LocalAdjustmentGeometry(x: 0.4, y: 0.4, sourceX: 0.9, sourceY: 0.1, radius: 0.12, feather: 25, healMode: .heal)
        )]
        let id = list[0].id

        guard let index = list.firstIndex(where: { $0.id == id }) else {
            return XCTFail("the selected entry must still be found by id after the switch")
        }
        list[index].geometry.healMode = .clone

        XCTAssertEqual(list[0].geometry.healMode, .clone, "the switch must apply to the already-selected entry immediately")
        XCTAssertEqual(list[0].geometry.x, 0.4)
        XCTAssertEqual(list[0].geometry.y, 0.4)
        XCTAssertEqual(list[0].geometry.sourceX, 0.9, "a mode switch must not clear or reset an already-placed source point")
        XCTAssertEqual(list[0].geometry.sourceY, 0.1)
        XCTAssertEqual(list[0].geometry.radius, 0.12)
        XCTAssertEqual(list[0].geometry.feather, 25)
    }

    func testSwitchingModeOnOneEntryDoesNotAffectAnyOtherEntrysMode() {
        var list = [
            LocalAdjustment(kind: .spotHeal, geometry: LocalAdjustmentGeometry(healMode: .heal)),
            LocalAdjustment(kind: .spotHeal, geometry: LocalAdjustmentGeometry(healMode: .heal))
        ]
        let secondID = list[1].id

        list[0].geometry.healMode = .clone

        XCTAssertEqual(list[0].geometry.healMode, .clone)
        XCTAssertEqual(list.selecting(secondID)?.geometry.healMode, .heal, "switching one selected point's mode must never leak onto a different point")
    }
}
