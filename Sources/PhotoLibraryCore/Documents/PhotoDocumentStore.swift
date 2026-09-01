import CryptoKit
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
    private static let pendingLocksDirectoryName = "PendingLocks"
    private static let activePointerFilename = "ActiveDocument.json"
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
    /// (activePointer:)` on the next launch.
    private enum CreationState {
        case pending
        case finalized
        case rolledBack
    }
    private var creationStates: [UUID: CreationState] = [:]

    /// Per-document crash-released leases (see `PendingLock`) held by
    /// creations *this actor instance* minted, from the moment
    /// `openInPlace`/`importCopy` returns until `finalizeCreation(_:)`
    /// durably commits or `rollbackNewDocument(_:)` fully cleans up.
    /// Deliberately spans multiple actor method calls — unlike
    /// `RootImportLock`, which is acquired and released within a single
    /// call — because the caller (`PhotoDocumentEditor`) does real
    /// off-actor work (metadata decode, adjustments load, flushing the
    /// previously-open document) between minting a creation and finalizing
    /// or rolling it back, and a *different* store instance's
    /// `reconcileOrphanedImports` must not be able to delete the pending
    /// creation out from under that in-flight work. `PendingLock` is a
    /// class specifically so a value here, once dropped (receipt consumed,
    /// or this actor itself deallocated without ever finalizing — the
    /// closest a single test process can get to simulating another
    /// process's crash), closes its file descriptor and lets the kernel
    /// release the underlying `flock` on its own.
    private var pendingLeases: [UUID: PendingLock] = [:]

    /// Test-only: force-releases every per-document lease this instance is
    /// currently holding, without finalizing or rolling back the
    /// underlying creations. Simulates the *lease-release* side effect of
    /// a real process crash directly, rather than requiring a test to
    /// deallocate this whole actor instance and hope its `deinit` (and the
    /// cascading `PendingLock.deinit`s) has actually run before the "next
    /// launch" store instance it constructs afterward — in a `-Onone`
    /// debug build, a local variable's storage can validly stay alive
    /// until the end of its lexical scope for debuggability, not just its
    /// last textual use, so `someStore = nil` earlier in a test function
    /// is not a reliable way to force this. Not `private` for the same
    /// reason `importLockFilename` above isn't — this is a deliberate test
    /// seam, not a defect in the visibility gating everywhere else in this
    /// type.
    func releaseAllPendingLeasesForTesting() {
        for (_, lease) in pendingLeases { lease.release() }
        pendingLeases.removeAll()
    }

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
        let id = UUID()
        // Acquired before anything else, and held (via `pendingLeases`)
        // past this method's return — see that property's documentation.
        let lease = try PendingLock.acquire(at: pendingLockURL(for: id), fileManager: fileManager)
        do {
            // Single identity transaction, same shape as
            // `relinkInPlaceDocument`: `sourceURL` is opened exactly once;
            // both the sampled `FileFingerprint` and the full-content
            // digest come from that one file descriptor, and its identity
            // is `fstat`-ed both before the read starts and again right
            // after it finishes — a change to the file mid-read (even one
            // that never touches the path, e.g. an in-place write to the
            // same inode) throws rather than silently committing a
            // fingerprint/digest pair that describes bytes that no longer
            // exist.
            let (fingerprint, digest) = try fingerprintAndDigest(forFileAt: sourceURL)
            let document = PhotoDocument(
                id: id,
                storageMode: .inPlace,
                workingURL: sourceURL,
                sourceURL: sourceURL,
                sourceBookmarkData: bookmarkData,
                sourceFingerprint: fingerprint,
                workingFingerprint: fingerprint,
                contentDigestSHA256: digest
            )
            try writeRecord(document, lifecycleState: .pending)
            pendingLeases[id] = lease
            return mintCreation(for: document)
        } catch {
            lease.release()
            throw error
        }
    }

    /// Returns an existing committed in-place document for the same
    /// reachable source file, if one is already known to the store. Used by
    /// the multi-source library grid: tapping the same external RAW again
    /// must reopen the document whose sidecar holds the user's edits, not
    /// mint a new neutral document every time.
    ///
    /// Identity is deliberately stricter than just the path: the current
    /// file's sampled fingerprint and full-content digest must still match
    /// the record that would be reused. If the external RAW changed in
    /// place, this returns `nil` and the caller can create a fresh document
    /// rather than applying stale adjustments to different bytes.
    public func committedInPlaceDocument(matching sourceURL: URL) throws -> PhotoDocument? {
        let (fingerprint, digest) = try fingerprintAndDigest(forFileAt: sourceURL)
        let normalizedSourceURL = sourceURL.standardizedFileURL
        let matches = try committedDocuments().documents.filter { document in
            guard document.storageMode == .inPlace else { return false }
            guard document.sourceURL.standardizedFileURL == normalizedSourceURL
                    || document.workingURL.standardizedFileURL == normalizedSourceURL else { return false }
            guard document.sourceFingerprint == fingerprint,
                  document.workingFingerprint == fingerprint else { return false }
            guard let expectedDigest = document.contentDigestSHA256 else { return true }
            return expectedDigest == digest
        }
        guard !matches.isEmpty else { return nil }

        return matches
            .map { document in
                let sidecar = try? sidecarRepository(documentID: document.id).loadSidecar(for: PhotoID(document.id))
                return (
                    document: document,
                    hasSavedAdjustments: !(sidecar?.adjustments.isNeutral ?? true),
                    modifiedAt: sidecar?.modifiedAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.hasSavedAdjustments != rhs.hasSavedAdjustments {
                    return lhs.hasSavedAdjustments && !rhs.hasSavedAdjustments
                }
                switch (lhs.modifiedAt, rhs.modifiedAt) {
                case let (left?, right?) where left != right:
                    return left > right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.document.id.uuidString < rhs.document.id.uuidString
                }
            }
            .first?
            .document
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
        let id = UUID()
        // Acquired *before* the root import lock, and held (via
        // `pendingLeases`) past this method's return — see that
        // property's and `PendingLock`'s documentation for why this
        // ordering (lease, then root lock) is fixed everywhere both are
        // needed, to avoid a deadlock against `reconcileOrphanedImports`.
        let lease = try PendingLock.acquire(at: pendingLockURL(for: id), fileManager: fileManager)

        let lock: RootImportLock
        do {
            lock = try RootImportLock.acquire(at: importLockURL, fileManager: fileManager)
        } catch {
            lease.release()
            throw error
        }
        defer { lock.release() }

        let directory = documentsDirectoryURL.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let destination = directory.appendingPathComponent(sourceURL.lastPathComponent)
            let temporary = directory.appendingPathComponent(Self.importingFilename)

            let preCopySnapshot = try sourceSnapshot(at: sourceURL)
            try checkCancellation()
            try copyFile(sourceURL, temporary)
            try checkCancellation()

            // Computes the copy's full-content digest as a side effect of
            // the same byte-for-byte comparison already required to prove
            // the copy matches the source — see
            // `contentsAreIdenticalComputingDigest`.
            let (identical, digest) = try contentsAreIdenticalComputingDigest(sourceURL, temporary)
            guard identical, let digest else {
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
                workingFingerprint: workingFingerprint,
                contentDigestSHA256: digest
            )
            try checkCancellation()
            try writeRecord(document, lifecycleState: .pending)
            pendingLeases[id] = lease
            return mintCreation(for: document)
        } catch {
            // Best-effort: if this can't fully clean up (e.g. a permissions
            // problem), the directory is left behind. It is still safe from
            // `reconcileOrphanedImports()` mistaking it for something else,
            // since that call cannot even start until this method's `defer`
            // above has released the lock.
            try? fileManager.removeItem(at: directory)
            lease.release()
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
    public func updateInPlaceLocation(
        newURL: URL,
        bookmarkData: Data,
        documentID: UUID,
        contentDigestSHA256: String? = nil
    ) throws {
        var record = try loadRecord(id: documentID)
        record.workingURL = newURL
        record.sourceURL = newURL
        record.sourceBookmarkData = bookmarkData
        if let contentDigestSHA256 {
            record.contentDigestSHA256 = contentDigestSHA256
        }
        try writeRecordData(try SidecarCoding.encode(record), recordURL(for: documentID), fileManager)
    }

    /// Re-links an existing `.inPlace` document to `candidateURL` — used
    /// when its bookmark can no longer be resolved (missing, or itself
    /// unreadable) and the user has picked what they believe is the same
    /// file again from Files. `resolvedBookmarkURL` is where a *fresh*
    /// bookmark minted from `candidateURL` (by the caller, immediately
    /// beforehand) actually resolves back to — passed in rather than
    /// re-resolved here because only the caller has the security-scoped
    /// bookmark machinery to do that.
    ///
    /// This is a single identity transaction, not a sequence of
    /// independent checks a swap could slip between:
    ///
    /// 1. `candidateURL` is opened exactly once. Every fact used below —
    ///    the full-content SHA-256, the legacy sampled-fingerprint
    ///    fallback, and the identity re-checked at the end — comes from
    ///    that one open file descriptor, via `fstat(2)`, never a second
    ///    independent open.
    /// 2. The digest is compared against `contentDigestSHA256` (full
    ///    guarantee) or, for a legacy record with none, the sampled
    ///    `sourceFingerprint` — but *only* when `candidateURL` is small
    ///    enough (`FingerprintCalculator.wholeFileThreshold`) that the
    ///    sample is actually a full-file hash; a larger legacy-record
    ///    candidate throws `RelinkError.legacyFullDigestUnavailable`
    ///    rather than accepting a guarantee weaker than the user has any
    ///    way to know about.
    /// 3. Immediately before commit, both `candidateURL` and
    ///    `resolvedBookmarkURL` are `stat(2)`-ed again and their device,
    ///    inode, size, modification time, and status-change time must all
    ///    match what was captured from the open descriptor in step 1 — a
    ///    swap of either path between the read and the commit, or a
    ///    bookmark that resolves to a different file than the one just
    ///    verified, is caught here.
    ///
    /// On any mismatch at any step, nothing is changed — the existing
    /// record, sidecar, bookmark and working `URL` are left completely
    /// untouched, so a caller can safely let the user try picking again.
    public func relinkInPlaceDocument(
        documentID: UUID,
        candidateURL: URL,
        bookmarkData: Data,
        resolvedBookmarkURL: URL
    ) throws -> PhotoDocument {
        let record = try loadRecord(id: documentID)
        guard record.storageMode == .inPlace else {
            throw RelinkError.notInPlace
        }

        let handle = try FileHandle(forReadingFrom: candidateURL)
        defer { try? handle.close() }
        let openedIdentity = try fileIdentity(fileDescriptor: handle.fileDescriptor)

        // A legacy record's sampled fingerprint is only a genuine
        // full-content guarantee when the whole file fits under
        // `wholeFileThreshold` -- `FingerprintCalculator` hashes the
        // entire file at that size, not just its edges. Accumulated from
        // the same read as the digest below, so there is still only one
        // open of `candidateURL`.
        let needsLegacyFallbackBuffer = record.contentDigestSHA256 == nil
            && openedIdentity.size <= FingerprintCalculator.wholeFileThreshold
        var legacyBuffer: Data? = needsLegacyFallbackBuffer ? Data() : nil

        var hasher = SHA256()
        while true {
            try checkCancellation()
            let chunk = try handle.read(upToCount: Self.verificationChunkByteCount) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            if legacyBuffer != nil { legacyBuffer!.append(chunk) }
        }
        let candidateDigest = Self.hexString(hasher.finalize())

        if let expectedDigest = record.contentDigestSHA256 {
            guard candidateDigest == expectedDigest else {
                throw RelinkError.contentMismatch
            }
        } else if let legacyBuffer {
            let candidateFingerprint = FingerprintCalculator.fingerprint(forData: legacyBuffer)
            guard candidateFingerprint == record.sourceFingerprint else {
                throw RelinkError.fingerprintMismatch
            }
        } else {
            // Legacy record, but too large for the sample to mean
            // anything -- refuse rather than silently under-verify.
            throw RelinkError.legacyFullDigestUnavailable
        }

        // Final identity re-check, right before commit: both the path the
        // user picked and where the fresh bookmark actually resolves must
        // still be the *exact* file (device + inode, not merely a
        // same-looking path) that was opened and hashed above, with
        // nothing about it changed since.
        try checkCancellation()
        let candidateRecheck = try fileIdentity(atPath: candidateURL.path)
        guard candidateRecheck == openedIdentity else {
            throw RelinkError.sourceModifiedDuringRelink
        }
        let resolvedRecheck = try fileIdentity(atPath: resolvedBookmarkURL.path)
        guard resolvedRecheck == openedIdentity else {
            throw RelinkError.bookmarkIdentityMismatch
        }

        try updateInPlaceLocation(
            newURL: candidateURL,
            bookmarkData: bookmarkData,
            documentID: documentID,
            contentDigestSHA256: candidateDigest
        )
        return try loadDocument(id: documentID)
    }

    /// Marks `creation` as kept: the document it produced has been shown to
    /// the user and must never be rolled back after this, even by a caller
    /// that (in error) still holds and reuses the same `PhotoDocumentCreation`
    /// value. Idempotent — finalizing an already-finalized or already-rolled-
    /// back creation does nothing.
    ///
    /// The in-memory receipt only transitions to `.finalized` — and the
    /// creation's per-document lease (see `pendingLeases`) is only
    /// released — *after* the record has been durably rewritten as
    /// `.committed` on disk. Nothing here uses `try?` to swallow that
    /// write: a failure at any step (loading the record, encoding it,
    /// writing it) is reported back as `.retryRequired` rather than
    /// silently treated as success, and the record, receipt, and lease are
    /// all left exactly as they were — safe, and necessary, to call again.
    /// A caller must retain the `PhotoDocumentCreation` and keep retrying
    /// (or eventually roll it back) rather than treating a returned
    /// creation as durably committed on its own; see `PhotoDocumentEditor
    /// .retryFinalizeIfNeeded()`.
    ///
    /// This is what makes the commit crash-durable rather than only living
    /// in this actor's memory: if the process is killed before this call
    /// ever runs (or while its write is in flight), the record stays
    /// `.pending` and the lease stays held (kernel-released automatically
    /// on process death). The *next* launch's `reconcileOrphanedImports
    /// (activePointer:)` finds it, sees whether it matches the durably
    /// persisted active document pointer (moved to it *before* finalize is
    /// even attempted — see `PhotoDocumentEditor.openFreshSelection`), and
    /// promotes or rolls it back accordingly.
    @discardableResult
    public func finalizeCreation(_ creation: PhotoDocumentCreation) -> PhotoDocumentFinalizeOutcome {
        switch creationStates[creation.receipt] {
        case .none:
            return .unknownReceipt
        case .finalized:
            return .alreadyFinalized
        case .rolledBack:
            return .alreadyRolledBack
        case .some(.pending):
            break
        }

        guard var record = try? loadRecord(id: creation.document.id) else {
            return .retryRequired
        }
        record.lifecycleState = .committed
        guard let encoded = try? SidecarCoding.encode(record) else {
            return .retryRequired
        }
        do {
            try writeRecordData(encoded, recordURL(for: creation.document.id), fileManager)
        } catch {
            return .retryRequired
        }

        creationStates[creation.receipt] = .finalized
        pendingLeases.removeValue(forKey: creation.document.id)?.release()
        return .committed
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
    /// so a caller (or a later `reconcileOrphanedImports(activePointer:)`
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
            // The record is deleted *last* — see the type documentation on
            // why record-last ordering matters: as long as the record is
            // still on disk (`.pending`), a crash between any two steps
            // here still leaves something for a retry, or a later
            // `reconcileOrphanedImports`, to find and finish.
            let sidecarResult: PhotoDocumentRollbackReport.StepResult = removeAndVerifyGone(at: sidecarURL)
            let recordResult: PhotoDocumentRollbackReport.StepResult =
                sidecarResult == .succeeded ? removeAndVerifyGone(at: recordURL) : .failed

            let cleaned = recordResult == .succeeded && sidecarResult == .succeeded
            if cleaned {
                creationStates[creation.receipt] = .rolledBack
                pendingLeases.removeValue(forKey: document.id)?.release()
            }
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

        // Deletion order is copy -> sidecar -> record, record always last:
        // as long as the record survives, its still-`.pending` state is
        // what lets a retry (this call again, or a later
        // `reconcileOrphanedImports`) find and finish an interrupted
        // rollback, rather than leaving an orphaned copy or sidecar with
        // nothing left pointing at it. Each step only proceeds if every
        // step before it actually succeeded.
        let copyDirectory = documentsDirectoryURL.appendingPathComponent(document.id.uuidString, isDirectory: true)
        let copyResult: PhotoDocumentRollbackReport.StepResult = removeAndVerifyGone(at: copyDirectory)
        let sidecarResult: PhotoDocumentRollbackReport.StepResult =
            copyResult == .succeeded ? removeAndVerifyGone(at: sidecarURL) : .failed
        let recordResult: PhotoDocumentRollbackReport.StepResult =
            (copyResult == .succeeded && sidecarResult == .succeeded) ? removeAndVerifyGone(at: recordURL) : .failed

        let cleaned = copyResult == .succeeded && sidecarResult == .succeeded && recordResult == .succeeded
        if cleaned {
            creationStates[creation.receipt] = .rolledBack
            pendingLeases.removeValue(forKey: document.id)?.release()
        }
        return PhotoDocumentRollbackReport(
            outcome: cleaned ? .cleaned : .retryRequired,
            lock: .succeeded, record: recordResult, sidecar: sidecarResult, copy: copyResult
        )
    }

    /// Best-effort removal, reporting whether the path is actually gone
    /// afterward rather than whether `removeItem` itself threw — a
    /// permissions error midway through a directory removal can leave
    /// something behind even though `removeItem` returned normally for the
    /// top-level call, and this is what every rollback/reconciliation step
    /// treats as ground truth.
    private func removeAndVerifyGone(at url: URL) -> PhotoDocumentRollbackReport.StepResult {
        try? fileManager.removeItem(at: url)
        return fileManager.fileExists(atPath: url.path) ? .failed : .succeeded
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

    private var sidecarsRootDirectoryURL: URL {
        rootURL.appendingPathComponent(Self.sidecarsDirectoryName, isDirectory: true)
    }

    private func sidecarsDirectoryURL(documentID: UUID) -> URL {
        sidecarsRootDirectoryURL.appendingPathComponent(documentID.uuidString, isDirectory: true)
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
    /// **Pass 1** removes both kinds of orphan a kill can leave with no
    /// record ever pointing at them at all: `Documents/<id>` directories
    /// (a kill between an app-copy landing at its final name and the
    /// record ever being written) and `Sidecars/<id>` directories (a kill
    /// between `saveAdjustments` writing one and the record that would
    /// reference it existing). Neither determination depends on the active
    /// pointer, so this pass always runs regardless of `activePointer`'s
    /// state. A `Sidecars/` entry whose name isn't a well-formed UUID is
    /// left completely untouched and reported in
    /// `PhotoDocumentReconciliationReport.ignoredSidecarEntries` — it may
    /// not even be this store's data, and this pass's job is reclaiming
    /// known orphans, not guessing about the unknown.
    ///
    /// **Pass 2** resolves every record still marked `.pending` — a kill
    /// between the record being written and `finalizeCreation(_:)`
    /// completing. `activePointer` (the durably persisted active-document
    /// pointer — see `loadActiveDocumentPointer()`) is what decides each
    /// one's fate: a pending record whose id matches `.active(id)` survived
    /// far enough to be the document the user was actually handed off to,
    /// so it is *promoted* to `.committed` rather than deleted. If
    /// `activePointer` is `.corrupt`, this entire pass is skipped and
    /// `PhotoDocumentReconciliationReport.activePointerWasUnreadable` is
    /// `true` — acting on *any* pending record while the pointer's own
    /// content cannot be trusted risks rolling back the very document the
    /// user was mid-handoff to. Otherwise, every pending record that
    /// doesn't match `.active(id)` never finished being shown to anyone and
    /// is rolled back exactly like a same-session `rollbackNewDocument(_:)`
    /// would — record and sidecar always, and its `Documents/` copy for
    /// `.appCopy`; an `.inPlace` record's rollback never touches the
    /// external RAW, since `workingURL` *is* that RAW. A record already
    /// `.committed` (including every legacy record written before this
    /// field existed) is never touched by this pass.
    ///
    /// Throws `PhotoDocumentError.importInProgress`, changing nothing, if
    /// the lock is already held elsewhere. A directory-listing failure in
    /// either pass propagates rather than being treated as "empty" — an
    /// unreadable `Documents/`, `Sidecars/`, or `Records/` is not the same
    /// as an empty one, and must not be silently reconciled as if nothing
    /// were there. Individual per-entry failures within either pass are
    /// instead collected in `PhotoDocumentReconciliationReport.failures`
    /// (fixed, path-free diagnostics — never `NSError.localizedDescription`,
    /// which can carry an absolute path) rather than aborting the whole
    /// call; whatever could not be resolved is left in place for a later
    /// call to retry.
    @discardableResult
    public func reconcileOrphanedImports(activePointer: ActiveDocumentPointer) throws -> PhotoDocumentReconciliationReport {
        var removedOrphanIDs: [UUID] = []
        var removedOrphanSidecarIDs: [UUID] = []
        var ignoredSidecarEntries: [String] = []
        var failures: [UUID: String] = [:]

        // PASS 1 needs the root lock: enumerating and removing entries
        // under `Documents/` races with `importCopy` creating a new one
        // there. Acquired and released just for this pass — pass 2 below
        // acquires its own per-record lease *first* and only takes the
        // root lock afterward (for an `.appCopy` rollback's copy
        // directory), never the other way around, so the two passes never
        // contend with each other over lock order.
        do {
            let lock = try RootImportLock.acquire(at: importLockURL, fileManager: fileManager)
            defer { lock.release() }
            if fileManager.fileExists(atPath: documentsDirectoryURL.path) {
                let entries = try fileManager.contentsOfDirectory(at: documentsDirectoryURL, includingPropertiesForKeys: nil)
                for entry in entries {
                    guard let id = UUID(uuidString: entry.lastPathComponent) else { continue }
                    guard !fileManager.fileExists(atPath: recordURL(for: id).path) else { continue }
                    do {
                        try fileManager.removeItem(at: entry)
                        removedOrphanIDs.append(id)
                    } catch {
                        failures[id] = Self.orphanCopyRemovalFailureMessage
                    }
                }
            }
            if fileManager.fileExists(atPath: sidecarsRootDirectoryURL.path) {
                let entries = try fileManager.contentsOfDirectory(at: sidecarsRootDirectoryURL, includingPropertiesForKeys: nil)
                for entry in entries {
                    guard let id = UUID(uuidString: entry.lastPathComponent) else {
                        // Not even a well-formed UUID -- never delete
                        // something this pass cannot positively identify
                        // as its own orphan. Only the entry's own name is
                        // recorded, never a full path.
                        ignoredSidecarEntries.append(entry.lastPathComponent)
                        continue
                    }
                    guard !fileManager.fileExists(atPath: recordURL(for: id).path) else { continue }
                    do {
                        try fileManager.removeItem(at: entry)
                        removedOrphanSidecarIDs.append(id)
                    } catch {
                        failures[id] = Self.orphanSidecarRemovalFailureMessage
                    }
                }
            }
        }

        // PASS 2 resolves every record still marked `.pending`. Skipped
        // entirely if the active pointer itself is unreadable -- see the
        // type documentation above for why.
        var promotedPendingIDs: [UUID] = []
        var rolledBackPendingIDs: [UUID] = []
        var activePointerWasUnreadable = false

        if case .corrupt = activePointer {
            activePointerWasUnreadable = true
        } else if fileManager.fileExists(atPath: recordsDirectoryURL.path) {
            let activeDocumentID: UUID? = {
                if case .active(let id) = activePointer { return id }
                return nil
            }()

            let recordFiles = try fileManager.contentsOfDirectory(at: recordsDirectoryURL, includingPropertiesForKeys: nil)
            for recordFile in recordFiles {
                guard recordFile.pathExtension == "json",
                      let filenameID = UUID(uuidString: recordFile.deletingPathExtension().lastPathComponent) else { continue }
                guard let record = try? SidecarCoding.decode(PhotoDocumentRecord.self, from: Data(contentsOf: recordFile)) else {
                    // Corrupt/unreadable: not this pass's job to repair --
                    // `loadDocument` surfaces this loudly if actually opened.
                    continue
                }
                guard record.effectiveLifecycleState == .pending else { continue }

                guard let lease = try? PendingLock.acquire(at: pendingLockURL(for: filenameID), fileManager: fileManager) else {
                    continue
                }
                defer { lease.release() }

                // Re-read now that the lease is held: between listing
                // `Records/` above and acquiring it, the record could have
                // been finalized, or already rolled back and removed.
                guard let freshRecord = try? SidecarCoding.decode(PhotoDocumentRecord.self, from: Data(contentsOf: recordFile)),
                      freshRecord.effectiveLifecycleState == .pending else {
                    continue
                }

                if let activeDocumentID, filenameID == activeDocumentID {
                    if let reason = validationFailureForPromotion(filenameID: filenameID, record: freshRecord) {
                        // Never promote a record this pass can't actually
                        // verify — left as `.pending` and surfaced as a
                        // quarantined diagnostic, not silently counted as
                        // a successful pass.
                        failures[filenameID] = reason
                        continue
                    }
                    var promoted = freshRecord
                    promoted.lifecycleState = .committed
                    do {
                        try writeRecordData(try SidecarCoding.encode(promoted), recordFile, fileManager)
                        promotedPendingIDs.append(filenameID)
                    } catch {
                        failures[filenameID] = Self.promotionWriteFailureMessage
                    }
                    continue
                }

                // Roll back, record deleted last — same ordering and same
                // reasoning as `rollbackNewDocument`: as long as the
                // record survives on disk, a later pass can always finish
                // an interrupted rollback.
                let sidecarURL = sidecarsDirectoryURL(documentID: filenameID)
                var sidecarResult: PhotoDocumentRollbackReport.StepResult = .notApplicable
                var copyResult: PhotoDocumentRollbackReport.StepResult = .notApplicable

                if freshRecord.storageMode == .appCopy {
                    guard let rootLock = try? RootImportLock.acquire(at: importLockURL, fileManager: fileManager) else {
                        failures[filenameID] = Self.rollbackFailureMessage
                        continue
                    }
                    defer { rootLock.release() }
                    let copyDirectory = documentsDirectoryURL.appendingPathComponent(filenameID.uuidString, isDirectory: true)
                    copyResult = removeAndVerifyGone(at: copyDirectory)
                    sidecarResult = copyResult == .succeeded ? removeAndVerifyGone(at: sidecarURL) : .failed
                } else {
                    sidecarResult = removeAndVerifyGone(at: sidecarURL)
                }

                let priorStepsOK = (copyResult == .notApplicable || copyResult == .succeeded) && sidecarResult == .succeeded
                let recordResult: PhotoDocumentRollbackReport.StepResult =
                    priorStepsOK ? removeAndVerifyGone(at: recordFile) : .failed

                if priorStepsOK && recordResult == .succeeded {
                    rolledBackPendingIDs.append(filenameID)
                } else {
                    failures[filenameID] = Self.rollbackFailureMessage
                }
            }
        }

        return PhotoDocumentReconciliationReport(
            removedOrphanIDs: removedOrphanIDs,
            removedOrphanSidecarIDs: removedOrphanSidecarIDs,
            ignoredSidecarEntries: ignoredSidecarEntries,
            promotedPendingIDs: promotedPendingIDs,
            rolledBackPendingIDs: rolledBackPendingIDs,
            failures: failures,
            activePointerWasUnreadable: activePointerWasUnreadable
        )
    }

    /// Fixed, path-free diagnostics for `PhotoDocumentReconciliationReport
    /// .failures` — deliberately never `(error as NSError)
    /// .localizedDescription`, which can embed the exact absolute path
    /// that failed (e.g. `NSCocoaErrorDomain` "couldn't be removed because
    /// you don't have permission to access <path>") straight into
    /// diagnostics a UI might display or a log might persist.
    private static let orphanCopyRemovalFailureMessage = "Could not remove an orphaned import."
    private static let orphanSidecarRemovalFailureMessage = "Could not remove an orphaned sidecar."
    private static let promotionWriteFailureMessage = "Could not finish confirming an interrupted import."
    private static let rollbackFailureMessage = "Could not fully roll back an interrupted import."

    /// Guards against promoting a `.pending` record to `.committed` that
    /// this pass cannot actually verify — see the type documentation on
    /// `PhotoDocumentReconciliationReport.failures`. Deliberately a
    /// lightweight, structural check (filename/id agreement, storage-mode
    /// shape, an app-copy's working file actually existing, a present
    /// digest at least being well-formed) rather than a full re-hash of
    /// the working file: the whole point of `contentDigestSHA256` is to be
    /// computed once, at creation time, not re-paid on every launch.
    private func validationFailureForPromotion(filenameID: UUID, record: PhotoDocumentRecord) -> String? {
        guard record.id == filenameID else {
            return "Record id does not match its filename."
        }
        if let digest = record.contentDigestSHA256 {
            guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else {
                return "Stored content digest is malformed."
            }
        }
        switch record.storageMode {
        case .appCopy:
            let workingURL: URL
            if let components = record.workingPathComponents, !components.isEmpty {
                workingURL = components.reduce(rootURL) { $0.appendingPathComponent($1) }
            } else {
                workingURL = record.workingURL
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: workingURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return "App-copy working file is missing or is not a regular file."
            }
            // Existence and shape alone don't prove the bytes are still
            // what this record claims -- silent disk corruption in the
            // untouched middle of a large working copy would pass both
            // checks above. When a digest was recorded, re-hash the
            // working file and require an exact match before promoting;
            // a legacy record with no digest at all falls back to the
            // existence/shape check only, same as before.
            if let expectedDigest = record.contentDigestSHA256 {
                guard let actualDigest = try? fullContentDigest(forFileAt: workingURL), actualDigest == expectedDigest else {
                    return "App-copy working file content does not match its stored digest."
                }
            }
        case .inPlace:
            // The working file is external to the store; its presence and
            // content are neither something this pass can nor should
            // verify -- relink already carries that guarantee for the
            // in-place path.
            break
        }
        return nil
    }

    // MARK: - Committed document listing

    /// Every committed, currently-readable document this store knows about
    /// (Task 4) — used to project App copies into the multi-source library
    /// via `PhotoLibraryService.refreshAppStorageProjection(from:)`. Both
    /// storage modes are included; the caller decides what to do with each
    /// (the app-storage projection itself only ever keeps the `.appCopy`
    /// ones — see that method).
    ///
    /// Enumerates `Records/*.json`, the same directory
    /// `reconcileOrphanedImports(activePointer:)` reads in its own pass 2,
    /// with the same lenient per-entry handling: a record this pass cannot
    /// decode, or whose committed working file is missing, is reported in
    /// `PhotoDocumentListing.failures` rather than aborting the whole
    /// listing or being silently dropped. A `.pending` record — still
    /// mid-import, or interrupted mid-import — is neither promoted nor
    /// deleted here: it is simply skipped, exactly as
    /// `reconcileOrphanedImports`'s own documentation already establishes
    /// for "don't touch a creation this pass didn't itself start." Only
    /// that dedicated reconciliation pass, gated on the durable
    /// active-document pointer, is ever allowed to promote or roll one
    /// back.
    ///
    /// This is a plain read: unlike `reconcileOrphanedImports`, it never
    /// acquires the root import lock or any per-document lease — nothing
    /// here mutates a record, and every record write elsewhere in this
    /// store goes through `AtomicFileWriter`, so a reader here only ever
    /// sees a complete, previously-committed write, never a partial one.
    ///
    /// Returned in stable ascending `UUID` order, not filesystem
    /// enumeration order, so a caller diffing two consecutive calls (or two
    /// different store instances pointed at the same `rootURL`) sees a
    /// deterministic sequence rather than one at the mercy of directory
    /// listing order.
    ///
    /// Throws only if `Records/` itself cannot be enumerated (mirroring
    /// `reconcileOrphanedImports`'s own directory-listing behavior) — a
    /// missing `Records/` directory is treated as "no documents yet," not
    /// an error.
    public func committedDocuments() throws -> PhotoDocumentListing {
        guard fileManager.fileExists(atPath: recordsDirectoryURL.path) else {
            return PhotoDocumentListing(documents: [], failures: [:])
        }

        var documents: [PhotoDocument] = []
        var failures: [UUID: String] = [:]

        let recordFiles = try fileManager.contentsOfDirectory(at: recordsDirectoryURL, includingPropertiesForKeys: nil)
        for recordFile in recordFiles {
            guard recordFile.pathExtension == "json",
                  let filenameID = UUID(uuidString: recordFile.deletingPathExtension().lastPathComponent) else { continue }

            guard let record = try? SidecarCoding.decode(PhotoDocumentRecord.self, from: Data(contentsOf: recordFile)),
                  record.id == filenameID else {
                failures[filenameID] = Self.corruptRecordFailureMessage
                continue
            }

            // Never promoted, never deleted here -- see the documentation
            // above.
            guard record.effectiveLifecycleState == .committed else { continue }

            let resolved: PhotoDocument
            if record.storageMode == .appCopy, record.workingPathComponents == nil {
                guard let migrated = try? migrateLegacyAppCopyRecordIfPossible(record) else {
                    failures[filenameID] = Self.corruptRecordFailureMessage
                    continue
                }
                resolved = migrated
            } else {
                resolved = resolvedDocument(from: record)
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolved.workingURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                failures[filenameID] = Self.missingWorkingFileFailureMessage
                continue
            }

            documents.append(resolved)
        }

        documents.sort { $0.id.uuidString < $1.id.uuidString }
        return PhotoDocumentListing(documents: documents, failures: failures)
    }

    /// Fixed, path-free diagnostics for `committedDocuments()` — same
    /// reasoning as `orphanCopyRemovalFailureMessage` and friends above:
    /// never `(error as NSError).localizedDescription`, which can embed an
    /// absolute path.
    private static let corruptRecordFailureMessage = "This document's record could not be read."
    private static let missingWorkingFileFailureMessage = "This document's working file is missing."

    // MARK: - Active document pointer

    /// Reads the durably persisted active-document pointer — in the same
    /// durability domain (an atomic file under `rootURL`, via the same
    /// `writeRecordData`/`AtomicFileWriter` path every record uses) as
    /// document records themselves, rather than `UserDefaults`. Never
    /// throws — every outcome, including "unreadable" and "malformed", is
    /// represented in `ActiveDocumentPointer` itself, since a caller (most
    /// importantly `reconcileOrphanedImports(activePointer:)`) has to
    /// react differently to "no active document" than to "cannot currently
    /// tell what the active document is."
    public func loadActiveDocumentPointer() -> ActiveDocumentPointer {
        guard fileManager.fileExists(atPath: activePointerURL.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: activePointerURL) else {
            return .corrupt
        }
        guard let record = try? SidecarCoding.decode(ActivePointerRecord.self, from: data) else {
            return .corrupt
        }
        if let id = record.documentID {
            return .active(id)
        }
        return .noActiveDocument
    }

    /// Convenience for callers (restore) that only ever care about "is
    /// there a document to restore" — `.missing`, `.noActiveDocument`, and
    /// `.corrupt` are all equally "nothing to restore" from that single
    /// caller's point of view, and restore never deletes anything on its
    /// own regardless of which one it was, so collapsing them here is
    /// safe. `reconcileOrphanedImports`, which *can* delete things, uses
    /// `loadActiveDocumentPointer()` directly instead and must not use
    /// this.
    public func loadActiveDocumentID() -> UUID? {
        if case .active(let id) = loadActiveDocumentPointer() {
            return id
        }
        return nil
    }

    /// Durably writes the active-document pointer. Throws — rather than
    /// swallowing a write failure — because a pointer write that silently
    /// failed must never be treated by a caller as though the hand-off it
    /// represents actually became durable; see `PhotoDocumentEditor
    /// .openFreshSelection` and `.closeCurrentDocument` for how each
    /// caller reacts to that.
    public func saveActiveDocumentID(_ id: UUID?) throws {
        let record = ActivePointerRecord(documentID: id)
        try writeRecordData(try SidecarCoding.encode(record), activePointerURL, fileManager)
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

    private var activePointerURL: URL {
        rootURL.appendingPathComponent(Self.activePointerFilename)
    }

    private func pendingLockURL(for id: UUID) -> URL {
        rootURL
            .appendingPathComponent(Self.pendingLocksDirectoryName, isDirectory: true)
            .appendingPathComponent("\(id.uuidString).lock")
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
            lifecycleState: lifecycleState,
            contentDigestSHA256: document.contentDigestSHA256
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
            workingFingerprint: record.workingFingerprint,
            contentDigestSHA256: record.contentDigestSHA256
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

    /// Streams both files start to finish, comparing their bytes exactly
    /// (never holding more than one chunk of each in memory at a time) and
    /// accumulating a SHA-256 over them as it goes. Returns that digest
    /// only when the files are identical — computing it during the same
    /// pass `importCopy` already has to make for verification, rather than
    /// paying for a second full read of the copy just to hash it.
    ///
    /// This is deliberately independent of `FingerprintCalculator`: that
    /// type only samples the first and last `edgeChunkByteCount` of a file
    /// above `wholeFileThreshold` to give photos a cheap, stable identity —
    /// it is not, and must not be used as, a copy checksum or a relink
    /// proof, since damage anywhere in the untouched middle of a large RAW
    /// is invisible to it.
    private func contentsAreIdenticalComputingDigest(_ first: URL, _ second: URL) throws -> (identical: Bool, digest: String?) {
        let firstHandle = try FileHandle(forReadingFrom: first)
        defer { try? firstHandle.close() }
        let secondHandle = try FileHandle(forReadingFrom: second)
        defer { try? secondHandle.close() }

        var hasher = SHA256()
        while true {
            try checkCancellation()
            let firstChunk = try firstHandle.read(upToCount: Self.verificationChunkByteCount) ?? Data()
            let secondChunk = try secondHandle.read(upToCount: Self.verificationChunkByteCount) ?? Data()
            guard firstChunk == secondChunk else { return (false, nil) }
            if firstChunk.isEmpty {
                return (true, Self.hexString(hasher.finalize()))
            }
            hasher.update(data: firstChunk)
        }
    }

    /// Streams a single file start to finish and returns its full-content
    /// SHA-256, never holding more than one chunk in memory — the basis
    /// for `PhotoDocument.contentDigestSHA256`. See
    /// `contentsAreIdenticalComputingDigest` for why this is intentionally
    /// separate from, and stronger than, `FingerprintCalculator`.
    private func fullContentDigest(forFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try checkCancellation()
            let chunk = try handle.read(upToCount: Self.verificationChunkByteCount) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Self.hexString(hasher.finalize())
    }

    /// Computes both a `FileFingerprint` (`FingerprintCalculator`'s
    /// sampled-or-whole-file algorithm, byte-for-byte compatible with it)
    /// and a full-content digest from a *single* open of `url` — used by
    /// `openInPlace`, where re-opening the source a second time to compute
    /// each independently would double both the I/O and the TOCTOU window.
    ///
    /// The file's identity (`fstat`) is captured the moment it's opened
    /// and re-checked the moment the read finishes; any difference — a
    /// write landing on this exact file while it's being read, not merely
    /// the path being replaced — throws `PhotoDocumentError
    /// .sourceModifiedDuringImport` rather than returning a
    /// fingerprint/digest pair for bytes that may no longer describe what
    /// is actually there.
    private func fingerprintAndDigest(forFileAt url: URL) throws -> (fingerprint: FileFingerprint, digest: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let openedIdentity = try fileIdentity(fileDescriptor: handle.fileDescriptor)
        let fileSize = openedIdentity.size

        var digestHasher = SHA256()
        var fingerprintHasher = SHA256()
        fingerprintHasher.update(data: FingerprintCalculator.header(fileSize: fileSize))

        if fileSize <= FingerprintCalculator.wholeFileThreshold {
            // Small file: every byte goes into both hashers, identically
            // to how `fullContentDigest` and `FingerprintCalculator` would
            // each treat it independently.
            while true {
                try checkCancellation()
                let chunk = try handle.read(upToCount: Self.verificationChunkByteCount) ?? Data()
                if chunk.isEmpty { break }
                digestHasher.update(data: chunk)
                fingerprintHasher.update(data: chunk)
            }
        } else {
            // Large file: the digest still needs every byte, but the
            // fingerprint only samples the first and last
            // `edgeChunkByteCount`. The head is captured directly from
            // the first chunk; the tail is tracked as a rolling buffer
            // (bounded at `edgeChunkByteCount`) updated as each chunk
            // streams past, rather than seeking back after the fact —
            // this is still a single sequential pass over the file.
            var isFirstChunk = true
            var tailBuffer = Data()
            while true {
                try checkCancellation()
                let chunk = try handle.read(upToCount: Self.verificationChunkByteCount) ?? Data()
                if chunk.isEmpty { break }
                digestHasher.update(data: chunk)
                if isFirstChunk {
                    fingerprintHasher.update(data: chunk.prefix(FingerprintCalculator.edgeChunkByteCount))
                    isFirstChunk = false
                }
                tailBuffer.append(chunk)
                if tailBuffer.count > FingerprintCalculator.edgeChunkByteCount {
                    tailBuffer.removeFirst(tailBuffer.count - FingerprintCalculator.edgeChunkByteCount)
                }
            }
            fingerprintHasher.update(data: tailBuffer.suffix(FingerprintCalculator.edgeChunkByteCount))
        }

        try checkCancellation()
        let closingIdentity = try fileIdentity(fileDescriptor: handle.fileDescriptor)
        guard closingIdentity == openedIdentity else {
            throw PhotoDocumentError.sourceModifiedDuringImport
        }
        let closingPathIdentity: FileIdentity
        do {
            closingPathIdentity = try fileIdentity(atPath: url.path)
        } catch {
            throw PhotoDocumentError.sourceModifiedDuringImport
        }
        guard closingPathIdentity == openedIdentity else {
            throw PhotoDocumentError.sourceModifiedDuringImport
        }

        let fingerprint = FileFingerprint(fileSize: fileSize, edgeDigest: FingerprintCalculator.hexString(fingerprintHasher.finalize()))
        let digest = Self.hexString(digestHasher.finalize())
        return (fingerprint, digest)
    }

    private static func hexString(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A file's kernel-level identity — device and inode, not merely a path
    /// — plus size and both timestamps `stat(2)` reports. Two `URL`s that
    /// resolve to the same `(device, inode)` are, by definition, the exact
    /// same file on disk regardless of what path either was reached
    /// through; a path alone can never prove that (it could have been
    /// unlinked and a different file created at the same location). Used
    /// by `relinkInPlaceDocument` to prove the file it hashed is still the
    /// same file at both `candidateURL` and wherever the fresh bookmark
    /// resolved to, right up to the moment of commit.
    private struct FileIdentity: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int
        let modificationNanoseconds: Int
        let statusChangeSeconds: Int
        let statusChangeNanoseconds: Int

        init(_ status: stat) {
            device = status.st_dev
            inode = UInt64(status.st_ino)
            size = Int64(status.st_size)
            modificationSeconds = status.st_mtimespec.tv_sec
            modificationNanoseconds = status.st_mtimespec.tv_nsec
            statusChangeSeconds = status.st_ctimespec.tv_sec
            statusChangeNanoseconds = status.st_ctimespec.tv_nsec
        }
    }

    /// `fstat(2)` on an already-open file descriptor — the identity of
    /// exactly the bytes that descriptor reads, immune to the path it was
    /// opened through being replaced afterward.
    private func fileIdentity(fileDescriptor: Int32) throws -> FileIdentity {
        var status = stat()
        guard fstat(fileDescriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileIdentity(status)
    }

    /// `stat(2)` on a path — re-checked immediately before a commit to
    /// prove the path still resolves to the exact same file (by device and
    /// inode, not merely by name) as whatever was actually opened and
    /// hashed earlier in the same call.
    private func fileIdentity(atPath path: String) throws -> FileIdentity {
        var status = stat()
        guard stat(path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileIdentity(status)
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

/// A per-document exclusive advisory lock (`flock`) at
/// `PendingLocks/<documentID>.lock`, held for the entire time one specific
/// document's creation is pending — from the moment `openInPlace`/
/// `importCopy` returns until `finalizeCreation(_:)` durably commits it or
/// `rollbackNewDocument(_:)` fully cleans it up (see `pendingLeases`).
///
/// This closes the crash window `RootImportLock` alone cannot: the root
/// lock is released the instant `importCopy` returns, but the calling
/// controller (`PhotoDocumentEditor`) still has real work left — decoding
/// metadata, loading adjustments, flushing whatever document was open
/// before — before it can show the new one and finalize it. A *different*
/// `PhotoDocumentStore` instance's `reconcileOrphanedImports`, running at
/// exactly that moment (another process's launch, most plausibly), must
/// not mistake that in-flight document for an orphan and delete it out
/// from under the first instance. Acquiring this lease non-blockingly
/// before touching a pending record is how reconciliation tells "still
/// being worked on by something alive" apart from "genuinely abandoned."
///
/// A class, not a struct: dropping the last reference to one — whether via
/// an explicit `release()`, or because the actor holding it in
/// `pendingLeases` is deallocated without ever finalizing or rolling back
/// (the closest one process can get to simulating a *different* process
/// dying) — closes the file descriptor, and the kernel releases the
/// underlying `flock` on its own. `release()` is idempotent so it is safe
/// to call explicitly and still let `deinit` run afterward.
///
/// **Lock ordering.** Whenever both this lease and `RootImportLock` are
/// needed together, this lease is always acquired *first* — see
/// `importCopy`, `rollbackNewDocument`, and
/// `reconcileOrphanedImports(activePointer:)`. `openInPlace` never
/// needs the root lock at all. Following this order everywhere rules out
/// the deadlock a mixed order would risk (one caller holding the lease and
/// waiting on the root lock, another holding the root lock and waiting on
/// the lease) — moot in practice today since every acquisition here is
/// non-blocking (`LOCK_NB`) and simply fails outright rather than
/// deadlocking, but the fixed order keeps that true even if a future
/// caller were to switch to a blocking acquisition.
private final class PendingLock {
    private let fileDescriptor: Int32
    private var released = false

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    static func acquire(at url: URL, fileManager: FileManager) throws -> PendingLock {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let fileDescriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let capturedErrno = errno
            close(fileDescriptor)
            if capturedErrno == EWOULDBLOCK {
                throw PendingLockError.heldElsewhere
            }
            throw POSIXError(POSIXErrorCode(rawValue: capturedErrno) ?? .EIO)
        }

        return PendingLock(fileDescriptor: fileDescriptor)
    }

    func release() {
        guard !released else { return }
        released = true
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }

    deinit { release() }
}

/// Not `PhotoDocumentError` deliberately: whether a per-document lease is
/// held elsewhere is an internal detail of how `reconcileOrphanedImports`
/// decides what is safe to touch, never something a public API caller
/// needs to distinguish or handle — every caller either doesn't observe it
/// (`openInPlace`/`importCopy`, where contention on a *brand-new* random
/// UUID cannot actually happen) or treats it identically to "skip this
/// record" (`reconcileOrphanedImports`, via `try?`).
private enum PendingLockError: Error {
    case heldElsewhere
}

/// On-disk shape of the durably persisted active-document pointer — see
/// `PhotoDocumentStore.loadActiveDocumentID()`/`saveActiveDocumentID(_:)`.
private struct ActivePointerRecord: Codable {
    var documentID: UUID?
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
    /// `reconcileOrphanedImports(activePointer:)`.
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
    /// Absent (`nil`) in every record written before full-content digests
    /// existed. See `PhotoDocument.contentDigestSHA256` and
    /// `relinkInPlaceDocument`'s legacy fallback.
    var contentDigestSHA256: String?

    var effectiveLifecycleState: LifecycleState { lifecycleState ?? .committed }
}

/// Result of a `reconcileOrphanedImports()` pass.
public struct PhotoDocumentReconciliationReport: Equatable, Sendable {
    /// `Documents/` directories found with no record at all, and removed.
    public let removedOrphanIDs: [UUID]
    /// `Sidecars/<uuid>` directories found with no record at all, and
    /// removed — the sidecar-side counterpart to `removedOrphanIDs`. A kill
    /// between `saveAdjustments` writing a sidecar and the record that
    /// would reference it existing can leave one of these behind.
    public let removedOrphanSidecarIDs: [UUID]
    /// `Sidecars/` entries whose name isn't even a well-formed UUID —
    /// too malformed to safely treat as an orphan (it may not be this
    /// store's data at all) and left completely untouched. Contains only
    /// each entry's own directory name, never a full path.
    public let ignoredSidecarEntries: [String]
    /// Pending records that matched the remembered active document and
    /// were promoted to `.committed` — the app survived far enough to hand
    /// this document off to the user before being killed.
    public let promotedPendingIDs: [UUID]
    /// Pending records that did *not* match the active document (or there
    /// was none) and were rolled back — record, sidecar, and (for
    /// `.appCopy`) its `Documents/` copy.
    public let rolledBackPendingIDs: [UUID]
    /// Entries that could not be fully resolved, keyed by id, with a
    /// fixed, path-free diagnostic description. Left in place for a later
    /// call to retry.
    public let failures: [UUID: String]
    /// `true` when the active-document pointer itself could not be read or
    /// decoded (`ActiveDocumentPointer.corrupt`). When this is `true`,
    /// pass 2 (every pending record) was skipped entirely — promoting or
    /// rolling back *anything* while the pointer's own content can't be
    /// trusted risks acting on the wrong document. Orphan copy/sidecar
    /// directories with no record at all (`removedOrphanIDs`/
    /// `removedOrphanSidecarIDs`) are unaffected, since that determination
    /// never depended on the pointer.
    public let activePointerWasUnreadable: Bool

    public init(
        removedOrphanIDs: [UUID],
        removedOrphanSidecarIDs: [UUID] = [],
        ignoredSidecarEntries: [String] = [],
        promotedPendingIDs: [UUID] = [],
        rolledBackPendingIDs: [UUID] = [],
        failures: [UUID: String],
        activePointerWasUnreadable: Bool = false
    ) {
        self.removedOrphanIDs = removedOrphanIDs
        self.removedOrphanSidecarIDs = removedOrphanSidecarIDs
        self.ignoredSidecarEntries = ignoredSidecarEntries
        self.promotedPendingIDs = promotedPendingIDs
        self.rolledBackPendingIDs = rolledBackPendingIDs
        self.failures = failures
        self.activePointerWasUnreadable = activePointerWasUnreadable
    }
}

/// Result of `PhotoDocumentStore.committedDocuments()`.
public struct PhotoDocumentListing: Equatable, Sendable {
    /// Every committed document whose record decoded cleanly and whose
    /// working file was confirmed present, in stable ascending `UUID`
    /// order.
    public let documents: [PhotoDocument]
    /// Committed-looking records that could not be read back, keyed by the
    /// `UUID` their filename names, with a fixed, path-free diagnostic —
    /// never `(error as NSError).localizedDescription`, which can embed an
    /// absolute path. A `.pending` record is never reported here: it is
    /// simply absent from both `documents` and `failures`, exactly as
    /// `reconcileOrphanedImports(activePointer:)` alone is responsible for
    /// promoting or rolling it back.
    public let failures: [UUID: String]

    public init(documents: [PhotoDocument], failures: [UUID: String]) {
        self.documents = documents
        self.failures = failures
    }
}
