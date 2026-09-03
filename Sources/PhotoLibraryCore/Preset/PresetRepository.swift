import Foundation
import Localization
import PresetCore

/// Which storage scope a `PresetRepository` instance manages (spec §5.1: "我的
/// Preset" is available everywhere; "此照片庫的 Preset" travels with one library).
public enum PresetScope: Sendable, Equatable {
    /// Rooted at the user's Application Support directory (spec §8.1:
    /// `LumaHarbor/Presets/`). `rootURL` is the presets directory itself.
    case myPresets(rootURL: URL)
    /// Rooted at `<library-root>/.lumaharbor/presets/` (spec §8.1). Stores the
    /// *library* root, not the presets subdirectory, so availability/writability
    /// checks reflect whether the drive itself is mounted -- an absent
    /// `presets/` subdirectory just means "no presets saved yet", not "offline".
    case libraryPresets(libraryRootURL: URL)

    /// The directory `.lhpreset` files are read from and written to.
    var directoryURL: URL {
        switch self {
        case .myPresets(let rootURL):
            return rootURL
        case .libraryPresets(let libraryRootURL):
            return libraryRootURL
                .appendingPathComponent(FileSidecarRepository.directoryName, isDirectory: true)
                .appendingPathComponent("presets", isDirectory: true)
        }
    }

    /// The path whose existence/writability determines "is this scope's
    /// storage available at all" -- for a library, that's the library root
    /// (which may be an unmounted drive), not the possibly-not-yet-created
    /// `presets/` subdirectory.
    var availabilityAnchorURL: URL {
        switch self {
        case .myPresets(let rootURL): return rootURL
        case .libraryPresets(let libraryRootURL): return libraryRootURL
        }
    }
}

/// How to resolve a same-UUID, different-content conflict on `save` (spec §8.2).
/// Not consulted when the existing document is canonically identical -- that
/// case is always a silent skip, regardless of this value.
public enum PresetConflictResolution: Sendable, Equatable {
    case cancel
    case replace
    case keepBoth
}

/// The outcome of one `save` call (spec §8.2).
public enum PresetStoreResult: Sendable, Equatable {
    case created
    case replaced
    /// A new UUID was minted for the incoming document so both copies coexist.
    case keptBoth(newID: UUID)
    /// Same UUID, canonically identical content -- treated as a duplicate,
    /// not written again.
    case duplicateSkipped
    /// A genuine conflict (same UUID, different content) with `.cancel`.
    case cancelled
}

/// Two scopes of durable `PresetDocument` storage (spec §5.1, §8.1): "my
/// presets" (Application Support, always available) and "this library's
/// presets" (`.lumaharbor/presets/`, may be offline or read-only).
public protocol PresetRepository: Sendable {
    func list() async throws -> [PresetDocument]
    func load(id: UUID) async throws -> PresetDocument?
    func save(_ document: PresetDocument, conflict: PresetConflictResolution) async throws -> PresetStoreResult
    func delete(id: UUID) async throws
}

/// Errors specific to moving/copying a preset between scopes -- distinct from
/// `PresetError` because "the id you asked to transfer doesn't exist at the
/// source" and "the destination doesn't have what we just wrote" are
/// repository-transaction concerns, not XMP/schema concerns.
public enum PresetTransferError: Error, Equatable, Sendable {
    case sourceNotFound(UUID)
    /// The destination's copy, read back immediately after `save`, didn't
    /// canonically match the source -- the transaction stops before deleting
    /// anything at the source (spec §8.2: never lose data to a transfer bug).
    case verificationFailed(UUID)
}

public enum PresetScopeTransferResult: Sendable, Equatable {
    case moved
    /// The verified copy exists at the destination, but deleting the source
    /// failed (e.g. it just went read-only) -- spec §8.2: never report a full
    /// move when the source is still there.
    case copiedSourceRetained(reason: String)
    /// The destination reported a genuine conflict and the caller chose
    /// `.cancel` -- nothing was written at the destination, so the source is
    /// untouched.
    case cancelled
}

/// Copy-then-verify-then-delete (spec §8.2). Never deletes the source until a
/// canonical read-back from the destination confirms the copy landed intact.
public func transferPreset(
    id: UUID,
    from source: any PresetRepository,
    to destination: any PresetRepository,
    conflict: PresetConflictResolution
) async throws -> PresetScopeTransferResult {
    guard let document = try await source.load(id: id) else {
        throw PresetTransferError.sourceNotFound(id)
    }

    let result = try await destination.save(document, conflict: conflict)
    let resolvedID: UUID
    switch result {
    case .created, .replaced, .duplicateSkipped:
        resolvedID = document.id
    case .keptBoth(let newID):
        resolvedID = newID
    case .cancelled:
        return .cancelled
    }

    guard let verified = try await destination.load(id: resolvedID),
          presetDocumentsAreCanonicallyEqual(verified, document) else {
        throw PresetTransferError.verificationFailed(id)
    }

    do {
        try await source.delete(id: id)
        return .moved
    } catch {
        return .copiedSourceRetained(reason: safeCopiedSourceRetainedReason(for: error))
    }
}

/// Never echoes an arbitrary caught `Error`'s description into this
/// user-facing result. A plain `NSError` -- e.g. from `FileManager.removeItem`
/// racing with a permission change after the writability check -- commonly
/// carries the full absolute path, and therefore the account username, in
/// `userInfo` (`NSFilePath`); `String(describing:)` prints that verbatim, and
/// even `(error as? LocalizedError)?.errorDescription` isn't a guarantee an
/// arbitrary `NSError` won't include it. Every `PresetError` case is
/// deliberately written so its own `errorDescription` never binds a path
/// into the message (see `PresetError+LocalizedError`), so those are safe to
/// surface as-is; anything else -- a type this function doesn't recognise --
/// gets one fixed, generic reason instead of whatever it happens to say.
private func safeCopiedSourceRetainedReason(for error: Error) -> String {
    if let presetError = error as? PresetError, let description = presetError.errorDescription {
        return description
    }
    return L10n.t("The copy at the new location is safe, but the original couldn't be removed from its previous location.")
}

/// The outcome of restoring a whole `PresetBackupArchive` into one
/// repository (Phase 3 Task 3.2) -- one document at a time, via the same
/// per-document conflict resolution `save`/`PresetStoreResult` already
/// define, tallied rather than surfaced individually since a restore can
/// easily cover dozens of presets at once.
public struct PresetRestoreSummary: Sendable, Equatable {
    public var created = 0
    public var replaced = 0
    public var keptBoth = 0
    public var duplicateSkipped = 0
    public var cancelled = 0
    /// A document that failed validation (`PresetDocument.validated()`) or
    /// hit a repository-level error (e.g. restoring into a read-only scope)
    /// -- counted, never thrown, so one bad document in a large archive
    /// doesn't abort every other document's restore.
    public var failed = 0

    public init() {}
}

/// Replays every document from a decoded `PresetBackupArchive` into
/// `destination`, one `save` per document under the same `conflict` policy,
/// tallying what happened rather than stopping at the first problem -- a
/// restore is expected to run over many presets at once, and one invalid or
/// conflicting document must not hide the rest.
public func restorePresets(
    _ documents: [PresetDocument],
    into destination: any PresetRepository,
    conflict: PresetConflictResolution
) async -> PresetRestoreSummary {
    var summary = PresetRestoreSummary()
    for document in documents {
        do {
            let validated = try document.validated()
            switch try await destination.save(validated, conflict: conflict) {
            case .created: summary.created += 1
            case .replaced: summary.replaced += 1
            case .keptBoth: summary.keptBoth += 1
            case .duplicateSkipped: summary.duplicateSkipped += 1
            case .cancelled: summary.cancelled += 1
            }
        } catch {
            summary.failed += 1
        }
    }
    return summary
}

/// Content equality that ignores identity/timestamps: two documents are the
/// "same preset" if everything a user or the render pipeline could observe is
/// identical, regardless of *when* each copy was created/modified.
func presetDocumentsAreCanonicallyEqual(_ a: PresetDocument, _ b: PresetDocument) -> Bool {
    a.schemaVersion == b.schemaVersion
        && a.name == b.name
        && a.groupPath == b.groupPath
        && a.isFavorite == b.isFavorite
        && a.source == b.source
        && a.patch == b.patch
        && a.xmpEnvelope == b.xmpEnvelope
}
