import XCTest
@testable import RawProcessingCore

/// Spec §9 and §12.2: one live interactive preview per photo, newer requests
/// replace older ones, and a preview for a photo the user has left must never
/// reach the screen.
final class PreviewSchedulerTests: XCTestCase {
    private func makeSubject() -> PreviewSubject {
        PreviewSubject(UUID())
    }

    // MARK: - Superseding within one photo

    func testNewerRequestSupersedesTheOlderOneForTheSamePhoto() async {
        let gate = ManualPreviewRenderer.Gate()
        let scheduler = PreviewScheduler(
            renderer: ManualPreviewRenderer(gate: gate, respectsCancellation: false)
        )
        let subject = makeSubject()

        _ = await scheduler.submit(.stub(subject: subject, exposure: 1))
        let newer = await scheduler.submit(.stub(subject: subject, exposure: 2))

        // The superseded render finishes anyway. It must be dropped, not shown.
        await gate.release("1.0")
        await waitUntil("the stale render to be discarded") {
            await scheduler.discardedStaleCount == 1
        }
        let deliveredBefore = await scheduler.deliveredCount
        XCTAssertEqual(deliveredBefore, 0, "A superseded render reached the stream")

        await gate.release("2.0")
        await waitUntil("the current render to be delivered") {
            await scheduler.deliveredCount == 1
        }

        let first = await firstProducedResult(from: scheduler)
        XCTAssertEqual(first?.token, newer)
        let superseded = await scheduler.supersededCount
        XCTAssertGreaterThanOrEqual(superseded, 1)
    }

    func testOnlyOneRenderIsInFlightPerPhoto() async {
        let gate = ManualPreviewRenderer.Gate()
        let scheduler = PreviewScheduler(
            renderer: ManualPreviewRenderer(gate: gate, respectsCancellation: false)
        )
        let subject = makeSubject()

        for exposure in stride(from: 1.0, through: 5.0, by: 1.0) {
            _ = await scheduler.submit(.stub(subject: subject, exposure: exposure))
        }

        let inFlight = await scheduler.inFlightCount
        XCTAssertEqual(inFlight, 1, "Dragging a slider must not queue five decodes")
        let superseded = await scheduler.supersededCount
        XCTAssertEqual(superseded, 4)

        await gate.releaseAll()
    }

    func testRapidDraggingDeliversOnlyTheFinalValue() async {
        let gate = ManualPreviewRenderer.Gate()
        let scheduler = PreviewScheduler(
            renderer: ManualPreviewRenderer(gate: gate, respectsCancellation: false)
        )
        let subject = makeSubject()

        var lastToken: PreviewToken?
        for exposure in stride(from: 1.0, through: 4.0, by: 1.0) {
            lastToken = await scheduler.submit(.stub(subject: subject, exposure: exposure))
        }

        await gate.releaseAll()
        await waitUntil("exactly one delivery") {
            await scheduler.deliveredCount == 1
        }

        let produced = await firstProducedResult(from: scheduler)
        XCTAssertEqual(produced?.token, lastToken)
    }

    // MARK: - Switching photos

    func testSwitchingPhotosDropsThePreviousPhotosPreview() async {
        let gate = ManualPreviewRenderer.Gate()
        let scheduler = PreviewScheduler(
            renderer: ManualPreviewRenderer(gate: gate, respectsCancellation: false)
        )
        let first = makeSubject()
        let second = makeSubject()

        _ = await scheduler.submit(.stub(subject: first, exposure: 1))
        let secondToken = await scheduler.submit(.stub(subject: second, exposure: 2))

        let current = await scheduler.currentSubject
        XCTAssertEqual(current, second)

        // Let the abandoned photo's render complete late.
        await gate.release("1.0")
        await waitUntil("the abandoned render to be discarded") {
            await scheduler.discardedStaleCount == 1
        }
        let delivered = await scheduler.deliveredCount
        XCTAssertEqual(delivered, 0, "A previous photo's preview overwrote the screen")

        await gate.release("2.0")
        await waitUntil("the current photo to be delivered") {
            await scheduler.deliveredCount == 1
        }

        let produced = await firstProducedResult(from: scheduler)
        XCTAssertEqual(produced?.token, secondToken)
        XCTAssertEqual(produced?.token.subject, second)
    }

    func testSwitchingPhotosCancelsTheAbandonedTask() async {
        let gate = ManualPreviewRenderer.Gate()
        let scheduler = PreviewScheduler(
            renderer: ManualPreviewRenderer(gate: gate, respectsCancellation: true)
        )
        let first = makeSubject()
        let second = makeSubject()

        _ = await scheduler.submit(.stub(subject: first, exposure: 1))
        _ = await scheduler.submit(.stub(subject: second, exposure: 2))

        // A cancellation-aware renderer bails out instead of finishing.
        await gate.release("1.0")
        await waitUntil("the cancelled render to be discarded") {
            await scheduler.discardedStaleCount == 1
        }

        let inFlight = await scheduler.inFlightCount
        XCTAssertEqual(inFlight, 1)
        await gate.releaseAll()
    }

    // MARK: - Token currency

    func testIsCurrentRejectsSupersededAndAbandonedTokens() async {
        let gate = ManualPreviewRenderer.Gate()
        let scheduler = PreviewScheduler(renderer: ManualPreviewRenderer(gate: gate))
        let subject = makeSubject()
        let other = makeSubject()

        let stale = await scheduler.submit(.stub(subject: subject, exposure: 1))
        let fresh = await scheduler.submit(.stub(subject: subject, exposure: 2))

        var isStaleCurrent = await scheduler.isCurrent(stale)
        var isFreshCurrent = await scheduler.isCurrent(fresh)
        XCTAssertFalse(isStaleCurrent)
        XCTAssertTrue(isFreshCurrent)

        _ = await scheduler.submit(.stub(subject: other, exposure: 3))
        isStaleCurrent = await scheduler.isCurrent(stale)
        isFreshCurrent = await scheduler.isCurrent(fresh)
        XCTAssertFalse(isStaleCurrent)
        XCTAssertFalse(isFreshCurrent, "Switching photos must invalidate the old token")

        await gate.releaseAll()
    }

    func testGenerationsIncreaseAcrossPhotos() async {
        let gate = ManualPreviewRenderer.Gate()
        let scheduler = PreviewScheduler(renderer: ManualPreviewRenderer(gate: gate))

        let first = await scheduler.submit(.stub(subject: makeSubject(), exposure: 1))
        let second = await scheduler.submit(.stub(subject: makeSubject(), exposure: 2))
        let third = await scheduler.submit(.stub(subject: makeSubject(), exposure: 3))

        // A globally increasing counter is what lets the view model reject a
        // late frame with one comparison.
        XCTAssertLessThan(first.generation, second.generation)
        XCTAssertLessThan(second.generation, third.generation)

        await gate.releaseAll()
    }

    // MARK: - Cancel-all and failures

    func testCancelAllClearsEverything() async {
        let gate = ManualPreviewRenderer.Gate()
        let scheduler = PreviewScheduler(
            renderer: ManualPreviewRenderer(gate: gate, respectsCancellation: false)
        )
        let subject = makeSubject()
        let token = await scheduler.submit(.stub(subject: subject, exposure: 1))

        await scheduler.cancelAll()

        let current = await scheduler.currentSubject
        let inFlight = await scheduler.inFlightCount
        let isCurrent = await scheduler.isCurrent(token)
        XCTAssertNil(current)
        XCTAssertEqual(inFlight, 0)
        XCTAssertFalse(isCurrent)

        // Even if the abandoned work completes, it stays off the stream.
        await gate.release("1.0")
        await waitUntil("the abandoned render to settle") {
            await scheduler.discardedStaleCount >= 1
        }
        let delivered = await scheduler.deliveredCount
        XCTAssertEqual(delivered, 0)
    }

    func testFailuresAreReportedForTheCurrentPhoto() async {
        let scheduler = PreviewScheduler(
            renderer: FailingPreviewRenderer(error: .unsupportedFormat(path: "/tmp/x.ARW"))
        )
        let subject = makeSubject()
        let token = await scheduler.submit(.stub(subject: subject, exposure: 1))

        var received: PreviewToken?
        for await event in scheduler.events {
            if case .failed(let failedToken, _) = event {
                received = failedToken
                break
            }
        }
        XCTAssertEqual(received, token)
        let failed = await scheduler.failedCount
        XCTAssertEqual(failed, 1)
    }

    // MARK: - Helpers

    /// Takes the first `.produced` event. Safe to call after the fact because
    /// the scheduler's stream buffers without bound.
    private func firstProducedResult(from scheduler: PreviewScheduler) async -> PreviewResult? {
        for await event in scheduler.events {
            if case .produced(let result) = event {
                return result
            }
        }
        return nil
    }
}
