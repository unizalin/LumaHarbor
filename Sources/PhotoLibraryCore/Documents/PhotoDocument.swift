import Foundation

/// Whether a single-photo document works directly on the RAW at its original
/// location, or on a verified copy inside App storage.
public enum PhotoDocumentStorageMode: String, Codable, Equatable, Sendable {
    case inPlace
    case appCopy
}

/// Identity and file locations for one photo opened outside a full library —
/// the iPad single-photo workflow. The RAW at `sourceURL` is never written to;
/// edits target `workingURL` and its sidecar only.
public struct PhotoDocument: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let storageMode: PhotoDocumentStorageMode
    /// The file adjustments and decoding read from. Equal to `sourceURL` in
    /// `.inPlace` mode; a verified copy inside App storage in `.appCopy` mode.
    public let workingURL: URL
    public let sourceURL: URL
    /// Security-scoped bookmark for `sourceURL`, when the caller supplied one.
    public let sourceBookmarkData: Data?
    /// Identity of the source *as it was at the moment this document was
    /// imported* — not a live description of whatever the source currently
    /// is. For `.appCopy`, this is derived from the verified copy itself
    /// (see `PhotoDocumentStore.importCopy`), so it equals
    /// `workingFingerprint` by construction. If the external source changes
    /// again after import, a later relink/verification pass comparing a
    /// fresh source fingerprint against this one is expected to see a
    /// mismatch — that is what surfaces the change, not this field updating
    /// on its own.
    public let sourceFingerprint: FileFingerprint
    public let workingFingerprint: FileFingerprint
    /// Streaming SHA-256 over the *entire* working file, computed once when
    /// the document is created (see `ContentDigestCalculator`) — unlike
    /// `sourceFingerprint`/`workingFingerprint`, which only sample the first
    /// and last MiB of a file over `FingerprintCalculator.wholeFileThreshold`.
    /// This is what `relinkInPlaceDocument` compares against a relink
    /// candidate, since a sampled fingerprint cannot prove full-file
    /// identity for a large RAW. `nil` only for a document created before
    /// this field existed; see `RelinkError` for how relink handles that.
    public let contentDigestSHA256: String?

    public init(
        id: UUID = UUID(),
        storageMode: PhotoDocumentStorageMode,
        workingURL: URL,
        sourceURL: URL,
        sourceBookmarkData: Data?,
        sourceFingerprint: FileFingerprint,
        workingFingerprint: FileFingerprint,
        contentDigestSHA256: String? = nil
    ) {
        self.id = id
        self.storageMode = storageMode
        self.workingURL = workingURL
        self.sourceURL = sourceURL
        self.sourceBookmarkData = sourceBookmarkData
        self.sourceFingerprint = sourceFingerprint
        self.workingFingerprint = workingFingerprint
        self.contentDigestSHA256 = contentDigestSHA256
    }
}

/// A `PhotoDocument` just produced by `PhotoDocumentStore.openInPlace`/
/// `importCopy`, paired with an unforgeable receipt that is the *only* way
/// to roll that specific creation back via `PhotoDocumentStore
/// .rollbackNewDocument(_:)`.
///
/// `receipt` is deliberately not `public` and this type has no public
/// initializer: a caller outside `PhotoLibraryCore` can read `document`
/// (everything it needs for the rest of the opening flow) but cannot
/// construct a `PhotoDocumentCreation` of its own — not for a document it
/// just created (only the store can mint one) and not for an existing
/// document it loaded via `loadDocument` (which returns a bare
/// `PhotoDocument`, never this type). That is what makes
/// `rollbackNewDocument(_:)` safe to expose publicly without also exposing
/// a way to delete arbitrary existing documents.
public struct PhotoDocumentCreation: Sendable {
    public let document: PhotoDocument
    let receipt: UUID

    init(document: PhotoDocument, receipt: UUID) {
        self.document = document
        self.receipt = receipt
    }
}

/// Structured result of `PhotoDocumentStore.rollbackNewDocument(_:)`, one
/// entry per step it attempts — never collapsed to a single `Bool`, so a
/// caller can tell exactly what did and didn't get cleaned up.
///
/// Only `PhotoDocumentStore` constructs this — the initializer is
/// module-internal so a client cannot fabricate a report (e.g. a fake
/// `.cleaned` outcome) and act as though cleanup happened when it didn't.
public struct PhotoDocumentRollbackReport: Equatable, Sendable {
    public enum StepResult: Equatable, Sendable {
        /// This step doesn't apply to this document's storage mode (e.g.
        /// `copy` for an `.inPlace` document), or wasn't attempted because
        /// the receipt didn't warrant it (see `Outcome`).
        case notApplicable
        case succeeded
        case failed
    }

    /// Mutually exclusive top-level result. Only `.cleaned` means every
    /// applicable step actually succeeded and the receipt was consumed;
    /// every other case leaves both disk and the receipt exactly as they
    /// were before the call.
    public enum Outcome: Equatable, Sendable {
        /// Every applicable step succeeded; the receipt is now consumed
        /// and can never be used again.
        case cleaned
        /// At least one applicable step failed (including "couldn't even
        /// acquire the root lock"); nothing was deleted, and the receipt
        /// is still valid — safe to call again, once whatever's blocking
        /// the failing step clears.
        case retryRequired
        /// This creation was already finalized (kept) by an earlier call;
        /// nothing was touched.
        case alreadyFinalized
        /// This creation was already rolled back by an earlier call;
        /// nothing was touched.
        case alreadyRolledBack
        /// The receipt isn't one this store instance recognizes at all.
        /// Should be unreachable given `PhotoDocumentCreation`'s contract,
        /// but never treated as success if it somehow occurs.
        case unknownReceipt
    }

    public let outcome: Outcome
    /// Whether the root import lock was acquired — only meaningful for
    /// `.appCopy`, where removing the App-storage copy needs it.
    public let lock: StepResult
    public let record: StepResult
    public let sidecar: StepResult
    public let copy: StepResult

    init(outcome: Outcome, lock: StepResult, record: StepResult, sidecar: StepResult, copy: StepResult) {
        self.outcome = outcome
        self.lock = lock
        self.record = record
        self.sidecar = sidecar
        self.copy = copy
    }

    /// `true` only for `Outcome.cleaned` — every other outcome (including
    /// "already finalized"/"already rolled back", which report every step
    /// as `.notApplicable` since nothing was attempted) is *not* success
    /// from a caller's point of view and must not be read as one.
    public var isFullyCleaned: Bool {
        outcome == .cleaned
    }
}

/// Result of `PhotoDocumentStore.finalizeCreation(_:)`.
public enum PhotoDocumentFinalizeOutcome: Equatable, Sendable {
    /// The record was durably written as `.committed`. The receipt is now
    /// consumed and the creation's per-document lease has been released.
    case committed
    /// The durable write did not succeed (couldn't load the record, encode
    /// it, or write it to disk). The record is still `.pending`, the
    /// receipt is still valid, and the per-document lease is still held —
    /// safe, and necessary, to call again once whatever's blocking the
    /// write clears.
    case retryRequired
    /// This creation was already finalized by an earlier call; nothing was
    /// touched.
    case alreadyFinalized
    /// This creation was already rolled back by an earlier call; nothing
    /// was touched.
    case alreadyRolledBack
    /// The receipt isn't one this store instance recognizes at all. Should
    /// be unreachable given `PhotoDocumentCreation`'s contract.
    case unknownReceipt
}

public enum PhotoDocumentError: Error, Equatable, Sendable {
    /// The copy's bytes didn't match the source after copying. The partial
    /// copy and any document record have already been removed.
    case copyVerificationFailed
    /// The source file's size, modification date, or resource identifier
    /// changed between the start of the copy and the end of verification —
    /// the copy may no longer describe the source it was taken from. The
    /// partial copy and any document record have already been removed.
    case sourceModifiedDuringImport
    /// Another import or a reconciliation pass already holds the root-level
    /// import lock for this store's `rootURL` — from this store instance,
    /// another instance in this process, or another process entirely.
    /// Nothing was changed; retry once the other operation has finished.
    case importInProgress
    case documentNotFound(UUID)
}

/// Thrown by `PhotoDocumentStore.relinkInPlaceDocument(documentID:candidateURL:bookmarkData:)`.
public enum RelinkError: Error, Equatable, Sendable {
    /// The document being relinked isn't `.inPlace` — an `.appCopy`
    /// document never loses access to its working file this way.
    case notInPlace
    /// `candidateURL`'s full-content digest doesn't match the document's
    /// stored `contentDigestSHA256`. Nothing was changed.
    case contentMismatch
    /// The document predates full-content digests (`contentDigestSHA256
    /// == nil`) and `candidateURL`'s *sampled* fingprint doesn't match the
    /// document's original `sourceFingerprint`. This legacy path is a
    /// weaker guarantee than `.contentMismatch` — see
    /// `PhotoDocumentStore.relinkInPlaceDocument` — but a mismatch here is
    /// still conclusive: nothing was changed.
    case fingerprintMismatch
    /// `candidateURL` changed (size, modification date, or resource
    /// identifier) between the start and end of verifying it — the file
    /// picked may no longer be the one that was actually checked. Nothing
    /// was changed.
    case sourceModifiedDuringRelink
}
