import Foundation
import XCTest
@testable import LumaHarborApp
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Phase 2.2, end to end through `LibraryViewModel` (spec §6.2: "複製調整" /
/// "貼上調整" / "同步到所選照片"). `EditorSession.pasteAdjustments`'s own
/// field-scoping/undo contract is covered by `EditorSessionPasteAdjustmentsTests`
/// in `EditorCoreTests`; `BatchAdjustmentSyncService.syncPatch`'s own
/// fault-tolerance/undo contract is covered by `BatchAdjustmentSyncServiceTests`
/// in `PhotoLibraryCoreTests`. This file only proves the wiring: the
/// clipboard toggles, the copy/paste/sync entry points, and the selection
/// snapshot/summary/compound-undo behavior driven through the real
/// `LibraryViewModel`/`EditorSession` the way the Mac UI would.
@MainActor
final class AdjustmentClipboardWorkflowTests: AppViewModelTestCase {
    private actor AdjustmentStore {
        private var values: [PhotoID: PhotoAdjustments] = [:]
        private var failingIDs: Set<PhotoID> = []
        func set(_ id: PhotoID, _ value: PhotoAdjustments) { values[id] = value }
        func get(_ id: PhotoID) -> PhotoAdjustments { values[id] ?? .neutral }
        func markFailing(_ id: PhotoID) { failingIDs.insert(id) }
        func load(_ id: PhotoID) throws -> PhotoAdjustments {
            if failingIDs.contains(id) { throw StoreError.loadFailed }
            return values[id] ?? .neutral
        }
    }

    private enum StoreError: Error { case loadFailed }

    // MARK: - Copy: global by default, Geometry/Local Adjustments opt-in only

    func testCopyAdjustmentsDefaultsToGlobalOnlyExcludingGeometryAndLocalAdjustments() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let store = AdjustmentStore()
        let services = try makeServices(
            loadAdjustments: { photo in await store.get(photo.id) },
            saveAdjustments: { adjustments, photo in await store.set(photo.id, adjustments) }
        )
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let photo = try XCTUnwrap(model.photos.first)

        model.requestSelectPhoto(photo.id)
        await waitUntilAppCondition("the photo to open") {
            await MainActor.run { model.editor.photo?.id == photo.id }
        }
        model.editor.setAdjustment(.exposure, to: 1.2)
        model.editor.updateAdjustments { $0.geometry.rotationDegrees = 90 }
        model.editor.updateAdjustments { $0.localAdjustments = [LocalAdjustment(kind: .spotHeal)] }

        XCTAssertFalse(model.copyIncludesGeometry)
        XCTAssertFalse(model.copyIncludesLocalAdjustments)
        model.copyAdjustments()

        let clipboard = try XCTUnwrap(model.adjustmentClipboard)
        XCTAssertEqual(clipboard.patch.scalarValue(for: .basicExposure), 1.2)
        XCTAssertNil(clipboard.geometry, "Geometry must not be captured unless explicitly opted in")
        XCTAssertNil(clipboard.localAdjustments, "Local Adjustments must not be captured unless explicitly opted in")
    }

    func testCopyAdjustmentsIncludesGeometryAndLocalAdjustmentsOnlyWhenToggledOn() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let store = AdjustmentStore()
        let services = try makeServices(
            loadAdjustments: { photo in await store.get(photo.id) },
            saveAdjustments: { adjustments, photo in await store.set(photo.id, adjustments) }
        )
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let photo = try XCTUnwrap(model.photos.first)

        model.requestSelectPhoto(photo.id)
        await waitUntilAppCondition("the photo to open") {
            await MainActor.run { model.editor.photo?.id == photo.id }
        }
        model.editor.updateAdjustments { $0.geometry.rotationDegrees = 90 }
        let localAdjustments = [LocalAdjustment(kind: .linearGradient)]
        model.editor.updateAdjustments { $0.localAdjustments = localAdjustments }

        model.copyIncludesGeometry = true
        model.copyIncludesLocalAdjustments = true
        model.copyAdjustments()

        let clipboard = try XCTUnwrap(model.adjustmentClipboard)
        XCTAssertEqual(clipboard.geometry?.rotationDegrees, 90)
        XCTAssertEqual(clipboard.localAdjustments, localAdjustments)
    }

    func testCopyAdjustmentsDoesNothingWithoutAnOpenPhoto() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)

        model.copyAdjustments()

        XCTAssertNil(model.adjustmentClipboard)
    }

    // MARK: - Paste: applies only the clipboard's fields, one undo entry

    func testPasteAdjustmentsAppliesOnlyTheClipboardsFieldsPreservingTheOpenPhotosOtherFields() async throws {
        try seedPhotos(["DSC0001.ARW", "DSC0002.ARW"])
        let store = AdjustmentStore()
        let services = try makeServices(
            loadAdjustments: { photo in await store.get(photo.id) },
            saveAdjustments: { adjustments, photo in await store.set(photo.id, adjustments) }
        )
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let source = model.photos[0]
        let target = model.photos[1]

        model.requestSelectPhoto(source.id)
        await waitUntilAppCondition("the source photo to open") {
            await MainActor.run { model.editor.photo?.id == source.id }
        }
        model.editor.setAdjustment(.exposure, to: 1.5)
        model.copyAdjustments()

        model.requestSelectPhoto(target.id)
        await waitUntilAppCondition("the target photo to open") {
            await MainActor.run { model.editor.photo?.id == target.id }
        }
        model.editor.setAdjustment(.saturation, to: 40)
        XCTAssertTrue(model.editor.canUndo)
        model.editor.undo()
        XCTAssertFalse(model.editor.canUndo)
        model.editor.setAdjustment(.saturation, to: 40)

        model.pasteAdjustments()

        XCTAssertEqual(model.editor.adjustments.exposure, 1.5, "the copied field must land on the target")
        XCTAssertEqual(model.editor.adjustments.saturation, 40, "the target's own pre-existing edit must survive the paste")

        model.editor.undo()
        XCTAssertEqual(model.editor.adjustments.exposure, 0, "one paste, however many fields it touches, must be exactly one undo entry")
        XCTAssertEqual(model.editor.adjustments.saturation, 40)
    }

    func testPasteAdjustmentsDoesNothingWithNothingCopiedYet() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let photo = try XCTUnwrap(model.photos.first)

        model.requestSelectPhoto(photo.id)
        await waitUntilAppCondition("the photo to open") {
            await MainActor.run { model.editor.photo?.id == photo.id }
        }

        model.pasteAdjustments()

        XCTAssertFalse(model.editor.canUndo)
    }

    // MARK: - Sync to Selected Photos: selection snapshot, partial failure, summary, compound undo

    func testSyncAdjustmentsToSelectedPhotosAppliesOnlyGlobalFieldsAndReportsASummary() async throws {
        try seedPhotos(["DSC0001.ARW", "DSC0002.ARW", "DSC0003.ARW"])
        let store = AdjustmentStore()
        var targetAOwn = PhotoAdjustments.neutral
        targetAOwn.contrast = 20
        let services = try makeServices(
            loadAdjustments: { photo in try await store.load(photo.id) },
            saveAdjustments: { adjustments, photo in await store.set(photo.id, adjustments) }
        )
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let source = model.photos[0]
        let targetA = model.photos[1]
        let targetB = model.photos[2]
        await store.set(targetA.id, targetAOwn)

        model.requestSelectPhoto(source.id)
        await waitUntilAppCondition("the source photo to open") {
            await MainActor.run { model.editor.photo?.id == source.id }
        }
        model.editor.setAdjustment(.exposure, to: 1.5)
        model.copyAdjustments()
        model.toggleMultiSelect(targetA.id)
        model.toggleMultiSelect(targetB.id)
        XCTAssertEqual(model.selectedPhotoIDs, [source.id, targetA.id, targetB.id])

        let transaction = await model.syncAdjustmentsToSelectedPhotos()

        XCTAssertNotNil(transaction)
        XCTAssertEqual(Set(transaction?.targetPhotoIDs ?? []), [targetA.id, targetB.id], "the source photo must never be its own sync target")
        let savedA = await store.get(targetA.id)
        let savedB = await store.get(targetB.id)
        XCTAssertEqual(savedA.exposure, 1.5)
        XCTAssertEqual(savedA.contrast, 20, "target A's own unrelated edit must survive the sync")
        XCTAssertEqual(savedB.exposure, 1.5)
        XCTAssertNotNil(model.alert, "a completed sync must surface a success/failure/skipped summary")
        XCTAssertNotNil(model.lastBatchTransaction, "the sync must be undoable through the existing compound batch undo")
    }

    func testSyncAdjustmentsToSelectedPhotosContinuesWhenOneTargetFailsAndStillProducesACompoundUndo() async throws {
        try seedPhotos(["DSC0001.ARW", "DSC0002.ARW", "DSC0003.ARW"])
        let store = AdjustmentStore()
        let services = try makeServices(
            loadAdjustments: { photo in try await store.load(photo.id) },
            saveAdjustments: { adjustments, photo in await store.set(photo.id, adjustments) }
        )
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let source = model.photos[0]
        let targetA = model.photos[1]
        let targetB = model.photos[2]
        await store.markFailing(targetA.id)

        model.requestSelectPhoto(source.id)
        await waitUntilAppCondition("the source photo to open") {
            await MainActor.run { model.editor.photo?.id == source.id }
        }
        model.editor.setAdjustment(.exposure, to: 1.5)
        model.copyAdjustments()
        model.toggleMultiSelect(targetA.id)
        model.toggleMultiSelect(targetB.id)

        let result = await model.syncAdjustmentsToSelectedPhotos()
        let transaction = try XCTUnwrap(result)

        if case .failure = transaction.results[targetA.id] {} else {
            XCTFail("target A must be reported as a failure, not silently skipped or half-applied")
        }
        XCTAssertEqual(transaction.results[targetB.id], .success, "target B must still succeed despite target A's failure")
        let savedB = await store.get(targetB.id)
        XCTAssertEqual(savedB.exposure, 1.5)

        let summary = await model.undoLastBatchTransaction()
        XCTAssertEqual(summary?.affected, 1, "only the one target that actually succeeded can be reverted")
    }

    func testSyncAdjustmentsToSelectedPhotosDoesNothingWithOnlyTheSourceSelected() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let store = AdjustmentStore()
        let services = try makeServices(
            loadAdjustments: { photo in try await store.load(photo.id) },
            saveAdjustments: { adjustments, photo in await store.set(photo.id, adjustments) }
        )
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let source = try XCTUnwrap(model.photos.first)

        model.requestSelectPhoto(source.id)
        await waitUntilAppCondition("the source photo to open") {
            await MainActor.run { model.editor.photo?.id == source.id }
        }
        model.editor.setAdjustment(.exposure, to: 1.5)
        model.copyAdjustments()

        let transaction = await model.syncAdjustmentsToSelectedPhotos()

        XCTAssertNil(transaction, "with no other photo selected there is nothing to sync to")
        XCTAssertNil(model.lastBatchTransaction)
    }

    func testSyncAdjustmentsToSelectedPhotosDoesNothingWithoutACopiedClipboard() async throws {
        try seedPhotos(["DSC0001.ARW", "DSC0002.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let source = model.photos[0]
        let target = model.photos[1]

        model.requestSelectPhoto(source.id)
        await waitUntilAppCondition("the source photo to open") {
            await MainActor.run { model.editor.photo?.id == source.id }
        }
        model.toggleMultiSelect(target.id)

        let transaction = await model.syncAdjustmentsToSelectedPhotos()

        XCTAssertNil(transaction)
    }
}
