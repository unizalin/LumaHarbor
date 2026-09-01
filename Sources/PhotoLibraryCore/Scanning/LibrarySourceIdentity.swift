import Foundation

/// How one known source relates to a freshly resolved candidate (spec §7).
///
/// Only `.same` may reuse an existing `LibraryID`; `.ancestor`/`.descendant`
/// must reject the add outright, before any mutation, so the same file is
/// never scanned under two sources. `.conflict` is reserved for physical
/// evidence (a matching resource identifier or canonical live path) that
/// says two sources are the same folder while their confirmed manifest
/// `LibraryID`s actively disagree — a genuine contradiction, never silently
/// resolved either way. Two sources that simply each carry their own,
/// different, otherwise-unrelated manifest `LibraryID` are ordinary
/// `.distinct` sources, not a conflict. `.ambiguous` must never auto-relink
/// or auto-reuse — it exists purely so a caller can ask the user to confirm.
public enum SourceRelationship: Sendable, Equatable {
    case same
    /// The known source contains the candidate.
    case ancestor
    /// The known source is contained by the candidate.
    case descendant
    case distinct
    case ambiguous
    /// Physical evidence indicates the same folder, but confirmed manifest
    /// `LibraryID`s disagree.
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

/// Whether a volume treats differently-cased paths as the same file.
/// `.unknown` is a real, distinct state — not something that may be folded
/// into `.insensitive` by default — because guessing wrong in either
/// direction is unsafe: guessing `.insensitive` can silently merge two
/// genuinely distinct folders, and guessing `.sensitive` can miss a real
/// alias (spec §7).
public enum PathCaseSensitivity: Sendable, Equatable {
    case sensitive
    case insensitive
    case unknown
}

/// One URL's raw, opaque platform identity, decoupled from `Foundation`'s
/// `URLResourceValues` so it can be fabricated in tests — including a
/// "provider-shaped" fixture whose identifiers aren't `Data`-backed at all —
/// without needing a real, case-configurable, mountable volume.
public struct ResolvedResourceIdentity: Sendable, Equatable {
    public var fileResourceIdentifier: Data?
    public var volumeIdentifier: Data?
    public var caseSensitivity: PathCaseSensitivity

    public init(
        fileResourceIdentifier: Data?,
        volumeIdentifier: Data?,
        caseSensitivity: PathCaseSensitivity
    ) {
        self.fileResourceIdentifier = fileResourceIdentifier
        self.volumeIdentifier = volumeIdentifier
        self.caseSensitivity = caseSensitivity
    }
}

/// Seam over the platform's URL resource-value lookup (spec §7), so
/// `LibrarySourceIdentity.resolve(...)` can be exercised deterministically
/// against real directories with a controlled, injected answer — including
/// the "case sensitivity unknown" branch a real local volume never actually
/// produces — rather than only against whatever this host's real volumes
/// happen to report.
public protocol ResourceIdentityResolving: Sendable {
    /// `nil` means the lookup itself failed entirely (an unreachable URL) —
    /// distinct from a lookup that succeeded but found no usable
    /// identifiers, which is a non-`nil` result with `nil` fields.
    func resolvedIdentity(for url: URL) -> ResolvedResourceIdentity?
}

/// The real, platform-backed resolver. If the platform can't reliably
/// canonicalize an identifier (a `fileResourceIdentifier`/`volumeIdentifier`
/// that isn't `Data`-backed, or the lookup fails outright), this returns
/// `nil` fields rather than fabricating something — callers must fail closed
/// on a missing identity, never invent one (spec §7).
public struct SystemResourceIdentityResolver: ResourceIdentityResolving, Sendable {
    public init() {}

    public func resolvedIdentity(for url: URL) -> ResolvedResourceIdentity? {
        let target = url
        guard let values = try? target.resourceValues(forKeys: [
            .fileResourceIdentifierKey, .volumeIdentifierKey, .volumeSupportsCaseSensitiveNamesKey
        ]) else {
            return nil
        }
        let sensitivity: PathCaseSensitivity
        switch values.volumeSupportsCaseSensitiveNames {
        case true?: sensitivity = .sensitive
        case false?: sensitivity = .insensitive
        case nil: sensitivity = .unknown
        }
        return ResolvedResourceIdentity(
            fileResourceIdentifier: values.fileResourceIdentifier as? Data,
            volumeIdentifier: values.volumeIdentifier as? Data,
            caseSensitivity: sensitivity
        )
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
/// offline. `canonicalLivePath`/`canonicalLivePathCaseSensitivity` are the
/// one exception — they exist only to detect parent/child/alias overlap
/// between two *currently reachable* sources at add-time, are never
/// persisted, and are never taken as identity on their own.
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
    /// Symlink-resolved, natural-case standardized path — only ever
    /// populated for a URL that was actually reachable and resolvable at
    /// resolve time. Kept in its natural case; whether two natural-case-
    /// differing paths should be treated as the same file is decided at
    /// comparison time using `canonicalLivePathCaseSensitivity` from both
    /// sides, never folded here.
    public var canonicalLivePath: String?
    public var canonicalLivePathCaseSensitivity: PathCaseSensitivity

    public init(
        confirmedManifestLibraryID: LibraryID? = nil,
        resourceIdentifier: Data? = nil,
        volumeIdentifier: String? = nil,
        rootFingerprint: RootFingerprint? = nil,
        canonicalLivePath: String? = nil,
        canonicalLivePathCaseSensitivity: PathCaseSensitivity = .unknown
    ) {
        self.confirmedManifestLibraryID = confirmedManifestLibraryID
        self.resourceIdentifier = resourceIdentifier
        self.volumeIdentifier = volumeIdentifier
        self.rootFingerprint = rootFingerprint
        self.canonicalLivePath = canonicalLivePath
        self.canonicalLivePathCaseSensitivity = canonicalLivePathCaseSensitivity
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
    /// supply stable identifiers still gets a usable identity built from
    /// whatever did resolve, falling through to `rootFingerprint` alone —
    /// which `relationship(to:)` only ever treats as grounds to ask, never to
    /// auto-match. `resourceIdentityResolver` is the seam a test uses to
    /// exercise the "case sensitivity unknown" and "no stable identifier"
    /// branches deterministically, without a real provider or a
    /// case-configurable volume.
    public static func resolve(
        url: URL,
        confirmedManifestLibraryID: LibraryID?,
        fileManager: FileManager = .default,
        resourceIdentityResolver: any ResourceIdentityResolving = SystemResourceIdentityResolver()
    ) -> LibrarySourceIdentity {
        let canonicalURL = url.resolvingSymlinksInPath()

        var resourceIdentifier: Data?
        var volumeIdentifier: String?
        var canonicalLivePath: String?
        var caseSensitivity: PathCaseSensitivity = .unknown

        if let resolved = resourceIdentityResolver.resolvedIdentity(for: canonicalURL) {
            resourceIdentifier = resolved.fileResourceIdentifier
            volumeIdentifier = resolved.volumeIdentifier?.base64EncodedString()
            caseSensitivity = resolved.caseSensitivity
            canonicalLivePath = canonicalURL.standardizedFileURL.path
        }

        return LibrarySourceIdentity(
            confirmedManifestLibraryID: confirmedManifestLibraryID,
            resourceIdentifier: resourceIdentifier,
            volumeIdentifier: volumeIdentifier,
            rootFingerprint: try? boundedRootFingerprint(of: canonicalURL, fileManager: fileManager),
            canonicalLivePath: canonicalLivePath,
            canonicalLivePathCaseSensitivity: caseSensitivity
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

    private enum ManifestComparison {
        case same, conflicting, unknown
    }

    private func compareManifestIDs(with other: LibrarySourceIdentity) -> ManifestComparison {
        guard let mine = confirmedManifestLibraryID, let theirs = other.confirmedManifestLibraryID else {
            return .unknown
        }
        return mine == theirs ? .same : .conflicting
    }

    /// Decides how `self` (an existing known source) relates to `other` (a
    /// freshly resolved candidate).
    ///
    /// Evidence priority, per spec §7:
    /// 1. Matching confirmed manifest `LibraryID`s on both sides is `.same`
    ///    outright, regardless of path (an approved contract: the same
    ///    portable manifest at a different path is still the same source).
    /// 2. Disagreeing confirmed manifest `LibraryID`s never *by themselves*
    ///    produce `.conflict` — two ordinary, independently-manifested
    ///    sources are simply `.distinct`. Physical evidence is still
    ///    evaluated below; only if *that* evidence says `.same` does the
    ///    manifest disagreement escalate the result to `.conflict`.
    /// 3. A known, differing volume is always `.distinct`.
    /// 4. On a confirmed *shared* volume, a matching resource identifier is
    ///    `.same`; a missing volume on either side never lets a resource
    ///    identifier alone confirm `.same`.
    /// 5. On a confirmed shared volume, reliable canonical live-path
    ///    containment (symlinks resolved) decides `.same`/`.ancestor`/
    ///    `.descendant`/`.distinct`; a case-fold-only match is `.same` only
    ///    when both sides confirm the volume is case-*insensitive*,
    ///    `.distinct` only when both confirm case-*sensitive*, and
    ///    `.ambiguous` whenever either side's case sensitivity is unknown.
    /// 6. A bounded fingerprint match is the last resort, and only ever
    ///    yields `.ambiguous` — never `.same`, never `.distinct` outright.
    /// 7. Anything left unresolved on a *known-shared* volume — no reliable
    ///    live path on one/both sides, no fingerprint match either — fails
    ///    closed to `.ambiguous` rather than guessing `.distinct` on a volume
    ///    known to be shared. With no shared-volume evidence at all, `.distinct`
    ///    is the safe default.
    public func relationship(to other: LibrarySourceIdentity) -> SourceRelationship {
        let manifestComparison = compareManifestIDs(with: other)
        if manifestComparison == .same {
            return .same
        }

        let physical = physicalRelationship(to: other)
        if physical == .same, manifestComparison == .conflicting {
            // Physical evidence says the same folder; confirmed manifest
            // identity actively disagrees. A genuine contradiction, never
            // silently resolved either way.
            return .conflict
        }
        return physical
    }

    /// `relationship(to:)` minus the manifest-ID comparison: purely
    /// volume/resource/path/fingerprint evidence.
    private func physicalRelationship(to other: LibrarySourceIdentity) -> SourceRelationship {
        if let myVolume = volumeIdentifier, let theirVolume = other.volumeIdentifier {
            guard myVolume == theirVolume else { return .distinct }
            return relationshipOnConfirmedSharedVolume(with: other)
        }

        // Volume unknown on at least one side: matching resource/path evidence
        // cannot confirm a shared physical location, but it is still strong
        // enough that declaring the sources distinct would be unsafe.
        if let mine = resourceIdentifier, let theirs = other.resourceIdentifier, mine == theirs {
            return .ambiguous
        }
        if let minePath = canonicalLivePath, let theirsPath = other.canonicalLivePath,
           Self.possiblyEqualOrContained(mine: minePath, theirs: theirsPath) {
            return .ambiguous
        }
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
            return Self.pathRelationship(
                mine: minePath, mineSensitivity: canonicalLivePathCaseSensitivity,
                theirs: theirsPath, theirsSensitivity: other.canonicalLivePathCaseSensitivity
            )
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

    private static func pathRelationship(
        mine: String, mineSensitivity: PathCaseSensitivity,
        theirs: String, theirsSensitivity: PathCaseSensitivity
    ) -> SourceRelationship {
        if let naturalRelationship = equalityOrContainmentRelationship(mine: mine, theirs: theirs) {
            return naturalRelationship
        }

        let foldedMine = mine.lowercased()
        let foldedTheirs = theirs.lowercased()
        if let foldedRelationship = equalityOrContainmentRelationship(
            mine: foldedMine, theirs: foldedTheirs
        ) {
            if mineSensitivity == .insensitive, theirsSensitivity == .insensitive {
                return foldedRelationship
            }
            if mineSensitivity == .sensitive, theirsSensitivity == .sensitive {
                return .distinct
            }
            return .ambiguous
        }

        return .distinct
    }

    private static func possiblyEqualOrContained(mine: String, theirs: String) -> Bool {
        equalityOrContainmentRelationship(mine: mine, theirs: theirs) != nil
            || equalityOrContainmentRelationship(
                mine: mine.lowercased(), theirs: theirs.lowercased()
            ) != nil
    }

    private static func equalityOrContainmentRelationship(
        mine: String,
        theirs: String
    ) -> SourceRelationship? {
        if mine == theirs { return .same }

        if mine == "/", theirs.hasPrefix("/") { return .ancestor }
        if theirs == "/", mine.hasPrefix("/") { return .descendant }

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
        return nil
    }
}
