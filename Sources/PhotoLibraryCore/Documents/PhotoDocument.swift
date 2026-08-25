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

    public init(
        id: UUID = UUID(),
        storageMode: PhotoDocumentStorageMode,
        workingURL: URL,
        sourceURL: URL,
        sourceBookmarkData: Data?,
        sourceFingerprint: FileFingerprint,
        workingFingerprint: FileFingerprint
    ) {
        self.id = id
        self.storageMode = storageMode
        self.workingURL = workingURL
        self.sourceURL = sourceURL
        self.sourceBookmarkData = sourceBookmarkData
        self.sourceFingerprint = sourceFingerprint
        self.workingFingerprint = workingFingerprint
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
public struct PhotoDocumentRollbackReport: Equatable, Sendable {
    public enum StepResult: Equatable, Sendable {
        /// This step doesn't apply to this document's storage mode (e.g.
        /// `copy` for an `.inPlace` document).
        case notApplicable
        case succeeded
        case failed
    }

    /// Whether the root import lock was acquired — only meaningful for
    /// `.appCopy`, where removing the App-storage copy needs it.
    public let lock: StepResult
    public let record: StepResult
    public let sidecar: StepResult
    public let copy: StepResult

    public init(lock: StepResult, record: StepResult, sidecar: StepResult, copy: StepResult) {
        self.lock = lock
        self.record = record
        self.sidecar = sidecar
        self.copy = copy
    }

    /// `true` only when every applicable step actually succeeded — a
    /// caller that only checks this, rather than the individual steps, is
    /// still told the truth about whether anything was left behind.
    public var isFullyCleaned: Bool {
        [lock, record, sidecar, copy].allSatisfy { $0 != .failed }
    }
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
