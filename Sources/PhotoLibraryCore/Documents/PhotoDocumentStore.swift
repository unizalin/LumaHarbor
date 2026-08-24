import Foundation
import RawProcessingCore

/// Opens and persists single-photo documents outside a full library — the
/// iPad workflow where a user works on one RAW from Files or an external
/// drive without importing a whole folder.
///
/// App-copy imports follow copy → full-content verification → record commit
/// (spec §8.1 / plan Task 4): the copy lands under a private per-document
/// directory first, and only after its bytes are proven identical to the
/// source — byte for byte, not just sampled via `FingerprintCalculator` — is
/// it moved to its final name and a document record written. A Swift error
/// thrown anywhere in that sequence removes the partial copy and its
/// directory before rethrowing. A hard process kill can still leave an
/// orphaned, uncommitted copy on disk between the rename and the record
/// write; `loadDocument` never treats such a copy as a document (there is no
/// record for it), and `reconcileOrphanedImports()` reclaims its storage the
/// next time it is safe to do so.
///
/// Sidecar reads/writes are delegated to `FileSidecarRepository` — the same
/// atomic-write, schema-gated, quarantine-on-corruption codec the full
/// library uses — so this store does not duplicate that format.
public actor PhotoDocumentStore {
    private static let documentsDirectoryName = "Documents"
    private static let recordsDirectoryName = "Records"
    private static let sidecarsDirectoryName = "Sidecars"
    private static let importingFilename = ".importing"
    /// Bound on how much of each file is held in memory at once while
    /// verifying a copy — the files being compared can be tens of megabytes.
    private static let verificationChunkByteCount = 1 << 20 // 1 MiB

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

    /// Copies `sourceURL` into App storage. See the type documentation for
    /// the copy → verify → commit sequence and what happens if any step
    /// fails or the process is killed mid-import.
    public func importCopy(of sourceURL: URL, bookmarkData: Data?) throws -> PhotoDocument {
        let id = UUID()
        let directory = documentsDirectoryURL.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(sourceURL.lastPathComponent)
            let temporary = directory.appendingPathComponent(Self.importingFilename)
            try copyFile(sourceURL, temporary)

            guard try contentsAreIdentical(sourceURL, temporary) else {
                throw PhotoDocumentError.copyVerificationFailed
            }

            // The copy is proven byte-identical to the source, so the two
            // fingerprints are necessarily equal — one calculation suffices.
            let fingerprint = try FingerprintCalculator.fingerprint(forFileAt: sourceURL)
            try fileManager.moveItem(at: temporary, to: destination)

            let document = PhotoDocument(
                id: id,
                storageMode: .appCopy,
                workingURL: destination,
                sourceURL: sourceURL,
                sourceBookmarkData: bookmarkData,
                sourceFingerprint: fingerprint,
                workingFingerprint: fingerprint
            )
            try writeRecord(document)
            return document
        } catch {
            // Best-effort: if this can't fully clean up (e.g. a permissions
            // problem), the directory is left behind rather than silently
            // discarded, and `reconcileOrphanedImports()` will find and
            // retry it on a later pass.
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    public func loadDocument(id: UUID) throws -> PhotoDocument {
        let url = recordURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw PhotoDocumentError.documentNotFound(id)
        }
        let record = try SidecarCoding.decode(PhotoDocumentRecord.self, from: Data(contentsOf: url))
        return resolvedDocument(from: record)
    }

    /// The currently saved adjustments for a document, or `.neutral` when no
    /// sidecar has been written yet. Schema-too-new or corrupt sidecars throw
    /// rather than being silently overwritten — `FileSidecarRepository`
    /// enforces that.
    public func loadAdjustments(documentID: UUID) throws -> PhotoAdjustments {
        _ = try loadDocument(id: documentID)
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

    /// Removes app-copy import directories under `Documents/` that have no
    /// matching committed record — the trace a process kill can leave
    /// between a copy landing at its final name and the record being
    /// written. A directory with a committed record is never touched, even
    /// if this is called while unrelated imports are idle. Call this at a
    /// point with no import concurrently in flight, e.g. app launch.
    ///
    /// Directories that fail to be removed are reported in
    /// `PhotoDocumentReconciliationReport.failures` rather than being
    /// swallowed; they remain in place for a later call to retry.
    @discardableResult
    public func reconcileOrphanedImports() throws -> PhotoDocumentReconciliationReport {
        var removed: [UUID] = []
        var failures: [UUID: String] = [:]

        guard fileManager.fileExists(atPath: documentsDirectoryURL.path) else {
            // Nothing has ever been imported into this store, so there is
            // nothing to reconcile.
            return PhotoDocumentReconciliationReport(removedOrphanIDs: [], failures: [:])
        }
        let entries = try fileManager.contentsOfDirectory(
            at: documentsDirectoryURL,
            includingPropertiesForKeys: nil
        )

        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent) else { continue }
            guard !fileManager.fileExists(atPath: recordURL(for: id).path) else { continue }
            do {
                try fileManager.removeItem(at: entry)
                removed.append(id)
            } catch {
                failures[id] = (error as NSError).localizedDescription
            }
        }

        return PhotoDocumentReconciliationReport(removedOrphanIDs: removed, failures: failures)
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
        let record = PhotoDocumentRecord(
            id: document.id,
            storageMode: document.storageMode,
            workingPathComponents: relativeWorkingPathComponents(for: document),
            workingURL: document.workingURL,
            sourceURL: document.sourceURL,
            sourceBookmarkData: document.sourceBookmarkData,
            sourceFingerprint: document.sourceFingerprint,
            workingFingerprint: document.workingFingerprint
        )
        try AtomicFileWriter.write(
            try SidecarCoding.encode(record),
            to: recordURL(for: document.id),
            fileManager: fileManager
        )
    }

    /// An app-copy's working file lives entirely inside `rootURL`, so its
    /// location is stored as path components relative to it — appended with
    /// `appendingPathComponent` on both write and read, so spaces and
    /// Unicode in the original filename never round-trip through manual
    /// percent-encoding. Resolving against the store's *current* `rootURL`
    /// at read time, rather than trusting the absolute path recorded at
    /// write time, is what lets a document survive its enclosing App
    /// container moving. `.inPlace` documents have nothing to relocate — the
    /// working file *is* the external source — so they keep only the
    /// absolute `workingURL`.
    private func relativeWorkingPathComponents(for document: PhotoDocument) -> [String]? {
        guard document.storageMode == .appCopy else { return nil }
        return [Self.documentsDirectoryName, document.id.uuidString, document.workingURL.lastPathComponent]
    }

    private func resolvedDocument(from record: PhotoDocumentRecord) -> PhotoDocument {
        let workingURL: URL
        if let components = record.workingPathComponents, !components.isEmpty {
            workingURL = components.reduce(rootURL) { $0.appendingPathComponent($1) }
        } else {
            // Either an `.inPlace` document, or a record written before
            // `workingPathComponents` existed — both resolve from the
            // absolute path they were written with.
            workingURL = record.workingURL
        }
        return PhotoDocument(
            id: record.id,
            storageMode: record.storageMode,
            workingURL: workingURL,
            sourceURL: record.sourceURL,
            sourceBookmarkData: record.sourceBookmarkData,
            sourceFingerprint: record.sourceFingerprint,
            workingFingerprint: record.workingFingerprint
        )
    }

    private func sidecarRepository(documentID: UUID) throws -> FileSidecarRepository {
        let libraryRoot = rootURL
            .appendingPathComponent(Self.sidecarsDirectoryName, isDirectory: true)
            .appendingPathComponent(documentID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        return FileSidecarRepository(libraryRootURL: libraryRoot, fileManager: fileManager)
    }

    /// Streams both files start to finish and compares their bytes exactly,
    /// never holding more than one chunk of each in memory at a time.
    ///
    /// This is deliberately independent of `FingerprintCalculator`: that
    /// type only samples the first and last `edgeChunkByteCount` of a file
    /// above `wholeFileThreshold` to give photos a cheap, stable identity —
    /// it is not, and must not be used as, a copy checksum, since damage
    /// anywhere in the untouched middle of a large RAW is invisible to it.
    private func contentsAreIdentical(_ first: URL, _ second: URL) throws -> Bool {
        let firstHandle = try FileHandle(forReadingFrom: first)
        defer { try? firstHandle.close() }
        let secondHandle = try FileHandle(forReadingFrom: second)
        defer { try? secondHandle.close() }

        while true {
            let firstChunk = try firstHandle.read(upToCount: Self.verificationChunkByteCount) ?? Data()
            let secondChunk = try secondHandle.read(upToCount: Self.verificationChunkByteCount) ?? Data()
            guard firstChunk == secondChunk else { return false }
            if firstChunk.isEmpty { return true }
        }
    }
}

/// On-disk shape of a document record. Kept separate from the public
/// `PhotoDocument` so the working location can be stored in a form that
/// survives the store's `rootURL` moving, while callers of `PhotoDocument`
/// itself always see a resolved, directly usable `workingURL`.
///
/// `workingPathComponents` is new; its absence (as in every record written
/// before this type existed) is not an error; `workingURL` is always
/// populated and used as the fallback.
private struct PhotoDocumentRecord: Codable {
    var id: UUID
    var storageMode: PhotoDocumentStorageMode
    var workingPathComponents: [String]?
    var workingURL: URL
    var sourceURL: URL
    var sourceBookmarkData: Data?
    var sourceFingerprint: FileFingerprint
    var workingFingerprint: FileFingerprint
}

/// Result of a `reconcileOrphanedImports()` pass.
public struct PhotoDocumentReconciliationReport: Equatable, Sendable {
    /// Orphaned import directories that were found and removed.
    public let removedOrphanIDs: [UUID]
    /// Orphan directories that were found but could not be removed, keyed by
    /// id, with the underlying failure description. Left in place for a
    /// later call to retry.
    public let failures: [UUID: String]

    public init(removedOrphanIDs: [UUID], failures: [UUID: String]) {
        self.removedOrphanIDs = removedOrphanIDs
        self.failures = failures
    }
}
