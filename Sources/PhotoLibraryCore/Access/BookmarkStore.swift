import Foundation

/// A remembered photo folder, as persisted on this Mac.
public struct StoredBookmark: Codable, Equatable, Sendable {
    public var libraryID: LibraryID
    public var displayName: String
    /// Only for showing the user which drive is missing. Never used to guess a
    /// replacement path (spec §7).
    public var lastKnownPath: String
    public var bookmarkData: Data
    public var addedAt: Date

    public init(
        libraryID: LibraryID,
        displayName: String,
        lastKnownPath: String,
        bookmarkData: Data,
        addedAt: Date = Date()
    ) {
        self.libraryID = libraryID
        self.displayName = displayName
        self.lastKnownPath = lastKnownPath
        self.bookmarkData = bookmarkData
        self.addedAt = addedAt
    }
}

public protocol BookmarkStoring: Sendable {
    func save(_ bookmark: StoredBookmark) throws
    func loadAll() throws -> [StoredBookmark]
    func load(libraryID: LibraryID) throws -> StoredBookmark?
    func remove(libraryID: LibraryID) throws
}

/// One JSON file per library under `Application Support/LumaHarbor/bookmarks/`.
///
/// A file each, rather than one combined plist, so a single unreadable bookmark
/// can't cost the user access to their other folders.
/// `FileManager` is not annotated `Sendable` by Foundation. This store only
/// keeps an immutable instance and performs synchronous, non-delegate file
/// operations, so sharing the value across an actor boundary is safe.
public struct FileBookmarkStore: BookmarkStoring, @unchecked Sendable {
    private let directoryURL: URL
    private let fileManager: FileManager

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    public func save(_ bookmark: StoredBookmark) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try SidecarCoding.encode(bookmark)
        try AtomicFileWriter.write(data, to: url(for: bookmark.libraryID), fileManager: fileManager)
    }

    public func loadAll() throws -> [StoredBookmark] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return contents
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? SidecarCoding.decode(StoredBookmark.self, from: data)
            }
            .sorted { $0.addedAt < $1.addedAt }
    }

    public func load(libraryID: LibraryID) throws -> StoredBookmark? {
        let url = url(for: libraryID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try SidecarCoding.decode(StoredBookmark.self, from: data)
    }

    public func remove(libraryID: LibraryID) throws {
        let url = url(for: libraryID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func url(for libraryID: LibraryID) -> URL {
        directoryURL.appendingPathComponent("\(libraryID.rawValue.uuidString).json")
    }
}
