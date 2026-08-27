import Foundation

enum RegistryTransactionKind: String, Codable, Sendable {
    case freshAdd
    case focus
    case relink
    case restoreRefresh
}

struct LibraryFolderSnapshot: Codable, Equatable, Sendable {
    var id: LibraryID
    var displayName: String
    var rootPath: String
    var lastKnownPath: String
    var sourceKind: LibrarySourceKind
    var connectionState: LibraryConnectionState
    var scanState: LibraryScanState
    var lastScanAt: Date?
    var photoCount: Int

    init(_ folder: LibraryFolder) {
        id = folder.id
        displayName = folder.displayName
        rootPath = folder.rootURL.path
        lastKnownPath = folder.lastKnownPath
        sourceKind = folder.sourceKind
        connectionState = folder.connectionState
        scanState = folder.scanState.normalizedForRestore
        lastScanAt = folder.lastScanAt
        photoCount = folder.photoCount
    }

    var folder: LibraryFolder {
        LibraryFolder(
            id: id,
            displayName: displayName,
            rootURL: URL(fileURLWithPath: rootPath, isDirectory: true),
            lastKnownPath: lastKnownPath,
            sourceKind: sourceKind,
            connectionState: connectionState,
            scanState: scanState.normalizedForRestore,
            lastScanAt: lastScanAt,
            photoCount: photoCount
        )
    }
}

struct RegistryTransactionRecord: Codable, Equatable, Sendable {
    var transactionID: UUID
    var libraryID: LibraryID
    var kind: RegistryTransactionKind
    var previousBookmark: StoredBookmark?
    var intendedBookmark: StoredBookmark
    var previousLibrary: LibraryFolderSnapshot?
    var intendedLibrary: LibraryFolderSnapshot
}

protocol RegistryTransactionStoring: Sendable {
    func load() throws -> RegistryTransactionRecord?
    func save(_ record: RegistryTransactionRecord) throws
    func remove() throws
}

struct FileRegistryTransactionStore: RegistryTransactionStoring, @unchecked Sendable {
    private let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    func load() throws -> RegistryTransactionRecord? {
        do {
            let data = try Data(contentsOf: recordURL)
            return try SidecarCoding.decode(RegistryTransactionRecord.self, from: data)
        } catch where FileSystemError.isNoSuchFile(error) {
            return nil
        }
    }

    func save(_ record: RegistryTransactionRecord) throws {
        let data = try SidecarCoding.encode(record)
        try AtomicFileWriter.write(data, to: recordURL, fileManager: fileManager)
    }

    func remove() throws {
        do {
            try fileManager.removeItem(at: recordURL)
        } catch where FileSystemError.isNoSuchFile(error) {
            return
        }
    }

    private var recordURL: URL {
        directoryURL.appendingPathComponent("pending.json")
    }
}
