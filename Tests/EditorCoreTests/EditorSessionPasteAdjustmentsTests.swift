import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import PresetCore
import RawProcessingCore

/// Phase 2.2 (spec §6.2): "Paste Adjustments" applies a copied
/// `AdjustmentPatch` -- plus optionally-included `GeometryAdjustments`/
/// `[LocalAdjustment]` -- to the currently-open photo as one undoable step,
/// the same "one action, one Undo entry" contract `commitPreset` already
/// gives preset application (`EditorWorkflowUXContractTests`/
/// `PresetCoreTests` cover that contract elsewhere; this file is
/// `EditorSession.pasteAdjustments`'s own unit tests).
@MainActor
final class EditorSessionPasteAdjustmentsTests: XCTestCase {
    private func makeOpenEditor() -> EditorSession {
        let editor = EditorSession()
        let photo = PhotoAsset(
            id: PhotoID(),
            libraryID: LibraryID(),
            relativePath: "fixture.ARW",
            fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"),
            status: .ready
        )
        editor.open(
            photo: photo,
            sourceURL: URL(fileURLWithPath: "/fixture.ARW"),
            adjustments: .neutral,
            isReadOnly: false
        )
        return editor
    }

    func testPasteAdjustmentsAppliesOnlyThePatchsFieldsAsOneUndoEntry() {
        let editor = makeOpenEditor()
        editor.setAdjustment(.contrast, to: 15)
        XCTAssertTrue(editor.canUndo)
        editor.undo()
        XCTAssertFalse(editor.canUndo)

        var source = PhotoAdjustments.neutral
        source.exposure = 1.2
        source.contrast = 30
        let patch = AdjustmentPatch.extracting([.basicExposure], from: source)

        editor.pasteAdjustments(patch: patch, geometry: nil, localAdjustments: nil)

        XCTAssertEqual(editor.adjustments.exposure, 1.2, "the pasted field must land")
        XCTAssertEqual(editor.adjustments.contrast, 0, "a field the patch didn't include must be untouched, not blindly overwritten")
        XCTAssertTrue(editor.canUndo, "a paste must be undoable")

        editor.undo()
        XCTAssertEqual(editor.adjustments.exposure, 0)
        XCTAssertFalse(editor.canUndo, "one paste, however many fields it touches, must be exactly one undo entry")
    }

    func testPasteAdjustmentsPreservesTheTargetsOwnUnselectedFieldAcrossThePaste() {
        let editor = makeOpenEditor()
        editor.setAdjustment(.saturation, to: 25)

        var source = PhotoAdjustments.neutral
        source.exposure = 0.8
        let patch = AdjustmentPatch.extracting([.basicExposure], from: source)

        editor.pasteAdjustments(patch: patch, geometry: nil, localAdjustments: nil)

        XCTAssertEqual(editor.adjustments.exposure, 0.8)
        XCTAssertEqual(editor.adjustments.saturation, 25, "the photo's own pre-existing edit on an unselected field must survive the paste")
    }

    func testPasteAdjustmentsAppliesGeometryOnlyWhenProvided() {
        let editor = makeOpenEditor()
        var geometry = GeometryAdjustments.neutral
        geometry.rotationDegrees = 90
        let patch = AdjustmentPatch.extracting([.basicExposure], from: .neutral)

        editor.pasteAdjustments(patch: patch, geometry: geometry, localAdjustments: nil)

        XCTAssertEqual(editor.adjustments.geometry.rotationDegrees, 90)
    }

    func testPasteAdjustmentsLeavesGeometryUntouchedWhenNotProvided() {
        let editor = makeOpenEditor()
        editor.updateAdjustments { $0.geometry.rotationDegrees = 180 }
        let patch = AdjustmentPatch.extracting([.basicExposure], from: .neutral)

        editor.pasteAdjustments(patch: patch, geometry: nil, localAdjustments: nil)

        XCTAssertEqual(editor.adjustments.geometry.rotationDegrees, 180, "omitting geometry from the paste must leave the target's own geometry alone")
    }

    func testPasteAdjustmentsAppliesLocalAdjustmentsOnlyWhenProvided() {
        let editor = makeOpenEditor()
        let localAdjustments = [LocalAdjustment(kind: .spotHeal)]
        let patch = AdjustmentPatch.extracting([.basicExposure], from: .neutral)

        editor.pasteAdjustments(patch: patch, geometry: nil, localAdjustments: localAdjustments)

        XCTAssertEqual(editor.adjustments.localAdjustments, localAdjustments)
    }

    func testPasteAdjustmentsLeavesLocalAdjustmentsUntouchedWhenNotProvided() {
        let editor = makeOpenEditor()
        let existing = [LocalAdjustment(kind: .linearGradient)]
        editor.updateAdjustments { $0.localAdjustments = existing }
        let patch = AdjustmentPatch.extracting([.basicExposure], from: .neutral)

        editor.pasteAdjustments(patch: patch, geometry: nil, localAdjustments: nil)

        XCTAssertEqual(editor.adjustments.localAdjustments, existing, "omitting local adjustments from the paste must leave the target's own local adjustments alone")
    }

    func testPasteAdjustmentsIsANoOpWhenNothingActuallyChanges() {
        let editor = makeOpenEditor()
        let patch = AdjustmentPatch.extracting([.basicExposure], from: .neutral)

        editor.pasteAdjustments(patch: patch, geometry: nil, localAdjustments: nil)

        XCTAssertFalse(editor.canUndo, "pasting values that match what's already current must not push an undo entry")
    }

    func testPasteAdjustmentsDoesNothingWithoutAnOpenPhoto() {
        let editor = EditorSession()
        let patch = AdjustmentPatch.extracting([.basicExposure], from: .neutral)

        editor.pasteAdjustments(patch: patch, geometry: .neutral, localAdjustments: [])

        XCTAssertEqual(editor.adjustments, .neutral)
        XCTAssertFalse(editor.canUndo)
    }
}
