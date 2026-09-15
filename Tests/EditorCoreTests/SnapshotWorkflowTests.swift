import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import RawProcessingCore

@MainActor
final class SnapshotWorkflowTests: XCTestCase {
    private func makeOpenEditor() -> (EditorSession, PhotoAsset) {
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
        return (editor, photo)
    }

    func testCreateSnapshotCapturesCurrentAdjustments() {
        let (editor, _) = makeOpenEditor()
        editor.setAdjustment(.exposure, to: 1.5)
        editor.setAdjustment(.contrast, to: 20)

        editor.createSnapshot(name: "High Key")
        XCTAssertEqual(editor.snapshots.count, 1)
        let snapshot = editor.snapshots[0]
        XCTAssertEqual(snapshot.name, "High Key")
        XCTAssertEqual(snapshot.adjustments.exposure, 1.5)
        XCTAssertEqual(snapshot.adjustments.contrast, 20)
    }

    func testCreateSnapshotWithEmptyNameUsesDefault() {
        let (editor, _) = makeOpenEditor()
        editor.createSnapshot(name: "   ")
        XCTAssertEqual(editor.snapshots.count, 1)
        XCTAssertTrue(editor.snapshots[0].name.contains("Snapshot"))
    }

    func testRenameSnapshotUpdatesName() {
        let (editor, _) = makeOpenEditor()
        editor.createSnapshot(name: "Initial")
        let id = editor.snapshots[0].id

        editor.renameSnapshot(id: id, newName: "Renamed Snapshot")
        XCTAssertEqual(editor.snapshots[0].name, "Renamed Snapshot")
    }

    func testDuplicateSnapshotCreatesCopy() {
        let (editor, _) = makeOpenEditor()
        editor.setAdjustment(.exposure, to: 0.8)
        editor.createSnapshot(name: "Warm Look")
        let id = editor.snapshots[0].id

        editor.duplicateSnapshot(id: id)
        XCTAssertEqual(editor.snapshots.count, 2)
        XCTAssertEqual(editor.snapshots[1].name, "Warm Look Copy")
        XCTAssertEqual(editor.snapshots[1].adjustments.exposure, 0.8)
        XCTAssertNotEqual(editor.snapshots[0].id, editor.snapshots[1].id)
    }

    func testDeleteSnapshotRemovesIt() {
        let (editor, _) = makeOpenEditor()
        editor.createSnapshot(name: "To Delete")
        let id = editor.snapshots[0].id

        editor.deleteSnapshot(id: id)
        XCTAssertTrue(editor.snapshots.isEmpty)
    }

    func testRestoreSnapshotIsSingleCompoundUndo() {
        let (editor, _) = makeOpenEditor()

        // 1. Initial edit (State A)
        editor.setAdjustment(.exposure, to: 1.0)
        XCTAssertEqual(editor.adjustments.exposure, 1.0)

        // 2. Save snapshot of State A
        editor.createSnapshot(name: "State A")
        let snapshotAId = editor.snapshots[0].id

        // 3. Apply multiple edits to reach State B
        editor.setAdjustment(.exposure, to: -1.5)
        editor.setAdjustment(.contrast, to: 30)
        XCTAssertEqual(editor.adjustments.exposure, -1.5)
        XCTAssertEqual(editor.adjustments.contrast, 30)

        // 4. Restore snapshot State A
        editor.restoreSnapshot(id: snapshotAId)
        XCTAssertEqual(editor.adjustments.exposure, 1.0)
        XCTAssertEqual(editor.adjustments.contrast, 0.0)

        // 5. Single undo must revert the restoration entirely back to State B!
        XCTAssertTrue(editor.canUndo)
        editor.undo()

        // State B restored in ONE compound undo step!
        XCTAssertEqual(editor.adjustments.exposure, -1.5)
        XCTAssertEqual(editor.adjustments.contrast, 30)
    }

    func testABComparisonDoesNotMutateActiveAdjustmentsOrSidecar() {
        let (editor, _) = makeOpenEditor()
        editor.setAdjustment(.exposure, to: 2.0)

        let snapshotAdj = PhotoAdjustments.neutral
        let snapshot = EditSnapshot(name: "Before", adjustments: snapshotAdj)

        // Active adjustments are exposure: 2.0
        XCTAssertEqual(editor.adjustments.exposure, 2.0)
        XCTAssertEqual(editor.displayedAdjustments.exposure, 2.0)

        // Switch to A/B compare with snapshot
        editor.setComparisonSnapshot(snapshot)

        // displayedAdjustments reflects comparison snapshot
        XCTAssertEqual(editor.displayedAdjustments.exposure, 0.0)
        // But active adjustments remain untouched!
        XCTAssertEqual(editor.adjustments.exposure, 2.0)

        // Clear comparison
        editor.setComparisonSnapshot(nil)
        XCTAssertEqual(editor.displayedAdjustments.exposure, 2.0)
        XCTAssertEqual(editor.adjustments.exposure, 2.0)
    }

    func testProfessionalPreviewOptionsCanBeUpdated() {
        let (editor, _) = makeOpenEditor()
        XCTAssertFalse(editor.previewOptions.isActive)

        let newOptions = ProfessionalPreviewOptions(
            showHighlightClipping: true,
            showShadowClipping: true,
            softProofProfile: .sRGB
        )
        editor.setPreviewOptions(newOptions)
        XCTAssertTrue(editor.previewOptions.isActive)
        XCTAssertTrue(editor.previewOptions.showHighlightClipping)
        XCTAssertTrue(editor.previewOptions.showShadowClipping)
        XCTAssertEqual(editor.previewOptions.softProofProfile, .sRGB)
    }
}
