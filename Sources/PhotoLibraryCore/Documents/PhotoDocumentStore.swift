import Foundation
import RawProcessingCore

/// Opens and persists single-photo documents outside a full library — the
/// iPad workflow where a user works on one RAW from Files or an external
/// drive without importing a whole folder.
///
/// App-copy imports follow copy → fingerprint verification → record commit
/// (spec §8.1 / plan Task 4): the copy lands under a private per-document
/// directory first, and only after its bytes are proven identical to the
/// source does a document record get written. A failure at any point removes
/// the partial copy and its directory, so a crash or verification failure
/// never leaves a half-imported document behind.
///
/// Sidecar reads/writes are delegated to `FileSidecarRepository` — the same
/// atomic-write, schema-gated, quarantine-on-corruption codec the full
/// library uses — so this store does not duplicate that format.
public actor PhotoDocumentStore {
    private static let documentsDirectoryName = "Documents"
    private static let recordsDirectoryName = "Records"
    private static let sidecarsDirectoryName = "Sidecars"
    private static let importingFilename = ".importing"

    private let rootURL: URL
    private let fileManager: FileManager
    private let copyFile: @Sendable (URL, URL) throws -> Void

    public init(
        rootURL: URL,
        fileManager: FileManager = .default,
        copyFile: (@Sendable (URL, URL) throws -> Void)? = nil
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.copyFile = copyFile ?? { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    /// Opens `sourceURL` in place. The RAW is only ever read: adjustments are
    /// saved to a sidecar next to the document record, never back to the
    /// source file.
    public func openInPlace(_ sourceURL: URL, bookmarkData: Data?) throws -> PhotoDocument {
        let fingerprint = try FingerprintCalculator.fingerprint(forFileAt: sourceURL)
        let document = PhotoDocument(
            storageMode: .inPlace,
            workingURL: sourceURL,
            sourceURL: sourceURL,
            sourceBookmarkData: bookmarkData,
            sourceFingerprint: fingerprint,
            workingFingerprint: fingerprint
        )
        try writeRecord(document)
        return document
    }

    /// Copies `sourceURL` into App storage, verifies the copy byte-for-byte
    /// via fingerprint, and only then commits a document record. On any
    /// failure the partial copy and its directory are removed and no record
    /// is left behind.
    public func importCopy(of sourceURL: URL, bookmarkData: Data?) throws -> PhotoDocument {
        let id = UUID()
        let directory = documentsDirectoryURL.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(sourceURL.lastPathComponent)
            let temporary = directory.appendingPathComponent(Self.importingFilename)
            try copyFile(sourceURL, temporary)

            let sourceFingerprint = try FingerprintCalculator.fingerprint(forFileAt: sourceURL)
            let copiedFingerprint = try FingerprintCalculator.fingerprint(forFileAt: temporary)
            guard sourceFingerprint == copiedFingerprint else {
                throw PhotoDocumentError.copyVerificationFailed
            }

            try fileManager.moveItem(at: temporary, to: destination)
            let document = PhotoDocument(
                id: id,
                storageMode: .appCopy,
                workingURL: destination,
                sourceURL: sourceURL,
                sourceBookmarkData: bookmarkData,
                sourceFingerprint: sourceFingerprint,
                workingFingerprint: copiedFingerprint
            )
            try writeRecord(document)
            return document
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    public func loadDocument(id: UUID) throws -> PhotoDocument {
        let url = recordURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw PhotoDocumentError.documentNotFound(id)
        }
        return try SidecarCoding.decode(PhotoDocument.self, from: Data(contentsOf: url))
    }

    /// The currently saved adjustments for a document, or `.neutral` when no
    /// sidecar has been written yet. Schema-too-new or corrupt sidecars throw
    /// rather than being silently overwritten — `FileSidecarRepository`
    /// enforces that.
    public func loadAdjustments(documentID: UUID) throws -> PhotoAdjustments {
        let document = try loadDocument(id: documentID)
        let repository = try sidecarRepository(documentID: documentID)
        return try repository.loadSidecar(for: PhotoID(documentID))?.adjustments ?? .neutral
    }

    public func saveAdjustments(_ adjustments: PhotoAdjustments, documentID: UUID) throws {
        let document = try loadDocument(id: documentID)
        let repository = try sidecarRepository(documentID: documentID)
        let existing = try repository.loadSidecar(for: PhotoID(documentID))
        let sidecar = existing?.updating(adjustments: adjustments) ?? PhotoSidecar(
            photoID: PhotoID(documentID),
            sourceRelativePath: document.workingURL.lastPathComponent,
            sourceFingerprint: document.workingFingerprint,
            adjustments: adjustments
        )
        try repository.write(sidecar: sidecar)
    }

    // MARK: - Private

    private var documentsDirectoryURL: URL {
        rootURL.appendingPathComponent(Self.documentsDirectoryName, isDirectory: true)
    }

    private var recordsDirectoryURL: URL {
        rootURL.appendingPathComponent(Self.recordsDirectoryName, isDirectory: true)
    }

    private func recordURL(for id: UUID) -> URL {
        recordsDirectoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func writeRecord(_ document: PhotoDocument) throws {
        try AtomicFileWriter.write(
            try SidecarCoding.encode(document),
            to: recordURL(for: document.id),
            fileManager: fileManager
        )
    }

    private func sidecarRepository(documentID: UUID) throws -> FileSidecarRepository {
        let libraryRoot = rootURL
            .appendingPathComponent(Self.sidecarsDirectoryName, isDirectory: true)
            .appendingPathComponent(documentID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        return FileSidecarRepository(libraryRootURL: libraryRoot, fileManager: fileManager)
    }
}
