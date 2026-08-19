import Foundation
import XCTest
@testable import LumaHarborApp
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Regression coverage for the two P1s found during 2026-08-17 manual
/// acceptance (`docs/testing/reports/2026-08-16-mvp-acceptance-progress.md`):
///   - a rapid slider drag queued one uncoalesced decode per tick, since the
///     underlying RAW decode can't be preempted mid-flight (spec §11);
///   - a failed decode left the previous photo's frame on screen looking like
///     a successful one, instead of clearing it (Gate E: no fake success).
@MainActor
final class EditorViewModelPreviewTests: AppViewModelTestCase {

    // MARK: - Interactive preview throttling

    func testRapidSliderDragCoalescesIntoTheThrottleFloorInsteadOfQueueingOnePerTick() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let renderer = RecordingPreviewRenderer()
        let services = try makeServices(previewRenderer: renderer)
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

        // A drag: 10 distinct adjustments (exposure's legal range is [-5, 5],
        // per AdjustmentCatalog) fired back-to-back, far faster than the 80ms
        // throttle floor (`EditorViewModel.interactiveThrottleInterval`).
        for exposure in stride(from: -5.0, through: 4.0, by: 1.0) {
            model.editor.setAdjustment(.exposure, to: exposure)
        }

        // Give the trailing throttled submission time to fire.
        try await Task.sleep(for: .milliseconds(300))

        // `open()` also renders a neutral (exposure 0) reference for the
        // original-image comparison, straight through `previewRenderer` and
        // outside the throttle entirely — exclude it so this only measures
        // the slider-driven interactive submissions.
        let interactiveCalls = await renderer.calls.filter { $0.exposure != 0.0 }
        XCTAssertLessThan(
            interactiveCalls.count, 10,
            "A rapid drag submitted almost one decode per tick instead of being throttled"
        )

        // No adjustment is lost: the last value the user set must still be the
        // one that eventually gets decoded.
        let lastExposure = try XCTUnwrap(interactiveCalls.last?.exposure)
        XCTAssertEqual(lastExposure, 4.0, "The final slider value never reached the renderer")

        // And the throttle actually spaced submissions out rather than merely
        // deduplicating them within the same instant.
        if interactiveCalls.count >= 2 {
            let gaps = zip(interactiveCalls, interactiveCalls.dropFirst())
                .map { $0.1.time - $0.0.time }
            let smallestGap = gaps.min() ?? .zero
            XCTAssertGreaterThanOrEqual(
                smallestGap, .milliseconds(40),
                "Two submissions landed closer together than the throttle floor allows"
            )
        }
    }

    func testASingleAdjustmentIsNotDelayedByTheThrottle() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let renderer = RecordingPreviewRenderer()
        let services = try makeServices(previewRenderer: renderer)
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
        // The open() itself submits once; give it a moment to clear the floor
        // before measuring an isolated, unhurried adjustment.
        try await Task.sleep(for: .milliseconds(150))

        model.editor.setAdjustment(.exposure, to: 5.0)

        await waitUntilAppCondition("the lone adjustment to reach the renderer") {
            await renderer.calls.contains { $0.exposure == 5.0 }
        }
        // No assertion beyond arriving promptly (the wait above times out
        // otherwise): a slow, deliberate edit must not be held back for
        // 80ms just because the throttle exists.
    }

    // MARK: - Decode failure must not look like success

    func testAFailedDecodeClearsTheOnScreenFrameInsteadOfLeavingTheOldOneUpVisible() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let renderer = SelectivelyFailingPreviewRenderer(failingExposures: [3.0])
        let services = try makeServices(previewRenderer: renderer)
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
        await waitUntilAppCondition("the first, successful preview to land") {
            await MainActor.run { model.editor.previewImage != nil }
        }

        // Now an edit whose decode is made to fail — the scenario the corrupt
        // RAW fixture reproduced by hand: the app must not go on showing the
        // previous frame as if it were current.
        model.editor.setAdjustment(.exposure, to: 3.0)

        await waitUntilAppCondition("the failure to be reported") {
            await MainActor.run { model.editor.alert != nil }
        }
        XCTAssertNil(
            model.editor.previewImage,
            "A failed decode left the previous photo's frame on screen looking like a success"
        )
    }

    // MARK: - Reverting on a read-only drive must not be a dead end

    /// Found manually on 2026-08-18 testing `Fixtures/Private/ReadOnly-Test/`:
    /// touch a slider on a read-only photo, then Reset All back to exactly
    /// what's on disk — the user should be able to navigate away again, since
    /// there is nothing left to lose. Before this fix, `didChangeAdjustments()`
    /// unconditionally set `saveState = .pending` on every edit event
    /// (including undo/reset), so it stayed `.failed` forever on a read-only
    /// drive and `flushPendingEdits()` refused to let the app navigate
    /// anywhere -- a real, un-escapable dead end confirmed by hand.
    func testResettingBackToTheSavedValueOnAReadOnlyDriveUnblocksNavigation() async throws {
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
            isReadOnly: true
        )

        model.editor.setAdjustment(.exposure, to: 1.5)
        XCTAssertTrue(model.editor.saveState.isDirty, "The edit itself should still register as dirty")
        var flushed = await model.editor.flushPendingEdits()
        XCTAssertFalse(flushed, "A genuinely different value on a read-only drive should still block navigation")

        model.editor.resetAll()
        XCTAssertEqual(model.editor.adjustments, .neutral, "Reset All should restore the saved value")
        XCTAssertFalse(
            model.editor.saveState.isDirty,
            "Back to exactly what's on disk -- there is nothing to write, so this must not read as dirty"
        )

        flushed = await model.editor.flushPendingEdits()
        XCTAssertTrue(flushed, "Reset back to the saved value must not stay stuck behind a read-only save failure")
    }
}
