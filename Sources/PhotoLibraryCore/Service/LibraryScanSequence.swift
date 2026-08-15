import Foundation

/// A single run of a library scan.
///
/// Each `makeAsyncIterator()` starts a new run with its own channel, so a
/// restarted scan can never share producer state with the one it replaced.
///
/// Non-throwing on purpose: failures the user can act on arrive as `.failed`,
/// `.photoFailed` or `.finished` events. Cancellation just ends the iteration —
/// hardening addendum §3.5 is explicit that giving up must not be reported as a
/// damaged photo.
public struct LibraryScanSequence: AsyncSequence, Sendable {
    public typealias Element = LibraryScanEvent

    let service: PhotoLibraryService
    let libraryID: LibraryID

    public func makeAsyncIterator() -> Iterator {
        let channel = AcknowledgedAsyncChannel<LibraryScanEvent>()
        let service = self.service
        let libraryID = self.libraryID

        let producer = Task {
            await service.performScan(libraryID: libraryID, emitter: channel)
            // `finish` rather than `cancel`: a last event still parked in the
            // channel stays drainable, so the terminal `.finished` is never
            // lost to the producer's own completion.
            await channel.finish()
        }

        return Iterator(channel: channel, producer: producer)
    }

    /// A class so that leaving a `for await` loop early deterministically tears
    /// the scan down. Releasing the iterator cancels the producer, which
    /// unblocks anything parked in the channel and — through the service's own
    /// `for await` over the folder walk — stops the directory cursor too.
    public final class Iterator: AsyncIteratorProtocol {
        private let channel: AcknowledgedAsyncChannel<LibraryScanEvent>
        private let producer: Task<Void, Never>

        init(channel: AcknowledgedAsyncChannel<LibraryScanEvent>, producer: Task<Void, Never>) {
            self.channel = channel
            self.producer = producer
        }

        deinit {
            producer.cancel()
            let channel = self.channel
            Task { await channel.cancel() }
        }

        public func next() async -> LibraryScanEvent? {
            guard let event = try? await channel.next() else { return nil }
            return event
        }
    }
}
