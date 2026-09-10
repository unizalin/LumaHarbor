import Foundation
import Localization
import RawProcessingCore

public struct LibraryScanResult: Sendable, Equatable {
    public var libraryID: LibraryID
    public var indexedCount: Int
    public var failedCount: Int
    public var ambiguousCount: Int
    public var movedCount: Int
    public var wasCancelled: Bool
    /// Set when the manifest could not be persisted — a read-only drive, for
    /// instance. The local index is still usable; the portable copy just didn't
    /// get updated.
    public var manifestWriteFailure: String?
    /// The failing error's own `recoverySuggestion`, when it has one. Callers
    /// showing `manifestWriteFailure` to the user should prefer this over any
    /// generic advice of their own — "unlock the drive" is correct for a
    /// read-only volume but actively wrong for e.g. insufficient disk space,
    /// and the two are indistinguishable from `manifestWriteFailure`'s plain
    /// text alone.
    public var manifestWriteRecoverySuggestion: String?
    public var completedAt: Date

    public init(
        libraryID: LibraryID,
        indexedCount: Int,
        failedCount: Int,
        ambiguousCount: Int,
        movedCount: Int,
        wasCancelled: Bool,
        manifestWriteFailure: String? = nil,
        manifestWriteRecoverySuggestion: String? = nil,
        completedAt: Date
    ) {
        self.libraryID = libraryID
        self.indexedCount = indexedCount
        self.failedCount = failedCount
        self.ambiguousCount = ambiguousCount
        self.movedCount = movedCount
        self.wasCancelled = wasCancelled
        self.manifestWriteFailure = manifestWriteFailure
        self.manifestWriteRecoverySuggestion = manifestWriteRecoverySuggestion
        self.completedAt = completedAt
    }
}

public enum LibraryScanEvent: Sendable {
    case started(LibraryID)
    /// A page of freshly indexed photos, for incremental display (spec §6.1).
    case photosIndexed([PhotoAsset])
    case photoFailed(relativePath: String, reason: String)
    case finished(LibraryScanResult)
    case failed(LibraryError)
}

public enum LibraryError: Error, Equatable, Sendable {
    case bookmark(BookmarkError)
    case sidecar(SidecarError)
    case offline(path: String)
    case notFound(LibraryID)
    case indexUnavailable(String)
    /// Spec §13.9: resetting the local index closes the live SQLite connection,
    /// which an active scan is still writing through.
    case resetRefusedWhileScanning
    case resetFailed(String)
    /// Spec §7: the folder being added is a reliably-detected ancestor or
    /// descendant of an already-known source. Rejected before any bookmark,
    /// in-memory, index, manifest, or source mutation, so nothing needs to be
    /// rolled back.
    case overlappingSource
    /// Spec §7 step 3: the folder being added shares only a bounded root
    /// fingerprint with an existing source — never a manifest `LibraryID` or
    /// a bookmark-resolved resource identifier. Never auto-relinked or
    /// auto-reused; the caller must ask the user to confirm before either
    /// adding it as new or reusing the named library.
    case ambiguousSource(LibraryID)
    /// Spec §7: the folder being added has a confirmed manifest `LibraryID`
    /// that disagrees with an already-known source's confirmed manifest
    /// `LibraryID`, even though other evidence (path, resource identifier)
    /// suggests they might be the same physical folder. A confirmed
    /// disagreement is never downgraded to a silent reuse.
    case manifestConflict(LibraryID)
    /// Spec §7: `relink(libraryID:to:)` was pointed at a folder that doesn't
    /// confirm as the same source being relinked. The bookmark, index and
    /// access scope for `libraryID` are left completely untouched.
    case relinkTargetMismatch(LibraryID)
    /// `removeLibrary` removed the authoritative bookmark but then failed to
    /// remove the rebuildable index rows, and the attempted bookmark rollback
    /// also failed. The actor's in-memory state and access scope are left
    /// untouched for this run, and callers must treat the removal as
    /// unresolved rather than successful.
    case removeLibraryRollbackFailed(
        libraryID: LibraryID,
        indexFailure: String,
        rollbackFailure: String
    )
    /// Phase 3 Task 3.5: `deleteVirtualCopy(_:)` refuses to run against a
    /// `PhotoAsset` that isn't itself a virtual copy (`variantOf == nil`) --
    /// this is never a "delete the original photo" operation.
    case notAVirtualCopy(PhotoID)
    /// A pending local registry transaction could not be rolled back. The
    /// journal remains in Application Support and all registry mutations stay
    /// blocked until a later recovery attempt succeeds.
    case registryRecoveryRequired
}

/// Safe, structured reason a remembered source could not be restored. These
/// values deliberately carry no paths or underlying error strings, so callers
/// can present them without exposing private filesystem details.
public enum LibraryRestoreDiagnostic: Equatable, Sendable {
    case authorizationFailure
    case manifestConflict
    case manifestMissing
    case corruptManifest
    case unsupportedManifest
    case manifestUnavailable
    case persistenceFailure
}

extension LibraryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .bookmark(let error): return error.errorDescription
        case .sidecar(let error): return error.errorDescription
        case .offline: return L10n.t("The drive holding this library isn't connected.")
        case .notFound: return L10n.t("That photo folder is no longer in your library list.")
        case .indexUnavailable(let message):
            return "\(L10n.t("The local index is unavailable.")) \(message)"
        case .resetRefusedWhileScanning:
            return L10n.t("The local index can't be reset while a scan is in progress.")
        case .resetFailed(let message):
            return "\(L10n.t("The local index couldn't be reset.")) \(message)"
        case .overlappingSource:
            return L10n.t("This folder overlaps a photo library you already added.")
        case .ambiguousSource:
            return L10n.t("LumaHarbor can't confirm whether this is a source you already added.")
        case .manifestConflict:
            return L10n.t("This folder's saved identity doesn't match a library you already added.")
        case .relinkTargetMismatch:
            return L10n.t("This folder doesn't match the library you're reconnecting.")
        case .removeLibraryRollbackFailed:
            return L10n.t("The photo folder couldn't be removed cleanly.")
        case .registryRecoveryRequired:
            return L10n.t("LumaHarbor couldn't safely recover a pending library change.")
        case .notAVirtualCopy:
            return L10n.t("This photo isn't a virtual copy.")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .bookmark(let error): return error.recoverySuggestion
        case .sidecar(let error): return error.recoverySuggestion
        case .offline: return L10n.t("Reconnect the drive, then try again.")
        case .notFound: return L10n.t("Add the folder again.")
        case .indexUnavailable: return L10n.t("Quit and reopen LumaHarbor to rebuild the index.")
        case .resetRefusedWhileScanning:
            return L10n.t("Wait for the current scan to finish, then try again.")
        case .resetFailed: return L10n.t("Quit and reopen LumaHarbor, then try again.")
        case .overlappingSource:
            return L10n.t("Choose a folder that doesn't contain, or sit inside, an existing library.")
        case .ambiguousSource:
            return L10n.t("Confirm whether this is the same source, then try again.")
        case .manifestConflict:
            return L10n.t("Choose a different folder, or confirm which library this one belongs to.")
        case .relinkTargetMismatch:
            return L10n.t("Choose the folder that holds this exact library, then try again.")
        case .removeLibraryRollbackFailed:
            return L10n.t("Quit and reopen LumaHarbor, then check whether the folder still appears before trying again.")
        case .registryRecoveryRequired:
            return L10n.t("Quit and reopen LumaHarbor, then try again.")
        case .notAVirtualCopy:
            return nil
        }
    }
}

/// Ties folder access, scanning, the index and sidecars together.
///
/// An actor because everything it touches — the SQLite handle, the security
/// scopes, the in-memory library table — is shared mutable state that the UI and
/// background scans both reach for.
public actor PhotoLibraryService {
    private let locations: ApplicationSupportLocations
    private let bookmarkStore: any BookmarkStoring
    private let registryTransactionStore: any RegistryTransactionStoring
    /// Replaceable so `resetRebuildableLocalData()` can swap in a fresh SQLite
    /// connection after closing this one, instead of the two ever being open
    /// on the same file at once.
    private var index: PhotoIndexStore
    private let decoder: any RawDecoding
    private let scanner: FolderScanner

    /// Held for the app's lifetime: dropping a `FolderAccessHandle` releases
    /// the security scope, so these must outlive every read of the folder.
    private var access: [LibraryID: any FolderAccessHandle] = [:]
    private var libraries: [LibraryID: LibraryFolder] = [:]
    private var restoreDiagnostics: [LibraryID: LibraryRestoreDiagnostic] = [:]
    /// Seam over resolving bookmarks/granting access (spec §7): the real
    /// implementation is `SystemFolderAccessResolver`; tests inject a fake
    /// so offline/needsAuthorization/stale-refresh/scope-pairing behaviour
    /// is verifiable deterministically, without a real removable volume.
    private let folderAccessResolver: any FolderAccessResolving
    private let resourceIdentityResolver: any ResourceIdentityResolving
    private let bookmarkDataCreator: any BookmarkDataCreating
    /// Schedules `scanLibraries`' per-source scans across a fixed two-slot
    /// budget (spec §9). Self-contained and not test-injectable: its own
    /// behavior is covered directly by `MultiSourceScanCoordinatorTests`.
    private let scanCoordinator = MultiSourceScanCoordinator()

    /// How long one file's fingerprint+decode inspection may run before it's
    /// treated as an unresponsive provider (an unreachable, cloud-backed
    /// Files folder that never answers a read) rather than a slow one.
    static let providerRequestTimeout: Duration = .seconds(30)
    /// Seam over waiting out that timeout: production really waits; a test
    /// substitutes a sleep that resolves immediately (while still recording
    /// what duration it was asked to wait), so the 30-second path is provable
    /// without an actual 30-second wait.
    private let providerTimeoutSleep: @Sendable (Duration) async throws -> Void

    /// How many `performScan` calls are currently running, across every
    /// library. Incremented at the top of `performScan` and decremented via
    /// `defer`, so every exit path — cancellation, early failure, normal
    /// completion — accounts for itself.
    private var activeScanCount = 0

    /// The scan each library is currently running. Anything older that comes
    /// back late is a ghost and must not write (addendum §3.5).
    private var currentScanGeneration: [LibraryID: UInt64] = [:]
    private var scanGenerationCounter: UInt64 = 0

    private func isCurrentScan(libraryID: LibraryID, generation: UInt64) -> Bool {
        currentScanGeneration[libraryID] == generation
    }

    public init(
        locations: ApplicationSupportLocations,
        bookmarkStore: (any BookmarkStoring)? = nil,
        decoder: any RawDecoding = CoreImageRawDecoder(),
        scanner: FolderScanner = FolderScanner(),
        folderAccessResolver: any FolderAccessResolving = SystemFolderAccessResolver(),
        resourceIdentityResolver: any ResourceIdentityResolving = SystemResourceIdentityResolver()
    ) throws {
        try self.init(
            locations: locations,
            bookmarkStore: bookmarkStore,
            decoder: decoder,
            scanner: scanner,
            folderAccessResolver: folderAccessResolver,
            resourceIdentityResolver: resourceIdentityResolver,
            bookmarkDataCreator: SystemBookmarkDataCreator(),
            registryTransactionStore: nil
        )
    }

    init(
        locations: ApplicationSupportLocations,
        bookmarkStore: (any BookmarkStoring)? = nil,
        decoder: any RawDecoding = CoreImageRawDecoder(),
        scanner: FolderScanner = FolderScanner(),
        folderAccessResolver: any FolderAccessResolving = SystemFolderAccessResolver(),
        resourceIdentityResolver: any ResourceIdentityResolving = SystemResourceIdentityResolver(),
        bookmarkDataCreator: any BookmarkDataCreating = SystemBookmarkDataCreator(),
        registryTransactionStore: (any RegistryTransactionStoring)?,
        providerTimeoutSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) throws {
        try locations.createDirectories()
        self.locations = locations
        self.bookmarkStore = bookmarkStore
            ?? FileBookmarkStore(directoryURL: locations.bookmarksDirectoryURL)
        self.registryTransactionStore = registryTransactionStore
            ?? FileRegistryTransactionStore(directoryURL: locations.registryTransactionsDirectoryURL)
        self.index = try PhotoIndexStore(databaseURL: locations.databaseURL)
        self.decoder = decoder
        self.scanner = scanner
        self.folderAccessResolver = folderAccessResolver
        self.resourceIdentityResolver = resourceIdentityResolver
        self.bookmarkDataCreator = bookmarkDataCreator
        self.providerTimeoutSleep = providerTimeoutSleep
    }

    public var indexStore: PhotoIndexStore { index }

    // MARK: - Libraries

    public func knownLibraries() -> [LibraryFolder] {
        libraries.values.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    public func library(id: LibraryID) -> LibraryFolder? {
        libraries[id]
    }

    public func restoreDiagnostic(for libraryID: LibraryID) -> LibraryRestoreDiagnostic? {
        restoreDiagnostics[libraryID]
    }

    /// Registers a folder the user just picked. The open panel has already
    /// granted access, so this only has to remember it (spec §7).
    ///
    /// The whole decision is a strictly read-only, order-independent
    /// preflight (spec §7): every currently-known library's relationship to
    /// the candidate is collected up front — nothing is mutated while doing
    /// so — before any bookmark, index, in-memory or source mutation
    /// happens. A reliably-detected exact match focuses the existing source
    /// instead of duplicating it; a reliably-detected parent/child overlap,
    /// a confirmed manifest conflict, or an ambiguous match (no manifest ID
    /// or resource identifier agrees, only a bounded fingerprint) is
    /// rejected outright rather than silently guessed either way; more than
    /// one confirmed match is itself treated as ambiguous.
    @discardableResult
    public func addLibrary(
        at url: URL,
        displayName: String? = nil,
        sourceKind: LibrarySourceKind = .externalFolder
    ) throws -> LibraryFolder {
        try recoverPendingRegistryTransaction()
        let repository = FileSidecarRepository(libraryRootURL: url)
        let confirmedManifestID = try Self.requireConfirmedManifestID(
            from: repository.probeManifest(), path: url.path
        )
        let candidateIdentity = LibrarySourceIdentity.resolve(
            url: url,
            confirmedManifestLibraryID: confirmedManifestID,
            resourceIdentityResolver: resourceIdentityResolver
        )

        switch try preflightDecision(for: candidateIdentity) {
        case .reject(let error):
            throw error
        case .focus(let existing):
            return try focusExistingLibrary(
                existing, at: url, displayName: displayName,
                candidateIdentity: candidateIdentity, repository: repository
            )
        case .addNew:
            return try createNewLibrary(
                at: url, displayName: displayName, sourceKind: sourceKind,
                confirmedManifestID: confirmedManifestID,
                candidateIdentity: candidateIdentity, repository: repository
            )
        }
    }

    private enum PreflightOutcome {
        case addNew
        case focus(LibraryFolder)
        case reject(LibraryError)
    }

    /// Compares `candidate` against *every* currently-known library, then
    /// decides using a fixed precedence over the whole collected set (spec
    /// §7): nothing is decided — or mutated — while iterating, and the
    /// specific error/outcome returned does not depend on `Dictionary`
    /// iteration order, only on the (order-independent) set of
    /// relationships found. Precedence, strongest first: any `.conflict`;
    /// any `.ancestor`/`.descendant` overlap; any `.ambiguous`; more than one
    /// `.same` match (itself a data inconsistency, treated as ambiguous);
    /// exactly one `.same` match focuses it; otherwise every relationship is
    /// `.distinct` and a fresh library is added.
    ///
    /// Propagates a `bookmarkStore.load` failure for any known library
    /// rather than treating a lookup failure as "no identity" (spec §7):
    /// an I/O or decode error must fail the whole preflight closed, never
    /// silently read as `.distinct`.
    private func preflightDecision(for candidate: LibrarySourceIdentity) throws -> PreflightOutcome {
        struct Match {
            let library: LibraryFolder
            let relationship: SourceRelationship
        }

        var matches: [Match] = []
        for existing in libraries.values {
            let relationship = try identity(for: existing).relationship(to: candidate)
            matches.append(Match(library: existing, relationship: relationship))
        }
        // Stable, content-derived order so the specific error/library
        // reported never depends on `Dictionary`'s iteration order.
        matches.sort { $0.library.id.description < $1.library.id.description }

        if let conflict = matches.first(where: { $0.relationship == .conflict }) {
            return .reject(.manifestConflict(conflict.library.id))
        }
        if matches.contains(where: { $0.relationship == .ancestor || $0.relationship == .descendant }) {
            return .reject(.overlappingSource)
        }
        if let ambiguous = matches.first(where: { $0.relationship == .ambiguous }) {
            return .reject(.ambiguousSource(ambiguous.library.id))
        }

        let sameMatches = matches.filter { $0.relationship == .same }.map(\.library)
        switch sameMatches.count {
        case 0: return .addNew
        case 1: return .focus(sameMatches[0])
        default:
            // Two different known libraries both confirm as the same
            // candidate: a data inconsistency, not a safe auto-pick between
            // them (spec §7).
            return .reject(.ambiguousSource(sameMatches[0].id))
        }
    }

    /// Classifies a read-only manifest probe into either a confirmed
    /// manifest `LibraryID` (or `nil` for a folder that simply has none yet)
    /// or a thrown, safe error — corrupt/unsupported-schema/unavailable must
    /// abort the add/focus/relink outright, never be silently treated as
    /// "no manifest" (spec §7).
    private static func requireConfirmedManifestID(
        from probe: ManifestProbeResult,
        path: String
    ) throws -> LibraryID? {
        switch probe {
        case .absent:
            return nil
        case .valid(let manifest):
            return manifest.libraryID
        case .corrupt(let reason):
            throw LibraryError.sidecar(.corruptManifest(quarantinedAt: nil, reason: reason))
        case .unsupportedSchema(let found, let supported):
            throw LibraryError.sidecar(.unsupportedSchemaVersion(found: found, supported: supported))
        case .unavailable:
            throw LibraryError.offline(path: path)
        }
    }

    private enum RestoreManifestValidation {
        case accepted(confirmedID: LibraryID?, requiresBackfill: Bool)
        case blocked(LibraryRestoreDiagnostic)
    }

    private static func validateManifestForRestore(
        persisted: LibraryID?,
        ownLibraryID: LibraryID,
        probe: ManifestProbeResult
    ) -> RestoreManifestValidation {
        switch probe {
        case .valid(let manifest):
            if let persisted {
                return persisted == manifest.libraryID
                    ? .accepted(confirmedID: persisted, requiresBackfill: false)
                    : .blocked(.manifestConflict)
            }
            return manifest.libraryID == ownLibraryID
                ? .accepted(confirmedID: ownLibraryID, requiresBackfill: true)
                : .blocked(.manifestConflict)
        case .absent:
            return persisted == nil
                ? .accepted(confirmedID: nil, requiresBackfill: false)
                : .blocked(.manifestMissing)
        case .corrupt:
            return .blocked(.corruptManifest)
        case .unsupportedSchema:
            return .blocked(.unsupportedManifest)
        case .unavailable:
            return .blocked(.manifestUnavailable)
        }
    }

    private func makeBookmarkData(for url: URL) throws -> Data {
        do {
            return try bookmarkDataCreator.makeBookmarkData(for: url)
        } catch let error as BookmarkError {
            throw LibraryError.bookmark(error)
        }
    }

    /// Mints a brand-new `LibraryFolder` for a candidate the preflight found
    /// no relationship to any known library for.
    ///
    /// Guards against a `LibraryID` collision before any mutation (spec §7):
    /// even though the preflight found nothing matching, a drifted or
    /// corrupted confirmed-ID record could in principle let two different
    /// physical folders both claim the same `LibraryID` — this never
    /// silently overwrites an existing `libraries` entry or bookmark record,
    /// it rejects.
    ///
    /// Otherwise staged so a mid-way failure can never leave
    /// `access`/`libraries` pointing at a source the persistent stores don't
    /// agree on: for a folder with no manifest yet, the manifest is written
    /// *before* anything is persisted, so a successful write and the
    /// confirmed ID it establishes land in the exact same bookmark save —
    /// never a separate best-effort backfill that could leave the disk
    /// manifest and the local registry disagreeing. The bookmark is written
    /// first, the index second — an index failure rolls the just-written
    /// bookmark back out — and only once both stores agree does this touch
    /// the security scope or in-memory state at all.
    private func createNewLibrary(
        at url: URL,
        displayName: String?,
        sourceKind: LibrarySourceKind,
        confirmedManifestID: LibraryID?,
        candidateIdentity: LibrarySourceIdentity,
        repository: FileSidecarRepository
    ) throws -> LibraryFolder {
        let libraryID = confirmedManifestID ?? LibraryID()

        guard libraries[libraryID] == nil else {
            throw LibraryError.manifestConflict(libraryID)
        }
        guard try bookmarkStore.load(libraryID: libraryID) == nil else {
            throw LibraryError.manifestConflict(libraryID)
        }
        guard try index.library(id: libraryID) == nil,
              try index.photoCount(inLibrary: libraryID) == 0 else {
            throw LibraryError.manifestConflict(libraryID)
        }

        let bookmarkData = try makeBookmarkData(for: url)

        var confirmedID = confirmedManifestID
        if confirmedID == nil, repository.isWritable,
           (try? repository.write(manifest: LibraryManifest(libraryID: libraryID))) != nil {
            confirmedID = libraryID
        }

        let folder = LibraryFolder(
            id: libraryID,
            displayName: displayName ?? url.lastPathComponent,
            rootURL: url,
            sourceKind: sourceKind,
            connectionState: repository.isWritable ? .ready : .readOnly,
            scanState: .idle
        )

        let storedBookmark = StoredBookmark(
            libraryID: libraryID,
            displayName: folder.displayName,
            lastKnownPath: url.path,
            bookmarkData: bookmarkData,
            sourceKind: sourceKind,
            scanState: .idle,
            confirmedManifestLibraryID: confirmedID,
            resourceIdentifier: candidateIdentity.resourceIdentifier,
            volumeIdentifier: candidateIdentity.volumeIdentifier,
            rootFingerprint: candidateIdentity.rootFingerprint
        )

        try applyRegistryTransaction(
            kind: .freshAdd,
            previousBookmark: nil,
            intendedBookmark: storedBookmark,
            previousLibrary: nil,
            intendedLibrary: folder
        )

        // COMMIT: only now touch the security scope and in-memory state,
        // now that both persistent stores agree.
        access[libraryID] = folderAccessResolver.grant(url: url)
        libraries[libraryID] = folder
        restoreDiagnostics.removeValue(forKey: libraryID)

        return folder
    }

    /// Re-points an already-known library at the exact folder the user just
    /// picked again, rather than minting a second `LibraryFolder` for the
    /// same physical location (spec §7). Shared by `addLibrary`'s `.same`
    /// branch and by `relink`; `displayName` is preserved when none is
    /// supplied, instead of being derived from the URL.
    ///
    /// The baseline read must fail closed, not be swallowed into "no
    /// previous bookmark" — that would make a later rollback *delete* a
    /// perfectly good existing record instead of restoring it (spec §7).
    /// Otherwise it uses the same durable rollback-to-old-state journal as
    /// `createNewLibrary`. A mid-way failure never touches actor memory or
    /// access. If rollback cannot finish, the journal stays in Application
    /// Support, a safe `.registryRecoveryRequired` error is returned, and a
    /// later same-session or restart recovery deterministically restores the
    /// old bookmark/index snapshot before any other registry mutation runs.
    private func focusExistingLibrary(
        _ existing: LibraryFolder,
        at url: URL,
        displayName: String?,
        candidateIdentity: LibrarySourceIdentity,
        repository: FileSidecarRepository,
        transactionKind: RegistryTransactionKind = .focus
    ) throws -> LibraryFolder {
        let previousStoredBookmark = try bookmarkStore.load(libraryID: existing.id)

        let bookmarkData = try makeBookmarkData(for: url)

        var folder = existing
        folder.rootURL = url
        folder.lastKnownPath = url.path
        folder.connectionState = repository.isWritable ? .ready : .readOnly
        if let displayName {
            folder.displayName = displayName
        }

        let newStoredBookmark = StoredBookmark(
            libraryID: existing.id,
            displayName: folder.displayName,
            lastKnownPath: url.path,
            bookmarkData: bookmarkData,
            sourceKind: existing.sourceKind,
            scanState: folder.scanState,
            confirmedManifestLibraryID: candidateIdentity.confirmedManifestLibraryID,
            resourceIdentifier: candidateIdentity.resourceIdentifier,
            volumeIdentifier: candidateIdentity.volumeIdentifier,
            rootFingerprint: candidateIdentity.rootFingerprint
        )

        let previousLibrary = try index.library(id: existing.id) ?? existing
        try applyRegistryTransaction(
            kind: transactionKind,
            previousBookmark: previousStoredBookmark,
            intendedBookmark: newStoredBookmark,
            previousLibrary: previousLibrary,
            intendedLibrary: folder
        )

        access[existing.id]?.stop()
        access[existing.id] = folderAccessResolver.grant(url: url)
        libraries[existing.id] = folder
        restoreDiagnostics.removeValue(forKey: existing.id)

        return folder
    }

    /// Explicit retry hook for UI/startup code after a safe
    /// `.registryRecoveryRequired` failure. Every mutating public entry point
    /// also invokes the same recovery automatically before doing any work.
    public func recoverPendingRegistryChanges() throws {
        try recoverPendingRegistryTransaction()
    }

    private func applyRegistryTransaction(
        kind: RegistryTransactionKind,
        previousBookmark: StoredBookmark?,
        intendedBookmark: StoredBookmark,
        previousLibrary: LibraryFolder?,
        intendedLibrary: LibraryFolder
    ) throws {
        try recoverPendingRegistryTransaction()

        let record = RegistryTransactionRecord(
            transactionID: UUID(),
            libraryID: intendedBookmark.libraryID,
            kind: kind,
            previousBookmark: previousBookmark,
            intendedBookmark: intendedBookmark,
            previousLibrary: previousLibrary.map(LibraryFolderSnapshot.init),
            intendedLibrary: LibraryFolderSnapshot(intendedLibrary)
        )
        try record.validate()

        // PREPARE: no bookmark/index mutation is legal before this durable
        // record exists.
        try registryTransactionStore.save(record)

        do {
            try bookmarkStore.save(intendedBookmark)
            try index.upsert(library: intendedLibrary)
            // Commit point. Actor memory/access is updated by the caller only
            // after this non-rebuildable record has durably disappeared.
            try registryTransactionStore.remove()
        } catch let operationError {
            do {
                try rollbackRegistryTransaction(record)
                try registryTransactionStore.remove()
            } catch {
                throw LibraryError.registryRecoveryRequired
            }
            throw operationError
        }
    }

    private func recoverPendingRegistryTransaction() throws {
        let pending: RegistryTransactionRecord?
        do {
            pending = try registryTransactionStore.load()
        } catch {
            throw LibraryError.registryRecoveryRequired
        }
        guard let pending else { return }

        do {
            try pending.validate()
            try rollbackRegistryTransaction(pending)
            try registryTransactionStore.remove()
        } catch {
            throw LibraryError.registryRecoveryRequired
        }
    }

    /// Idempotent rollback-to-old-state. Both stores are attempted even when
    /// the first one fails, so a later retry can finish whichever half still
    /// differs. The journal is cleared only by the caller after both succeed.
    private func rollbackRegistryTransaction(_ record: RegistryTransactionRecord) throws {
        try record.validate()
        var firstError: Error?

        do {
            if let previousBookmark = record.previousBookmark {
                try bookmarkStore.save(previousBookmark)
            } else {
                try bookmarkStore.remove(libraryID: record.libraryID)
            }
        } catch {
            firstError = error
        }

        do {
            if let previousLibrary = record.previousLibrary {
                try index.upsert(library: previousLibrary.folder)
            } else {
                switch record.kind {
                case .freshAdd:
                    // The collision gate proved the ID had no pre-existing
                    // rows, so everything written by this failed add is an
                    // orphan and may be removed together.
                    try index.removeLibrary(id: record.libraryID)
                case .focus, .relink, .restoreRefresh:
                    // Existing-source rollback must preserve exact photo rows
                    // even when the old index happened to lack its library
                    // metadata row.
                    try index.removeLibraryMetadata(id: record.libraryID)
                }
            }
        } catch {
            if firstError == nil { firstError = error }
        }

        if let firstError { throw firstError }
    }

    /// The identity a currently-known library presents for overlap/reuse
    /// comparison (spec §7): its confirmed manifest `LibraryID` (if any) and
    /// resource/volume identity are read from its persisted bookmark record,
    /// never assumed from its own in-memory `LibraryID` — so an offline or
    /// never-manifested source compares only on evidence that's actually
    /// been confirmed. Live path/volume data is added only while the source
    /// is actually reachable right now, so ancestor/descendant detection
    /// never fires against an offline source's stale path.
    ///
    /// Throws on a bookmark-store I/O or decode failure rather than
    /// swallowing it (spec §7): a lookup that fails is not the same as a
    /// source with no identity, and treating it as `.distinct` would let a
    /// transient read glitch silently defeat overlap/conflict detection.
    private func identity(for folder: LibraryFolder) throws -> LibrarySourceIdentity {
        let stored = try bookmarkStore.load(libraryID: folder.id)
        var resourceIdentifier = stored?.resourceIdentifier
        var volumeIdentifier = stored?.volumeIdentifier
        var canonicalLivePath: String?
        var caseSensitivity: PathCaseSensitivity = .unknown

        if folder.isOnline {
            let live = LibrarySourceIdentity.resolve(
                url: folder.rootURL,
                confirmedManifestLibraryID: stored?.confirmedManifestLibraryID,
                resourceIdentityResolver: resourceIdentityResolver
            )
            resourceIdentifier = resourceIdentifier ?? live.resourceIdentifier
            volumeIdentifier = volumeIdentifier ?? live.volumeIdentifier
            canonicalLivePath = live.canonicalLivePath
            caseSensitivity = live.canonicalLivePathCaseSensitivity
        }

        return LibrarySourceIdentity(
            confirmedManifestLibraryID: stored?.confirmedManifestLibraryID,
            resourceIdentifier: resourceIdentifier,
            volumeIdentifier: volumeIdentifier,
            rootFingerprint: stored?.rootFingerprint,
            canonicalLivePath: canonicalLivePath,
            canonicalLivePathCaseSensitivity: caseSensitivity
        )
    }

    /// Restores every remembered folder at launch (spec §7).
    ///
    /// A bookmark that no longer resolves is reported as offline rather than
    /// dropped — the user's edits are on that drive, and guessing at another
    /// path is explicitly forbidden.
    @discardableResult
    public func restoreLibraries() throws -> [LibraryFolder] {
        try recoverPendingRegistryTransaction()
        let stored = try bookmarkStore.loadAll()
        var restored: [LibraryFolder] = []

        let storedIDs = Set(stored.map(\.libraryID))
        for libraryID in Array(libraries.keys) where !storedIDs.contains(libraryID) {
            access.removeValue(forKey: libraryID)?.stop()
            libraries.removeValue(forKey: libraryID)
            restoreDiagnostics.removeValue(forKey: libraryID)
        }

        for bookmark in stored {
            var folder = LibraryFolder(
                id: bookmark.libraryID,
                displayName: bookmark.displayName,
                rootURL: URL(fileURLWithPath: bookmark.lastKnownPath, isDirectory: true),
                lastKnownPath: bookmark.lastKnownPath,
                sourceKind: bookmark.sourceKind,
                connectionState: .needsAuthorization,
                scanState: bookmark.scanState.normalizedForRestore
            )
            let persistedFolder = folder

            let stagedAccess: any FolderAccessHandle
            do {
                stagedAccess = try folderAccessResolver.resolve(bookmarkData: bookmark.bookmarkData)
            } catch {
                folder.connectionState = .needsAuthorization
                folder = try commitDisconnectedRestore(
                    folder: folder,
                    diagnostic: .authorizationFailure,
                    stagedAccess: nil
                )
                restored.append(folder)
                continue
            }

            guard stagedAccess.isReachable else {
                folder.connectionState = .offline
                folder = try commitDisconnectedRestore(
                    folder: folder,
                    diagnostic: nil,
                    stagedAccess: stagedAccess
                )
                restored.append(folder)
                continue
            }

            let repository = FileSidecarRepository(libraryRootURL: stagedAccess.url)
            folder.rootURL = stagedAccess.url
            folder.lastKnownPath = stagedAccess.url.path

            let validation = Self.validateManifestForRestore(
                persisted: bookmark.confirmedManifestLibraryID,
                ownLibraryID: bookmark.libraryID,
                probe: repository.probeManifest()
            )
            guard case .accepted(let confirmedID, let requiresBackfill) = validation else {
                guard case .blocked(let diagnostic) = validation else { preconditionFailure() }
                folder.connectionState = .needsAuthorization
                folder = try commitDisconnectedRestore(
                    folder: folder,
                    diagnostic: diagnostic,
                    stagedAccess: stagedAccess
                )
                restored.append(folder)
                continue
            }

            var updatedBookmark = bookmark
            var requiresSave = requiresBackfill
            updatedBookmark.confirmedManifestLibraryID = confirmedID

            if stagedAccess.isStale {
                do {
                    let refreshed = try makeBookmarkData(for: stagedAccess.url)
                    let refreshedIdentity = LibrarySourceIdentity.resolve(
                        url: stagedAccess.url,
                        confirmedManifestLibraryID: confirmedID,
                        resourceIdentityResolver: resourceIdentityResolver
                    )
                    updatedBookmark.bookmarkData = refreshed
                    updatedBookmark.lastKnownPath = stagedAccess.url.path
                    updatedBookmark.resourceIdentifier = refreshedIdentity.resourceIdentifier
                    updatedBookmark.volumeIdentifier = refreshedIdentity.volumeIdentifier
                    updatedBookmark.rootFingerprint = refreshedIdentity.rootFingerprint
                    requiresSave = true
                } catch {
                    // `folder` was already re-pointed at the newly resolved
                    // (uncommitted) root above, and no registry transaction
                    // was ever prepared for this failure to roll back. Rebuild
                    // the blocked result from the last known-good durable
                    // projection so the uncommitted root can never reach
                    // SQLite or actor-visible state.
                    let priorProjection: LibraryFolder?
                    do {
                        priorProjection = try index.library(id: folder.id)
                    } catch {
                        // The service cannot safely construct a blocked
                        // projection either. The staged B handle must not be
                        // leaked, but the old A actor/access state, bookmark,
                        // SQLite and diagnostic must be left completely
                        // untouched -- there is nothing safe to commit, so
                        // this propagates rather than inventing a result.
                        stagedAccess.stop()
                        throw error
                    }
                    folder = priorProjection ?? persistedFolder
                    folder.connectionState = .needsAuthorization
                    folder = try commitDisconnectedRestore(
                        folder: folder,
                        diagnostic: .persistenceFailure,
                        stagedAccess: stagedAccess,
                        persistLibraryProjection: false
                    )
                    restored.append(folder)
                    continue
                }
            }

            folder.connectionState = repository.isWritable ? .ready : .readOnly
            var previousLibrary: LibraryFolder?
            do {
                previousLibrary = try index.library(id: folder.id)
                try populateRestoreProjection(&folder)
                if requiresSave {
                    try applyRegistryTransaction(
                        kind: .restoreRefresh,
                        previousBookmark: bookmark,
                        intendedBookmark: updatedBookmark,
                        previousLibrary: previousLibrary,
                        intendedLibrary: folder
                    )
                } else {
                    try index.upsert(library: folder)
                }
            } catch LibraryError.registryRecoveryRequired {
                stagedAccess.stop()
                throw LibraryError.registryRecoveryRequired
            } catch {
                if requiresSave {
                    // The journal already restored the old bookmark/index.
                    // Keep the disconnected in-memory diagnostic, but base it
                    // on the old projection and do not persist the uncommitted
                    // resolved URL back over that rollback result.
                    folder = previousLibrary ?? persistedFolder
                    folder.connectionState = .needsAuthorization
                    folder = try commitDisconnectedRestore(
                        folder: folder,
                        diagnostic: .persistenceFailure,
                        stagedAccess: stagedAccess,
                        persistLibraryProjection: false
                    )
                    restored.append(folder)
                    continue
                } else {
                    stagedAccess.stop()
                    throw error
                }
            }

            let oldAccess = access.updateValue(stagedAccess, forKey: folder.id)
            libraries[folder.id] = folder
            restoreDiagnostics.removeValue(forKey: folder.id)
            oldAccess?.stop()
            restored.append(folder)
        }

        return restored
    }

    private func populateRestoreProjection(_ folder: inout LibraryFolder) throws {
        folder.photoCount = try index.photoCount(inLibrary: folder.id)
        if let indexed = try index.library(id: folder.id) {
            folder.lastScanAt = indexed.lastScanAt
        }
    }

    /// Every throwing step (the projection re-read and, when requested, the
    /// index upsert) must finish before anything nonthrowing is committed.
    /// `stagedAccess` was never inserted into `access`, so stopping it on
    /// failure only releases a resource this call never published — it does
    /// not touch durable or actor-visible state. If either throwing step
    /// fails, the existing `access`/`libraries`/`restoreDiagnostics` entries
    /// for this library are left completely untouched, matching whatever was
    /// last durably committed.
    private func commitDisconnectedRestore(
        folder initialFolder: LibraryFolder,
        diagnostic: LibraryRestoreDiagnostic?,
        stagedAccess: (any FolderAccessHandle)?,
        persistLibraryProjection: Bool = true
    ) throws -> LibraryFolder {
        var folder = initialFolder
        do {
            try populateRestoreProjection(&folder)
            if persistLibraryProjection {
                try index.upsert(library: folder)
            }
        } catch {
            stagedAccess?.stop()
            throw error
        }

        stagedAccess?.stop()
        access.removeValue(forKey: folder.id)?.stop()
        libraries[folder.id] = folder
        if let diagnostic {
            restoreDiagnostics[folder.id] = diagnostic
        } else {
            restoreDiagnostics.removeValue(forKey: folder.id)
        }
        return folder
    }

    /// Re-points a library at a folder the user picked again after the
    /// bookmark went stale. The `LibraryID` is preserved, so every sidecar
    /// still matches.
    ///
    /// Runs the exact same read-only, order-independent identity preflight
    /// as `addLibrary` (spec §7): the new target must confirm as `.same` as
    /// the library being relinked — never merely `.distinct`,
    /// `.ancestor`/`.descendant`, `.conflict`, or `.ambiguous` — and must not
    /// overlap, match or conflict with any *other* known library either.
    /// Nothing is mutated until every check passes.
    @discardableResult
    public func relink(libraryID: LibraryID, to url: URL) throws -> LibraryFolder {
        try recoverPendingRegistryTransaction()
        guard let target = libraries[libraryID] else {
            throw LibraryError.notFound(libraryID)
        }

        let repository = FileSidecarRepository(libraryRootURL: url)
        let confirmedManifestID = try Self.requireConfirmedManifestID(
            from: repository.probeManifest(), path: url.path
        )
        let candidateIdentity = LibrarySourceIdentity.resolve(
            url: url,
            confirmedManifestLibraryID: confirmedManifestID,
            resourceIdentityResolver: resourceIdentityResolver
        )

        let targetRelationship = try identity(for: target).relationship(to: candidateIdentity)
        guard targetRelationship == .same else {
            switch targetRelationship {
            case .ambiguous:
                throw LibraryError.ambiguousSource(libraryID)
            default:
                throw LibraryError.relinkTargetMismatch(libraryID)
            }
        }

        // Collected then decided with a fixed precedence, exactly like
        // `preflightDecision` (spec §7): the specific rejection reported
        // for the "other known libraries" check must not depend on
        // `Dictionary` iteration order either.
        var otherRelationships: [(other: LibraryFolder, relationship: SourceRelationship)] = []
        for other in libraries.values where other.id != libraryID {
            otherRelationships.append((other, try identity(for: other).relationship(to: candidateIdentity)))
        }
        otherRelationships.sort { $0.other.id.description < $1.other.id.description }

        if otherRelationships.contains(where: {
            $0.relationship == .same || $0.relationship == .ancestor || $0.relationship == .descendant
        }) {
            throw LibraryError.overlappingSource
        }
        if let ambiguous = otherRelationships.first(where: {
            $0.relationship == .conflict || $0.relationship == .ambiguous
        }) {
            throw LibraryError.ambiguousSource(ambiguous.other.id)
        }

        return try focusExistingLibrary(
            target, at: url, displayName: nil,
            candidateIdentity: candidateIdentity, repository: repository,
            transactionKind: .relink
        )
    }

    /// Removes a source's *local* bookmark, index rows and progress state
    /// only. Must never touch the source root itself — RAW, sidecar and
    /// manifest content all stay exactly where they are (spec §7, §11): this
    /// intentionally never constructs a `FileSidecarRepository` or otherwise
    /// calls a source-file remover.
    public func removeLibrary(id: LibraryID) throws {
        try recoverPendingRegistryTransaction()

        let previousStoredBookmark = try bookmarkStore.load(libraryID: id)
        try bookmarkStore.remove(libraryID: id)
        do {
            try index.removeLibrary(id: id)
        } catch let indexError {
            if let previousStoredBookmark {
                do {
                    try bookmarkStore.save(previousStoredBookmark)
                } catch let rollbackError {
                    throw LibraryError.removeLibraryRollbackFailed(
                        libraryID: id,
                        indexFailure: Self.describePersistenceFailure(indexError),
                        rollbackFailure: Self.describePersistenceFailure(rollbackError)
                    )
                }
            }
            throw indexError
        }

        access[id]?.stop()
        access[id] = nil
        libraries[id] = nil
        restoreDiagnostics[id] = nil
    }

    private static func describePersistenceFailure(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// Re-checks whether the drive is plugged in and writable (spec §10).
    @discardableResult
    public func refreshAvailability(libraryID: LibraryID) throws -> LibraryFolder {
        try recoverPendingRegistryTransaction()
        guard var folder = libraries[libraryID] else {
            throw LibraryError.notFound(libraryID)
        }
        if restoreDiagnostics[libraryID] != nil || access[libraryID] == nil {
            folder.connectionState = restoreDiagnostics[libraryID] != nil
                ? .needsAuthorization
                : .offline
            libraries[libraryID] = folder
            try index.upsert(library: folder)
            return folder
        }
        let repository = FileSidecarRepository(libraryRootURL: folder.rootURL)
        folder.connectionState = !repository.isAvailable
            ? .offline
            : (repository.isWritable ? .ready : .readOnly)
        libraries[libraryID] = folder
        try index.setLibraryAvailability(
            id: libraryID,
            isOnline: folder.isOnline,
            isWritable: folder.isWritable
        )
        return folder
    }

    public func photos(inLibrary libraryID: LibraryID) throws -> [PhotoAsset] {
        try index.photos(inLibrary: libraryID)
    }

    public func sourceURL(for photo: PhotoAsset) -> URL? {
        guard let folder = libraries[photo.libraryID] else { return nil }
        return photo.url(inLibraryRootedAt: folder.rootURL)
    }

    // MARK: - App-storage projection

    /// Projects every currently-committed App-copy `PhotoDocument` into the
    /// synthetic `.appStorage` library (Task 4), so it shows up through the
    /// same paged, multi-source index (Task 1's `LibraryScope.appStorage`,
    /// which selects `WHERE library.source_kind = 'appStorage'`) as every
    /// other source. `documents` is the caller's own up-to-date listing —
    /// typically `PhotoDocumentStore.committedDocuments().documents` —
    /// since this actor does not itself hold a `PhotoDocumentStore`
    /// instance; the two are independent components composed by the caller.
    ///
    /// This projection is local and rebuildable, exactly like the rest of
    /// `PhotoIndexStore`: it is never the authority on a document's
    /// identity, content or editability — `PhotoDocumentStore`'s own
    /// committed records remain that. Opening an App copy for editing goes
    /// through `PhotoDocumentEditor.openLibraryAsset(.appCopy(documentID:))`
    /// directly against the store, never through this projection —
    /// `sourceURL(for:)` must never be relied on for a projected App copy;
    /// see `appStorageRelativePath(for:)` for why.
    ///
    /// Idempotent and safe to call repeatedly (e.g. every launch, or
    /// whenever the committed set changes): every call re-derives the whole
    /// `.appStorage` projection from `documents` and prunes any previously
    /// projected row for a document no longer present in it (removed,
    /// rolled back, or no longer committed) — the same "re-seen vs. pruned"
    /// pattern a folder scan already uses to drop rows for files that
    /// disappeared, applied here to committed documents instead of files on
    /// a scanned drive.
    ///
    /// Only `.appCopy` documents are projected. An `.inPlace` document's
    /// working file is an external RAW that, if it happens to live inside
    /// an already-indexed external source, is already projected through
    /// that source's own scan; this is not a second, competing path for it.
    public func refreshAppStorageProjection(from documents: [PhotoDocument]) throws {
        let appCopies = documents.filter { $0.storageMode == .appCopy }
        let projectedAt = Date()

        if libraries[.appStorage] == nil {
            let folder = LibraryFolder(
                id: .appStorage,
                displayName: L10n.t("App Copies"),
                rootURL: Self.appStorageProjectionRootURL,
                sourceKind: .appStorage,
                connectionState: .ready,
                scanState: .idle
            )
            try index.upsert(library: folder)
            libraries[.appStorage] = folder
        }

        let assets = appCopies.map { document in
            PhotoAsset(
                id: PhotoID(document.id),
                libraryID: .appStorage,
                relativePath: Self.appStorageRelativePath(for: document),
                fingerprint: document.workingFingerprint,
                status: .ready,
                lastSeenAt: projectedAt
            )
        }
        try index.upsert(photos: assets)
        // Anything not just re-seen above (a document rolled back, removed,
        // or no longer committed since the last call) still carries an
        // older `lastSeenAt` and is pruned here -- never something newer
        // than `projectedAt` itself, since every row this call just wrote
        // shares that exact timestamp.
        try index.removePhotos(inLibrary: .appStorage, notSeenSince: projectedAt)

        if var folder = libraries[.appStorage] {
            folder.photoCount = try index.photoCount(inLibrary: .appStorage)
            libraries[.appStorage] = folder
            try index.upsert(library: folder)
        }
    }

    /// Root every projected App-copy `PhotoAsset.relativePath` is expressed
    /// relative to. A fixed, synthetic, absolute-looking placeholder —
    /// deliberately never a real filesystem location (not `/`, not
    /// `PhotoDocumentStore`'s own `rootURL`, which this actor never even
    /// holds a reference to) — because `folder.rootURL
    /// .appendingPathComponent(relativePath)` is not meant to resolve to
    /// anything real; see `appStorageRelativePath(for:)` for why.
    /// `URL(fileURLWithPath:)` with a relative string would resolve against
    /// this *process's* current working directory, which is itself not
    /// something to leak here, so this is written as an already-absolute
    /// path literal instead.
    private static let appStorageProjectionRootURL = URL(fileURLWithPath: "/LumaHarborAppStorage", isDirectory: true)

    /// A stable, non-private, synthetic `relativePath` for a projected App
    /// copy: `"<document id>/<filename>"`. Deliberately never derived from
    /// `document.workingURL`'s real path components (the user's home
    /// directory, Application Support, `PhotoDocumentStore`'s own
    /// `Documents/<id>` layout).
    ///
    /// `relativePath` is not an internal-only field — `PhotoIndexStore`'s
    /// page, folder and filename-search queries all read it directly, and
    /// it is meant to eventually reach a library browser UI. Storing a
    /// document's real absolute path in it would leak local, private path
    /// fragments (e.g. `Users/<name>/Library/Application Support/...`)
    /// into a place a UI or a future export could surface, and would seed
    /// a fake `Users`/`<name>`/... folder-tree node out of what are really
    /// just this device's own directory names, not user-meaningful
    /// folders. The document's own UUID is already a stable identifier
    /// that reveals nothing about the local filesystem; paired with just
    /// the filename, this keeps same-named files from different documents
    /// distinct without carrying any of that.
    ///
    /// This value is not meant to be resolved back into a real file
    /// location — `sourceURL(for:)` must never be relied on for a
    /// projected App copy. Opening one always goes through
    /// `PhotoDocumentEditor.openLibraryAsset(.appCopy(documentID:))` →
    /// `PhotoDocumentStore.loadDocument(id:)`, which reads the real
    /// `workingURL` from the store's own durable record — never reverse-
    /// derived from this projected index path.
    private static func appStorageRelativePath(for document: PhotoDocument) -> String {
        "\(document.id.uuidString)/\(document.workingURL.lastPathComponent)"
    }

    // MARK: - Rebuildable local data

    /// Deletes and recreates the local SQLite index and thumbnail/preview
    /// caches, leaving bookmarks and portable sidecars untouched (spec §13.9).
    ///
    /// This is the only supported way to do it: closing the connection here,
    /// before the file is unlinked, is what prevents the disk I/O error that
    /// comes from a second connection opening the same path while this actor
    /// still holds the first one.
    public func resetRebuildableLocalData() throws {
        try recoverPendingRegistryTransaction()
        guard activeScanCount == 0 else {
            throw LibraryError.resetRefusedWhileScanning
        }

        index.close()

        do {
            try locations.removeRebuildableData()
            try locations.createDirectories()
            let freshIndex = try PhotoIndexStore(databaseURL: locations.databaseURL)
            for folder in libraries.values {
                try freshIndex.upsert(library: folder)
            }
            index = freshIndex
        } catch {
            // The old connection is already closed and must not be mistaken for
            // usable. Leaving it as `index` here still surfaces every
            // subsequent index call as a thrown error rather than silently
            // succeeding; quitting and reopening the app runs `init` again and
            // recreates the index from scratch.
            throw LibraryError.resetFailed(
                (error as? LocalizedError)?.errorDescription
                    ?? (error as NSError).localizedDescription
            )
        }
    }

    // MARK: - Scanning

    /// Streams a full folder scan.
    ///
    /// Rebuilding a deleted SQLite database is the same code path: the manifest
    /// on the SSD supplies the `PhotoID`s, so photos keep their edits (spec §13.9).
    public nonisolated func scan(libraryID: LibraryID) -> LibraryScanSequence {
        LibraryScanSequence(service: self, libraryID: libraryID)
    }

    /// Runs bounded, coordinated scans across every listed source at once
    /// (spec §9): at most two scan concurrently, and the rest queue behind
    /// them. `selectedLibraryID`, when present, is scheduled ahead of the
    /// other queued sources -- but never interrupts a scan already running,
    /// so an in-flight batch is never rudely cut off.
    ///
    /// Each source's events flow through the exact same acknowledged,
    /// bounded `scan(libraryID:)` pipeline a single-source scan already
    /// uses -- including its existing generation validation and prune/
    /// `lastScanAt` safety, both left completely untouched. `onEvent` is
    /// awaited for every event before the next one is requested, so
    /// backpressure reaches the directory cursor exactly as it does for one
    /// source; this method never buffers events of its own.
    ///
    /// `libraryIDs` is de-duplicated up front -- a repeated entry is only
    /// ever scanned once, and only ever delivers one `.started`/`.finished`
    /// pair -- then ordered with the selected source (if present) first,
    /// followed by every other requested source in its original order, and
    /// registered with `scanCoordinator.runBatch(_:)` as a single atomic
    /// batch rather than one `run(...)` call per source inside a
    /// `TaskGroup`. That distinction matters: a `TaskGroup`'s child tasks
    /// give no guarantee about which one actually reaches the coordinator
    /// actor first, so spawning one concurrent child per source could let
    /// two `.normal` sources win both scan slots before a `.selected` one
    /// ever registers, even though this array puts it first. `runBatch(_:)`
    /// registers the whole ordered batch in one non-suspending pass before
    /// anything is allowed to start, so selected-source priority holds
    /// regardless of how the coordinator's own internal tasks get scheduled
    /// afterward.
    ///
    /// Returns once every listed source's scan has finished, failed, or been
    /// cancelled.
    public nonisolated func scanLibraries(
        _ libraryIDs: [LibraryID],
        selectedLibraryID: LibraryID?,
        onEvent: @escaping @Sendable (LibraryID, LibraryScanEvent) async -> Void
    ) async {
        guard !libraryIDs.isEmpty else { return }

        var orderedIDs: [LibraryID] = []
        var seenIDs: Set<LibraryID> = []
        if let selectedLibraryID, libraryIDs.contains(selectedLibraryID) {
            orderedIDs.append(selectedLibraryID)
            seenIDs.insert(selectedLibraryID)
        }
        for libraryID in libraryIDs where seenIDs.insert(libraryID).inserted {
            orderedIDs.append(libraryID)
        }

        let entries = orderedIDs.map { libraryID in
            (
                libraryID: libraryID,
                priority: (libraryID == selectedLibraryID)
                    ? MultiSourceScanCoordinator.ScanPriority.selected
                    : MultiSourceScanCoordinator.ScanPriority.normal,
                operation: { @Sendable () async -> Void in
                    for await event in self.scan(libraryID: libraryID) {
                        await onEvent(libraryID, event)
                    }
                }
            )
        }
        await scanCoordinator.runBatch(entries)
    }

    /// Runs one scan against an acknowledging emitter.
    ///
    /// Every `send` below suspends until the UI has taken the event, so the
    /// service cannot inspect the next batch while the previous one is still on
    /// screen-side. That is what carries backpressure all the way from the view
    /// model back to the directory cursor (bounded-pipeline spec §3.4).
    func performScan(
        libraryID: LibraryID,
        emitter: AcknowledgedAsyncChannel<LibraryScanEvent>
    ) async {
        activeScanCount += 1
        defer { activeScanCount -= 1 }

        // Delivery suspends until the consumer takes the event. The return
        // value matters: a `false` means nobody received it, and carrying on
        // from there means doing real work — opening the manifest, walking the
        // drive — for an audience that has already left.
        @discardableResult
        func emit(_ event: LibraryScanEvent) async -> Bool {
            do {
                try await emitter.send(event)
                return true
            } catch {
                return false
            }
        }

        do {
            try recoverPendingRegistryTransaction()
        } catch {
            await emit(.failed(.registryRecoveryRequired))
            return
        }

        guard let folder = libraries[libraryID] else {
            await emit(.failed(.notFound(libraryID)))
            return
        }
        guard folder.isOnline else {
            await emit(.failed(.offline(path: folder.lastKnownPath)))
            return
        }

        let repository = FileSidecarRepository(libraryRootURL: folder.rootURL)
        guard repository.isAvailable else {
            await emit(.failed(.offline(path: folder.rootURL.path)))
            return
        }

        // Addendum §3.5: the UI cancels a scan and starts another immediately.
        // A non-cooperative inspection from the old run can come back *after*
        // the new one finished, still holding the manifest snapshot it read at
        // its own start — writing that back would roll the newer scan's work
        // backwards. Claiming the token here is what makes the older run
        // recognise it has been replaced.
        scanGenerationCounter += 1
        let generation = scanGenerationCounter
        currentScanGeneration[libraryID] = generation

        // If `.started` never lands the consumer is already gone, so there is
        // nothing to gain from reading the manifest or starting the walk.
        guard await emit(.started(libraryID)) else { return }
        let scanStartedAt = Date()

        var manifest: LibraryManifest
        do {
            manifest = try repository.loadManifest() ?? LibraryManifest(libraryID: libraryID)
        } catch let error as SidecarError {
            // A damaged manifest has already been quarantined; rebuilding from
            // the sidecars still on disk is better than refusing to scan.
            guard await emit(.failed(.sidecar(error))) else { return }
            manifest = LibraryManifest(libraryID: libraryID)
        } catch {
            manifest = LibraryManifest(libraryID: libraryID)
        }

        // Phase 3 Task 3.5: a snapshot, taken once, of every virtual copy
        // record this manifest already knows about, keyed by whatever it
        // was duplicated from -- see `virtualCopyAssets(for:...)`'s own doc
        // comment for why the scan loop below needs this to reconcile a
        // copy's index row back in whenever its original is rescanned.
        let variantRecordsByOriginal: [PhotoID: [PhotoRecord]] = Dictionary(
            grouping: manifest.photos.filter { $0.variantOf != nil },
            by: { $0.variantOf! }
        )

        // Curation sidecar v3 migration (professional editing completion
        // spec §6.1, plan gap G1): one bulk read per scan, not one query per
        // file, of "what SQLite currently thinks" every photo's rating/flag/
        // keywords are. `CurationMigration.decide` compares this against
        // each photo's own sidecar. A newly rebuilt index returns an empty
        // snapshot normally. A thrown read error is different: fail this scan
        // instead of treating unknown data as empty and risking a neutral
        // projection over the last known state.
        let curationSnapshot: [PhotoID: PhotoCuration]
        do {
            curationSnapshot = try index.curationSnapshot(inLibrary: libraryID)
        } catch {
            await emit(.failed(.indexUnavailable((error as NSError).localizedDescription)))
            // The scan sequence contract exposes an explicit terminal result
            // after a started run. This run has no trustworthy curation
            // baseline, so finish it as cancelled rather than letting the
            // consumer interpret the failure as a clean completion.
            await emit(.finished(LibraryScanResult(
                libraryID: libraryID,
                indexedCount: 0,
                failedCount: 0,
                ambiguousCount: 0,
                movedCount: 0,
                wasCancelled: true,
                completedAt: Date()
            )))
            return
        }
        let decoderDescriptor = DecoderDescriptor(decoder.identifier)

        var indexed = 0
        var failed = 0
        var ambiguous = 0
        var moved = 0
        var cancelled = false

        // Breaking out of this loop releases the folder-scan iterator, whose
        // `deinit` cancels the walk. Equally, while this loop is suspended in
        // `emit` it is not calling the folder iterator's `next()`, so the
        // cursor stops advancing — that is the backpressure chain reaching the
        // directory.
        for await event in scanner.scan(root: folder.rootURL) {
            let consumerGone = await emitter.isCancelled
            if Task.isCancelled
                || consumerGone
                || !isCurrentScan(libraryID: libraryID, generation: generation) {
                cancelled = true
                break
            }

            switch event {
            case .started:
                continue

            case .fileFailed(let relativePath, let reason):
                failed += 1
                await emit(.photoFailed(relativePath: relativePath, reason: reason))

            case .discovered(let files):
                var batch: [PhotoAsset] = []
                batch.reserveCapacity(files.count)

                for file in files {
                    let consumerLeft = await emitter.isCancelled
                    if Task.isCancelled || consumerLeft { cancelled = true; break }

                    let outcome = await self.inspectWithTimeout(
                        file: file,
                        manifest: manifest,
                        decoder: decoder,
                        libraryID: libraryID
                    )

                    switch outcome {
                    case .cancelled:
                        // Addendum §3.5: giving up is not a damaged photo. A
                        // non-cooperative decoder is allowed to finish the file
                        // it already started, but the result is dropped and the
                        // next file is never begun.
                        cancelled = true
                    case .failure(let reason):
                        failed += 1
                        await emit(.photoFailed(relativePath: file.relativePath, reason: reason))
                    case .success(var asset, let record, let decision):
                        if case .ambiguous = decision { ambiguous += 1 }
                        if case .moved = decision { moved += 1 }
                        Self.hydrateCurationAndEditState(
                            asset: &asset,
                            existingSQLiteCuration: curationSnapshot[asset.id],
                            repository: repository,
                            decoder: decoderDescriptor
                        )
                        manifest.upsert(record)
                        batch.append(asset)
                        indexed += 1
                        // Phase 3 Task 3.5: bring any virtual copy of this
                        // photo back into the index too -- it was never
                        // discovered by the walk above (see
                        // `virtualCopyAssets(for:...)`'s own doc comment).
                        let copies = Self.virtualCopyAssets(
                            for: asset.id,
                            metadata: asset.metadata,
                            status: asset.status,
                            libraryID: libraryID,
                            recordsByOriginal: variantRecordsByOriginal,
                            repository: repository,
                            curationSnapshot: curationSnapshot,
                            decoder: decoderDescriptor
                        )
                        batch.append(contentsOf: copies)
                    }

                    if cancelled { break }
                }

                if !batch.isEmpty {
                    // Bounded-pipeline spec §3.4: a batch that wasn't inspected
                    // all the way through never reaches the index. `cancelled`
                    // is set the moment an inspection is abandoned, so it is
                    // what tells a half-inspected batch from a whole one — and
                    // a cancel can also land in the gap between the last
                    // inspection and this commit, which the other three checks
                    // cover. Batches already committed before this point stay;
                    // only the current, incomplete one is dropped.
                    let consumerHasLeft = await emitter.isCancelled
                    guard !cancelled,
                          !Task.isCancelled,
                          !consumerHasLeft,
                          isCurrentScan(libraryID: libraryID, generation: generation) else {
                        cancelled = true
                        break
                    }
                    do {
                        // `emitter.isCancelled` suspended the actor. A
                        // registry mutation may have failed and left a journal
                        // while this scan was reentrant, so recovery must be
                        // rechecked immediately before this synchronous write.
                        try recoverPendingRegistryTransaction()
                        try index.upsert(photos: batch)
                        // Must run after the batch upsert above: `photo_keyword`
                        // has a foreign key onto `photo.photo_id` (enforced,
                        // `SQLiteDatabase` turns `PRAGMA foreign_keys` on), so
                        // projecting curation for a row that doesn't exist in
                        // `photo` yet -- e.g. every photo during an index
                        // rebuild -- would fail this insert outright.
                        for photo in batch { projectCuration(of: photo) }
                        await emit(.photosIndexed(batch))
                    } catch LibraryError.registryRecoveryRequired {
                        await emit(.failed(.registryRecoveryRequired))
                        return
                    } catch {
                        await emit(.failed(
                            .indexUnavailable((error as NSError).localizedDescription)
                        ))
                        // A batch that failed to persist leaves this scan's
                        // "which photos are still there" picture incomplete
                        // for at least those photos -- never safe grounds for
                        // the differential prune below, or for stamping
                        // `lastScanAt`/the manifest's success timestamp as if
                        // this run finished cleanly. Folding it into
                        // `cancelled` reuses the exact same "don't trust an
                        // incomplete picture" gate a genuine cancellation
                        // already relies on, rather than inventing a second,
                        // parallel one.
                        cancelled = true
                    }
                }

            case .finished:
                continue
            }
        }

        // The loop can end for reasons that never set `cancelled`: the walk
        // finished normally while the consumer was already gone, or the folder
        // channel returned nil because this task was cancelled. Merge every
        // reason here — this is the last gate before anything is treated as a
        // completed scan.
        let taskWasCancelled = Task.isCancelled
        let consumerHasGone = await emitter.isCancelled
        if taskWasCancelled || consumerHasGone { cancelled = true }

        let isSuperseded = !isCurrentScan(libraryID: libraryID, generation: generation)
        if isSuperseded { cancelled = true }

        guard !isSuperseded else {
            // Everything below writes state derived from a snapshot taken before
            // the newer scan existed. A superseded run therefore touches
            // nothing at all — not the index, not the manifest, not the folder
            // record — and only reports that it stopped.
            await emit(.finished(LibraryScanResult(
                libraryID: libraryID,
                indexedCount: indexed,
                failedCount: failed,
                ambiguousCount: ambiguous,
                movedCount: moved,
                wasCancelled: true,
                manifestWriteFailure: nil,
                manifestWriteRecoverySuggestion: nil,
                completedAt: Date()
            )))
            return
        }

        // A `FileManager.DirectoryEnumerator` can't tell "ran out of files"
        // from "the drive disappeared mid-walk" -- both just stop yielding
        // items, so `cancelled` alone never catches this. Re-checking here,
        // once, right before anything destructive runs, is what does: a
        // source that vanished partway through a scan must be reported as
        // offline -- exactly like the guard at the top of this function that
        // refuses to even start a scan on an already-offline source -- and
        // must never be mistaken for "every file this run didn't re-see is
        // actually gone".
        if !cancelled, !repository.isAvailable {
            await emit(.failed(.offline(path: folder.rootURL.path)))
            return
        }

        // The scan loop and cancellation checks contain multiple suspension
        // points. Keep the final index/manifest/memory commit in one actor-
        // isolated synchronous region, preceded by a fresh recovery gate.
        do {
            try recoverPendingRegistryTransaction()
        } catch {
            await emit(.failed(.registryRecoveryRequired))
            return
        }

        // Drop rows for files that disappeared from the drive.
        if !cancelled {
            try? index.removePhotos(inLibrary: libraryID, notSeenSince: scanStartedAt)
        }

        var manifestFailure: String?
        var manifestFailureRecoverySuggestion: String?
        manifest.lastSuccessfulScanAt = cancelled ? manifest.lastSuccessfulScanAt : Date()
        do {
            try repository.write(manifest: manifest)
        } catch {
            // Spec §10: a read-only drive stays browsable. The portable copy is
            // stale, but nothing is lost and the user is told why.
            manifestFailure = (error as? LocalizedError)?.errorDescription
                ?? (error as NSError).localizedDescription
            manifestFailureRecoverySuggestion = (error as? LocalizedError)?.recoverySuggestion
        }

        if var updated = libraries[libraryID] {
            // Addendum §3.5: `lastScanAt` means "a full scan finished". The UI
            // uses `nil` to decide a folder still needs its first scan, so
            // stamping it here after a cancel would quietly skip that scan
            // forever. Cancelled runs keep whatever was there before.
            if !cancelled {
                updated.lastScanAt = Date()
            }
            updated.photoCount = (try? index.photoCount(inLibrary: libraryID)) ?? indexed
            // The scan only got this far because the source was reachable
            // (checked before it started), so writability is the only thing
            // that can have changed.
            updated.connectionState = repository.isWritable ? .ready : .readOnly
            libraries[libraryID] = updated
            try? index.upsert(library: updated)
        }

        await emit(.finished(LibraryScanResult(
            libraryID: libraryID,
            indexedCount: indexed,
            failedCount: failed,
            ambiguousCount: ambiguous,
            movedCount: moved,
            wasCancelled: cancelled,
            manifestWriteFailure: manifestFailure,
            manifestWriteRecoverySuggestion: manifestFailureRecoverySuggestion,
            completedAt: Date()
        )))
    }

    private enum InspectionOutcome: Sendable {
        case success(PhotoAsset, PhotoRecord, RelinkDecision)
        case failure(reason: String)
        /// The caller gave up. Explicitly not a `failure`: a cancelled scan must
        /// never leave the user looking at photos marked damaged (addendum §3.5).
        case cancelled
    }

    /// A safe, path-free reason for a per-file inspection that never
    /// answered. Never mentions the file itself -- `.photoFailed(relativePath:reason:)`
    /// already carries that separately.
    private static var providerTimeoutMessage: String {
        L10n.t("LumaHarbor gave up waiting for this file to respond.")
    }

    /// Bridges three independent signals -- the inspection finishing, the
    /// timeout elapsing, and the caller of `inspectWithTimeout` itself being
    /// cancelled -- into one single-resolution `CheckedContinuation`.
    ///
    /// The single-resolution shape matches `MultiSourceScanCoordinator`'s
    /// own `CompletionBox`: whichever signal calls `resolve(_:)` first wins,
    /// and every later call is silently dropped, so a slow loser can never
    /// overwrite an already-reported result. `cancel()` additionally
    /// forwards real cancellation into `inspectTask` via `Task.cancel()` --
    /// which `Self.inspect`'s own `runOffActor` call observes, so a
    /// *cooperative* decoder still notices and stops promptly -- while
    /// resolving immediately with `.cancelled` itself, so `inspectWithTimeout`
    /// never blocks its own return on how long that decoder actually takes
    /// to notice. A *non-cooperative* decoder is simply left running,
    /// forgotten, exactly like the timeout path already treats one
    /// (addendum §3.5): whatever it eventually reports arrives after this
    /// box has already resolved, and is dropped by the same guard.
    ///
    /// (Codex pre-landing review, Task 8 round: an earlier version raced the
    /// inspection and the timeout as two unstructured `Task { }`s with no
    /// cancellation bridge at all, so cancelling the scan never interrupted
    /// whichever file was currently mid-inspection. A structured `TaskGroup`
    /// was tried next, but a `TaskGroup` cannot resolve and return before
    /// *every* child finishes -- which reintroduced exactly the "block on a
    /// non-cooperative provider" stall this timeout exists to prevent, and
    /// deadlocked `testNonCooperativeInspectionDiscardsItsResultAndStopsThere`.
    /// This `withTaskCancellationHandler`-based bridge is what actually
    /// satisfies both constraints: prompt cancellation response, and never
    /// waiting on the loser.)
    private final class InspectionRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<InspectionOutcome, Never>?
        private var inspectTask: Task<Void, Never>?
        private var isCancelled = false

        func start(
            continuation: CheckedContinuation<InspectionOutcome, Never>,
            inspect: @escaping @Sendable () async -> InspectionOutcome,
            timeout: @escaping @Sendable () async -> InspectionOutcome?
        ) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let task = Task { [weak self] in
                let outcome = await inspect()
                self?.resolve(outcome)
            }

            // Storing `inspectTask` and reading `isCancelled` inside the
            // *same* critical section is what closes a race a two-lock
            // version of this had: `cancel()` (which can run concurrently,
            // from `onCancel`, on a different thread) also reads/writes
            // both of these under this same lock, so whichever of `cancel()`
            // or this section runs first, the other sees a fully consistent
            // picture -- never "`inspectTask` not stored yet" paired with
            // "the earlier snapshot said not cancelled." The just-created
            // task is therefore always cancelled exactly once, from
            // whichever side notices first, with no window in between.
            lock.lock()
            inspectTask = task
            let cancelledNow = isCancelled
            lock.unlock()

            if cancelledNow {
                // The caller was already cancelled by the time this race
                // began (or `cancel()` won this exact race) -- stop the
                // inspection immediately rather than letting it run
                // needlessly, and resolve now since a concurrent `cancel()`
                // may have found `inspectTask` still nil and been unable to
                // do either of these itself.
                task.cancel()
                resolve(.cancelled)
                return
            }

            Task { [weak self] in
                guard let outcome = await timeout() else { return }
                self?.resolve(outcome)
            }
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let task = inspectTask
            lock.unlock()
            task?.cancel()
            resolve(.cancelled)
        }

        func resolve(_ value: InspectionOutcome) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    /// Races one file's fingerprint+decode inspection against a fixed
    /// provider timeout: an unresponsive, cloud-backed Files folder that
    /// never answers a read must not stall the rest of the scan.
    ///
    /// A timeout is reported as an ordinary `.failure`, the same outcome a
    /// fingerprint I/O error already produces: no `PhotoAsset` is added to
    /// this scan's batch and the manifest keeps whatever record it already
    /// had for this path, so a *later* scan -- a fresh generation, not a
    /// retry loop inside this one -- picks the file up completely fresh. This
    /// call never retries on its own: one timeout is exactly one
    /// `.photoFailed` event, and the scan moves straight on to the next file.
    private func inspectWithTimeout(
        file: ScannedFile,
        manifest: LibraryManifest,
        decoder: any RawDecoding,
        libraryID: LibraryID
    ) async -> InspectionOutcome {
        let sleep = providerTimeoutSleep
        let race = InspectionRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<InspectionOutcome, Never>) in
                race.start(
                    continuation: continuation,
                    inspect: {
                        await Self.inspect(
                            file: file, manifest: manifest, decoder: decoder, libraryID: libraryID
                        )
                    },
                    timeout: {
                        do {
                            try await sleep(Self.providerRequestTimeout)
                        } catch {
                            // The sleep itself was cancelled -- the
                            // inspection side already won, or the caller was
                            // cancelled and `onCancel` below already
                            // resolved this race. Nothing to report.
                            return nil
                        }
                        return .failure(reason: Self.providerTimeoutMessage)
                    }
                )
            }
        } onCancel: {
            race.cancel()
        }
    }

    /// Fingerprint, identity and metadata for one file.
    ///
    /// Runs off the actor so hashing and EXIF reads stay off the main thread
    /// (spec §11), via `runOffActor` rather than a bare `Task.detached` so the
    /// caller's cancellation actually reaches the work. A decoder that refuses
    /// to notice is allowed to finish this one file — the checkpoint after it
    /// returns is what stops the result being used.
    private static func inspect(
        file: ScannedFile,
        manifest: LibraryManifest,
        decoder: any RawDecoding,
        libraryID: LibraryID
    ) async -> InspectionOutcome {
        let records = manifest.photos
        let url = file.url

        let outcome: InspectionOutcome
        do {
            outcome = try await runOffActor(priority: .utility) { () -> InspectionOutcome in
                try Task.checkCancellation()
                return Self.inspectSynchronously(
                    file: file, url: url, records: records,
                    decoder: decoder, libraryID: libraryID
                )
            }
        } catch {
            return .cancelled
        }

        // The uncooperative case: the work came back with a perfectly good
        // answer for a scan nobody is waiting for any more.
        if Task.isCancelled { return .cancelled }
        return outcome
    }

    private static func inspectSynchronously(
        file: ScannedFile,
        url: URL,
        records: [PhotoRecord],
        decoder: any RawDecoding,
        libraryID: LibraryID
    ) -> InspectionOutcome {
        do {
            let fingerprint: FileFingerprint
            do {
                fingerprint = try FingerprintCalculator.fingerprint(forFileAt: url)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failure(
                    reason: (error as? LocalizedError)?.errorDescription
                        ?? (error as NSError).localizedDescription
                )
            }

            let decision = RelinkResolver.resolve(
                relativePath: file.relativePath,
                fingerprint: fingerprint,
                against: records
            )

            let photoID: PhotoID
            var status: PhotoStatus = .ready
            var needsConfirmation = false

            switch decision {
            case .unchanged(let id), .contentChanged(let id):
                photoID = id
            case .moved(let id, _):
                photoID = id
            case .ambiguous:
                // Spec §8.1: never merge on a fingerprint tie. A fresh identity
                // keeps this file's future edits from landing on someone else's
                // photo; the UI asks the user to confirm.
                photoID = PhotoID()
                status = .needsConfirmation
                needsConfirmation = true
            case .new:
                photoID = PhotoID()
            }

            var metadata = RawMetadata()
            var failureReason: String?
            do {
                metadata = try decoder.readMetadata(at: url)
                if !decoder.supportsFile(at: url) {
                    status = .unsupported
                    failureReason = RawDecodingError
                        .unsupportedFormat(path: url.path).errorDescription
                }
            } catch RawDecodingError.cancelled {
                return .cancelled
            } catch is CancellationError {
                return .cancelled
            } catch let error as RawDecodingError {
                // Spec §10: flag the single photo, let the scan continue.
                switch error {
                case .unsupportedFormat:
                    status = .unsupported
                default:
                    status = .failed
                }
                failureReason = error.errorDescription
            } catch {
                status = .failed
                failureReason = (error as NSError).localizedDescription
            }

            let asset = PhotoAsset(
                id: photoID,
                libraryID: libraryID,
                relativePath: file.relativePath,
                fingerprint: fingerprint,
                metadata: metadata,
                status: status,
                failureReason: failureReason,
                lastSeenAt: Date()
            )
            let record = PhotoRecord(
                photoID: photoID,
                relativePath: file.relativePath,
                fingerprint: fingerprint,
                lastSeenAt: Date(),
                needsConfirmation: needsConfirmation
            )
            return .success(asset, record, decision)
        }
    }

    /// Explicitly projects a scan-hydrated asset's resolved curation into
    /// SQLite (spec §8.1: sidecar authoritative, SQLite a rebuildable
    /// projection). This does not rely on `upsertPhoto`'s own `INSERT`
    /// values: `photo_keyword` is a separate table that a batch
    /// `upsert(photos:)` never touches at all, and `rating`/`flag` are
    /// intentionally excluded from `upsertPhoto`'s own `ON CONFLICT` `SET`
    /// clause so an unrelated rescan can never clobber a value only
    /// `setRating`/`setFlag`/`setKeywords` should change. Every failure here
    /// is best-effort by design, same as `saveAdjustments`'s own
    /// `index.setEditState` call: the sidecar write already succeeded (or
    /// intentionally didn't happen), so a SQLite failure here must never be
    /// surfaced as a lost edit.
    private func projectCuration(of asset: PhotoAsset) {
        try? index.setRating(asset.rating, for: asset.id)
        try? index.setFlag(asset.flag, for: asset.id)
        try? index.setKeywords(asset.keywords.map(\.displayValue), for: asset.id)
        try? index.setCurationMigrationPending(asset.curationMigrationPending, for: asset.id)
    }

    /// Reconstructs a scanned photo's edit-state columns and curation from
    /// its sidecar, and runs the curation migration state machine (plan gap
    /// G1) against `existingSQLiteCuration` -- the current SQLite row's
    /// rating/flag/keywords, taken from a `curationSnapshot` computed once
    /// per scan, or `nil` for a photo with no prior row.
    ///
    /// Edit-state reconstruction is unchanged from before this plan: the
    /// sidecar is authoritative, SQLite is a rebuildable projection of it
    /// (spec §8.1). A neutral or absent sidecar maps to `(false, nil)`; a
    /// non-neutral one carries its own `modifiedAt` forward as `lastEditAt`,
    /// matching what `saveAdjustments` would have projected at save time.
    ///
    /// Curation resolution never throws and never leaves the caller with
    /// stale/lost values: `CurationMigration.decide` picks exactly one of
    /// three outcomes, and only `.migrate` attempts a sidecar write. If that
    /// write fails (offline, read-only, out of space, or the write races a
    /// cancel), the asset keeps `existingSQLiteCuration`'s old values and is
    /// marked `curationMigrationPending` so the next scan retries the exact
    /// same decision from scratch -- see the plan's G1 table for why no
    /// separate retry queue is needed.
    private static func hydrateCurationAndEditState(
        asset: inout PhotoAsset,
        existingSQLiteCuration: PhotoCuration?,
        repository: FileSidecarRepository,
        decoder: DecoderDescriptor
    ) {
        let existingSidecar: PhotoSidecar?
        do {
            existingSidecar = try repository.loadSidecar(for: asset.id)
        } catch {
            // A newer-schema sidecar must remain byte-for-byte untouched, and
            // a corrupt/unavailable one must not be treated as absent. Keep the
            // last known projection visible and mark it for a later retry.
            let fallback = existingSQLiteCuration ?? .neutral
            asset.hasEdits = false
            asset.lastEditAt = nil
            asset.rating = fallback.rating
            asset.flag = fallback.flag
            asset.keywords = fallback.keywords
            asset.curationMigrationPending = true
            return
        }
        let hasEdits = existingSidecar.map { !$0.adjustments.isNeutral } ?? false
        asset.hasEdits = hasEdits
        asset.lastEditAt = hasEdits ? existingSidecar?.modifiedAt : nil

        let decision = CurationMigration.decide(
            existingSidecar: existingSidecar,
            existingSQLiteCuration: existingSQLiteCuration,
            photoID: asset.id,
            sourceRelativePath: asset.relativePath,
            sourceFingerprint: asset.fingerprint,
            decoder: decoder,
            now: Date()
        )
        switch decision {
        case .sidecarAuthoritative(let curation), .unchanged(let curation):
            asset.rating = curation.rating
            asset.flag = curation.flag
            asset.keywords = curation.keywords
            asset.curationMigrationPending = false
        case .migrate(let sidecar, let curation):
            if (try? repository.write(sidecar: sidecar)) != nil {
                asset.rating = curation.rating
                asset.flag = curation.flag
                asset.keywords = curation.keywords
                asset.curationMigrationPending = false
            } else {
                let fallback = existingSQLiteCuration ?? .neutral
                asset.rating = fallback.rating
                asset.flag = fallback.flag
                asset.keywords = fallback.keywords
                asset.curationMigrationPending = true
            }
        }
    }

    /// Phase 3 Task 3.5: a virtual copy is never independently discovered
    /// by the scanner's own file walk (it shares its original's
    /// `relativePath`, so no second file ever triggers `inspectWithTimeout`
    /// for it) -- its own index row must instead be reconciled back in
    /// from `library.json`'s own persisted `variantOf` record whenever the
    /// photo it was duplicated from is itself successfully scanned. This is
    /// what makes `resetRebuildableLocalData()` + rescan (spec §13.9,
    /// "identities come from library.json, so edits survive the rebuild")
    /// actually true for a copy too, not just an original -- without this,
    /// deleting the local SQLite index permanently drops every virtual copy
    /// from the app (though its sidecar and manifest record stay behind,
    /// orphaned, on disk).
    ///
    /// `originalID` is walked recursively, not just one level, since
    /// `createVirtualCopy(of:)` allows a copy of a copy (`variantOf`
    /// pointing directly at whatever was duplicated, never chased to some
    /// "root" original) -- a rebuild must bring every generation back, not
    /// only the ones directly off the true original.
    ///
    /// `relativePath`/`fingerprint` come from the copy's own frozen
    /// `PhotoRecord`, never from the just-rescanned original's current
    /// values: a copy's own record is never touched by scanning (matching
    /// `LibraryViewModel.orderedForDisplay`'s own documented reasoning), so
    /// reconciling it must preserve that same frozen state, not
    /// "unfreeze" it into the original's possibly-since-moved path.
    /// `metadata`/`status` have no equivalent in `library.json` at all
    /// (only `PhotoIndexStore` ever carried them), so the freshly
    /// rescanned original's own values are reused -- correct because both
    /// describe the same underlying RAW file's bytes.
    private static func virtualCopyAssets(
        for originalID: PhotoID,
        metadata: RawMetadata,
        status: PhotoStatus,
        libraryID: LibraryID,
        recordsByOriginal: [PhotoID: [PhotoRecord]],
        repository: FileSidecarRepository,
        curationSnapshot: [PhotoID: PhotoCuration],
        decoder: DecoderDescriptor
    ) -> [PhotoAsset] {
        guard let records = recordsByOriginal[originalID] else { return [] }
        var result: [PhotoAsset] = []
        for record in records {
            // A copy's own sidecar (never its manifest record) is what
            // makes it real (spec §8.1). `deleteVirtualCopy(_:)` removes
            // the sidecar as its correctness gate but only best-effort
            // cleans up the matching manifest record afterward -- the same
            // tolerance `createVirtualCopy`'s own manifest write already
            // has. Skipping a record with no loadable sidecar here is what
            // stops a copy that failed exactly that manifest cleanup from
            // being silently resurrected into the index by a later rescan.
            guard (try? repository.loadSidecar(for: record.photoID)) != nil else { continue }
            var copyAsset = PhotoAsset(
                id: record.photoID,
                libraryID: libraryID,
                relativePath: record.relativePath,
                fingerprint: record.fingerprint,
                metadata: metadata,
                status: status,
                lastSeenAt: Date(),
                variantOf: record.variantOf,
                variantName: record.variantName
            )
            Self.hydrateCurationAndEditState(
                asset: &copyAsset,
                existingSQLiteCuration: curationSnapshot[record.photoID],
                repository: repository,
                decoder: decoder
            )
            result.append(copyAsset)
            result.append(contentsOf: Self.virtualCopyAssets(
                for: record.photoID,
                metadata: metadata,
                status: status,
                libraryID: libraryID,
                recordsByOriginal: recordsByOriginal,
                repository: repository,
                curationSnapshot: curationSnapshot,
                decoder: decoder
            ))
        }
        return result
    }

    // MARK: - Edits

    /// Reads a photo's saved adjustments, or neutral when it has never been
    /// edited. Corrupt or newer-schema sidecars throw so the UI can explain.
    public func adjustments(for photo: PhotoAsset) throws -> PhotoAdjustments {
        try recoverPendingRegistryTransaction()
        guard let folder = libraries[photo.libraryID] else {
            throw LibraryError.notFound(photo.libraryID)
        }
        guard folder.isOnline else {
            throw LibraryError.offline(path: folder.lastKnownPath)
        }
        let repository = FileSidecarRepository(libraryRootURL: folder.rootURL)
        do {
            return try repository.loadSidecar(for: photo.id)?.adjustments ?? .neutral
        } catch let error as SidecarError {
            throw LibraryError.sidecar(error)
        }
    }

    /// Persists adjustments to the portable sidecar.
    ///
    /// Throws on a read-only or missing drive so the caller can leave the UI's
    /// "saved" state false — spec §8.2 forbids showing a save that didn't happen.
    public func saveAdjustments(
        _ adjustments: PhotoAdjustments,
        for photo: PhotoAsset
    ) throws {
        try recoverPendingRegistryTransaction()
        guard let folder = libraries[photo.libraryID] else {
            throw LibraryError.notFound(photo.libraryID)
        }
        guard folder.isOnline else {
            throw LibraryError.offline(path: folder.lastKnownPath)
        }
        let repository = FileSidecarRepository(libraryRootURL: folder.rootURL)

        do {
            // Only a confirmed missing sidecar may start from neutral. Read
            // errors, corruption, and newer schemas must propagate so this
            // older build cannot replace edits it does not understand.
            let existing = try repository.loadSidecar(for: photo.id)
            let now = Date()
            let sidecar = PhotoSidecar(
                photoID: photo.id,
                sourceRelativePath: photo.relativePath,
                sourceFingerprint: photo.fingerprint,
                decoder: DecoderDescriptor(decoder.identifier),
                adjustments: adjustments,
                // Preserve whatever curation already exists (spec §6.1): an
                // adjustment save is unrelated to rating/flag/keywords, and
                // must never silently reset them to neutral.
                curation: existing?.curation ?? .neutral,
                createdAt: existing?.createdAt ?? now,
                modifiedAt: now,
                variantOf: photo.variantOf ?? existing?.variantOf
            )
            try repository.write(sidecar: sidecar)
            // Best-effort by design (spec §8.1): the sidecar write above is
            // what makes the save real, and SQLite is only a rebuildable
            // projection of it. A failure here must never turn a
            // successfully persisted sidecar into an apparently-unsaved
            // photo, so this doesn't throw and doesn't get folded into the
            // `catch` below.
            try? index.setEditState(
                for: photo.id,
                hasEdits: !adjustments.isNeutral,
                lastEditAt: adjustments.isNeutral ? nil : sidecar.modifiedAt
            )
        } catch let error as SidecarError {
            throw LibraryError.sidecar(error)
        }
    }

    // MARK: - Curation

    /// Reads a photo's curation from its sidecar -- never from SQLite, which
    /// is only a rebuildable projection (spec §6.1 rule 1).
    public func curation(for photo: PhotoAsset) throws -> PhotoCuration {
        try recoverPendingRegistryTransaction()
        guard let folder = libraries[photo.libraryID] else {
            throw LibraryError.notFound(photo.libraryID)
        }
        guard folder.isOnline else {
            throw LibraryError.offline(path: folder.lastKnownPath)
        }
        let repository = FileSidecarRepository(libraryRootURL: folder.rootURL)
        do {
            return try repository.loadSidecar(for: photo.id)?.curation ?? .neutral
        } catch let error as SidecarError {
            throw LibraryError.sidecar(error)
        }
    }

    /// Sidecar-first curation mutation shared by `setRating`/`setFlag`/
    /// `setKeywords` (spec §6.1 rule 5): load the existing sidecar (or start
    /// from neutral), apply `transform`, write atomically, then best-effort
    /// project the result into SQLite -- exactly the same tolerance
    /// `saveAdjustments`'s own `index.setEditState` call already has. A
    /// curation-only mutation never touches `adjustments`/`modifiedAt`'s own
    /// "last edit" meaning used elsewhere (see `PhotoAsset.lastEditAt`).
    private func mutateCuration(
        for photo: PhotoAsset,
        transform: (inout PhotoCuration) -> Void
    ) throws {
        try recoverPendingRegistryTransaction()
        guard let folder = libraries[photo.libraryID] else {
            throw LibraryError.notFound(photo.libraryID)
        }
        guard folder.isOnline else {
            throw LibraryError.offline(path: folder.lastKnownPath)
        }
        let repository = FileSidecarRepository(libraryRootURL: folder.rootURL)

        do {
            let existing = try repository.loadSidecar(for: photo.id)
            var curation = existing?.curation ?? .neutral
            transform(&curation)
            let now = Date()
            let sidecar = PhotoSidecar(
                photoID: photo.id,
                sourceRelativePath: photo.relativePath,
                sourceFingerprint: photo.fingerprint,
                decoder: DecoderDescriptor(decoder.identifier),
                adjustments: existing?.adjustments ?? .neutral,
                curation: curation,
                createdAt: existing?.createdAt ?? now,
                modifiedAt: existing?.modifiedAt ?? now,
                variantOf: photo.variantOf ?? existing?.variantOf
            )
            try repository.write(sidecar: sidecar)
            try? index.setRating(curation.rating, for: photo.id)
            try? index.setFlag(curation.flag, for: photo.id)
            try? index.setKeywords(curation.keywords.map(\.displayValue), for: photo.id)
            try? index.setCurationMigrationPending(false, for: photo.id)
        } catch let error as SidecarError {
            throw LibraryError.sidecar(error)
        }
    }

    public func setRating(_ rating: Int, for photo: PhotoAsset) throws {
        guard (0...5).contains(rating) else { throw LibraryQueryError.invalidRating(rating) }
        try mutateCuration(for: photo) { $0.rating = rating }
    }

    public func setFlag(_ flag: PhotoFlag, for photo: PhotoAsset) throws {
        try mutateCuration(for: photo) { $0.flag = flag }
    }

    public func setKeywords(_ inputs: [String], for photo: PhotoAsset) throws {
        var keywords: [PhotoKeyword] = []
        for input in inputs {
            guard let keyword = PhotoKeyword.make(from: input) else {
                throw LibraryQueryError.invalidKeyword
            }
            keywords.append(keyword)
        }
        try mutateCuration(for: photo) {
            $0 = PhotoCuration(rating: $0.rating, flag: $0.flag, keywords: keywords)
        }
    }

    // MARK: - Virtual copies

    /// Creates a new, independently-editable "virtual copy" of `photo`
    /// (Phase 3 Task 3.5): a fresh `PhotoID` sharing `photo`'s own
    /// `relativePath`/`fingerprint`/`metadata` -- the same underlying RAW
    /// file, never duplicated on disk -- starting from a copy of `photo`'s
    /// own current adjustments (ordinary "duplicate" semantics: identical
    /// now, independent from this point on). Works whether `photo` is
    /// itself an original or another virtual copy; either way the new
    /// copy's `variantOf` points at `photo.id` directly, never chased back
    /// to some "root" original -- Task 3.5's scope has no concept of nested
    /// copy trees, only a flat original/copy relationship.
    @discardableResult
    public func createVirtualCopy(
        of photo: PhotoAsset,
        named name: String? = nil
    ) throws -> PhotoAsset {
        try recoverPendingRegistryTransaction()
        guard let folder = libraries[photo.libraryID] else {
            throw LibraryError.notFound(photo.libraryID)
        }
        guard folder.isOnline else {
            throw LibraryError.offline(path: folder.lastKnownPath)
        }
        let repository = FileSidecarRepository(libraryRootURL: folder.rootURL)

        let copyID = PhotoID()
        let now = Date()
        var copy = PhotoAsset(
            id: copyID,
            libraryID: photo.libraryID,
            relativePath: photo.relativePath,
            fingerprint: photo.fingerprint,
            metadata: photo.metadata,
            status: photo.status,
            lastSeenAt: now,
            variantOf: photo.id,
            variantName: name
        )

        do {
            let sourceAdjustments = try repository.loadSidecar(for: photo.id)?.adjustments ?? .neutral
            let sidecar = PhotoSidecar(
                photoID: copyID,
                sourceRelativePath: photo.relativePath,
                sourceFingerprint: photo.fingerprint,
                decoder: DecoderDescriptor(decoder.identifier),
                adjustments: sourceAdjustments,
                createdAt: now,
                modifiedAt: now,
                variantOf: photo.id
            )
            try repository.write(sidecar: sidecar)
            copy.hasEdits = !sourceAdjustments.isNeutral
            copy.lastEditAt = copy.hasEdits ? now : nil
        } catch let error as SidecarError {
            throw LibraryError.sidecar(error)
        }

        // Best-effort, matching every scan's own tolerance for a manifest
        // write failing on a read-only drive (spec §10): the sidecar above
        // is what makes the copy real, and library.json is a portable cache
        // of it, re-derivable by a future successful write or rescan.
        if var manifest = try? repository.loadManifest() {
            manifest.upsert(PhotoRecord(
                photoID: copyID,
                relativePath: photo.relativePath,
                fingerprint: photo.fingerprint,
                lastSeenAt: now,
                variantOf: photo.id,
                variantName: name
            ))
            try? repository.write(manifest: manifest)
        }

        try index.upsert(photo: copy)
        return copy
    }

    /// Deletes `copy` -- its own sidecar and index row only. Never touches
    /// the shared RAW file, or the manifest record, sidecar or index row of
    /// the original or any other virtual copy (Phase 3 Task 3.5). Refuses
    /// anything that isn't itself a virtual copy: this is not a "delete the
    /// original photo" operation.
    public func deleteVirtualCopy(_ copy: PhotoAsset) throws {
        guard copy.variantOf != nil else {
            throw LibraryError.notAVirtualCopy(copy.id)
        }
        try recoverPendingRegistryTransaction()
        guard let folder = libraries[copy.libraryID] else {
            throw LibraryError.notFound(copy.libraryID)
        }
        guard folder.isOnline else {
            throw LibraryError.offline(path: folder.lastKnownPath)
        }
        let repository = FileSidecarRepository(libraryRootURL: folder.rootURL)

        // The sidecar is this copy's only authoritative record (spec §8.1)
        // -- removing it is what makes the deletion real, so it's the one
        // step allowed to throw and leave everything else untouched.
        do {
            try repository.removeSidecar(for: copy.id)
        } catch let error as SidecarError {
            throw LibraryError.sidecar(error)
        }

        // Best-effort, same reasoning as createVirtualCopy's own manifest
        // write: the sidecar is already gone, so the deletion already
        // succeeded from the user's point of view; a stale manifest entry
        // self-heals on the next successful write.
        if var manifest = try? repository.loadManifest() {
            manifest.remove(photoID: copy.id)
            try? repository.write(manifest: manifest)
        }

        try index.removePhotos(ids: [copy.id])
    }
}
