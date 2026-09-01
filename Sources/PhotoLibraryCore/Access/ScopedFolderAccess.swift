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

/// A held security-scoped access grant, narrowed to exactly the surface
/// `PhotoLibraryService` needs (spec §7). Exists so tests can substitute a
/// deterministic fake for `ScopedFolderAccess` — resolution success/failure,
/// staleness and reachability all otherwise depend on real bookmark/volume
/// behaviour that a unit test can't control.
///
/// `ScopedFolderAccess`'s only mutable state (`isAccessing`) is guarded by
/// its own lock and never exposed by anything this protocol requires, so it
/// is safe to treat as `Sendable` across the actor boundary.
public protocol FolderAccessHandle: AnyObject, Sendable {
    var url: URL { get }
    var isStale: Bool { get }
    var isReachable: Bool { get }
    func stop()
}

extension ScopedFolderAccess: FolderAccessHandle, @unchecked Sendable {}

/// Seam over resolving a bookmark into a held access grant, and over
/// granting access to a URL the user just picked (spec §7). The real
/// implementation is a thin pass-through to `ScopedFolderAccess`; a test
/// substitutes a resolver whose success/failure, staleness and reachability
/// are all explicitly controlled, so `PhotoLibraryService`'s
/// offline/needsAuthorization/stale-refresh/scope-pairing behaviour is
/// testable deterministically without a real disk-image or removable volume.
public protocol FolderAccessResolving: Sendable {
    /// Throws exactly when bookmark resolution itself fails (spec §7:
    /// `.needsAuthorization`) — a resolved-but-unreachable result is a
    /// successful return whose `isReachable` is `false` (spec §7: `.offline`).
    func resolve(bookmarkData: Data) throws -> any FolderAccessHandle
    /// For a folder the user just picked via a panel, where access is
    /// already granted by the picker itself.
    func grant(url: URL) -> any FolderAccessHandle
}

public struct SystemFolderAccessResolver: FolderAccessResolving {
    public init() {}

    public func resolve(bookmarkData: Data) throws -> any FolderAccessHandle {
        try ScopedFolderAccess(resolving: bookmarkData)
    }

    public func grant(url: URL) -> any FolderAccessHandle {
        ScopedFolderAccess(url: url)
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
