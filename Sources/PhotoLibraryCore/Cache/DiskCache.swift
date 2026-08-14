import Foundation

public enum CacheError: Error, Equatable, Sendable {
    case insufficientDiskSpace
    case writeFailed(reason: String)
}

extension CacheError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace:
            return "There isn't enough free space to cache previews."
        case .writeFailed(let reason):
            return "A cached preview couldn't be written. \(reason)"
        }
    }

    public var recoverySuggestion: String? {
        // Spec §10: never leave the user with a dead end.
        "Free up space on your startup disk, or lower the cache limit in Settings."
    }
}

/// Byte-budgeted, LRU disk cache for thumbnails and previews.
///
/// Everything here is disposable (spec §8.3), so a failed write degrades to
/// "render it again next time" rather than surfacing as an error the user has to
/// deal with — except running out of space, which they do need to know about.
public actor DiskCache {
    public let directoryURL: URL
    public private(set) var byteBudget: Int64

    private var entries: [CacheKey: CacheEntryMetadata] = [:]
    private var pinnedKeys: Set<CacheKey> = []
    private let fileManager: FileManager

    public init(
        directoryURL: URL,
        byteBudget: Int64 = LRUEvictionPlanner.defaultByteBudget,
        fileManager: FileManager = .default
    ) throws {
        self.directoryURL = directoryURL
        self.byteBudget = max(0, byteBudget)
        self.fileManager = fileManager
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        self.entries = Self.loadExistingEntries(
            in: directoryURL,
            fileManager: fileManager
        )
    }

    public var totalByteCount: Int64 {
        entries.values.reduce(0) { $0 + $1.byteCount }
    }

    public var entryCount: Int { entries.count }

    public func setByteBudget(_ budget: Int64) throws {
        byteBudget = max(0, budget)
        try evictIfNeeded()
    }

    // MARK: - Pinning

    /// Protects an entry while it is on screen or being exported (spec §8.3).
    public func pin(_ key: CacheKey) {
        pinnedKeys.insert(key)
    }

    public func unpin(_ key: CacheKey) {
        pinnedKeys.remove(key)
    }

    public func isPinned(_ key: CacheKey) -> Bool {
        pinnedKeys.contains(key)
    }

    // MARK: - Access

    public func data(for key: CacheKey) -> Data? {
        let url = url(for: key)
        guard let data = try? Data(contentsOf: url) else {
            // File vanished under us (user emptied the folder); forget it.
            entries[key] = nil
            return nil
        }
        entries[key]?.lastAccessedAt = Date()
        return data
    }

    public func contains(_ key: CacheKey) -> Bool {
        entries[key] != nil && fileManager.fileExists(atPath: url(for: key).path)
    }

    @discardableResult
    public func store(_ data: Data, for key: CacheKey) throws -> CacheEntryMetadata {
        let url = url(for: key)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            let nsError = error as NSError
            if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
                || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC)) {
                throw CacheError.insufficientDiskSpace
            }
            throw CacheError.writeFailed(reason: nsError.localizedDescription)
        }

        let metadata = CacheEntryMetadata(
            key: key,
            byteCount: Int64(data.count),
            lastAccessedAt: Date()
        )
        entries[key] = metadata
        try evictIfNeeded()
        return metadata
    }

    public func remove(_ key: CacheKey) {
        try? fileManager.removeItem(at: url(for: key))
        entries[key] = nil
    }

    public func removeAll() throws {
        try fileManager.removeItem(at: directoryURL)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        entries.removeAll()
        // Addendum §3.4: a key pinned before the wipe would otherwise stay
        // un-evictable forever, since nothing will ever unpin an entry that no
        // longer exists.
        pinnedKeys.removeAll()
    }

    /// Runs the LRU plan. Returns what it dropped, so callers can log or assert.
    @discardableResult
    public func evictIfNeeded() throws -> [CacheKey] {
        let plan = LRUEvictionPlanner.keysToEvict(
            entries: Array(entries.values),
            byteBudget: byteBudget,
            pinned: pinnedKeys
        )
        for key in plan {
            try? fileManager.removeItem(at: url(for: key))
            entries[key] = nil
        }
        return plan
    }

    // MARK: - Private

    private func url(for key: CacheKey) -> URL {
        directoryURL.appendingPathComponent(key.filename)
    }

    /// Rebuilds the in-memory index from whatever is on disk, so a relaunch
    /// keeps the budget accurate without a separate metadata file to corrupt.
    /// Actor initializers are nonisolated under Swift 6. Keep startup discovery
    /// as a synchronous value-producing helper, then assign the result before
    /// the actor becomes externally visible.
    private static func loadExistingEntries(
        in directoryURL: URL,
        fileManager: FileManager
    ) -> [CacheKey: CacheEntryMetadata] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var entries: [CacheKey: CacheEntryMetadata] = [:]
        for url in contents {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize else { continue }
            let key = CacheKey(url.lastPathComponent)
            entries[key] = CacheEntryMetadata(
                key: key,
                byteCount: Int64(size),
                lastAccessedAt: values.contentAccessDate
                    ?? values.contentModificationDate
                    ?? Date.distantPast
            )
        }
        return entries
    }
}
