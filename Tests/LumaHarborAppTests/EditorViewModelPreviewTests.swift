import Foundation
import XCTest
@testable import LumaHarborApp
@testable import PhotoLibraryCore
@testable import PresetCore
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

    // MARK: - Preset hover preview shares the same throttle (finding #9)
    //
    // `previewPreset`/`cancelPresetPreview` used to call
    // `submitInteractivePreview()` directly, bypassing
    // `requestInteractivePreview()`'s 80ms coalescing floor -- so quickly
    // hovering across several preset rows queued one un-interruptible full
    // RAW decode per row instead of coalescing like a slider drag does.

    private func makePreset(exposure: Double) -> PresetDocument {
        PresetDocument(name: "Test Preset", patch: AdjustmentPatch(basic: BasicAdjustmentPatch(exposure: exposure)))
    }

    func testRapidPresetHoverCoalescesIntoTheThrottleFloorInsteadOfQueueingOnePerRow() async throws {
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

        // Simulates the pointer sweeping across 10 rows in a preset list,
        // far faster than the 80ms throttle floor
        // (`EditorViewModel.interactiveThrottleInterval`) -- each row's
        // `.onHover` firing `previewPreset` on entry.
        for exposure in stride(from: -4.5, through: 4.5, by: 1.0) {
            model.editor.previewPreset(makePreset(exposure: exposure), mode: .merge)
        }

        // Give the trailing throttled submission time to fire.
        try await Task.sleep(for: .milliseconds(300))

        // `open()` also renders a neutral (exposure 0) reference for the
        // original-image comparison, straight through `previewRenderer` and
        // outside the throttle entirely -- exclude it, same as the slider
        // drag test above.
        let hoverCalls = await renderer.calls.filter { $0.exposure != 0.0 }
        XCTAssertLessThan(
            hoverCalls.count, 10,
            "Rapid preset hovering submitted almost one decode per row instead of being throttled"
        )

        // The preset hovered *last* must be what eventually gets decoded --
        // coalescing must never leave a stale mid-sweep preset on screen.
        let lastExposure = try XCTUnwrap(hoverCalls.last?.exposure)
        XCTAssertEqual(lastExposure, 4.5, "The last-hovered preset never reached the renderer")
    }

    func testCancellingAPresetPreviewAlsoGoesThroughTheThrottle() async throws {
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
        try await Task.sleep(for: .milliseconds(150)) // clear open()'s own submission

        model.editor.previewPreset(makePreset(exposure: 3.0), mode: .merge)
        model.editor.cancelPresetPreview() // hover-out, immediately after hover-in

        await waitUntilAppCondition("the cancelled preview to settle back to the neutral committed edit") {
            await renderer.calls.last?.exposure == 0.0
        }
        // Reaching neutral at all (rather than timing out on 3.0 forever)
        // confirms `cancelPresetPreview` doesn't bypass throttling into some
        // state the coalesced submission can't recover from.
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
        XCTAssertTrue(
            model.editor.decodeFailed,
            "EditorView has no other way to tell this apart from still-in-flight and would show " +
            "an indefinite \"Decoding RAW…\" spinner over a decode that has already given up"
        )

        // A further edit that decodes successfully must clear the stuck-looking
        // state again -- decodeFailed isn't a one-way latch for this photo.
        model.editor.setAdjustment(.exposure, to: 1.0)
        await waitUntilAppCondition("the recovered preview to land") {
            await MainActor.run { model.editor.previewImage != nil }
        }
        XCTAssertFalse(
            model.editor.decodeFailed,
            "A subsequent successful decode must clear the earlier failure's state"
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

// MARK: - Round 3: hover-preview must not flood modal alerts (Codex re-review)
//
// `previewPreset`/`cancelPresetPreview` used to call `requestInteractivePreview()`
// unconditionally, even when the preset resolved to exactly the committed
// adjustments (nothing to render) or when the decode it triggered failed --
// against a photo whose decode always fails, every hover kicked off a fresh
// doomed decode and popped the modal `alert` reserved for "the photo itself
// can't be shown", burying `presetPreviewMessage` and flooding the screen
// with alerts as the pointer moved across the preset list.

extension EditorViewModelPreviewTests {
    private func makeNoOpPreset() -> PresetDocument {
        // Absolute Kelvin from an Adobe source, with no white-balance
        // baseline available yet (this test suite's fake renderers never
        // supply one) -- `PresetApplicator` skips the leaf entirely, so the
        // result is pixel-for-pixel the committed edit: a diagnostic with
        // nothing to render.
        PresetDocument(
            name: "No-Op Preset",
            source: .adobeXMP(tool: nil, version: nil),
            patch: AdjustmentPatch(basic: BasicAdjustmentPatch(temperature: 5500))
        )
    }

    // 1. diagnostic-only no-op preview must not submit a decode.
    func testDiagnosticOnlyNoOpPreviewSubmitsNoDecode() async throws {
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
        // Let open()'s own submissions (interactive + original reference)
        // land before measuring, so they're not mistaken for the preview's.
        try await Task.sleep(for: .milliseconds(150))
        let callsBeforeHover = await renderer.calls.count

        model.editor.previewPreset(makeNoOpPreset(), mode: .merge)
        XCTAssertTrue(
            model.editor.presetPreviewDiagnostics.contains { $0.code == "missingWhiteBalanceBaseline" },
            "The skipped leaf must still be reported as a diagnostic"
        )

        try await Task.sleep(for: .milliseconds(150))
        let callsAfterHover = await renderer.calls.count
        XCTAssertEqual(
            callsAfterHover, callsBeforeHover,
            "A preview with nothing to render must not submit a new decode"
        )
    }

    // 2. a hover that genuinely changes the picture, but fails to render,
    // must never produce a modal alert -- and must not accumulate a second
    // one on a second failing hover.
    func testRapidFailingHoversNeverProduceAModalAlert() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let renderer = SelectivelyFailingPreviewRenderer(failingExposures: [2.0, 3.5])
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
        await waitUntilAppCondition("open()'s own preview to land") {
            await MainActor.run { model.editor.previewImage != nil }
        }

        model.editor.previewPreset(makePreset(exposure: 2.0), mode: .merge)
        await waitUntilAppCondition("the first failing hover to be reported") {
            await MainActor.run { model.editor.previewRenderFailureMessage != nil }
        }
        XCTAssertNil(model.editor.alert, "A preview render failure must never use the modal alert")

        model.editor.cancelPresetPreview()
        model.editor.previewPreset(makePreset(exposure: 3.5), mode: .merge)
        await waitUntilAppCondition("the second failing hover to be reported") {
            await MainActor.run { model.editor.previewRenderFailureMessage != nil }
        }
        XCTAssertNil(model.editor.alert, "A second failing hover must still never produce a modal alert")
    }

    // 3. the most-recently-hovered preset always wins, even when it's a
    // no-op that submits nothing and an earlier real decode is still
    // in-flight when it eventually (and irrelevantly) resolves.
    func testTheLastHoveredPresetWinsEvenOverALateArrivingEarlierFailure() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let renderer = GatedPreviewRenderer(shouldFail: { $0 == 2.0 })
        let services = try makeServices(previewRenderer: renderer)
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let photo = try XCTUnwrap(model.photos.first)

        // open()'s own neutral submissions must not be blocked by the gate
        // for exposure 0 -- release it up front.
        await renderer.release(0.0)
        model.editor.open(
            photo: photo,
            sourceURL: photo.url(inLibraryRootedAt: library.rootURL),
            adjustments: .neutral,
            isReadOnly: false
        )
        await waitUntilAppCondition("open()'s own preview to land") {
            await MainActor.run { model.editor.previewImage != nil }
        }

        // Hover A: a real change, whose decode will hang until released.
        model.editor.previewPreset(makePreset(exposure: 2.0), mode: .merge)
        // Clear the 80ms throttle floor so B's hover submits (or, being a
        // no-op, doesn't need to) independently rather than coalescing with A.
        try await Task.sleep(for: .milliseconds(120))

        // Hover B: a no-op -- submits nothing at all (test 1's guarantee),
        // so the scheduler is never told A's in-flight decode is stale.
        model.editor.previewPreset(makeNoOpPreset(), mode: .merge)
        let messageAfterB = model.editor.presetPreviewMessage
        XCTAssertNotNil(messageAfterB, "B's own diagnostic must be showing")
        XCTAssertNil(model.editor.previewRenderFailureMessage, "Nothing has failed for B yet")

        // Now let A's long-delayed decode finally resolve (as a failure).
        await renderer.release(2.0)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(
            model.editor.previewRenderFailureMessage,
            "A's late failure must be discarded -- B is the current preview intent, not A"
        )
        XCTAssertEqual(
            model.editor.presetPreviewMessage, messageAfterB,
            "B's diagnostic must still be what's showing, undisturbed by A's late arrival"
        )
    }

    // 4. cancelling a preview restores the committed render state and clears
    // both kinds of transient message -- and, for a preview that never
    // rendered anything (a no-op), must not submit a wasted decode either.
    func testCancellingANoOpPreviewClearsStateWithoutSubmittingARestoreDecode() async throws {
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
        try await Task.sleep(for: .milliseconds(150))
        let callsBeforeHover = await renderer.calls.count

        model.editor.previewPreset(makeNoOpPreset(), mode: .merge)
        XCTAssertNotNil(model.editor.presetPreviewMessage)

        model.editor.cancelPresetPreview()
        XCTAssertNil(model.editor.presetPreviewDiagnostics.first)
        XCTAssertNil(model.editor.presetPreviewMessage, "Cancel must clear the diagnostic")
        XCTAssertNil(model.editor.previewRenderFailureMessage, "Cancel must clear any preview failure too")

        try await Task.sleep(for: .milliseconds(150))
        let callsAfterCancel = await renderer.calls.count
        XCTAssertEqual(
            callsAfterCancel, callsBeforeHover,
            "Cancelling a preview that never changed the screen must not submit a restoring decode"
        )
    }

    // 5. a general (non-preview) render failure -- opening a photo whose
    // decode fails outright -- must still surface through the modal alert,
    // not be silently absorbed by the preview-failure path.
    func testAGeneralOpenFailureStillShowsTheModalAlert() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let renderer = SelectivelyFailingPreviewRenderer(failingExposures: [0.0])
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

        await waitUntilAppCondition("the general open failure to be reported") {
            await MainActor.run { model.editor.alert != nil }
        }
        XCTAssertNil(
            model.editor.previewRenderFailureMessage,
            "A general open failure is not a preview failure and must not use that channel"
        )
        XCTAssertTrue(
            model.editor.decodeFailed,
            "A photo whose decode failed and won't be retried must not read as still rendering " +
            "-- EditorView would otherwise show an indefinite \"Decoding RAW…\" spinner over nothing"
        )
        XCTAssertFalse(
            model.editor.isRendering,
            "Nothing is actually in flight once the failure has been reported"
        )
    }
}
