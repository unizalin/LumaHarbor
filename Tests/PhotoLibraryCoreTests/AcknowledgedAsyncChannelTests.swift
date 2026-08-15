import Foundation
import XCTest
@testable import PhotoLibraryCore

/// A one-way flag a test can flip from inside a task and read from outside.
actor AsyncFlag {
    private(set) var isSet = false
    func set() { isSet = true }
}

/// Records values in order from concurrent contexts.
actor OrderedRecorder<Value: Sendable> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
    var count: Int { values.count }
}

/// Bounded-pipeline spec §6.1.
///
/// This is the primitive the whole backpressure story rests on: if `send` ever
/// returns before the consumer has taken the element, every "at most one batch
/// in flight" guarantee above it becomes untrue.
final class AcknowledgedAsyncChannelTests: XCTestCase {

    func testSendDoesNotReturnUntilTheConsumerTakesTheElement() async throws {
        let channel = AcknowledgedAsyncChannel<Int>()
        let didReturn = AsyncFlag()

        let sender = Task {
            try await channel.send(7)
            await didReturn.set()
        }

        await waitUntilTrue("the element to park") {
            await channel.pendingElementCount == 1
        }

        // The element is sitting in the slot and nobody has taken it, so the
        // producer must still be suspended.
        let returnedEarly = await didReturn.isSet
        XCTAssertFalse(returnedEarly, "send() returned before the consumer took the element")
        let senderIsSuspended = await channel.hasSuspendedSender
        XCTAssertTrue(senderIsSuspended)

        let received = try await channel.next()
        XCTAssertEqual(received, 7)

        await waitUntilTrue("the sender to resume once its element was taken") {
            await didReturn.isSet
        }
        _ = await sender.result
    }

    func testAWaitingConsumerReceivesAndTheSenderSucceedsOnlyAfterTheTake() async throws {
        // A parked consumer is woken, not handed the element directly: it comes
        // back through the actor, checks cancellation and only then takes. The
        // sender's success must still be gated on that take, otherwise a
        // consumer cancelled mid-wake would leave the producer thinking a batch
        // had landed.
        let channel = AcknowledgedAsyncChannel<Int>()
        let sendReturned = AsyncFlag()
        let receiverEntered = AsyncFlag()

        let receiver = Task { () -> Int? in
            await receiverEntered.set()
            return try await channel.next()
        }

        await waitUntilTrue("the consumer to park") {
            await channel.hasWaitingReceiver
        }
        let enteredFirst = await receiverEntered.isSet
        XCTAssertTrue(enteredFirst)

        let sender = Task {
            try await channel.send(3)
            await sendReturned.set()
        }

        let received = try await receiver.value
        XCTAssertEqual(received, 3, "A waiting consumer stopped receiving values")

        await waitUntilTrue("the sender to be released by the take") {
            await sendReturned.isSet
        }
        _ = await sender.result

        let pending = await channel.pendingElementCount
        XCTAssertEqual(pending, 0)
    }

    func testASecondConcurrentSendIsRejectedRatherThanOverwriting() async throws {
        let channel = AcknowledgedAsyncChannel<Int>()
        let first = Task { try await channel.send(1) }

        await waitUntilTrue("the first element to park") {
            await channel.pendingElementCount == 1
        }

        do {
            try await channel.send(2)
            XCTFail("A second concurrent send should not have been accepted")
        } catch {
            XCTAssertEqual(error as? AcknowledgedChannelError, .concurrentSendUnsupported)
        }

        // Capacity is still one, and it is still the *first* element.
        let pending = await channel.pendingElementCount
        XCTAssertEqual(pending, 1)
        let taken = try await channel.next()
        XCTAssertEqual(taken, 1, "The parked element was overwritten by the rejected send")

        _ = await first.result
    }

    func testASecondConcurrentReceiveIsRejected() async throws {
        let channel = AcknowledgedAsyncChannel<Int>()
        let first = Task { try await channel.next() }

        await waitUntilTrue("the first consumer to park") {
            await channel.hasWaitingReceiver
        }

        do {
            _ = try await channel.next()
            XCTFail("A second concurrent receive should not have been accepted")
        } catch {
            XCTAssertEqual(error as? AcknowledgedChannelError, .concurrentReceiveUnsupported)
        }

        await channel.cancel()
        _ = try? await first.value
    }

    func testOrderingIsLosslessAcrossManyElements() async throws {
        let channel = AcknowledgedAsyncChannel<Int>()
        let total = 1_000

        let producer = Task {
            for value in 0..<total {
                try await channel.send(value)
            }
            await channel.finish()
        }

        var received: [Int] = []
        received.reserveCapacity(total)
        while let value = try await channel.next() {
            received.append(value)
        }

        XCTAssertEqual(received, Array(0..<total), "Elements were dropped, duplicated or reordered")
        _ = await producer.result
    }

    func testFinishDrainsTheParkedElementBeforeEnding() async throws {
        let channel = AcknowledgedAsyncChannel<Int>()
        let sender = Task { try await channel.send(42) }

        await waitUntilTrue("the element to park") {
            await channel.pendingElementCount == 1
        }
        await channel.finish()

        // The producer's own completion must not swallow its last event.
        let drained = try await channel.next()
        XCTAssertEqual(drained, 42)

        let ended = try await channel.next()
        XCTAssertNil(ended)
        _ = await sender.result
    }

    func testFinishWakesAConsumerThatHasNothingLeftToTake() async throws {
        let channel = AcknowledgedAsyncChannel<Int>()
        let receiver = Task { try await channel.next() }

        await waitUntilTrue("the consumer to park") {
            await channel.hasWaitingReceiver
        }
        await channel.finish()

        let received = try await receiver.value
        XCTAssertNil(received, "A finished channel left its consumer suspended")
    }

    func testSendAfterFinishIsRefused() async throws {
        let channel = AcknowledgedAsyncChannel<Int>()
        await channel.finish()

        do {
            try await channel.send(1)
            XCTFail("A finished channel accepted another element")
        } catch {
            XCTAssertEqual(error as? AcknowledgedChannelError, .finished)
        }
    }

    func testCancelWakesABlockedSenderAndDiscardsItsElement() async throws {
        let channel = AcknowledgedAsyncChannel<Int>()
        let outcome = AsyncFlag()

        let sender = Task { () -> Error? in
            do {
                try await channel.send(9)
                return nil
            } catch {
                await outcome.set()
                return error
            }
        }

        await waitUntilTrue("the element to park") {
            await channel.pendingElementCount == 1
        }
        await channel.cancel()

        let error = await sender.value
        XCTAssertEqual(error as? AcknowledgedChannelError, .cancelled)
        let didThrow = await outcome.isSet
        XCTAssertTrue(didThrow)

        // The undelivered element is gone, not queued for a future consumer.
        let pending = await channel.pendingElementCount
        XCTAssertEqual(pending, 0)
        let afterCancel = try await channel.next()
        XCTAssertNil(afterCancel)
    }

    func testCancelWakesABlockedConsumer() async throws {
        let channel = AcknowledgedAsyncChannel<Int>()
        let receiver = Task { try await channel.next() }

        await waitUntilTrue("the consumer to park") {
            await channel.hasWaitingReceiver
        }
        await channel.cancel()

        let received = try await receiver.value
        XCTAssertNil(received, "A cancelled channel left its consumer suspended")
    }

    func testSendAfterCancelIsRefused() async throws {
        let channel = AcknowledgedAsyncChannel<Int>()
        await channel.cancel()

        do {
            try await channel.send(1)
            XCTFail("A cancelled channel accepted a late element")
        } catch {
            XCTAssertEqual(error as? AcknowledgedChannelError, .cancelled)
        }
    }

    func testRepeatedFinishAndCancelAreSafe() async throws {
        let channel = AcknowledgedAsyncChannel<Int>()

        // Every continuation is resumed exactly once, so hammering the
        // terminators must not double-resume or hang.
        await channel.finish()
        await channel.finish()
        await channel.cancel()
        await channel.cancel()
        await channel.finish()

        let ended = try await channel.next()
        XCTAssertNil(ended)
    }

    func testCancelBeatsAnUndeliveredElementEvenAfterFinish() async throws {
        // Finish keeps the element drainable; cancel then throws it away. The
        // ordering matters because a consumer that has gone must not be able to
        // resurrect and take stale work.
        let channel = AcknowledgedAsyncChannel<Int>()
        let sender = Task { try? await channel.send(5) }

        await waitUntilTrue("the element to park") {
            await channel.pendingElementCount == 1
        }
        await channel.finish()
        await channel.cancel()

        let received = try await channel.next()
        XCTAssertNil(received)
        _ = await sender.result
    }

    func testACancelledProducerTaskReleasesItsParkedSend() async throws {
        let channel = AcknowledgedAsyncChannel<Int>()
        let sender = Task { () -> Error? in
            do {
                try await channel.send(11)
                return nil
            } catch {
                return error
            }
        }

        await waitUntilTrue("the element to park") {
            await channel.pendingElementCount == 1
        }
        sender.cancel()

        // The producer's own cancellation has to unblock it; otherwise a
        // torn-down scan would leak a suspended task forever.
        let error = await sender.value
        XCTAssertNotNil(error)
        await waitUntilTrue("the abandoned element to be dropped") {
            await channel.pendingElementCount == 0
        }
    }

    func testAnAlreadyCancelledConsumerIsNotHandedAParkedElement() async throws {
        // Codex review finding 1. The element is parked and ready; the consumer
        // is cancelled *before* it ever calls `next()`. Taking it here would
        // both deliver work nobody wants and tell the producer it landed.
        let channel = AcknowledgedAsyncChannel<Int>()
        let senderOutcome = Task { () -> Error? in
            do { try await channel.send(99); return nil } catch { return error }
        }

        await waitUntilTrue("the element to park") {
            await channel.pendingElementCount == 1
        }

        let consumer = Task { () -> Result<Int?, Error> in
            // Cancelled before the first `next()` runs.
            while !Task.isCancelled { await Task.yield() }
            do { return .success(try await channel.next()) }
            catch { return .failure(error) }
        }
        consumer.cancel()

        switch await consumer.value {
        case .success(let element):
            XCTFail("A cancelled consumer was handed element \(String(describing: element))")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "Got \(error)")
        }

        // The parked sender must have been woken rather than left suspended.
        let senderError = await senderOutcome.value
        XCTAssertNotNil(senderError, "The blocked sender was never released")
        let stillPending = await channel.pendingElementCount
        XCTAssertEqual(stillPending, 0, "The undelivered element was left in the slot")
    }

    func testCancellingAWaitingConsumerFailsTheSenderAndAdvancesNothing() async throws {
        // Codex review finding A. The consumer is parked, then cancelled, and
        // only then does the producer send. Whichever way the actor sequences
        // those, the sender must *fail*: if it succeeded it would be free to
        // read the next page for an audience that has gone.
        //
        // Deterministic because the cancel happens before the send. Either the
        // channel is already torn down when `send` arrives, or the woken
        // consumer hits its cancellation checkpoint before taking — and both
        // paths resume the sender with an error.
        for _ in 0..<50 {
            let channel = AcknowledgedAsyncChannel<Int>()
            let advances = AtomicCounter()

            let consumer = Task { () -> Result<Int?, Error> in
                do { return .success(try await channel.next()) }
                catch { return .failure(error) }
            }
            await waitUntilTrue("the consumer to park") {
                await channel.hasWaitingReceiver
            }
            consumer.cancel()

            let sender = Task { () -> Error? in
                do {
                    try await channel.send(1)
                    // Only ever reached on a genuine acknowledgement, which is
                    // what "the producer may now read another page" means.
                    _ = advances.increment()
                    return nil
                } catch {
                    return error
                }
            }

            switch await consumer.value {
            case .success(let element):
                XCTAssertNil(
                    element,
                    "A cancelled consumer received \(String(describing: element))"
                )
            case .failure(let error):
                XCTAssertTrue(error is CancellationError, "Got \(error)")
            }

            let senderError = await sender.value
            XCTAssertNotNil(
                senderError,
                "The sender was told its element landed after the consumer had gone"
            )
            XCTAssertEqual(
                advances.current, 0,
                "The producer was released to build another batch after cancellation"
            )
        }
    }

    func testConcurrentTerminatorsNeitherDoubleResumeNorHang() async throws {
        // Spec §6.1.6. A double-resume traps the process, so this test failing
        // looks like a crash rather than an assertion — which is precisely why
        // it is worth running the terminators against a live sender.
        for _ in 0..<50 {
            let channel = AcknowledgedAsyncChannel<Int>()
            let sender = Task { try? await channel.send(1) }
            let receiver = Task { try? await channel.next() }

            await withTaskGroup(of: Void.self) { group in
                group.addTask { await channel.finish() }
                group.addTask { await channel.cancel() }
                group.addTask { await channel.finish() }
                group.addTask { await channel.cancel() }
            }

            // Both sides must come back; a leaked continuation shows up here as
            // the test hanging rather than passing.
            _ = await sender.result
            _ = await receiver.result

            let ended = try await channel.next()
            XCTAssertNil(ended)
        }
    }

    func testCancelDuringAHandOffLeavesNoSuspendedParticipant() async throws {
        // The narrow window the acknowledgement design has to survive: a
        // consumer taking an element at the same moment the channel is torn
        // down.
        for _ in 0..<50 {
            let channel = AcknowledgedAsyncChannel<Int>()
            let sender = Task { try? await channel.send(1) }

            async let taken: Int? = try? await channel.next()
            async let _: Void = channel.cancel()

            _ = await taken
            _ = await sender.result

            // Whatever the interleaving, the channel ends up terminal and
            // nobody is left suspended.
            let ended = try await channel.next()
            XCTAssertNil(ended)
        }
    }

    func testProducerAndConsumerInterleaveWithoutBuildingABacklog() async throws {
        // The high-water assertion in miniature: with one producer and one
        // consumer, the channel never holds more than a single element.
        let channel = AcknowledgedAsyncChannel<Int>()
        let observed = OrderedRecorder<Int>()

        let watcher = Task {
            for _ in 0..<200 {
                await observed.append(await channel.pendingElementCount)
                await Task.yield()
            }
        }

        let producer = Task {
            for value in 0..<100 { try await channel.send(value) }
            await channel.finish()
        }

        var received = 0
        while try await channel.next() != nil { received += 1 }

        XCTAssertEqual(received, 100)
        _ = await producer.result
        _ = await watcher.result

        let samples = await observed.values
        XCTAssertTrue(
            samples.allSatisfy { $0 <= 1 },
            "The channel held more than one element: max \(samples.max() ?? 0)"
        )
    }
}
