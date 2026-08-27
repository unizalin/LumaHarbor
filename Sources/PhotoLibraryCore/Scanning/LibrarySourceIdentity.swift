import Foundation

/// How one known source relates to a freshly resolved candidate (spec §7).
///
/// Only `.same` may reuse an existing `LibraryID`; `.ancestor`/`.descendant`
/// must reject the add outright, before any mutation, so the same file is
/// never scanned under two sources. `.conflict` — two sources whose manifests
/// carry different confirmed `LibraryID`s but otherwise look like the same
/// physical folder — is a stronger, terminal disagreement, never downgraded
/// to `.same` by a matching path or resource identifier. `.ambiguous` must
/// never auto-relink or auto-reuse — it exists purely so a caller can ask the
/// user to confirm.
public enum SourceRelationship: Sendable, Equatable {
    case same
    /// The known source contains the candidate.
    case ancestor
    /// The known source is contained by the candidate.
    case descendant
    case distinct
    case ambiguous
    /// Both sides have a confirmed manifest `LibraryID`, and they disagree.
    case conflict
}

/// A bounded, cheap summary of a folder's immediate contents.
///
/// Spec §7 step 3: used only to prompt the user for confirmation when no
/// stronger identity signal — manifest `LibraryID` or bookmark-resolved
/// resource identifier — is available. Never used to auto-declare two
/// sources the same; listing is one level deep, never recursive, and the
/// sample is capped so it stays cheap even over a folder with many entries.
public struct RootFingerprint: Sendable, Equatable, Codable {
    public var childCount: Int
    public var sampleNames: [String]

    public init(childCount: Int, sampleNames: [String]) {
        self.childCount = childCount
        self.sampleNames = sampleNames
    }
}

/// What makes one authorised photo source the same physical location as
/// another, across relaunches, relinks and re-adds (spec §7).
///
/// Deliberately holds no runtime root URL as identity: `resourceIdentifier`
/// and `volumeIdentifier` are values read once from bookmark resolution, and
/// `confirmedManifestLibraryID` is portable data read from an actual manifest
/// on the source itself — never assumed from an in-memory `LibraryID` — so
/// all three survive being persisted and compared while the source is
/// offline. `canonicalLivePath` is the one exception — it exists only to
/// detect parent/child/alias overlap between two *currently reachable*
/// sources at add-time, is never persisted, and never taken as identity on
/// its own.
public struct LibrarySourceIdentity: Sendable, Equatable {
    /// A manifest `LibraryID` actually read from `.lumaharbor/library.json`
    /// via a read-only probe — never a locally-minted `LibraryID` standing in
    /// for one, and never set just because a manifest write is about to
    /// happen or just happened to fail.
    public var confirmedManifestLibraryID: LibraryID?
    public var resourceIdentifier: Data?
    /// Canonical, stable string form of the bookmark-resolved volume
    /// identifier (base64 of the underlying bytes) — a `String` rather than
    /// `Data` so it round-trips through `StoredBookmark`'s existing
    /// (already-base64) JSON representation unchanged.
    public var volumeIdentifier: String?
    public var rootFingerprint: RootFingerprint?
    /// Symlink-resolved, filesystem-case-normalized path — only ever
    /// populated for a URL that was actually reachable at resolve time.
    public var canonicalLivePath: String?

    public init(
        confirmedManifestLibraryID: LibraryID? = nil,
        resourceIdentifier: Data? = nil,
        volumeIdentifier: String? = nil,
        rootFingerprint: RootFingerprint? = nil,
        canonicalLivePath: String? = nil
    ) {
        self.confirmedManifestLibraryID = confirmedManifestLibraryID
        self.resourceIdentifier = resourceIdentifier
        self.volumeIdentifier = volumeIdentifier
        self.rootFingerprint = rootFingerprint
        self.canonicalLivePath = canonicalLivePath
    }

    /// Reads the stable, bookmark-resolvable identity components for a
    /// currently-reachable folder (spec §7 steps 1-2). `confirmedManifestLibraryID`
    /// is supplied by the caller, already obtained from a read-only manifest
    /// probe — this type doesn't depend on the sidecar repository so it stays
    /// testable without a file system.
    ///
    /// The URL is resolved through any symlinks *before* any resource lookup
    /// or path canonicalization, so a symlink alias to an already-known
    /// source's root reliably surfaces as the same underlying file, not a
    /// distinct one (spec §7: overlap detection must not be bypassable by an
    /// alias).
    ///
    /// Every component is best-effort: a read-only provider that can't
    /// supply `fileResourceIdentifierKey`/`volumeIdentifierKey` still gets a
    /// usable identity built from whatever did resolve, falling through to
    /// `rootFingerprint` alone — which `relationship(to:)` only ever treats
    /// as grounds to ask, never to auto-match.
    public static func resolve(
        url: URL,
        confirmedManifestLibraryID: LibraryID?,
        fileManager: FileManager = .default
    ) -> LibrarySourceIdentity {
        let canonicalURL = url.resolvingSymlinksInPath()

        var resourceIdentifier: Data?
        var volumeIdentifier: String?
        var canonicalLivePath: String?
        if let values = try? canonicalURL.resourceValues(forKeys: [
            .fileResourceIdentifierKey, .volumeIdentifierKey, .volumeSupportsCaseSensitiveNamesKey
        ]) {
            resourceIdentifier = values.fileResourceIdentifier as? Data
            volumeIdentifier = (values.volumeIdentifier as? Data)?.base64EncodedString()
            // Only a volume that actually reports itself case-sensitive is
            // treated as one; an unknown answer is folded case-insensitively
            // to the safe side, since that's the direction that catches an
            // alias rather than missing it.
            let isCaseSensitive = values.volumeSupportsCaseSensitiveNames ?? false
            let standardizedPath = canonicalURL.standardizedFileURL.path
            canonicalLivePath = isCaseSensitive ? standardizedPath : standardizedPath.lowercased()
        }

        return LibrarySourceIdentity(
            confirmedManifestLibraryID: confirmedManifestLibraryID,
            resourceIdentifier: resourceIdentifier,
            volumeIdentifier: volumeIdentifier,
            rootFingerprint: try? boundedRootFingerprint(of: canonicalURL, fileManager: fileManager),
            canonicalLivePath: canonicalLivePath
        )
    }

    private static let sampleLimit = 8

    private static func boundedRootFingerprint(
        of url: URL,
        fileManager: FileManager
    ) throws -> RootFingerprint {
        let entries = try fileManager.contentsOfDirectory(atPath: url.path)
        let sample = entries.sorted().prefix(sampleLimit)
        return RootFingerprint(childCount: entries.count, sampleNames: Array(sample))
    }

    /// Only the components that may be persisted across a relaunch (spec
    /// §7): no live path, so a stored identity can never be mistaken for a
    /// runtime root URL.
    public var persistable: LibrarySourceIdentity {
        LibrarySourceIdentity(
            confirmedManifestLibraryID: confirmedManifestLibraryID,
            resourceIdentifier: resourceIdentifier,
            volumeIdentifier: volumeIdentifier,
            rootFingerprint: rootFingerprint,
            canonicalLivePath: nil
        )
    }

    /// Decides how `self` (an existing known source) relates to `other` (a
    /// freshly resolved candidate).
    ///
    /// Evidence priority, per spec §7:
    /// 1. Both sides have a confirmed manifest `LibraryID`: equal is `.same`,
    ///    unequal is `.conflict` — terminal either way, never downgraded by
    ///    a matching path or resource identifier.
    /// 2. A known, differing volume is always `.distinct`.
    /// 3. On a confirmed *shared* volume, a matching resource identifier is
    ///    `.same`; a missing volume on either side never lets a resource
    ///    identifier alone confirm `.same`.
    /// 4. On a confirmed shared volume, reliable canonical live-path
    ///    containment (symlinks resolved, case-normalized per volume) decides
    ///    `.same`/`.ancestor`/`.descendant`/`.distinct`.
    /// 5. A bounded fingerprint match is the last resort, and only ever
    ///    yields `.ambiguous` — never `.same`, never `.distinct` outright.
    /// 6. Anything left unresolved on a *known-shared* volume — no reliable
    ///    live path on one/both sides, no fingerprint match either — fails
    ///    closed to `.ambiguous` rather than guessing `.distinct` on a volume
    ///    known to be shared. With no shared-volume evidence at all, `.distinct`
    ///    is the safe default.
    public func relationship(to other: LibrarySourceIdentity) -> SourceRelationship {
        if let mine = confirmedManifestLibraryID, let theirs = other.confirmedManifestLibraryID {
            return mine == theirs ? .same : .conflict
        }

        if let myVolume = volumeIdentifier, let theirVolume = other.volumeIdentifier {
            guard myVolume == theirVolume else { return .distinct }
            return relationshipOnConfirmedSharedVolume(with: other)
        }

        // Volume unknown on at least one side: resource-identifier and
        // live-path comparisons both require a confirmed shared volume, so
        // only a fingerprint match remains, and it only ever asks.
        if let mine = rootFingerprint, let theirs = other.rootFingerprint, mine == theirs {
            return .ambiguous
        }
        return .distinct
    }

    private func relationshipOnConfirmedSharedVolume(with other: LibrarySourceIdentity) -> SourceRelationship {
        if let mine = resourceIdentifier, let theirs = other.resourceIdentifier, mine == theirs {
            return .same
        }

        if let minePath = canonicalLivePath, let theirsPath = other.canonicalLivePath {
            return Self.pathRelationship(mine: minePath, theirs: theirsPath)
        }

        // Same volume confirmed, but no reliable live-path comparison was
        // possible (an offline source, or an unresolved candidate) — a
        // fingerprint match is still only ever grounds to ask.
        if let mine = rootFingerprint, let theirs = other.rootFingerprint, mine == theirs {
            return .ambiguous
        }

        // Known to share a volume, yet nothing let us tell same/ancestor/
        // descendant/distinct apart reliably: fail closed rather than assert
        // `.distinct` on a volume we know is shared (spec §7).
        return .ambiguous
    }

    private static func pathRelationship(mine: String, theirs: String) -> SourceRelationship {
        if mine == theirs { return .same }
        let separator: Character = "/"
        if mine.count < theirs.count,
           theirs.hasPrefix(mine),
           theirs[theirs.index(theirs.startIndex, offsetBy: mine.count)] == separator {
            return .ancestor
        }
        if theirs.count < mine.count,
           mine.hasPrefix(theirs),
           mine[mine.index(mine.startIndex, offsetBy: theirs.count)] == separator {
            return .descendant
        }
        return .distinct
    }
}
