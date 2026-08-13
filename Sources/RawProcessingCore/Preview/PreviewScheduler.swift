import Foundation

/// Serialises interactive preview work and drops stale results.
///
/// Spec §9 states two rules this type exists to enforce:
///   - only one live interactive preview per photo; a newer request cancels and
///     replaces the older one,
///   - when the user switches photos, an in-flight preview for the previous
///     photo must never reach the screen.
///
/// Both are enforced here rather than in the view model, so the guarantee holds
/// no matter which UI drives it — including the future iPadOS one.
public actor PreviewScheduler {
    private struct InFlight {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private let renderer: PreviewRendering
    private var generationCounter: UInt64 = 0
    private var activeSubject: PreviewSubject?
    private var inFlight: [PreviewSubject: InFlight] = [:]
    private var latestGeneration: [PreviewSubject: UInt64] = [:]
    /// `nonisolated` so `deinit` can finish the stream without hopping onto the
    /// actor, which it can't do.
    private nonisolated let continuation: AsyncStream<PreviewEvent>.Continuation

    /// Results and failures, in delivery order. Stale work never appears here.
    public nonisolated let events: AsyncStream<PreviewEvent>

    // MARK: Diagnostics
    //
    // Counters rather than logs, so tests can assert that cancellation actually
    // happened instead of inferring it from timing.

    public private(set) var supersededCount = 0
    public private(set) var deliveredCount = 0
    public private(set) var discardedStaleCount = 0
    public private(set) var failedCount = 0

    public init(renderer: PreviewRendering) {
        let (stream, continuation) = AsyncStream<PreviewEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.renderer = renderer
        self.events = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    /// The subject the scheduler currently considers on screen.
    public var currentSubject: PreviewSubject? { activeSubject }

    public var inFlightCount: Int { inFlight.count }

    /// Submits a preview and returns the token it will be delivered under.
    @discardableResult
    public func submit(_ request: PreviewRequest) -> PreviewToken {
        generationCounter += 1
        let token = PreviewToken(subject: request.subject, generation: generationCounter)

        // Switching photos: everything queued for other photos is now pointless
        // work competing for the same GPU. Cancel it before starting the new one.
        if activeSubject != request.subject {
            cancelInFlight(excluding: request.subject)
            activeSubject = request.subject
        }

        // Same photo, newer parameters: the older render can only produce a
        // frame the user has already scrolled past.
        if let existing = inFlight[request.subject] {
            existing.task.cancel()
            supersededCount += 1
        }

        latestGeneration[request.subject] = token.generation

        let task = Task { [renderer] in
            do {
                let image = try await renderer.render(request)
                try Task.checkCancellation()
                self.deliver(
                    PreviewResult(token: token, quality: request.quality, image: image)
                )
            } catch is CancellationError {
                self.discard(token)
            } catch {
                self.fail(token, error: error)
            }
        }

        inFlight[request.subject] = InFlight(generation: token.generation, task: task)
        return token
    }

    /// Cancels everything and forgets which photo is on screen. Called when the
    /// editor closes or the library goes offline.
    public func cancelAll() {
        for (_, entry) in inFlight {
            entry.task.cancel()
            supersededCount += 1
        }
        inFlight.removeAll()
        latestGeneration.removeAll()
        activeSubject = nil
    }

    /// True when `token` still describes the preview that belongs on screen.
    ///
    /// Consumers should re-check this before applying a result they held onto,
    /// which is the second half of the stale-result guarantee.
    public func isCurrent(_ token: PreviewToken) -> Bool {
        activeSubject == token.subject && latestGeneration[token.subject] == token.generation
    }

    // MARK: - Private

    private func cancelInFlight(excluding subject: PreviewSubject) {
        for (key, entry) in inFlight where key != subject {
            entry.task.cancel()
            supersededCount += 1
            inFlight[key] = nil
        }
    }

    private func deliver(_ result: PreviewResult) {
        clearInFlight(result.token)
        // A renderer that ignores cancellation still can't put a stale frame on
        // screen: the token is checked at the moment of delivery, not at submit.
        guard isCurrent(result.token) else {
            discardedStaleCount += 1
            return
        }
        deliveredCount += 1
        continuation.yield(.produced(result))
    }

    private func discard(_ token: PreviewToken) {
        clearInFlight(token)
        discardedStaleCount += 1
    }

    private func fail(_ token: PreviewToken, error: Error) {
        clearInFlight(token)
        guard isCurrent(token) else {
            discardedStaleCount += 1
            return
        }
        failedCount += 1
        continuation.yield(.failed(token, error))
    }

    /// Only clears the slot if it still holds *this* attempt — a late-finishing
    /// older task must not evict the newer one that replaced it.
    private func clearInFlight(_ token: PreviewToken) {
        if inFlight[token.subject]?.generation == token.generation {
            inFlight[token.subject] = nil
        }
    }
}
