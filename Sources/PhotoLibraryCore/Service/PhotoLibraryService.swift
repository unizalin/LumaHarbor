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
        try locations.createDirectories()
        self.locations = locations
        self.bookmarkStore = bookmarkStore
            ?? FileBookmarkStore(directoryURL: locations.bookmarksDirectoryURL)
        self.index = try PhotoIndexStore(databaseURL: locations.databaseURL)
        self.decoder = decoder
        self.scanner = scanner
        self.folderAccessResolver = folderAccessResolver
        self.resourceIdentityResolver = resourceIdentityResolver
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

    private static func makeBookmarkData(for url: URL) throws -> Data {
        do {
            return try SecurityScopedBookmark.makeBookmarkData(for: url)
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

        let bookmarkData = try Self.makeBookmarkData(for: url)

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

        // PERSIST: bookmark, then index. A failure here has touched nothing
        // that needs undoing except the bookmark this very call just wrote.
        try bookmarkStore.save(storedBookmark)
        do {
            try index.upsert(library: folder)
        } catch {
            try? bookmarkStore.remove(libraryID: libraryID)
            throw error
        }

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
    /// Otherwise staged identically to `createNewLibrary`: bookmark, then
    /// index; a mid-way failure rolls the bookmark back to its previous
    /// value (or removes it, if there really wasn't one) and never touches
    /// the security scope or in-memory state — so a failed focus/relink
    /// leaves the old root, bookmark, index and access completely
    /// untouched, and never opens a new security scope it would have to
    /// release. If the rollback write itself also fails, the original
    /// failure is still what's thrown (never silently swallowed) and
    /// `access`/`libraries` remain the old, untouched values for the rest of
    /// this run; the next `restoreLibraries()` call re-reads whichever
    /// complete state the bookmark file (written atomically, so never torn)
    /// actually ended up holding and re-syncs the index to match it, so a
    /// restart always converges to one consistent, recognisable state.
    private func focusExistingLibrary(
        _ existing: LibraryFolder,
        at url: URL,
        displayName: String?,
        candidateIdentity: LibrarySourceIdentity,
        repository: FileSidecarRepository
    ) throws -> LibraryFolder {
        let previousStoredBookmark = try bookmarkStore.load(libraryID: existing.id)

        let bookmarkData = try Self.makeBookmarkData(for: url)

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

        try bookmarkStore.save(newStoredBookmark)
        do {
            try index.upsert(library: folder)
        } catch {
            if let previousStoredBookmark {
                try? bookmarkStore.save(previousStoredBookmark)
            } else {
                try? bookmarkStore.remove(libraryID: existing.id)
            }
            throw error
        }

        access[existing.id]?.stop()
        access[existing.id] = folderAccessResolver.grant(url: url)
        libraries[existing.id] = folder
        restoreDiagnostics.removeValue(forKey: existing.id)

        return folder
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
                    let refreshed = try Self.makeBookmarkData(for: stagedAccess.url)
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
                    folder.connectionState = .needsAuthorization
                    folder = try commitDisconnectedRestore(
                        folder: folder,
                        diagnostic: .persistenceFailure,
                        stagedAccess: stagedAccess
                    )
                    restored.append(folder)
                    continue
                }
            }

            if requiresSave {
                do {
                    try bookmarkStore.save(updatedBookmark)
                } catch {
                    folder.connectionState = .needsAuthorization
                    folder = try commitDisconnectedRestore(
                        folder: folder,
                        diagnostic: .persistenceFailure,
                        stagedAccess: stagedAccess
                    )
                    restored.append(folder)
                    continue
                }
            }

            folder.connectionState = repository.isWritable ? .ready : .readOnly
            do {
                try populateRestoreProjection(&folder)
                try index.upsert(library: folder)
            } catch {
                stagedAccess.stop()
                throw error
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

    private func commitDisconnectedRestore(
        folder initialFolder: LibraryFolder,
        diagnostic: LibraryRestoreDiagnostic?,
        stagedAccess: (any FolderAccessHandle)?
    ) throws -> LibraryFolder {
        stagedAccess?.stop()
        access.removeValue(forKey: initialFolder.id)?.stop()

        var folder = initialFolder
        libraries[folder.id] = folder
        if let diagnostic {
            restoreDiagnostics[folder.id] = diagnostic
        } else {
            restoreDiagnostics.removeValue(forKey: folder.id)
        }

        try populateRestoreProjection(&folder)
        libraries[folder.id] = folder
        try index.upsert(library: folder)
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
            candidateIdentity: candidateIdentity, repository: repository
        )
    }

    /// Removes a source's *local* bookmark, index rows and progress state
    /// only. Must never touch the source root itself — RAW, sidecar and
    /// manifest content all stay exactly where they are (spec §7, §11): this
    /// intentionally never constructs a `FileSidecarRepository` or otherwise
    /// calls a source-file remover.
    public func removeLibrary(id: LibraryID) throws {
        access[id]?.stop()
        access[id] = nil
        libraries[id] = nil
        restoreDiagnostics[id] = nil
        try bookmarkStore.remove(libraryID: id)
        try index.removeLibrary(id: id)
    }

    /// Re-checks whether the drive is plugged in and writable (spec §10).
    @discardableResult
    public func refreshAvailability(libraryID: LibraryID) throws -> LibraryFolder {
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

    // MARK: - Rebuildable local data

    /// Deletes and recreates the local SQLite index and thumbnail/preview
    /// caches, leaving bookmarks and portable sidecars untouched (spec §13.9).
    ///
    /// This is the only supported way to do it: closing the connection here,
    /// before the file is unlinked, is what prevents the disk I/O error that
    /// comes from a second connection opening the same path while this actor
    /// still holds the first one.
    public func resetRebuildableLocalData() throws {
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

                    let outcome = await Self.inspect(
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
                        let editState = Self.editState(photoID: asset.id, repository: repository)
                        asset.hasEdits = editState.hasEdits
                        asset.lastEditAt = editState.lastEditAt
                        manifest.upsert(record)
                        batch.append(asset)
                        indexed += 1
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
                        try index.upsert(photos: batch)
                        await emit(.photosIndexed(batch))
                    } catch {
                        await emit(.failed(
                            .indexUnavailable((error as NSError).localizedDescription)
                        ))
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

    /// Reconstructs both edit-state columns from the sidecar during a
    /// rescan: the sidecar is authoritative, SQLite is a rebuildable
    /// projection of it (spec §8.1). A neutral or absent sidecar maps to
    /// `(false, nil)`; a non-neutral one carries its own `modifiedAt`
    /// forward as `lastEditAt`, matching what `saveAdjustments` would have
    /// projected at save time.
    private static func editState(
        photoID: PhotoID,
        repository: FileSidecarRepository
    ) -> (hasEdits: Bool, lastEditAt: Date?) {
        guard let sidecar = try? repository.loadSidecar(for: photoID) else { return (false, nil) }
        let hasEdits = !sidecar.adjustments.isNeutral
        return (hasEdits, hasEdits ? sidecar.modifiedAt : nil)
    }

    // MARK: - Edits

    /// Reads a photo's saved adjustments, or neutral when it has never been
    /// edited. Corrupt or newer-schema sidecars throw so the UI can explain.
    public func adjustments(for photo: PhotoAsset) throws -> PhotoAdjustments {
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
        guard let folder = libraries[photo.libraryID] else {
            throw LibraryError.notFound(photo.libraryID)
        }
        guard folder.isOnline else {
            throw LibraryError.offline(path: folder.lastKnownPath)
        }
        let repository = FileSidecarRepository(libraryRootURL: folder.rootURL)

        do {
            // `try?` flattens, so this is a single-level optional: nil means
            // "no sidecar yet" or "unreadable", and either way we write a fresh
            // one rather than inheriting a bogus creation date.
            let existing = try? repository.loadSidecar(for: photo.id)
            let now = Date()
            let sidecar = PhotoSidecar(
                photoID: photo.id,
                sourceRelativePath: photo.relativePath,
                sourceFingerprint: photo.fingerprint,
                decoder: DecoderDescriptor(decoder.identifier),
                adjustments: adjustments,
                createdAt: existing?.createdAt ?? now,
                modifiedAt: now
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
}
