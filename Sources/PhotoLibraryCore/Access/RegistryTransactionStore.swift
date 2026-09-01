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

    /// A decoded journal is executable recovery state, not merely data that
    /// happened to parse. Reject cross-library IDs and impossible operation
    /// shapes before either rollback store is touched.
    func validate() throws {
        guard intendedBookmark.libraryID == libraryID,
              intendedLibrary.id == libraryID,
              previousBookmark?.libraryID == nil || previousBookmark?.libraryID == libraryID,
              previousLibrary?.id == nil || previousLibrary?.id == libraryID,
              intendedBookmark.confirmedManifestLibraryID == nil
                || intendedBookmark.confirmedManifestLibraryID == libraryID,
              previousBookmark?.confirmedManifestLibraryID == nil
                || previousBookmark?.confirmedManifestLibraryID == libraryID else {
            throw RegistryTransactionValidationError.inconsistentLibraryIdentity
        }

        switch kind {
        case .freshAdd:
            guard previousBookmark == nil, previousLibrary == nil else {
                throw RegistryTransactionValidationError.invalidOldState
            }
        case .focus, .relink:
            guard previousBookmark != nil, previousLibrary != nil else {
                throw RegistryTransactionValidationError.invalidOldState
            }
        case .restoreRefresh:
            guard previousBookmark != nil else {
                throw RegistryTransactionValidationError.invalidOldState
            }
        }
    }
}

private enum RegistryTransactionValidationError: Error {
    case inconsistentLibraryIdentity
    case invalidOldState
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
            let record = try SidecarCoding.decode(RegistryTransactionRecord.self, from: data)
            try record.validate()
            return record
        } catch where FileSystemError.isNoSuchFile(error) {
            return nil
        }
    }

    func save(_ record: RegistryTransactionRecord) throws {
        try record.validate()
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
