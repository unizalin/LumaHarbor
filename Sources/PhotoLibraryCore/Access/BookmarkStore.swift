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
    public var sourceKind: LibrarySourceKind
    /// Only ever `.idle` or `.partialFailure` (spec §7) — enforced on both
    /// write and read, so a `.queued`/`.scanning` value can never survive a
    /// relaunch even if something upstream forgot to normalize it first.
    public var scanState: LibraryScanState
    /// A manifest `LibraryID` actually confirmed by reading
    /// `.lumaharbor/library.json` — never a locally-minted `LibraryID`
    /// standing in for one. `nil` means no manifest has ever been confirmed
    /// for this source, not "assume it matches its own `libraryID`" (spec §7).
    public var confirmedManifestLibraryID: LibraryID?
    /// Bookmark-resolved identity, captured the last time this source was
    /// reachable (spec §7 step 2). Lets a re-add or overlap check recognise
    /// this exact source even while it's offline, without ever needing its
    /// runtime root URL.
    public var resourceIdentifier: Data?
    /// Canonical, stable string form of the volume identifier (base64 of the
    /// resolved bytes) — kept wire-compatible with the previously-shipped
    /// `Data`-typed field: `Data`'s default JSON encoding is already a base64
    /// string, so decoding that same key directly as `String` reads either
    /// shape identically.
    public var volumeIdentifier: String?
    public var rootFingerprint: RootFingerprint?

    public init(
        libraryID: LibraryID,
        displayName: String,
        lastKnownPath: String,
        bookmarkData: Data,
        addedAt: Date = Date(),
        sourceKind: LibrarySourceKind = .externalFolder,
        scanState: LibraryScanState = .idle,
        confirmedManifestLibraryID: LibraryID? = nil,
        resourceIdentifier: Data? = nil,
        volumeIdentifier: String? = nil,
        rootFingerprint: RootFingerprint? = nil
    ) {
        self.libraryID = libraryID
        self.displayName = displayName
        self.lastKnownPath = lastKnownPath
        self.bookmarkData = bookmarkData
        self.addedAt = addedAt
        self.sourceKind = sourceKind
        self.scanState = scanState.normalizedForRestore
        self.confirmedManifestLibraryID = confirmedManifestLibraryID
        self.resourceIdentifier = resourceIdentifier
        self.volumeIdentifier = volumeIdentifier
        self.rootFingerprint = rootFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case libraryID, displayName, lastKnownPath, bookmarkData, addedAt
        case sourceKind, scanState
        case confirmedManifestLibraryID, resourceIdentifier, volumeIdentifier, rootFingerprint
    }

    /// Custom so a bookmark file written before Task 2 — with none of the
    /// new keys — still decodes: every addition here is optional-with-a-
    /// default, never a newly required field (spec §7: "existing bookmark
    /// records must decode backward-compatibly as `.externalFolder`").
    ///
    /// `sourceKind`/`scanState` are decoded through their *raw string* first,
    /// not the enum's own `Decodable` conformance: a future, unrecognized raw
    /// value must fall back to a safe default and let the rest of the record
    /// through. It is backward-compatible data, not corruption that should
    /// fail the registry load (spec §7 fail-safe requirement).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        libraryID = try container.decode(LibraryID.self, forKey: .libraryID)
        displayName = try container.decode(String.self, forKey: .displayName)
        lastKnownPath = try container.decode(String.self, forKey: .lastKnownPath)
        bookmarkData = try container.decode(Data.self, forKey: .bookmarkData)
        addedAt = try container.decode(Date.self, forKey: .addedAt)

        let sourceKindRaw = try container.decodeIfPresent(String.self, forKey: .sourceKind)
        sourceKind = sourceKindRaw.flatMap(LibrarySourceKind.init(rawValue:)) ?? .externalFolder

        let scanStateRaw = try container.decodeIfPresent(String.self, forKey: .scanState)
        let decodedScanState = scanStateRaw.flatMap(LibraryScanState.init(rawValue:)) ?? .idle
        scanState = decodedScanState.normalizedForRestore

        confirmedManifestLibraryID = try container.decodeIfPresent(
            LibraryID.self, forKey: .confirmedManifestLibraryID
        )
        resourceIdentifier = try container.decodeIfPresent(Data.self, forKey: .resourceIdentifier)
        // See the property doc: reading the same key as `String` (not
        // `Data`) is what makes this compatible with records written by the
        // previous, `Data`-typed field.
        volumeIdentifier = try container.decodeIfPresent(String.self, forKey: .volumeIdentifier)
        rootFingerprint = try container.decodeIfPresent(RootFingerprint.self, forKey: .rootFingerprint)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(libraryID, forKey: .libraryID)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(lastKnownPath, forKey: .lastKnownPath)
        try container.encode(bookmarkData, forKey: .bookmarkData)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encode(sourceKind.rawValue, forKey: .sourceKind)
        try container.encode(scanState.normalizedForRestore.rawValue, forKey: .scanState)
        try container.encodeIfPresent(confirmedManifestLibraryID, forKey: .confirmedManifestLibraryID)
        try container.encodeIfPresent(resourceIdentifier, forKey: .resourceIdentifier)
        try container.encodeIfPresent(volumeIdentifier, forKey: .volumeIdentifier)
        try container.encodeIfPresent(rootFingerprint, forKey: .rootFingerprint)
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
/// A file each, rather than one combined plist, so records can be replaced
/// atomically and inspected independently. Registry reads still fail closed:
/// silently dropping one unreadable record would make later mutation operate
/// on an incomplete view of the user's sources.
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
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }

        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        return try contents
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { url in
                let data = try Data(contentsOf: url)
                return try SidecarCoding.decode(StoredBookmark.self, from: data)
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
