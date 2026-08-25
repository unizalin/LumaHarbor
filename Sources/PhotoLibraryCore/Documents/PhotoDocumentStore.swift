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
    /// In-memory lifecycle of every receipt `openInPlace`/`importCopy` has
    /// minted in *this* actor instance's lifetime. Backs
    /// `rollbackNewDocument(_:)`'s single-use, unforgeable-receipt
    /// contract — see `PhotoDocumentCreation`. This is a fast, in-process
    /// cache only: the durable source of truth for "was this creation ever
    /// finished?" across a process crash is the `.pending`/`.committed`
    /// state written into the record itself (see `PhotoDocumentRecord
    /// .lifecycleState`) and reconciled by `reconcileOrphanedImports
    /// (activeDocumentID:)` on the next launch.
    private enum CreationState {
        case pending
        case finalized
        case rolledBack
    }
    private var creationStates: [UUID: CreationState] = [:]

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
    ///
    /// Returns a `PhotoDocumentCreation`, not a bare `PhotoDocument` — see
    /// that type's documentation for why.
    public func openInPlace(_ sourceURL: URL, bookmarkData: Data?) throws -> PhotoDocumentCreation {
        let fingerprint = try FingerprintCalculator.fingerprint(forFileAt: sourceURL)
        let document = PhotoDocument(
            storageMode: .inPlace,
            workingURL: sourceURL,
            sourceURL: sourceURL,
            sourceBookmarkData: bookmarkData,
            sourceFingerprint: fingerprint,
            workingFingerprint: fingerprint
        )
        try writeRecord(document, lifecycleState: .pending)
        return mintCreation(for: document)
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
    ///
    /// Returns a `PhotoDocumentCreation`, not a bare `PhotoDocument` — see
    /// that type's documentation for why.
    public func importCopy(of sourceURL: URL, bookmarkData: Data?) throws -> PhotoDocumentCreation {
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
            try writeRecord(document, lifecycleState: .pending)
            return mintCreation(for: document)
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
        let record = try loadRecord(id: id)
        if record.storageMode == .appCopy, record.workingPathComponents == nil {
            return try migrateLegacyAppCopyRecordIfPossible(record)
        }
        return resolvedDocument(from: record)
    }

    /// Atomically rewrites a document's `sourceBookmarkData` — used to
    /// persist a refreshed bookmark after restoring an `.inPlace` document
    /// finds the saved one stale (macOS/iOS ask for the bookmark to be
    /// regenerated, but the old one still resolves for that one restore),
    /// when the bookmark still resolves to the *same* `workingURL`. Every
    /// other field of the record, including the working location, is left
    /// untouched. When a stale bookmark resolves to a *different* URL, use
    /// `updateInPlaceLocation(newURL:bookmarkData:documentID:)` instead — a
    /// bookmark refresh must never be persisted alongside a working URL
    /// that no longer matches where it actually resolves.
    public func updateSourceBookmark(_ bookmarkData: Data, documentID: UUID) throws {
        var record = try loadRecord(id: documentID)
        record.sourceBookmarkData = bookmarkData
        try writeRecordData(try SidecarCoding.encode(record), recordURL(for: documentID), fileManager)
    }

    /// Atomically moves an `.inPlace` document's persisted location to
    /// `newURL`, together with the bookmark that resolved to it — used when
    /// restoring finds the saved bookmark now resolves somewhere other than
    /// the last persisted `workingURL` (e.g. an external volume remounted
    /// under a new path). `workingURL` and `sourceURL` always move together
    /// for an `.inPlace` document, since they are the same file; this never
    /// leaves a fresh bookmark recorded alongside a stale working URL, or
    /// vice versa. Fingerprints are untouched — the file's *content*
    /// identity has not changed, only where it currently resolves.
    public func updateInPlaceLocation(newURL: URL, bookmarkData: Data, documentID: UUID) throws {
        var record = try loadRecord(id: documentID)
        record.workingURL = newURL
        record.sourceURL = newURL
        record.sourceBookmarkData = bookmarkData
        try writeRecordData(try SidecarCoding.encode(record), recordURL(for: documentID), fileManager)
    }

    /// Re-links an existing `.inPlace` document to `candidateURL` — used
    /// when its bookmark can no longer be resolved (missing, or itself
    /// unreadable) and the user has picked what they believe is the same
    /// file again from Files.
    ///
    /// Verifies `candidateURL`'s content fingerprint matches the document's
    /// original `sourceFingerprint` *before* touching anything — an
    /// unrelated RAW can never be attached to another document's saved
    /// sidecar/adjustments by mistake. On a mismatch, throws
    /// `RelinkError.fingerprintMismatch` and leaves the existing record,
    /// sidecar, and everything else about the document completely
    /// untouched, so a caller can safely let the user try picking again.
    public func relinkInPlaceDocument(documentID: UUID, candidateURL: URL, bookmarkData: Data) throws -> PhotoDocument {
        let record = try loadRecord(id: documentID)
        guard record.storageMode == .inPlace else {
            throw RelinkError.notInPlace
        }
        let candidateFingerprint = try FingerprintCalculator.fingerprint(forFileAt: candidateURL)
        guard candidateFingerprint == record.sourceFingerprint else {
            throw RelinkError.fingerprintMismatch
        }
        try updateInPlaceLocation(newURL: candidateURL, bookmarkData: bookmarkData, documentID: documentID)
        return try loadDocument(id: documentID)
    }

    /// Marks `creation` as kept: the document it produced has been shown to
    /// the user and must never be rolled back after this, even by a caller
    /// that (in error) still holds and reuses the same `PhotoDocumentCreation`
    /// value. Idempotent — finalizing an already-finalized or already-rolled-
    /// back creation does nothing.
    ///
    /// Also persists `.committed` into the record on disk. This is what
    /// makes the commit crash-durable rather than only living in this
    /// actor's memory: if the process is killed after this call started but
    /// before the write lands, the in-memory state above is lost along with
    /// everything else, but the *next* launch's `reconcileOrphanedImports
    /// (activeDocumentID:)` will find the record still `.pending`, see it
    /// matches the remembered active document (this call runs only after
    /// that pointer has already been moved to it — see `PhotoDocumentEditor
    /// .openFreshSelection`), and promote it to `.committed` itself. A
    /// failure to write here is therefore not fatal to this session — the
    /// document is already fully open and usable — only to how quickly the
    /// on-disk state catches up.
    public func finalizeCreation(_ creation: PhotoDocumentCreation) {
        guard creationStates[creation.receipt] == .pending else { return }
        creationStates[creation.receipt] = .finalized
        guard var record = try? loadRecord(id: creation.document.id) else { return }
        record.lifecycleState = .committed
        guard let encoded = try? SidecarCoding.encode(record) else { return }
        try? writeRecordData(encoded, recordURL(for: creation.document.id), fileManager)
    }

    /// Removes a document this store itself created but that never
    /// finished being shown to the user — e.g. `importCopy`/`openInPlace`
    /// committed successfully, but reading the working file's metadata
    /// right afterward failed.
    ///
    /// Takes the `PhotoDocumentCreation` `openInPlace`/`importCopy` handed
    /// back, not a bare `PhotoDocument` — a caller cannot construct or
    /// otherwise obtain a `PhotoDocumentCreation` for a document it did not
    /// just create (there is no public initializer, and `loadDocument`
    /// returns a plain `PhotoDocument`), so this can never be pointed at
    /// existing user data by accident or misuse. It is also single-use: the
    /// receipt is consumed on the first call, whether that call is this one
    /// or `finalizeCreation(_:)`, so a stale or reused value can never
    /// trigger a second, unintended deletion.
    ///
    /// Removes only what this store wrote for the creation: its record and
    /// sidecar always, and its App-storage copy in `.appCopy` mode only.
    /// Never touches `sourceURL` — an `.inPlace` document's `workingURL`
    /// *is* the external RAW, so rolling one back only removes the record
    /// and sidecar this store created, never the file itself.
    ///
    /// Restoring an *existing* document that then fails to open must never
    /// call this; there is nothing here to roll back, and doing so would
    /// delete real user data — which is exactly what the receipt contract
    /// above prevents even if a caller tried.
    ///
    /// For `.appCopy`, every step — copy, record, sidecar — waits until the
    /// root import lock is actually held before touching anything: a failed
    /// lock acquisition deletes nothing and does not consume the receipt,
    /// so there is never a half state where the record is gone but the copy
    /// (or vice versa) is still on disk. The receipt itself is consumed
    /// only once every applicable step has actually succeeded; if any step
    /// fails, the receipt stays valid and the outcome is `.retryRequired`,
    /// so a caller (or a later `reconcileOrphanedImports(activeDocumentID:)`
    /// pass, via the record's still-`.pending` on-disk state) can safely
    /// retry without risking a double-delete or a lost cleanup.
    @discardableResult
    public func rollbackNewDocument(_ creation: PhotoDocumentCreation) -> PhotoDocumentRollbackReport {
        switch creationStates[creation.receipt] {
        case .none:
            // Should be impossible given the receipt contract (no public
            // initializer, single-use), but never touch disk for a receipt
            // this instance doesn't recognize at all.
            return PhotoDocumentRollbackReport(
                outcome: .unknownReceipt, lock: .notApplicable, record: .notApplicable, sidecar: .notApplicable, copy: .notApplicable
            )
        case .finalized:
            return PhotoDocumentRollbackReport(
                outcome: .alreadyFinalized, lock: .notApplicable, record: .notApplicable, sidecar: .notApplicable, copy: .notApplicable
            )
        case .rolledBack:
            return PhotoDocumentRollbackReport(
                outcome: .alreadyRolledBack, lock: .notApplicable, record: .notApplicable, sidecar: .notApplicable, copy: .notApplicable
            )
        case .some(.pending):
            break
        }

        let document = creation.document
        let recordURL = recordURL(for: document.id)
        let sidecarURL = sidecarsDirectoryURL(documentID: document.id)

        guard document.storageMode == .appCopy else {
            // `.inPlace` never touches `Documents/` or the root lock: only
            // the record and sidecar this store itself wrote are at stake.
            try? fileManager.removeItem(at: recordURL)
            let recordResult: PhotoDocumentRollbackReport.StepResult =
                fileManager.fileExists(atPath: recordURL.path) ? .failed : .succeeded
            try? fileManager.removeItem(at: sidecarURL)
            let sidecarResult: PhotoDocumentRollbackReport.StepResult =
                fileManager.fileExists(atPath: sidecarURL.path) ? .failed : .succeeded

            let cleaned = recordResult == .succeeded && sidecarResult == .succeeded
            if cleaned { creationStates[creation.receipt] = .rolledBack }
            return PhotoDocumentRollbackReport(
                outcome: cleaned ? .cleaned : .retryRequired,
                lock: .notApplicable, record: recordResult, sidecar: sidecarResult, copy: .notApplicable
            )
        }

        guard let lock = try? RootImportLock.acquire(at: importLockURL, fileManager: fileManager) else {
            // Nothing attempted, nothing deleted, receipt still valid.
            return PhotoDocumentRollbackReport(
                outcome: .retryRequired, lock: .failed, record: .notApplicable, sidecar: .notApplicable, copy: .notApplicable
            )
        }
        defer { lock.release() }

        let copyDirectory = documentsDirectoryURL.appendingPathComponent(document.id.uuidString, isDirectory: true)
        try? fileManager.removeItem(at: copyDirectory)
        let copyResult: PhotoDocumentRollbackReport.StepResult =
            fileManager.fileExists(atPath: copyDirectory.path) ? .failed : .succeeded

        try? fileManager.removeItem(at: recordURL)
        let recordResult: PhotoDocumentRollbackReport.StepResult =
            fileManager.fileExists(atPath: recordURL.path) ? .failed : .succeeded

        try? fileManager.removeItem(at: sidecarURL)
        let sidecarResult: PhotoDocumentRollbackReport.StepResult =
            fileManager.fileExists(atPath: sidecarURL.path) ? .failed : .succeeded

        let cleaned = copyResult == .succeeded && recordResult == .succeeded && sidecarResult == .succeeded
        if cleaned { creationStates[creation.receipt] = .rolledBack }
        return PhotoDocumentRollbackReport(
            outcome: cleaned ? .cleaned : .retryRequired,
            lock: .succeeded, record: recordResult, sidecar: sidecarResult, copy: copyResult
        )
    }

    private func mintCreation(for document: PhotoDocument) -> PhotoDocumentCreation {
        let receipt = UUID()
        creationStates[receipt] = .pending
        return PhotoDocumentCreation(document: document, receipt: receipt)
    }

    private func loadRecord(id: UUID) throws -> PhotoDocumentRecord {
        let url = recordURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw PhotoDocumentError.documentNotFound(id)
        }
        return try SidecarCoding.decode(PhotoDocumentRecord.self, from: Data(contentsOf: url))
    }

    private func sidecarsDirectoryURL(documentID: UUID) -> URL {
        rootURL
            .appendingPathComponent(Self.sidecarsDirectoryName, isDirectory: true)
            .appendingPathComponent(documentID.uuidString, isDirectory: true)
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

    /// Reclaims two different traces a process kill can leave behind, both
    /// under the same root import lock `importCopy` requires before it can
    /// even create a `Documents/<id>` directory — so an import genuinely in
    /// progress, on this store instance, another instance, or another
    /// process, cannot have anything removed out from under it, and no new
    /// import can start while this call holds the lock. There is no timeout
    /// anywhere in either pass; a large RAW over a slow connection taking
    /// far longer than any fixed threshold is not treated as abandoned,
    /// because nothing here measures elapsed time.
    ///
    /// **Pass 1** removes `Documents/` directories with no record at all —
    /// a kill between an app-copy landing at its final name and the record
    /// ever being written.
    ///
    /// **Pass 2** resolves every record still marked `.pending` — a kill
    /// between the record being written and `finalizeCreation(_:)`
    /// completing. `activeDocumentID` (the caller's remembered
    /// last-open document, e.g. from `UserDefaults`) is what decides each
    /// one's fate: a pending record whose id matches it survived far enough
    /// to be the document the user was actually handed off to, so it is
    /// *promoted* to `.committed` rather than deleted. Every other pending
    /// record never finished being shown to anyone and is rolled back
    /// exactly like a same-session `rollbackNewDocument(_:)` would — record
    /// and sidecar always, and its `Documents/` copy for `.appCopy`; an
    /// `.inPlace` record's rollback never touches the external RAW, since
    /// `workingURL` *is* that RAW. A record already `.committed` (including
    /// every legacy record written before this field existed) is never
    /// touched by this pass.
    ///
    /// Throws `PhotoDocumentError.importInProgress`, changing nothing, if
    /// the lock is already held elsewhere. Individual failures within
    /// either pass are collected in `PhotoDocumentReconciliationReport
    /// .failures` rather than aborting the whole call; whatever could not
    /// be resolved is left in place for a later call to retry.
    @discardableResult
    public func reconcileOrphanedImports(activeDocumentID: UUID?) throws -> PhotoDocumentReconciliationReport {
        let lock = try RootImportLock.acquire(at: importLockURL, fileManager: fileManager)
        defer { lock.release() }

        var removedOrphanIDs: [UUID] = []
        var promotedPendingIDs: [UUID] = []
        var rolledBackPendingIDs: [UUID] = []
        var failures: [UUID: String] = [:]

        if fileManager.fileExists(atPath: documentsDirectoryURL.path) {
            let entries = try fileManager.contentsOfDirectory(at: documentsDirectoryURL, includingPropertiesForKeys: nil)
            for entry in entries {
                guard let id = UUID(uuidString: entry.lastPathComponent) else { continue }
                // Re-checked immediately before removal — see the type
                // documentation for why this can never drift from what
                // holding the lock already guarantees.
                guard !fileManager.fileExists(atPath: recordURL(for: id).path) else { continue }
                do {
                    try fileManager.removeItem(at: entry)
                    removedOrphanIDs.append(id)
                } catch {
                    failures[id] = (error as NSError).localizedDescription
                }
            }
        }

        if fileManager.fileExists(atPath: recordsDirectoryURL.path) {
            let recordFiles = try fileManager.contentsOfDirectory(at: recordsDirectoryURL, includingPropertiesForKeys: nil)
            for recordFile in recordFiles {
                guard recordFile.pathExtension == "json",
                      let id = UUID(uuidString: recordFile.deletingPathExtension().lastPathComponent) else { continue }
                guard let record = try? SidecarCoding.decode(PhotoDocumentRecord.self, from: Data(contentsOf: recordFile)) else {
                    // Corrupt/unreadable: not this pass's job to repair --
                    // `loadDocument` surfaces this loudly if actually opened.
                    continue
                }
                guard record.effectiveLifecycleState == .pending else { continue }

                if let activeDocumentID, record.id == activeDocumentID {
                    var promoted = record
                    promoted.lifecycleState = .committed
                    do {
                        try writeRecordData(try SidecarCoding.encode(promoted), recordFile, fileManager)
                        promotedPendingIDs.append(id)
                    } catch {
                        failures[id] = (error as NSError).localizedDescription
                    }
                    continue
                }

                var stepFailed = false
                try? fileManager.removeItem(at: recordFile)
                if fileManager.fileExists(atPath: recordFile.path) { stepFailed = true }
                let sidecarURL = sidecarsDirectoryURL(documentID: id)
                try? fileManager.removeItem(at: sidecarURL)
                if fileManager.fileExists(atPath: sidecarURL.path) { stepFailed = true }
                if record.storageMode == .appCopy {
                    let copyDirectory = documentsDirectoryURL.appendingPathComponent(id.uuidString, isDirectory: true)
                    try? fileManager.removeItem(at: copyDirectory)
                    if fileManager.fileExists(atPath: copyDirectory.path) { stepFailed = true }
                }
                if stepFailed {
                    failures[id] = "Could not fully roll back an interrupted import."
                } else {
                    rolledBackPendingIDs.append(id)
                }
            }
        }

        return PhotoDocumentReconciliationReport(
            removedOrphanIDs: removedOrphanIDs,
            promotedPendingIDs: promotedPendingIDs,
            rolledBackPendingIDs: rolledBackPendingIDs,
            failures: failures
        )
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

    /// Writes a brand-new record. `lifecycleState` is always explicit here
    /// (never inherited from an existing record, since there isn't one
    /// yet) — every call site creating a document for the first time must
    /// say `.pending`; only `finalizeCreation(_:)` and the reconciliation
    /// promotion path may write `.committed`.
    private func writeRecord(_ document: PhotoDocument, lifecycleState: PhotoDocumentRecord.LifecycleState) throws {
        let record = PhotoDocumentRecord(
            id: document.id,
            storageMode: document.storageMode,
            workingPathComponents: relativeWorkingPathComponents(for: document),
            workingURL: document.workingURL,
            sourceURL: document.sourceURL,
            sourceBookmarkData: document.sourceBookmarkData,
            sourceFingerprint: document.sourceFingerprint,
            workingFingerprint: document.workingFingerprint,
            lifecycleState: lifecycleState
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
        let libraryRoot = sidecarsDirectoryURL(documentID: documentID)
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
    /// Whether a creation has finished being handed off to the user
    /// (`.committed`) or might still be interrupted mid-handoff
    /// (`.pending`). Backs crash-durable creation tracking — see
    /// `reconcileOrphanedImports(activeDocumentID:)`.
    enum LifecycleState: String, Codable {
        case pending
        case committed
    }

    var id: UUID
    var storageMode: PhotoDocumentStorageMode
    var workingPathComponents: [String]?
    var workingURL: URL
    var sourceURL: URL
    var sourceBookmarkData: Data?
    var sourceFingerprint: FileFingerprint
    var workingFingerprint: FileFingerprint
    /// Absent (`nil`) in every record written before crash-durable
    /// creation tracking existed. Treated as `.committed` for backward
    /// compatibility: those records were always written by a single,
    /// synchronous commit step with no separate pending phase a crash
    /// could land in the middle of.
    var lifecycleState: LifecycleState?

    var effectiveLifecycleState: LifecycleState { lifecycleState ?? .committed }
}

/// Result of a `reconcileOrphanedImports()` pass.
public struct PhotoDocumentReconciliationReport: Equatable, Sendable {
    /// `Documents/` directories found with no record at all, and removed.
    public let removedOrphanIDs: [UUID]
    /// Pending records that matched the remembered active document and
    /// were promoted to `.committed` — the app survived far enough to hand
    /// this document off to the user before being killed.
    public let promotedPendingIDs: [UUID]
    /// Pending records that did *not* match the active document (or there
    /// was none) and were rolled back — record, sidecar, and (for
    /// `.appCopy`) its `Documents/` copy.
    public let rolledBackPendingIDs: [UUID]
    /// Entries that could not be fully resolved, keyed by id, with a
    /// diagnostic description. Left in place for a later call to retry.
    public let failures: [UUID: String]

    public init(
        removedOrphanIDs: [UUID],
        promotedPendingIDs: [UUID] = [],
        rolledBackPendingIDs: [UUID] = [],
        failures: [UUID: String]
    ) {
        self.removedOrphanIDs = removedOrphanIDs
        self.promotedPendingIDs = promotedPendingIDs
        self.rolledBackPendingIDs = rolledBackPendingIDs
        self.failures = failures
    }
}
