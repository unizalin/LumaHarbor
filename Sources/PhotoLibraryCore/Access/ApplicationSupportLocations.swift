import Foundation

/// Where the Mac's disposable local data lives.
///
/// Spec §8.3:
///   Application Support/LumaHarbor/
///   ├─ library.sqlite
///   ├─ bookmarks/
///   └─ cache/{thumbnails,previews}
///
/// Everything under here is rebuildable from the SSD, and the bookmark folder is
/// per-Mac by design (spec §7) — it must never be copied to the drive.
public struct ApplicationSupportLocations: Sendable, Equatable {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public var databaseURL: URL { baseURL.appendingPathComponent("library.sqlite") }
    public var bookmarksDirectoryURL: URL {
        baseURL.appendingPathComponent("bookmarks", isDirectory: true)
    }
    public var cacheDirectoryURL: URL {
        baseURL.appendingPathComponent("cache", isDirectory: true)
    }
    public var thumbnailCacheURL: URL {
        cacheDirectoryURL.appendingPathComponent("thumbnails", isDirectory: true)
    }
    public var previewCacheURL: URL {
        cacheDirectoryURL.appendingPathComponent("previews", isDirectory: true)
    }
    /// "My Presets" (spec §8.1) -- user-authored data, not rebuildable from
    /// the drive, so it is created up front like `bookmarksDirectoryURL` and
    /// deliberately excluded from `removeRebuildableData`.
    public var presetsDirectoryURL: URL {
        baseURL.appendingPathComponent("Presets", isDirectory: true)
    }
    /// WAL-mode sidecars, named `library.sqlite-wal` / `library.sqlite-shm`
    /// alongside the database file itself. Only present while (or just after)
    /// a connection is open, but a reset must not leave them behind for a
    /// fresh connection to trip over.
    public var databaseWALURL: URL {
        databaseURL.deletingLastPathComponent()
            .appendingPathComponent(databaseURL.lastPathComponent + "-wal")
    }
    public var databaseSHMURL: URL {
        databaseURL.deletingLastPathComponent()
            .appendingPathComponent(databaseURL.lastPathComponent + "-shm")
    }

    public static func standard(
        folderName: String = "LumaHarbor",
        fileManager: FileManager = .default
    ) throws -> ApplicationSupportLocations {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return ApplicationSupportLocations(
            baseURL: support.appendingPathComponent(folderName, isDirectory: true)
        )
    }

    public func createDirectories(using fileManager: FileManager = .default) throws {
        for url in [baseURL, bookmarksDirectoryURL, thumbnailCacheURL, previewCacheURL, presetsDirectoryURL] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Spec §13.9: deleting the local database and caches must be recoverable.
    /// Exposed so the app can offer it and so tests can prove the rebuild.
    ///
    /// Never touches `bookmarksDirectoryURL` — those are per-Mac and not
    /// rebuildable from the drive.
    public func removeRebuildableData(using fileManager: FileManager = .default) throws {
        let targets = [databaseURL, databaseWALURL, databaseSHMURL, cacheDirectoryURL]
        for url in targets where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
