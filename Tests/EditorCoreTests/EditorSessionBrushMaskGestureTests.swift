import CoreGraphics
import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import RawProcessingCore

private struct BrushGesturePreviewRenderer: PreviewRendering {
    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        throw CancellationError()
    }
}

private actor BrushSaveCounter {
    private(set) var values: [PhotoAdjustments] = []
    func append(_ value: PhotoAdjustments) { values.append(value) }
    func count() -> Int { values.count }
}

@MainActor
final class EditorSessionBrushMaskGestureTests: XCTestCase {
    private func makeEditor(counter: BrushSaveCounter? = nil, isReadOnly: Bool = false) -> EditorSession {
        let editor = EditorSession()
        let renderer = BrushGesturePreviewRenderer()
        editor.attach(dependencies: EditorDependencies(
            previewScheduler: PreviewScheduler(renderer: renderer),
            previewRenderer: renderer,
            loadAdjustments: { _ in .neutral },
            saveAdjustments: { adjustments, _ in
                if let counter { await counter.append(adjustments) }
            }
        ))
        editor.open(
            photo: PhotoAsset(
                id: PhotoID(), libraryID: LibraryID(), relativePath: "fixture.ARW",
                fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"), status: .ready
            ),
            sourceURL: URL(fileURLWithPath: "/fixture.ARW"),
            adjustments: .neutral,
            isReadOnly: isReadOnly
        )
        return editor
    }

    private func mapping() throws -> BrushCoordinateMapping {
        try BrushCoordinateMapping(sourceSize: CGSize(width: 100, height: 100))
    }

    func testActivatingBrushMaskAndEmptyOrOutsideReleaseDoNotCreateHistory() throws {
        let editor = makeEditor()
        editor.setToolMode(.brushMask)
        XCTAssertFalse(editor.canUndo)
        XCTAssertEqual(editor.undoCountForTesting, 0)
        let mapper = try mapping()
        XCTAssertNil(editor.beginBrushMaskGesture(at: CGPoint(x: -1, y: -1), mapping: mapper))
        XCTAssertFalse(editor.endBrushMaskGesture())
        XCTAssertFalse(editor.canUndo)
        XCTAssertEqual(editor.undoCountForTesting, 0)
        editor.cancelBrushMaskGesture()
        XCTAssertFalse(editor.canUndo)
        XCTAssertEqual(editor.undoCountForTesting, 0)
        XCTAssertNil(editor.beginBrushMaskGesture(
            at: CGPoint(x: 10, y: 10), mapping: mapper,
            settings: BrushMaskGestureSettings(size: .nan)
        ))
        XCTAssertFalse(editor.canUndo)
        let invalidRelease = try XCTUnwrap(editor.beginBrushMaskGesture(
            at: CGPoint(x: 10, y: 10), mapping: mapper
        ))
        XCTAssertFalse(editor.endBrushMaskGesture(
            at: CGPoint(x: CGFloat.nan, y: 10), context: invalidRelease
        ))
        XCTAssertFalse(editor.canUndo)
    }

    func testValidGestureCommitsOneEntryAndKeepsGapPathsSeparate() throws {
        let editor = makeEditor()
        editor.setToolMode(.brushMask)
        let mapper = try mapping()
        let context = try XCTUnwrap(editor.beginBrushMaskGesture(
            at: CGPoint(x: 10, y: 10), mapping: mapper,
            settings: BrushMaskGestureSettings(adjustments: BrushMaskPatch(exposure: 1))
        ))
        XCTAssertTrue(editor.updateBrushMaskGesture(at: CGPoint(x: 20, y: 20), context: context))
        XCTAssertFalse(editor.updateBrushMaskGesture(at: CGPoint(x: -2, y: 20), context: context))
        XCTAssertTrue(editor.updateBrushMaskGesture(at: CGPoint(x: 80, y: 80), context: context))
        XCTAssertTrue(editor.endBrushMaskGesture(context: context))

        XCTAssertEqual(editor.adjustments.brushMasks.count, 1)
        XCTAssertEqual(editor.adjustments.brushMasks[0].strokes.count, 2)
        XCTAssertTrue(editor.canUndo)
        XCTAssertEqual(editor.undoCountForTesting, 1)
        XCTAssertEqual(editor.redoCountForTesting, 0)
        XCTAssertFalse(editor.canRedo)
        editor.undo()
        XCTAssertTrue(editor.adjustments.brushMasks.isEmpty)
        XCTAssertEqual(editor.undoCountForTesting, 0)
        XCTAssertEqual(editor.redoCountForTesting, 1)
        XCTAssertTrue(editor.canRedo)
        editor.redo()
        XCTAssertEqual(editor.adjustments.brushMasks.count, 1)
        XCTAssertEqual(editor.adjustments.brushMasks[0].strokes.count, 2)
        XCTAssertEqual(editor.undoCountForTesting, 1)
        XCTAssertEqual(editor.redoCountForTesting, 0)
    }

    func testCompetingEditInvalidatesReleaseAndDoesNotAddHistory() throws {
        let editor = makeEditor()
        editor.setToolMode(.brushMask)
        let mapper = try mapping()
        let context = try XCTUnwrap(editor.beginBrushMaskGesture(at: CGPoint(x: 10, y: 10), mapping: mapper))
        editor.setAdjustment(.exposure, to: 0.5)
        XCTAssertFalse(editor.endBrushMaskGesture(context: context))
        XCTAssertTrue(editor.adjustments.brushMasks.isEmpty)
        editor.undo()
        XCTAssertFalse(editor.canUndo)
        XCTAssertEqual(editor.undoCountForTesting, 0)
    }

    func testPhotoGeometryUndoSnapshotAndCancelInvalidateOldRelease() throws {
        let mapper = try mapping()
        let editor = makeEditor()

        let photoChange = try XCTUnwrap(editor.beginBrushMaskGesture(at: CGPoint(x: 10, y: 10), mapping: mapper))
        editor.open(
            photo: PhotoAsset(
                id: PhotoID(), libraryID: LibraryID(), relativePath: "other.ARW",
                fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "other"), status: .ready
            ),
            sourceURL: URL(fileURLWithPath: "/other.ARW"), adjustments: .neutral, isReadOnly: false
        )
        XCTAssertFalse(editor.endBrushMaskGesture(context: photoChange))

        let geometryChange = try XCTUnwrap(editor.beginBrushMaskGesture(at: CGPoint(x: 10, y: 10), mapping: mapper))
        editor.updateAdjustments { $0.geometry.rotationDegrees = 90 }
        XCTAssertFalse(editor.endBrushMaskGesture(context: geometryChange))

        let undoChange = try XCTUnwrap(editor.beginBrushMaskGesture(at: CGPoint(x: 10, y: 10), mapping: mapper))
        editor.setAdjustment(.exposure, to: 0.4)
        editor.undo()
        XCTAssertFalse(editor.endBrushMaskGesture(context: undoChange))

        let snapshotChange = try XCTUnwrap(editor.beginBrushMaskGesture(at: CGPoint(x: 10, y: 10), mapping: mapper))
        editor.createSnapshot(name: "base")
        let snapshot = try XCTUnwrap(editor.snapshots.first)
        editor.restoreSnapshot(id: snapshot.id)
        XCTAssertFalse(editor.endBrushMaskGesture(context: snapshotChange))

        let cancelled = try XCTUnwrap(editor.beginBrushMaskGesture(at: CGPoint(x: 10, y: 10), mapping: mapper))
        editor.cancelBrushMaskGesture()
        XCTAssertFalse(editor.endBrushMaskGesture(context: cancelled))
        XCTAssertTrue(editor.adjustments.brushMasks.isEmpty)
    }

    func testDeleteBrushMaskIsUndoableAndSelectionIsTyped() throws {
        let editor = makeEditor()
        let id = try XCTUnwrap(editor.addBrushMask(name: "A"))
        XCTAssertEqual(editor.selectedAdjustmentIdentity, .brushMask(id))
        XCTAssertTrue(editor.deleteSelectedBrushMask())
        XCTAssertTrue(editor.adjustments.brushMasks.isEmpty)
        editor.undo()
        XCTAssertEqual(editor.adjustments.brushMasks.map(\.id), [id])
        editor.redo()
        XCTAssertTrue(editor.adjustments.brushMasks.isEmpty)
    }

    func testValidGestureSchedulesOnlyOneSaveIntent() async throws {
        let counter = BrushSaveCounter()
        let editor = makeEditor(counter: counter)
        let mapper = try mapping()
        let context = try XCTUnwrap(editor.beginBrushMaskGesture(at: CGPoint(x: 10, y: 10), mapping: mapper))
        XCTAssertTrue(editor.endBrushMaskGesture(context: context))
        XCTAssertEqual(editor.saveState, .pending)
        await editor.save()
        let saveCount = await counter.count()
        XCTAssertEqual(saveCount, 1)
    }

    func testPressFreezesSettingsAndMappingUntilRelease() throws {
        let editor = makeEditor()
        editor.setToolMode(.brushMask)
        let mapper = try mapping()
        var settings = BrushMaskGestureSettings(size: 0.12, feather: 0.25, flow: 0.6, density: 0.7)
        let context = try XCTUnwrap(editor.beginBrushMaskGesture(
            at: CGPoint(x: 10, y: 20), mapping: mapper, settings: settings
        ))

        // UI controls and any newly-created mapper may change while the
        // pointer is down; the press context owns the values used at release.
        settings.size = 0.8
        settings.feather = 0.9
        XCTAssertTrue(editor.updateBrushMaskGesture(at: CGPoint(x: 30, y: 40), context: context))
        XCTAssertTrue(editor.endBrushMaskGesture(context: context))

        let stroke = try XCTUnwrap(editor.adjustments.brushMasks.first?.strokes.first)
        XCTAssertEqual(stroke.size, 0.12)
        XCTAssertEqual(stroke.feather, 0.25)
        XCTAssertEqual(stroke.flow, 0.6)
        XCTAssertEqual(stroke.density, 0.7)
        let firstPoint = try XCTUnwrap(stroke.points.first)
        XCTAssertEqual(firstPoint.x, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(firstPoint.y, 0.2, accuracy: 0.000_001)
    }

    func testSnapshotAndCompareChangesInvalidateAnInFlightGesture() throws {
        let editor = makeEditor()
        editor.setToolMode(.brushMask)
        let mapper = try mapping()

        let snapshotGesture = try XCTUnwrap(editor.beginBrushMaskGesture(
            at: CGPoint(x: 10, y: 10), mapping: mapper
        ))
        editor.createSnapshot(name: "base")
        XCTAssertFalse(editor.endBrushMaskGesture(context: snapshotGesture))

        let snapshot = try XCTUnwrap(editor.snapshots.first)
        let compareGesture = try XCTUnwrap(editor.beginBrushMaskGesture(
            at: CGPoint(x: 10, y: 10), mapping: mapper
        ))
        editor.setComparisonSnapshot(snapshot)
        XCTAssertFalse(editor.endBrushMaskGesture(context: compareGesture))
        XCTAssertTrue(editor.adjustments.brushMasks.isEmpty)
    }

    func testRenamingSnapshotInvalidatesAnInFlightGesture() throws {
        let editor = makeEditor()
        editor.setToolMode(.brushMask)
        let mapper = try mapping()
        editor.createSnapshot(name: "base")
        let snapshot = try XCTUnwrap(editor.snapshots.first)
        let context = try XCTUnwrap(editor.beginBrushMaskGesture(at: CGPoint(x: 10, y: 10), mapping: mapper))

        editor.renameSnapshot(id: snapshot.id, newName: "renamed")

        XCTAssertFalse(editor.endBrushMaskGesture(context: context))
        XCTAssertEqual(editor.undoCountForTesting, 0)
        XCTAssertTrue(editor.adjustments.brushMasks.isEmpty)
    }

    func testReadOnlyGestureNeverClaimsSavedOrWrites() async throws {
        let counter = BrushSaveCounter()
        let editor = makeEditor(counter: counter, isReadOnly: true)
        editor.setToolMode(.brushMask)
        let mapper = try mapping()
        let context = try XCTUnwrap(editor.beginBrushMaskGesture(at: CGPoint(x: 10, y: 10), mapping: mapper))
        XCTAssertTrue(editor.endBrushMaskGesture(context: context))
        guard case .failed = editor.saveState else {
            return XCTFail("read-only edit must remain failed, got \(editor.saveState)")
        }
        await editor.save()
        guard case .failed = editor.saveState else {
            return XCTFail("manual save must not claim success for a read-only photo")
        }
        let saveCount = await counter.count()
        XCTAssertEqual(saveCount, 0)
    }
}
