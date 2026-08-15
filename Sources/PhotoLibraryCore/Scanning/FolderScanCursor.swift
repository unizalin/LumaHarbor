import Foundation

/// One file the walk couldn't read. Spec §10: the scan keeps going.
public struct FolderScanFailure: Equatable, Sendable {
    public var relativePath: String
    public var reason: String

    public init(relativePath: String, reason: String) {
        self.relativePath = relativePath
        self.reason = reason
    }
}

/// The result of advancing the walk exactly once.
///
/// At most one batch of files, capped at the scanner's batch size, plus any
/// failures Foundation reported *during this advance*. Nothing is carried over
/// from an earlier page, which is what makes "no read-ahead" checkable rather
/// than aspirational (bounded-pipeline spec §3.3).
public struct FolderScanPage: Equatable, Sendable {
    public var files: [ScannedFile]
    public var failures: [FolderScanFailure]
    /// `true` when the walk is exhausted; the caller must not ask again.
    public var isAtEnd: Bool

    public init(files: [ScannedFile] = [], failures: [FolderScanFailure] = [], isAtEnd: Bool = false) {
        self.files = files
        self.failures = failures
        self.isAtEnd = isAtEnd
    }

    public var isEmpty: Bool { files.isEmpty && failures.isEmpty }
}

/// A directory walk that only moves when asked.
///
/// Pull-based on purpose: the enumerator advances once per `nextPage()`, so a
/// fast disk cannot queue thousands of batches ahead of a slow inspection pass.
/// Implementations own blocking I/O and must never be driven from the main
/// actor.
protocol FolderScanCursor: AnyObject, Sendable {
    /// Advances the walk once. Blocking.
    func nextPage() -> FolderScanPage
    /// Releases the underlying enumerator. Idempotent.
    func close()
}

protocol FolderScanCursorFactory: Sendable {
    func makeCursor(
        root: URL,
        supportedExtensions: Set<String>,
        batchSize: Int
    ) -> any FolderScanCursor
}

/// The production walk, backed by `FileManager.DirectoryEnumerator`.
///
/// INVARIANT (the reason for `@unchecked Sendable`): every read or write of
/// `enumerator`, `pendingFailures` and `isClosed` happens while holding `lock`.
/// `DirectoryEnumerator` is not thread-safe and Foundation marks `nextObject()`
/// unavailable from async contexts, so the lock — together with this type only
/// ever being driven by its owning producer task — is what keeps the walk both
/// serialised and legal to perform.
final class FileManagerFolderScanCursor: FolderScanCursor, @unchecked Sendable {
    private static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isDirectoryKey
    ]

    /// Reads a file's resource values.
    ///
    /// Injectable so a test can make every file fail without needing a
    /// directory full of genuinely corrupt entries — which is the only way to
    /// prove the failure path is budgeted rather than unbounded.
    typealias ResourceValuesLoader =
        @Sendable (URL, Set<URLResourceKey>) throws -> URLResourceValues

    private let root: URL
    private let supportedExtensions: Set<String>
    private let batchSize: Int
    private let loadResourceValues: ResourceValuesLoader

    private let lock = NSLock()
    private var enumerator: FileManager.DirectoryEnumerator?
    /// Failures Foundation handed us during the advance currently in progress.
    private var pendingFailures: [FolderScanFailure] = []
    private var isClosed = false
    private var didStart = false

    init(
        root: URL,
        supportedExtensions: Set<String>,
        batchSize: Int,
        loadResourceValues: @escaping ResourceValuesLoader = { url, keys in
            try url.resourceValues(forKeys: keys)
        }
    ) {
        self.root = root
        self.supportedExtensions = supportedExtensions
        self.batchSize = max(1, batchSize)
        self.loadResourceValues = loadResourceValues
    }

    func nextPage() -> FolderScanPage {
        lock.lock()
        defer { lock.unlock() }

        guard !isClosed else { return FolderScanPage(isAtEnd: true) }

        if !didStart {
            didStart = true
            let root = self.root
            // `.skipsHiddenFiles` also keeps `.lumaharbor` out of the results,
            // which is exactly what we want: it's our data, not the user's.
            enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Self.resourceKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { [weak self] url, error in
                    // Called synchronously from `nextObject()`, so this only
                    // ever appends to the advance that is currently running.
                    self?.appendFailureWhileLocked(
                        FolderScanFailure(
                            relativePath: FolderScanner.relativePath(of: url, from: root),
                            reason: (error as NSError).localizedDescription
                        )
                    )
                    return true // keep going
                }
            )
        }

        guard let enumerator else {
            // An unreadable or missing root: nothing to walk, and the caller
            // still gets a terminal page rather than hanging.
            return FolderScanPage(failures: takeFailures(), isAtEnd: true)
        }

        var files: [ScannedFile] = []
        files.reserveCapacity(batchSize)

        // The budget covers *items*, not just successes. A folder where every
        // file is unreadable produces only failures, and counting just
        // `files.count` would let one page accumulate one entry per broken file
        // on the whole drive — unbounded, which is the thing this design
        // exists to prevent.
        //
        // Foundation's error handler fires inside `nextObject()` and can append
        // more than one failure for a single advance; that granularity isn't
        // ours to split, so a page may exceed the budget by whatever one
        // `nextObject()` call reports. The bound is per-advance, not exact.
        while files.count + pendingFailures.count < batchSize {
            if Task.isCancelled {
                // Hand back what we have; the producer checks cancellation and
                // will not ask for another page.
                return FolderScanPage(files: files, failures: takeFailures(), isAtEnd: false)
            }

            guard let fileURL = enumerator.nextObject() as? URL else {
                return FolderScanPage(files: files, failures: takeFailures(), isAtEnd: true)
            }

            guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else {
                continue
            }

            do {
                let values = try loadResourceValues(fileURL, Set(Self.resourceKeys))
                guard values.isRegularFile == true else { continue }

                files.append(ScannedFile(
                    url: fileURL,
                    relativePath: FolderScanner.relativePath(of: fileURL, from: root),
                    fileSize: Int64(values.fileSize ?? 0),
                    contentModificationDate: values.contentModificationDate
                ))
            } catch {
                pendingFailures.append(FolderScanFailure(
                    relativePath: FolderScanner.relativePath(of: fileURL, from: root),
                    reason: (error as NSError).localizedDescription
                ))
            }
        }

        return FolderScanPage(files: files, failures: takeFailures(), isAtEnd: false)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        isClosed = true
        enumerator = nil
        pendingFailures.removeAll()
    }

    /// Caller already holds `lock` — the Foundation error handler runs inside
    /// `nextObject()`, which we only ever call from `nextPage()`.
    private func appendFailureWhileLocked(_ failure: FolderScanFailure) {
        pendingFailures.append(failure)
    }

    private func takeFailures() -> [FolderScanFailure] {
        let failures = pendingFailures
        pendingFailures.removeAll(keepingCapacity: true)
        return failures
    }
}

struct FileManagerFolderScanCursorFactory: FolderScanCursorFactory {
    /// Overridable so a test can drive the *real* cursor — enumerator and all —
    /// while forcing every resource read to fail.
    var loadResourceValues: FileManagerFolderScanCursor.ResourceValuesLoader = { url, keys in
        try url.resourceValues(forKeys: keys)
    }

    func makeCursor(
        root: URL,
        supportedExtensions: Set<String>,
        batchSize: Int
    ) -> any FolderScanCursor {
        FileManagerFolderScanCursor(
            root: root,
            supportedExtensions: supportedExtensions,
            batchSize: batchSize,
            loadResourceValues: loadResourceValues
        )
    }
}
