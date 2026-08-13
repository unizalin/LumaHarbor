import Foundation

/// Holds a security scope open for as long as the object lives.
///
/// Spec §7 requires `startAccessingSecurityScopedResource()` and
/// `stopAccessingSecurityScopedResource()` to be paired. Tying the pair to an
/// object's lifetime is the only way to keep that true across the early returns
/// and thrown errors a scan is full of.
public final class ScopedFolderAccess {
    public let url: URL
    /// macOS asked for the bookmark to be regenerated.
    public let isStale: Bool
    /// `false` when the scope could not be taken. Access may still work for a
    /// non-sandboxed build, so this is reported rather than treated as fatal.
    public private(set) var isAccessing: Bool

    private var hasStopped = false
    private let lock = NSLock()

    public init(resolving bookmarkData: Data) throws {
        let resolved = try SecurityScopedBookmark.resolve(bookmarkData)
        self.url = resolved.url
        self.isStale = resolved.isStale
        self.isAccessing = resolved.url.startAccessingSecurityScopedResource()
    }

    /// For a folder the user just picked in the open panel, where the scope is
    /// already granted by the panel itself.
    public init(url: URL, startAccessing: Bool = true) {
        self.url = url
        self.isStale = false
        self.isAccessing = startAccessing ? url.startAccessingSecurityScopedResource() : false
    }

    deinit {
        stop()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !hasStopped else { return }
        hasStopped = true
        if isAccessing {
            url.stopAccessingSecurityScopedResource()
            isAccessing = false
        }
    }

    /// Whether the folder is currently reachable — the offline test in spec §10.
    public var isReachable: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

/// `NSFileCoordinator` wrappers for external-volume I/O (spec §7.3).
public enum FileCoordination {
    public static func read<T>(
        _ url: URL,
        options: NSFileCoordinator.ReadingOptions = [],
        _ body: (URL) throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var result: Result<T, Error>?

        coordinator.coordinate(readingItemAt: url, options: options, error: &coordinatorError) { readURL in
            result = Result { try body(readURL) }
        }

        if let coordinatorError { throw coordinatorError }
        guard let result else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
        }
        return try result.get()
    }

    public static func write(
        _ url: URL,
        options: NSFileCoordinator.WritingOptions = [],
        _ body: (URL) throws -> Void
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var thrown: Error?

        coordinator.coordinate(writingItemAt: url, options: options, error: &coordinatorError) { writeURL in
            do {
                try body(writeURL)
            } catch {
                thrown = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let thrown { throw thrown }
    }
}
