import Foundation
import RawProcessingCore

public struct ScannedFile: Equatable, Sendable {
    public var url: URL
    public var relativePath: String
    public var fileSize: Int64
    public var contentModificationDate: Date?

    public init(
        url: URL,
        relativePath: String,
        fileSize: Int64,
        contentModificationDate: Date? = nil
    ) {
        self.url = url
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.contentModificationDate = contentModificationDate
    }
}

public struct ScanSummary: Equatable, Sendable {
    public var discoveredCount: Int
    public var failedCount: Int
    public var completedAt: Date
    /// `true` when the walk stopped because the caller went away.
    public var wasCancelled: Bool
}

public enum ScanEvent: Sendable {
    case started
    /// A batch, so the UI can grow the grid incrementally (spec §6.1) rather
    /// than waiting for the whole tree.
    case discovered([ScannedFile])
    /// One file failed. Spec §10: the scan keeps going.
    case fileFailed(relativePath: String, reason: String)
    case finished(ScanSummary)
}

/// A single run of a folder walk.
///
/// Each `makeAsyncIterator()` starts its own walk with its own cursor and
/// channel, so two consumers never share producer state.
///
/// The sequence is non-throwing: file-level problems arrive as `.fileFailed`
/// events, and cancellation simply ends the iteration. A cancelled walk is not
/// a damaged photo (hardening addendum §3.5).
public struct FolderScanSequence: AsyncSequence, Sendable {
    public typealias Element = ScanEvent

    let root: URL
    let supportedExtensions: Set<String>
    let batchSize: Int
    let cursorFactory: any FolderScanCursorFactory

    public func makeAsyncIterator() -> Iterator {
        let channel = AcknowledgedAsyncChannel<ScanEvent>()
        let root = self.root
        let supportedExtensions = self.supportedExtensions
        let batchSize = self.batchSize
        let cursorFactory = self.cursorFactory

        // Detached at utility priority: the walk is blocking I/O and must not
        // run on the main actor. It is not fire-and-forget — the iterator owns
        // this task and cancels it on teardown.
        let producer = Task.detached(priority: .utility) {
            await FolderScanProducer.run(
                root: root,
                supportedExtensions: supportedExtensions,
                batchSize: batchSize,
                cursorFactory: cursorFactory,
                channel: channel
            )
        }

        return Iterator(channel: channel, producer: producer)
    }

    /// A class so that ending a `for await` loop early — which releases the
    /// iterator — deterministically tears the producer down. Nothing here waits
    /// for process exit to reclaim a walk.
    public final class Iterator: AsyncIteratorProtocol {
        private let channel: AcknowledgedAsyncChannel<ScanEvent>
        private let producer: Task<Void, Never>

        init(channel: AcknowledgedAsyncChannel<ScanEvent>, producer: Task<Void, Never>) {
            self.channel = channel
            self.producer = producer
        }

        deinit {
            producer.cancel()
            let channel = self.channel
            Task { await channel.cancel() }
        }

        public func next() async -> ScanEvent? {
            // Any channel error means "there is nothing more for you", which is
            // exactly what `nil` says to `for await`.
            guard let event = try? await channel.next() else { return nil }
            return event
        }
    }
}

/// Streams a photo folder in bounded batches.
///
/// Spec §11: never load every RAW or all metadata into memory at once. The
/// walk is pull-based and the channel only holds one batch, so a 100k-file
/// drive costs the same as a 100-file one no matter how slow the consumer is.
public struct FolderScanner: Sendable {
    public var supportedExtensions: Set<String>
    public var batchSize: Int

    /// Injectable so the bounded-pipeline tests can drive the walk without
    /// needing a real 10,000-file directory.
    var cursorFactory: any FolderScanCursorFactory

    public init(
        supportedExtensions: Set<String> = CoreImageRawDecoder.candidateFileExtensions,
        batchSize: Int = 32
    ) {
        self.supportedExtensions = supportedExtensions
        self.batchSize = max(1, batchSize)
        self.cursorFactory = FileManagerFolderScanCursorFactory()
    }

    init(
        supportedExtensions: Set<String> = CoreImageRawDecoder.candidateFileExtensions,
        batchSize: Int = 32,
        cursorFactory: any FolderScanCursorFactory
    ) {
        self.supportedExtensions = supportedExtensions
        self.batchSize = max(1, batchSize)
        self.cursorFactory = cursorFactory
    }

    public func scan(root: URL) -> FolderScanSequence {
        FolderScanSequence(
            root: root,
            supportedExtensions: supportedExtensions,
            batchSize: batchSize,
            cursorFactory: cursorFactory
        )
    }

    /// Library-relative, `/`-separated, so the value stored in the sidecar is
    /// portable between this Mac and a future iPad.
    static func relativePath(of url: URL, from root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = url.standardizedFileURL.pathComponents

        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
            return url.lastPathComponent
        }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}

/// Drives one cursor against one channel.
///
/// The ordering here is the whole backpressure contract (bounded-pipeline
/// spec §3.3): advance the walk once, deliver everything that advance produced,
/// and only then advance again. Because `send` doesn't return until the
/// consumer has taken the element, "we are still sending" and "we have not
/// looked at more files" are the same state.
enum FolderScanProducer {
    static func run(
        root: URL,
        supportedExtensions: Set<String>,
        batchSize: Int,
        cursorFactory: any FolderScanCursorFactory,
        channel: AcknowledgedAsyncChannel<ScanEvent>
    ) async {
        let cursor = cursorFactory.makeCursor(
            root: root,
            supportedExtensions: supportedExtensions,
            batchSize: batchSize
        )
        defer { cursor.close() }

        var discovered = 0
        var failed = 0
        var wasCancelled = false

        do {
            try await channel.send(.started)

            while true {
                if Task.isCancelled { wasCancelled = true; break }

                let page = cursor.nextPage()

                // A non-cooperative page read is allowed to finish, but its
                // result is dropped rather than published.
                if Task.isCancelled { wasCancelled = true; break }

                for failure in page.failures {
                    failed += 1
                    try await channel.send(
                        .fileFailed(relativePath: failure.relativePath, reason: failure.reason)
                    )
                }

                if !page.files.isEmpty {
                    discovered += page.files.count
                    try await channel.send(.discovered(page.files))
                }

                if page.isAtEnd { break }
            }

            if !wasCancelled { wasCancelled = Task.isCancelled }

            // Fixed choice (spec §3.3 offers two): a cancelled run still
            // *attempts* a terminal summary, but never blocks on it. When the
            // consumer has already gone the send throws and the run just ends —
            // so in practice only a completed walk delivers `.finished`.
            try await channel.send(.finished(ScanSummary(
                discoveredCount: discovered,
                failedCount: failed,
                completedAt: Date(),
                wasCancelled: wasCancelled
            )))
        } catch {
            // Channel cancelled or closed, or our own task was cancelled.
            // There is no one left to tell.
        }

        await channel.finish()
    }
}
