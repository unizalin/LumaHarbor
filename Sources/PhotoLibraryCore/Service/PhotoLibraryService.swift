import Foundation
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
}

extension LibraryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .bookmark(let error): return error.errorDescription
        case .sidecar(let error): return error.errorDescription
        case .offline: return "The drive holding this library isn't connected."
        case .notFound: return "That photo folder is no longer in your library list."
        case .indexUnavailable(let message): return "The local index is unavailable. \(message)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .bookmark(let error): return error.recoverySuggestion
        case .sidecar(let error): return error.recoverySuggestion
        case .offline: return "Reconnect the drive, then try again."
        case .notFound: return "Add the folder again."
        case .indexUnavailable: return "Quit and reopen LumaHarbor to rebuild the index."
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
    private let index: PhotoIndexStore
    private let decoder: any RawDecoding
    private let scanner: FolderScanner

    /// Held for the app's lifetime: dropping a `ScopedFolderAccess` releases the
    /// security scope, so these must outlive every read of the folder.
    private var access: [LibraryID: ScopedFolderAccess] = [:]
    private var libraries: [LibraryID: LibraryFolder] = [:]

    public init(
        locations: ApplicationSupportLocations,
        bookmarkStore: (any BookmarkStoring)? = nil,
        decoder: any RawDecoding = CoreImageRawDecoder(),
        scanner: FolderScanner = FolderScanner()
    ) throws {
        try locations.createDirectories()
        self.locations = locations
        self.bookmarkStore = bookmarkStore
            ?? FileBookmarkStore(directoryURL: locations.bookmarksDirectoryURL)
        self.index = try PhotoIndexStore(databaseURL: locations.databaseURL)
        self.decoder = decoder
        self.scanner = scanner
    }

    public var indexStore: PhotoIndexStore { index }

    // MARK: - Libraries

    public func knownLibraries() -> [LibraryFolder] {
        libraries.values.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    public func library(id: LibraryID) -> LibraryFolder? {
        libraries[id]
    }

    /// Registers a folder the user just picked. The open panel has already
    /// granted access, so this only has to remember it (spec §7).
    @discardableResult
    public func addLibrary(at url: URL, displayName: String? = nil) throws -> LibraryFolder {
        let bookmarkData: Data
        do {
            bookmarkData = try SecurityScopedBookmark.makeBookmarkData(for: url)
        } catch let error as BookmarkError {
            throw LibraryError.bookmark(error)
        }

        let repository = FileSidecarRepository(libraryRootURL: url)
        // Reuse the identifier the folder already carries, so re-adding a drive
        // on a second Mac doesn't fork the library into two.
        let existingManifest = try? repository.loadManifest()
        let libraryID = existingManifest?.libraryID ?? LibraryID()

        let folder = LibraryFolder(
            id: libraryID,
            displayName: displayName ?? url.lastPathComponent,
            rootURL: url,
            isOnline: true,
            isWritable: repository.isWritable
        )

        try bookmarkStore.save(StoredBookmark(
            libraryID: libraryID,
            displayName: folder.displayName,
            lastKnownPath: url.path,
            bookmarkData: bookmarkData
        ))

        access[libraryID] = ScopedFolderAccess(url: url)
        libraries[libraryID] = folder
        try index.upsert(library: folder)

        if existingManifest == nil, repository.isWritable {
            try? repository.write(manifest: LibraryManifest(libraryID: libraryID))
        }
        return folder
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

        for bookmark in stored {
            var folder = LibraryFolder(
                id: bookmark.libraryID,
                displayName: bookmark.displayName,
                rootURL: URL(fileURLWithPath: bookmark.lastKnownPath, isDirectory: true),
                lastKnownPath: bookmark.lastKnownPath,
                isOnline: false,
                isWritable: false
            )

            if let scopedAccess = try? ScopedFolderAccess(resolving: bookmark.bookmarkData),
               scopedAccess.isReachable {
                access[bookmark.libraryID] = scopedAccess
                let repository = FileSidecarRepository(libraryRootURL: scopedAccess.url)
                folder.rootURL = scopedAccess.url
                folder.isOnline = true
                folder.isWritable = repository.isWritable

                // macOS asked for a fresh bookmark; write one back now while we
                // still hold a live scope.
                if scopedAccess.isStale,
                   let refreshed = try? SecurityScopedBookmark.makeBookmarkData(for: scopedAccess.url) {
                    var updated = bookmark
                    updated.bookmarkData = refreshed
                    updated.lastKnownPath = scopedAccess.url.path
                    try? bookmarkStore.save(updated)
                }
            }

            folder.photoCount = (try? index.photoCount(inLibrary: folder.id)) ?? 0
            if let indexed = try? index.library(id: folder.id) {
                folder.lastScanAt = indexed.lastScanAt
            }

            libraries[folder.id] = folder
            try? index.upsert(library: folder)
            restored.append(folder)
        }

        return restored
    }

    /// Re-points a library at a folder the user picked again after the bookmark
    /// went stale. The `LibraryID` is preserved, so every sidecar still matches.
    @discardableResult
    public func relink(libraryID: LibraryID, to url: URL) throws -> LibraryFolder {
        guard var folder = libraries[libraryID] else {
            throw LibraryError.notFound(libraryID)
        }
        let bookmarkData: Data
        do {
            bookmarkData = try SecurityScopedBookmark.makeBookmarkData(for: url)
        } catch let error as BookmarkError {
            throw LibraryError.bookmark(error)
        }

        access[libraryID]?.stop()
        access[libraryID] = ScopedFolderAccess(url: url)

        let repository = FileSidecarRepository(libraryRootURL: url)
        folder.rootURL = url
        folder.lastKnownPath = url.path
        folder.isOnline = true
        folder.isWritable = repository.isWritable

        try bookmarkStore.save(StoredBookmark(
            libraryID: libraryID,
            displayName: folder.displayName,
            lastKnownPath: url.path,
            bookmarkData: bookmarkData
        ))
        libraries[libraryID] = folder
        try index.upsert(library: folder)
        return folder
    }

    public func removeLibrary(id: LibraryID) throws {
        access[id]?.stop()
        access[id] = nil
        libraries[id] = nil
        try bookmarkStore.remove(libraryID: id)
        try index.removeLibrary(id: id)
    }

    /// Re-checks whether the drive is plugged in and writable (spec §10).
    @discardableResult
    public func refreshAvailability(libraryID: LibraryID) throws -> LibraryFolder {
        guard var folder = libraries[libraryID] else {
            throw LibraryError.notFound(libraryID)
        }
        let repository = FileSidecarRepository(libraryRootURL: folder.rootURL)
        folder.isOnline = repository.isAvailable
        folder.isWritable = repository.isWritable
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

    // MARK: - Scanning

    /// Streams a full folder scan.
    ///
    /// Rebuilding a deleted SQLite database is the same code path: the manifest
    /// on the SSD supplies the `PhotoID`s, so photos keep their edits (spec §13.9).
    public nonisolated func scan(libraryID: LibraryID) -> AsyncStream<LibraryScanEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                await self.performScan(libraryID: libraryID, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performScan(
        libraryID: LibraryID,
        continuation: AsyncStream<LibraryScanEvent>.Continuation
    ) async {
        guard let folder = libraries[libraryID] else {
            continuation.yield(.failed(.notFound(libraryID)))
            return
        }

        let repository = FileSidecarRepository(libraryRootURL: folder.rootURL)
        guard repository.isAvailable else {
            continuation.yield(.failed(.offline(path: folder.rootURL.path)))
            return
        }

        continuation.yield(.started(libraryID))
        let scanStartedAt = Date()

        var manifest: LibraryManifest
        do {
            manifest = try repository.loadManifest() ?? LibraryManifest(libraryID: libraryID)
        } catch let error as SidecarError {
            // A damaged manifest has already been quarantined; rebuilding from
            // the sidecars still on disk is better than refusing to scan.
            continuation.yield(.failed(.sidecar(error)))
            manifest = LibraryManifest(libraryID: libraryID)
        } catch {
            manifest = LibraryManifest(libraryID: libraryID)
        }

        var indexed = 0
        var failed = 0
        var ambiguous = 0
        var moved = 0
        var cancelled = false

        for await event in scanner.scan(root: folder.rootURL) {
            if Task.isCancelled {
                cancelled = true
                break
            }

            switch event {
            case .started:
                continue

            case .fileFailed(let relativePath, let reason):
                failed += 1
                continuation.yield(.photoFailed(relativePath: relativePath, reason: reason))

            case .discovered(let files):
                var batch: [PhotoAsset] = []
                batch.reserveCapacity(files.count)

                for file in files {
                    if Task.isCancelled { cancelled = true; break }

                    let outcome = await Self.inspect(
                        file: file,
                        manifest: manifest,
                        decoder: decoder,
                        libraryID: libraryID
                    )

                    switch outcome {
                    case .failure(let reason):
                        failed += 1
                        continuation.yield(
                            .photoFailed(relativePath: file.relativePath, reason: reason)
                        )
                    case .success(var asset, let record, let decision):
                        if case .ambiguous = decision { ambiguous += 1 }
                        if case .moved = decision { moved += 1 }
                        asset.hasEdits = Self.hasStoredEdits(
                            photoID: asset.id, repository: repository
                        )
                        manifest.upsert(record)
                        batch.append(asset)
                        indexed += 1
                    }
                }

                if !batch.isEmpty {
                    do {
                        try index.upsert(photos: batch)
                        continuation.yield(.photosIndexed(batch))
                    } catch {
                        continuation.yield(.failed(
                            .indexUnavailable((error as NSError).localizedDescription)
                        ))
                    }
                }

            case .finished:
                continue
            }
        }

        // Drop rows for files that disappeared from the drive.
        if !cancelled {
            try? index.removePhotos(inLibrary: libraryID, notSeenSince: scanStartedAt)
        }

        var manifestFailure: String?
        manifest.lastSuccessfulScanAt = cancelled ? manifest.lastSuccessfulScanAt : Date()
        do {
            try repository.write(manifest: manifest)
        } catch {
            // Spec §10: a read-only drive stays browsable. The portable copy is
            // stale, but nothing is lost and the user is told why.
            manifestFailure = (error as? LocalizedError)?.errorDescription
                ?? (error as NSError).localizedDescription
        }

        if var updated = libraries[libraryID] {
            updated.lastScanAt = Date()
            updated.photoCount = (try? index.photoCount(inLibrary: libraryID)) ?? indexed
            updated.isWritable = repository.isWritable
            libraries[libraryID] = updated
            try? index.upsert(library: updated)
        }

        continuation.yield(.finished(LibraryScanResult(
            libraryID: libraryID,
            indexedCount: indexed,
            failedCount: failed,
            ambiguousCount: ambiguous,
            movedCount: moved,
            wasCancelled: cancelled,
            manifestWriteFailure: manifestFailure,
            completedAt: Date()
        )))
    }

    private enum InspectionOutcome: Sendable {
        case success(PhotoAsset, PhotoRecord, RelinkDecision)
        case failure(reason: String)
    }

    /// Fingerprint, identity and metadata for one file.
    ///
    /// Detached so hashing and EXIF reads stay off the main thread (spec §11),
    /// and `nonisolated static` so it can't accidentally capture actor state.
    private static func inspect(
        file: ScannedFile,
        manifest: LibraryManifest,
        decoder: any RawDecoding,
        libraryID: LibraryID
    ) async -> InspectionOutcome {
        let records = manifest.photos
        let url = file.url

        return await Task.detached(priority: .utility) { () -> InspectionOutcome in
            let fingerprint: FileFingerprint
            do {
                fingerprint = try FingerprintCalculator.fingerprint(forFileAt: url)
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
        }.value
    }

    private static func hasStoredEdits(
        photoID: PhotoID,
        repository: FileSidecarRepository
    ) -> Bool {
        guard let sidecar = try? repository.loadSidecar(for: photoID) else { return false }
        return !sidecar.adjustments.isNeutral
    }

    // MARK: - Edits

    /// Reads a photo's saved adjustments, or neutral when it has never been
    /// edited. Corrupt or newer-schema sidecars throw so the UI can explain.
    public func adjustments(for photo: PhotoAsset) throws -> PhotoAdjustments {
        guard let folder = libraries[photo.libraryID] else {
            throw LibraryError.notFound(photo.libraryID)
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
            try? index.setHasEdits(!adjustments.isNeutral, for: photo.id)
        } catch let error as SidecarError {
            throw LibraryError.sidecar(error)
        }
    }
}
