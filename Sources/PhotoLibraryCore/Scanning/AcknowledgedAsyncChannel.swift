import Foundation

public enum AcknowledgedChannelError: Error, Equatable, Sendable {
    /// The consumer went away. Anything not yet delivered is gone with it.
    case cancelled
    /// `finish()` was called; no further elements are accepted.
    case finished
    /// Two producers, or two consumers, used the channel at once. The channel
    /// is single-producer/single-consumer by construction, so this is a bug in
    /// the caller rather than a runtime condition to recover from.
    case concurrentSendUnsupported
    case concurrentReceiveUnsupported
}

/// A lossless, single-slot channel whose `send` only returns once the consumer
/// has actually taken the element.
///
/// This is the backpressure primitive for the scan pipeline (bounded-pipeline
/// spec §3.1). A plain buffered stream can't express it: with `.unbounded` the
/// producer races ahead without limit, and the dropping policies lose files —
/// which for a photo library means silently not importing them.
///
/// Because the sender stays suspended until its element is consumed, "the
/// channel holds one element" and "the producer has not started building the
/// next one" are the same statement. That is what caps the whole pipeline at
/// one in-flight batch per layer.
///
/// Single producer, single consumer. Every continuation stored here is resumed
/// exactly once: it is moved out of the field that holds it *before* being
/// resumed, so a concurrent `cancel()` or `next()` finds nothing left to
/// resume.
actor AcknowledgedAsyncChannel<Element: Sendable> {
    private enum Lifecycle {
        case active
        /// No more sends, but a parked element is still drainable.
        case finishing
        case cancelled
    }

    /// The element in flight plus the sender waiting for it to be taken.
    ///
    /// Keeping them together is what makes "resume exactly the sender whose
    /// element was consumed" true by construction rather than by bookkeeping.
    private struct Parked {
        let element: Element
        var sender: CheckedContinuation<Void, Error>?
    }

    private var lifecycle: Lifecycle = .active
    private var parked: Parked?
    /// A bare wake signal, deliberately not a value channel.
    ///
    /// Handing the element straight to a parked receiver would let `send`
    /// return before the consumer had done anything with it — and a consumer
    /// that is cancelled at that moment discards it, leaving the producer
    /// believing a batch landed and free to read the next page. Waking the
    /// receiver and making *it* come back through the actor to take the element
    /// is what keeps "send returned" and "consumer took it" the same event.
    private var waitingReceiver: CheckedContinuation<Void, Never>?
    private var isSending = false
    private var isReceiving = false

    init() {}

    // MARK: - Producer

    /// Hands `element` to the consumer, returning only once the consumer has
    /// taken it.
    ///
    /// Throws `.cancelled` / `.finished` when there is no longer anyone to
    /// deliver to — the producer should treat that as "stop", not as a photo
    /// failure.
    func send(_ element: Element) async throws {
        try Task.checkCancellation()

        switch lifecycle {
        case .cancelled: throw AcknowledgedChannelError.cancelled
        case .finishing: throw AcknowledgedChannelError.finished
        case .active: break
        }
        guard !isSending, parked == nil else {
            throw AcknowledgedChannelError.concurrentSendUnsupported
        }

        isSending = true
        defer { isSending = false }

        // Always park and suspend, even when a consumer is already waiting.
        // The sender is resumed by `takeParked()` and by nothing else, so its
        // return is proof of a take rather than of a hand-off attempt.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Re-check inside the continuation: `finish()` or `cancel()`
                // can land between the guard above and here.
                switch lifecycle {
                case .cancelled:
                    continuation.resume(throwing: AcknowledgedChannelError.cancelled)
                case .finishing:
                    continuation.resume(throwing: AcknowledgedChannelError.finished)
                case .active:
                    parked = Parked(element: element, sender: continuation)
                    // Nudge a consumer that is already waiting. It returns to
                    // the actor, checks cancellation, and only then takes.
                    if let receiver = waitingReceiver {
                        waitingReceiver = nil
                        receiver.resume()
                    }
                }
            }
        } onCancel: {
            Task { await self.abandonParkedSend() }
        }
    }

    // MARK: - Consumer

    /// Takes the next element, or `nil` once the channel has finished draining
    /// or been cancelled.
    func next() async throws -> Element? {
        guard !isReceiving else {
            throw AcknowledgedChannelError.concurrentReceiveUnsupported
        }

        // A consumer that is already cancelled must not be handed work — and
        // crucially, taking a parked element here would *also* resume its
        // sender, telling the producer the batch was delivered when nobody will
        // ever look at it. Tear the channel down instead, which wakes that
        // sender with an error rather than leaving it suspended.
        if Task.isCancelled {
            cancel()
            throw CancellationError()
        }
        if lifecycle == .cancelled { return nil }

        // Something is waiting: take it and release its sender, which is what
        // lets the producer build the next batch.
        if let element = takeParked() { return element }

        // `finish()` keeps a parked element drainable; once it's gone we're done.
        if lifecycle == .finishing { return nil }

        isReceiving = true
        defer { isReceiving = false }

        // Only a wake signal: nothing is handed over here.
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                switch lifecycle {
                case .cancelled, .finishing:
                    continuation.resume()
                case .active:
                    waitingReceiver = continuation
                }
            }
        } onCancel: {
            // The consumer is gone, so the whole run is over.
            Task { await self.cancel() }
        }

        // Back on the actor, and this is the second phase of the hand-off. The
        // checkpoint comes *before* the take, so a consumer cancelled while it
        // was being woken never claims the element — and its sender therefore
        // never sees a success it could act on.
        if Task.isCancelled {
            cancel()
            throw CancellationError()
        }
        if lifecycle == .cancelled { return nil }

        if let element = takeParked() { return element }

        // Woken by `finish()` with an empty slot, or by a terminator.
        return nil
    }

    // MARK: - Termination

    /// Stops accepting new elements. A parked element stays drainable, so the
    /// last batch a producer sent is never lost to its own completion.
    ///
    /// Idempotent, and a no-op once cancelled.
    func finish() {
        guard lifecycle == .active else { return }
        lifecycle = .finishing

        // A receiver can only be parked when the slot is empty, so there is
        // nothing more coming for it.
        if parked == nil, let receiver = waitingReceiver {
            waitingReceiver = nil
            receiver.resume()
        }
    }

    /// Tears the channel down: the undelivered element is dropped, blocked
    /// participants are woken, and later sends are refused.
    ///
    /// Idempotent.
    func cancel() {
        guard lifecycle != .cancelled else { return }
        lifecycle = .cancelled

        if var current = parked {
            parked = nil
            let sender = current.sender
            current.sender = nil
            sender?.resume(throwing: AcknowledgedChannelError.cancelled)
        }
        if let receiver = waitingReceiver {
            waitingReceiver = nil
            receiver.resume()
        }
    }

    // MARK: - Test observability

    /// How many elements the channel is holding. Zero or one, always — asserted
    /// by the bounded-pipeline tests rather than assumed.
    var pendingElementCount: Int { parked == nil ? 0 : 1 }

    /// `true` once the consumer has gone. Producers read this to wind down
    /// rather than carrying on with work nobody will receive.
    var isCancelled: Bool { lifecycle == .cancelled }

    var hasWaitingReceiver: Bool { waitingReceiver != nil }

    var hasSuspendedSender: Bool { parked?.sender != nil }

    // MARK: - Private

    private func takeParked() -> Element? {
        guard var current = parked else { return nil }
        parked = nil
        let sender = current.sender
        current.sender = nil
        sender?.resume()
        return current.element
    }

    /// The *producer's* task was cancelled while parked. Drop the element and
    /// release the sender; the channel itself stays usable for the terminal
    /// bookkeeping the producer may still want to do.
    private func abandonParkedSend() {
        guard var current = parked else { return }
        parked = nil
        let sender = current.sender
        current.sender = nil
        sender?.resume(throwing: CancellationError())
    }
}
