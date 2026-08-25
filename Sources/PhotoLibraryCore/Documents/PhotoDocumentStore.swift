import Darwin
import Foundation
import RawProcessingCore

/// Opens and persists single-photo documents outside a full library — the
/// iPad workflow where a user works on one RAW from Files or an external
/// drive without importing a whole folder.
///
/// App-copy imports follow copy → full-content verification → source
/// unchanged? → record commit (spec §8.1 / plan Task 4): the copy lands
/// under a private per-document directory first; only after its bytes are
/// proven identical to the source — byte for byte, not just sampled via
/// `FingerprintCalculator` — and the source is shown to still match the
/// snapshot taken before the copy began, is it moved to its final name and a
/// document record written. `workingFingerprint` is always computed from the
/// copy itself, and `sourceFingerprint` is set equal to it rather than being
/// re-read from the source a second time — see `PhotoDocument.sourceFingerprint`
/// for why that's the correct semantics, not a shortcut. A Swift error or
/// cancellation thrown anywhere in that sequence removes the partial copy
/// and its directory before rethrowing.
///
/// A hard process kill can still leave an orphaned, uncommitted copy on disk
/// between the rename and the record write. `loadDocument` never treats such
/// a copy as a document (there is no record for it), and
/// `reconcileOrphanedImports()` reclaims it. Both `importCopy` and
/// `reconcileOrphanedImports` hold the same root-level `flock` (see
/// `RootImportLock`) for their entire duration, which is what makes it safe
/// for a *different* `PhotoDocumentStore` instance — in this process or
/// another — to call either one against the same `rootURL` without racing:
/// the kernel, not any in-memory or time-based bookkeeping, is the
/// arbiter of "is an import still running here."
///
/// Sidecar reads/writes are delegated to `FileSidecarRepository` — the same
/// atomic-write, schema-gated, quarantine-on-corruption codec the full
/// library uses — so this store does not duplicate that format.
public actor PhotoDocumentStore {
    private static let documentsDirectoryName = "Documents"
    private static let recordsDirectoryName = "Records"
    private static let sidecarsDirectoryName = "Sidecars"
    private static let importingFilename = ".importing"
    /// Name of the root-level lock file. Not `private` so tests can acquire
    /// or contend for the same lock directly — the mutual-exclusion contract
    /// is defined entirely by this on-disk lock, not by any in-memory actor
    /// state, which is what lets a second store instance (or process)
    /// reason about it correctly. Lives directly under `rootURL`, alongside
    /// but outside `Documents/`, so it is never itself mistaken for an
    /// imported document by `reconcileOrphanedImports`.
    static let importLockFilename = ".photo-document-import.lock"
    /// Bound on how much of each file is held in memory at once while
    /// verifying a copy — the files being compared can be tens of megabytes.
    private static let verificationChunkByteCount = 1 << 20 // 1 MiB

    private let rootURL: URL
    private let fileManager: FileManager
    private let copyFile: @Sendable (URL, URL) throws -> Void
    private let checkCancellation: @Sendable () throws -> Void
    private let writeRecordData: @Sendable (Data, URL, FileManager) throws -> Void

    public init(
        rootURL: URL,
        fileManager: FileManager = .default,
        copyFile: (@Sendable (URL, URL) throws -> Void)? = nil,
        checkCancellation: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() },
        writeRecordData: (@Sendable (Data, URL, FileManager) throws -> Void)? = nil
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.copyFile = copyFile ?? { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
        self.checkCancellation = checkCancellation
        self.writeRecordData = writeRecordData ?? { data, url, fileManager in
            try AtomicFileWriter.write(data, to: url, fileManager: fileManager)
        }
    }

    /// Opens `sourceURL` in place. The RAW is only ever read: adjustments are
    /// saved to a sidecar next to the document record, never back to the
    /// source file. Never creates anything under `Documents/`, so it neither
    /// needs nor takes the root import lock.
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
    /// fails, the source changes mid-import, or the process is killed or the
    /// calling task cancelled. Cancellation is checked before the copy
    /// begins, right after it returns, on every chunk of the full-content
    /// comparison, right after that comparison passes, before the copy is
    /// moved to its final name, and before the record is committed — a
    /// cancellation caught at any of those points is cleaned up exactly like
    /// any other thrown error.
    ///
    /// Throws `PhotoDocumentError.importInProgress`, making no changes at
    /// all, if another import or a reconciliation pass already holds the
    /// root import lock.
    public func importCopy(of sourceURL: URL, bookmarkData: Data?) throws -> PhotoDocument {
        let lock = try RootImportLock.acquire(at: importLockURL, fileManager: fileManager)
        defer { lock.release() }

        let id = UUID()
        let directory = documentsDirectoryURL.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let destination = directory.appendingPathComponent(sourceURL.lastPathComponent)
            let temporary = directory.appendingPathComponent(Self.importingFilename)

            let preCopySnapshot = try sourceSnapshot(at: sourceURL)
            try checkCancellation()
            try copyFile(sourceURL, temporary)
            try checkCancellation()

            guard try contentsAreIdentical(sourceURL, temporary) else {
                throw PhotoDocumentError.copyVerificationFailed
            }
            try checkCancellation()

            // The source must still be the same file it was when the copy
            // started, or the copy just verified above may no longer
            // describe it. Checked once more, right after every byte has
            // been read from the source, rather than continuously — see
            // `SourceSnapshot`.
            let finalSnapshot = try sourceSnapshot(at: sourceURL)
            guard preCopySnapshot == finalSnapshot else {
                throw PhotoDocumentError.sourceModifiedDuringImport
            }

            // Computed once, from the copy itself — never re-read from the
            // source. `sourceFingerprint` is set equal to it deliberately:
            // the copy has just been proven byte-identical to the source as
            // of `finalSnapshot`, so a second, independent read of the
            // source here would only reopen the exact TOCTOU window
            // `finalSnapshot` exists to close, for a value guaranteed to
            // match anyway. See `PhotoDocument.sourceFingerprint`.
            let workingFingerprint = try FingerprintCalculator.fingerprint(forFileAt: temporary)
            let sourceFingerprint = workingFingerprint

            try checkCancellation()
            try fileManager.moveItem(at: temporary, to: destination)

            let document = PhotoDocument(
                id: id,
                storageMode: .appCopy,
                workingURL: destination,
                sourceURL: sourceURL,
                sourceBookmarkData: bookmarkData,
                sourceFingerprint: sourceFingerprint,
                workingFingerprint: workingFingerprint
            )
            try checkCancellation()
            try writeRecord(document)
            return document
        } catch {
            // Best-effort: if this can't fully clean up (e.g. a permissions
            // problem), the directory is left behind. It is still safe from
            // `reconcileOrphanedImports()` mistaking it for something else,
            // since that call cannot even start until this method's `defer`
            // above has released the lock.
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
        if record.storageMode == .appCopy, record.workingPathComponents == nil {
            return try migrateLegacyAppCopyRecordIfPossible(record)
        }
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
    /// written. A directory with a committed record is never touched.
    ///
    /// Holds the same root import lock `importCopy` requires before it can
    /// even create a `Documents/<id>` directory, for the entire scan, so an
    /// import genuinely in progress — on this store instance, another
    /// instance, or another process — cannot have anything removed out from
    /// under it: this call cannot even start until that import releases the
    /// lock, and no new import can start while this call holds it. There is
    /// no timeout anywhere in this decision; a large RAW over a slow
    /// connection taking far longer than any fixed threshold is not treated
    /// as abandoned, because nothing here is measuring elapsed time at all.
    ///
    /// Throws `PhotoDocumentError.importInProgress`, deleting nothing, if
    /// the lock is already held elsewhere.
    ///
    /// Directories that fail to be removed are reported in
    /// `PhotoDocumentReconciliationReport.failures` rather than being
    /// swallowed; they remain in place for a later call to retry.
    @discardableResult
    public func reconcileOrphanedImports() throws -> PhotoDocumentReconciliationReport {
        let lock = try RootImportLock.acquire(at: importLockURL, fileManager: fileManager)
        defer { lock.release() }

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
            // Re-checked immediately before removal. While this method holds
            // the lock, no importer can create this check's answer out from
            // under it — `importCopy` cannot commit a record for `id`
            // without first acquiring the very lock this call is holding —
            // but the check stays right next to the removal regardless, so
            // the two can never drift apart even if either one changes.
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

    private var importLockURL: URL {
        rootURL.appendingPathComponent(Self.importLockFilename)
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
        try writeRecordData(try SidecarCoding.encode(record), recordURL(for: document.id), fileManager)
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
            // Either an `.inPlace` document, or an app-copy record that could
            // not be migrated (see `migrateLegacyAppCopyRecordIfPossible`) —
            // both resolve from the absolute path they were written with.
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

    /// Upgrades an app-copy record written before `workingPathComponents`
    /// existed. The legacy `workingURL` is an absolute path that may no
    /// longer exist if the App container has since moved — but its
    /// filename, combined with the record's own id, is enough to rebuild the
    /// path an app-copy of this document would live at under the *current*
    /// `rootURL`. If a file actually exists there, this atomically rewrites
    /// the record with the new relative form (never touching the RAW or the
    /// app copy itself) so future loads skip this step. If nothing exists
    /// there, the record is left as-is and this falls back to the legacy
    /// absolute path, exactly as before migration support existed.
    private func migrateLegacyAppCopyRecordIfPossible(_ record: PhotoDocumentRecord) throws -> PhotoDocument {
        let candidateComponents = [
            Self.documentsDirectoryName,
            record.id.uuidString,
            record.workingURL.lastPathComponent
        ]
        let candidateURL = candidateComponents.reduce(rootURL) { $0.appendingPathComponent($1) }
        guard fileManager.fileExists(atPath: candidateURL.path) else {
            return resolvedDocument(from: record)
        }
        var migratedRecord = record
        migratedRecord.workingPathComponents = candidateComponents
        try writeRecordData(try SidecarCoding.encode(migratedRecord), recordURL(for: record.id), fileManager)
        return resolvedDocument(from: migratedRecord)
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
            try checkCancellation()
            let firstChunk = try firstHandle.read(upToCount: Self.verificationChunkByteCount) ?? Data()
            let secondChunk = try secondHandle.read(upToCount: Self.verificationChunkByteCount) ?? Data()
            guard firstChunk == secondChunk else { return false }
            if firstChunk.isEmpty { return true }
        }
    }

    /// A cheap, best-effort description of a source file's identity, used to
    /// detect a write landing on it during an import. Deliberately not a
    /// full re-read: that's what `contentsAreIdentical` already does, at the
    /// cost this exists to avoid paying twice.
    private struct SourceSnapshot: Equatable {
        let fileSize: Int64
        let modificationDate: Date?
        let resourceIdentifierDescription: String?
    }

    private func sourceSnapshot(at url: URL) throws -> SourceSnapshot {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modificationDate = attributes[.modificationDate] as? Date
        let resourceIdentifierDescription = (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))
            .flatMap(\.fileResourceIdentifier)
            .map { String(describing: $0) }
        return SourceSnapshot(
            fileSize: fileSize,
            modificationDate: modificationDate,
            resourceIdentifierDescription: resourceIdentifierDescription
        )
    }
}

/// A root-level exclusive advisory lock (`flock`) that makes `importCopy`
/// and `reconcileOrphanedImports` mutually exclusive across *every*
/// `PhotoDocumentStore` instance pointed at the same `rootURL` — including
/// instances in other processes. This is what an actor alone cannot provide:
/// actor isolation only protects one instance in one process, but the same
/// store `rootURL` can legitimately be opened by more than one instance (an
/// app relaunch, a second window, a background extension).
///
/// `flock` is a kernel-held lock tied to the open file description: it is
/// released automatically if the holding process crashes or is killed,
/// which is what lets `reconcileOrphanedImports` safely reclaim storage left
/// behind by a killed import without any timeout — a lock that's still held
/// means the holder (or its process) is still alive, or the kernel would
/// already have released it.
///
/// Acquisition is non-blocking (`LOCK_NB`). If another holder already has
/// the lock, this throws `PhotoDocumentError.importInProgress` immediately
/// rather than blocking the calling thread — blocking here would risk
/// starving Swift's cooperative executor, since actor methods run on threads
/// drawn from that same limited pool.
private struct RootImportLock {
    private let fileDescriptor: Int32

    static func acquire(at url: URL, fileManager: FileManager) throws -> RootImportLock {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let fileDescriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let capturedErrno = errno
            close(fileDescriptor)
            if capturedErrno == EWOULDBLOCK {
                throw PhotoDocumentError.importInProgress
            }
            throw POSIXError(POSIXErrorCode(rawValue: capturedErrno) ?? .EIO)
        }

        return RootImportLock(fileDescriptor: fileDescriptor)
    }

    func release() {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}

/// On-disk shape of a document record. Kept separate from the public
/// `PhotoDocument` so the working location can be stored in a form that
/// survives the store's `rootURL` moving, while callers of `PhotoDocument`
/// itself always see a resolved, directly usable `workingURL`.
///
/// `workingPathComponents` is new; its absence (as in every record written
/// before this type existed) is not an error — `workingURL` is always
/// populated and used as the fallback, and an absent app-copy
/// `workingPathComponents` is opportunistically migrated by `loadDocument`.
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
