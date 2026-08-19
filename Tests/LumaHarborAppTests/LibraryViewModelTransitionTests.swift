import Combine
import Foundation
import XCTest
@testable import LumaHarborApp
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Addendum §3.1 and §4.1, plus the two Codex review findings about leaving a
/// photo while work is still in flight.
@MainActor
final class LibraryViewModelTransitionTests: AppViewModelTestCase {

    // MARK: - Removing a library with unsaved edits

    func testRemovingSelectedLibraryWithAFailingSaveDoesNotRemoveIt() async throws {
        try seedPhotos(["DSC0001.ARW"])

        let log = ServiceCallLog()
        let services = try makeServices(
            saveAdjustments: { adjustments, photo in
                await log.recordSave(photo.id, adjustments)
                throw LibraryError.sidecar(.notWritable(path: "/Volumes/SSD"))
            }
        )
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let model = await makeModel(services: services, libraryID: library.id)
        let photo = try XCTUnwrap(model.photos.first)

        // Writable as far as the editor knows, so the flush really is attempted
        // and really fails — the state a user is in when the drive drops out
        // just as they hit "remove".
        model.editor.open(
            photo: photo,
            sourceURL: photo.url(inLibraryRootedAt: library.rootURL),
            adjustments: .neutral,
            isReadOnly: false
        )
        model.editor.setAdjustment(.exposure, to: 1.5)
        XCTAssertTrue(model.editor.saveState.isDirty)

        await model.removeLibrary(library.id)

        // The write was genuinely attempted before the removal was abandoned.
        let attempts = await log.saveCount
        XCTAssertGreaterThan(attempts, 0, "removeLibrary skipped the flush entirely")

        // The folder must still be there: losing an unsaved edit is worse than
        // leaving a row in the sidebar.
        let remaining = await services.libraryService.knownLibraries()
        XCTAssertTrue(
            remaining.contains { $0.id == library.id },
            "A library with unsaved edits was removed anyway"
        )

        // And nothing about the editing session moved.
        XCTAssertEqual(model.selectedLibraryID, library.id)
        XCTAssertEqual(model.editor.photo?.id, photo.id)
        XCTAssertEqual(model.editor.adjustments.exposure, 1.5)
        XCTAssertTrue(model.editor.saveState.isDirty)
        XCTAssertNotNil(model.editor.alert?.nextStep, "The failure had no next step")
    }

    func testRemovingSelectedLibraryFlushesFirstWhenTheSaveSucceeds() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let model = await makeModel(services: services, libraryID: library.id)
        let photo = try XCTUnwrap(model.photos.first)

        model.editor.open(
            photo: photo,
            sourceURL: photo.url(inLibraryRootedAt: library.rootURL),
            adjustments: .neutral,
            isReadOnly: false
        )
        model.editor.setAdjustment(.contrast, to: 25)

        // The sidecar has to be written before the folder goes away, because
        // afterwards there is nowhere left to write it.
        let repository = FileSidecarRepository(libraryRootURL: libraryRoot)
        await model.removeLibrary(library.id)

        let sidecar = try repository.loadSidecar(for: photo.id)
        XCTAssertEqual(sidecar?.adjustments.contrast, 25, "The edit was lost with the library")

        let remaining = await services.libraryService.knownLibraries()
        XCTAssertFalse(remaining.contains { $0.id == library.id })
    }

    func testRemovingANonSelectedLibraryDoesNotFlushTheOpenEditor() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let log = ServiceCallLog()
        let services = try makeServices(
            saveAdjustments: { adjustments, photo in
                await log.recordSave(photo.id, adjustments)
            }
        )
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let model = await makeModel(services: services, libraryID: library.id)
        let photo = try XCTUnwrap(model.photos.first)

        // Leave a dirty editor open, then point the selection somewhere else.
        model.editor.open(
            photo: photo,
            sourceURL: photo.url(inLibraryRootedAt: library.rootURL),
            adjustments: .neutral,
            isReadOnly: false
        )
        model.editor.setAdjustment(.exposure, to: 1.0)
        await model.selectForTesting(libraryID: nil)

        await model.removeLibrary(library.id)

        // Removing a folder the user isn't in must not drag their open edit
        // through a write it never asked for.
        let attempts = await log.saveCount
        XCTAssertEqual(attempts, 0, "A non-selected removal flushed the open editor")

        let remaining = await services.libraryService.knownLibraries()
        XCTAssertFalse(remaining.contains { $0.id == library.id })
        XCTAssertTrue(model.editor.saveState.isDirty, "The open edit was disturbed")
    }

    // MARK: - Stale sidecar reads

    func testALateAdjustmentsLoadDoesNotOpenThePhotoTheUserLeft() async throws {
        try seedPhotos(["DSC0001.ARW", "DSC0002.ARW"])

        let firstGate = AsyncGate()
        let services = try makeServices(
            loadAdjustments: { photo in
                // Only the first photo stalls; the second answers immediately.
                if photo.relativePath.hasSuffix("DSC0001.ARW") {
                    await firstGate.enter()
                }
                return .neutral
            }
        )
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let model = await makeModel(services: services, libraryID: library.id)
        XCTAssertEqual(model.photos.count, 2)
        let first = try XCTUnwrap(model.photos.first)
        let second = try XCTUnwrap(model.photos.last)

        // A → B in quick succession, with A's sidecar read still parked.
        model.requestSelectPhoto(first.id)
        await waitUntilAppCondition("A's sidecar read to start") {
            await firstGate.enteredCount > 0
        }
        model.requestSelectPhoto(second.id)
        await waitUntilAppCondition("B to be selected and open") {
            await MainActor.run { model.selectedPhotoID == second.id
                && model.editor.photo?.id == second.id }
        }

        // Now let A come back. It must not take the editor over.
        await firstGate.open()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(model.selectedPhotoID, second.id)
        XCTAssertEqual(
            model.editor.photo?.id, second.id,
            "A late sidecar read reopened the photo the user had already left"
        )
    }

    func testALateAdjustmentsFailureDoesNotAlertOverTheCurrentPhoto() async throws {
        try seedPhotos(["DSC0001.ARW", "DSC0002.ARW"])

        let firstGate = AsyncGate()
        let services = try makeServices(
            loadAdjustments: { photo in
                if photo.relativePath.hasSuffix("DSC0001.ARW") {
                    await firstGate.enter()
                    throw LibraryError.sidecar(
                        .corruptSidecar(photoID: photo.id, quarantinedAt: nil, reason: "test")
                    )
                }
                return .neutral
            }
        )
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let model = await makeModel(services: services, libraryID: library.id)
        let first = try XCTUnwrap(model.photos.first)
        let second = try XCTUnwrap(model.photos.last)

        model.requestSelectPhoto(first.id)
        await waitUntilAppCondition("A's read to start") { await firstGate.enteredCount > 0 }
        model.requestSelectPhoto(second.id)
        await waitUntilAppCondition("B to open") {
            await MainActor.run { model.editor.photo?.id == second.id }
        }

        await firstGate.open()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(
            model.alert,
            "A photo the user left put its error on screen over the one they're on"
        )
        XCTAssertEqual(model.editor.photo?.id, second.id)
    }

    func testSelectingNothingCancelsAPendingOpen() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let gate = AsyncGate()
        let services = try makeServices(
            loadAdjustments: { _ in
                await gate.enter()
                return .neutral
            }
        )
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let model = await makeModel(services: services, libraryID: library.id)
        let photo = try XCTUnwrap(model.photos.first)

        model.requestSelectPhoto(photo.id)
        await waitUntilAppCondition("the read to start") { await gate.enteredCount > 0 }
        model.requestSelectPhoto(nil)
        await waitUntilAppCondition("selection to clear") {
            await MainActor.run { model.selectedPhotoID == nil }
        }

        await gate.open()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(model.editor.photo, "A cancelled open still put a photo in the editor")
    }

    // MARK: - Addendum §4.1 flush semantics

    func testDirtyEditIsWrittenBeforeTheNextPhotoOpens() async throws {
        try seedPhotos(["DSC0001.ARW", "DSC0002.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let model = await makeModel(services: services, libraryID: library.id)
        let first = try XCTUnwrap(model.photos.first)
        let second = try XCTUnwrap(model.photos.last)

        model.requestSelectPhoto(first.id)
        await waitUntilAppCondition("A to open") {
            await MainActor.run { model.editor.photo?.id == first.id }
        }

        // Dirty, then immediately move on — inside the autosave debounce.
        model.editor.setAdjustment(.exposure, to: 0.75)
        XCTAssertTrue(model.editor.saveState.isDirty)
        model.requestSelectPhoto(second.id)

        await waitUntilAppCondition("B to be selected") {
            await MainActor.run { model.selectedPhotoID == second.id }
        }

        let repository = FileSidecarRepository(libraryRootURL: libraryRoot)
        let sidecar = try repository.loadSidecar(for: first.id)
        XCTAssertEqual(
            sidecar?.adjustments.exposure, 0.75,
            "Switching photos raced the autosave debounce and lost the edit"
        )
    }

    func testASaveFailureKeepsTheSelectionAndTheDirtyState() async throws {
        try seedPhotos(["DSC0001.ARW", "DSC0002.ARW"])
        let services = try makeServices(
            saveAdjustments: { _, _ in
                throw LibraryError.sidecar(.notWritable(path: "/Volumes/SSD"))
            }
        )
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let model = await makeModel(services: services, libraryID: library.id)
        let first = try XCTUnwrap(model.photos.first)
        let second = try XCTUnwrap(model.photos.last)

        model.requestSelectPhoto(first.id)
        await waitUntilAppCondition("A to open") {
            await MainActor.run { model.editor.photo?.id == first.id }
        }
        model.editor.setAdjustment(.shadows, to: 40)

        model.requestSelectPhoto(second.id)
        await waitUntilAppCondition("the failed flush to settle") {
            await MainActor.run {
                if case .failed = model.editor.saveState { return true }
                return false
            }
        }
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(model.selectedPhotoID, first.id, "The UI moved on despite a failed save")
        XCTAssertEqual(model.editor.photo?.id, first.id)
        XCTAssertEqual(model.editor.adjustments.shadows, 40)
        XCTAssertTrue(model.editor.saveState.isDirty)
        XCTAssertNotNil(model.editor.alert?.nextStep)
    }

    func testAnEditMadeDuringASaveIsAlsoWritten() async throws {
        try seedPhotos(["DSC0001.ARW"])

        let saveGate = AsyncGate()
        let log = ServiceCallLog()
        let repositoryRoot = libraryRoot!

        let services = try makeServices(
            saveAdjustments: { adjustments, photo in
                await log.recordSave(photo.id, adjustments)
                // Stall only the first write, so the test can edit underneath it.
                if await log.saveCount == 1 {
                    await saveGate.enter()
                }
                let repository = FileSidecarRepository(libraryRootURL: repositoryRoot)
                let existing = try? repository.loadSidecar(for: photo.id)
                try repository.write(sidecar: PhotoSidecar(
                    photoID: photo.id,
                    sourceRelativePath: photo.relativePath,
                    sourceFingerprint: photo.fingerprint,
                    adjustments: adjustments,
                    createdAt: existing?.createdAt ?? Date(),
                    modifiedAt: Date()
                ))
            }
        )
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let model = await makeModel(services: services, libraryID: library.id)
        let photo = try XCTUnwrap(model.photos.first)
        model.editor.open(
            photo: photo,
            sourceURL: photo.url(inLibraryRootedAt: library.rootURL),
            adjustments: .neutral,
            isReadOnly: false
        )

        model.editor.setAdjustment(.exposure, to: 1.0)
        let flush = Task { await model.editor.flushPendingEdits() }

        await waitUntilAppCondition("the first write to start") { await log.saveCount == 1 }
        // The user keeps dragging while the write is in flight.
        model.editor.setAdjustment(.exposure, to: 2.0)
        await saveGate.open()

        let succeeded = await flush.value
        XCTAssertTrue(succeeded)

        // Addendum §3.1.5: the first snapshot's success must not be reported as
        // "everything saved".
        let lastSaved = await log.lastSavedAdjustments
        XCTAssertEqual(lastSaved?.exposure, 2.0, "The edit made during the save was dropped")

        let sidecar = try FileSidecarRepository(libraryRootURL: libraryRoot)
            .loadSidecar(for: photo.id)
        XCTAssertEqual(sidecar?.adjustments.exposure, 2.0)
        XCTAssertFalse(model.editor.saveState.isDirty)
    }

    func testResettingToNeutralClearsTheEditBadge() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let model = await makeModel(services: services, libraryID: library.id)
        let photo = try XCTUnwrap(model.photos.first)
        model.editor.open(
            photo: photo,
            sourceURL: photo.url(inLibraryRootedAt: library.rootURL),
            adjustments: .neutral,
            isReadOnly: false
        )

        model.editor.setAdjustment(.vibrance, to: 30)
        var flushed = await model.editor.flushPendingEdits()
        XCTAssertTrue(flushed)
        XCTAssertEqual(model.photos.first?.hasEdits, true, "The badge never appeared")

        // Addendum §3.2: the badge is the only thing a save changes in the grid,
        // and it has to come back off again.
        model.editor.resetAll()
        flushed = await model.editor.flushPendingEdits()
        XCTAssertTrue(flushed)
        XCTAssertEqual(model.photos.first?.hasEdits, false, "The badge stuck after a reset")

        let sidecar = try FileSidecarRepository(libraryRootURL: libraryRoot)
            .loadSidecar(for: photo.id)
        XCTAssertEqual(sidecar?.adjustments, .neutral)
    }

    // MARK: - Editor changes reaching the UI

    /// `InspectorView` and `EditorView` only ever declare
    /// `@EnvironmentObject var model: LibraryViewModel` -- `editor` is never
    /// injected on its own (`LumaHarborMainApp.swift`, `RootView.swift`). If an
    /// editor-only change (a new preview arriving, a slider moving) doesn't
    /// republish through `model`, SwiftUI has no signal to redraw those views:
    /// they keep showing whatever editor state existed at the last unrelated
    /// `LibraryViewModel` publish -- one photo selection behind, which is
    /// exactly the stale-inspector-panel bug found manually on 2026-08-18.
    func testEditorOnlyChangesRepublishThroughTheLibraryViewModel() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let model = await makeModel(services: services, libraryID: library.id)
        let photo = try XCTUnwrap(model.photos.first)
        model.editor.open(
            photo: photo,
            sourceURL: photo.url(inLibraryRootedAt: library.rootURL),
            adjustments: .neutral,
            isReadOnly: false
        )

        var publishCount = 0
        let cancellable = model.objectWillChange.sink { publishCount += 1 }
        defer { cancellable.cancel() }

        // Mutates only EditorViewModel's own @Published state (saveState,
        // undo flags) -- nothing on LibraryViewModel itself changes here.
        model.editor.setAdjustment(.exposure, to: 2.0)

        XCTAssertGreaterThan(
            publishCount, 0,
            "An editor-only state change must republish through LibraryViewModel, or InspectorView/EditorView never redraw"
        )
    }
}
