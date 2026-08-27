import Foundation

/// How one known source relates to a freshly resolved candidate (spec §7).
///
/// Only `.same` may reuse an existing `LibraryID`; `.ancestor`/`.descendant`
/// must reject the add outright, before any mutation, so the same file is
/// never scanned under two sources. `.ambiguous` must never auto-relink or
/// auto-reuse — it exists purely so a caller can ask the user to confirm.
public enum SourceRelationship: Sendable, Equatable {
    case same
    /// The known source contains the candidate.
    case ancestor
    /// The known source is contained by the candidate.
    case descendant
    case distinct
    case ambiguous
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
/// `manifestLibraryID` is portable data from the source itself, so both
/// survive being persisted and compared while the source is offline.
/// `livePathComponents` is the one exception — it exists only to detect
/// parent/child overlap between two *currently reachable* sources at
/// add-time, is never persisted, and never taken as identity on its own.
public struct LibrarySourceIdentity: Sendable, Equatable {
    public var manifestLibraryID: LibraryID?
    public var resourceIdentifier: Data?
    public var volumeIdentifier: Data?
    public var rootFingerprint: RootFingerprint?
    public var livePathComponents: [String]?

    public init(
        manifestLibraryID: LibraryID? = nil,
        resourceIdentifier: Data? = nil,
        volumeIdentifier: Data? = nil,
        rootFingerprint: RootFingerprint? = nil,
        livePathComponents: [String]? = nil
    ) {
        self.manifestLibraryID = manifestLibraryID
        self.resourceIdentifier = resourceIdentifier
        self.volumeIdentifier = volumeIdentifier
        self.rootFingerprint = rootFingerprint
        self.livePathComponents = livePathComponents
    }

    /// Reads the stable, bookmark-resolvable identity components for a
    /// currently-reachable folder (spec §7 steps 1-2). `manifestLibraryID`
    /// is supplied by the caller — reading `.lumaharbor/library.json` needs
    /// the sidecar repository, which this type deliberately doesn't depend
    /// on so it stays testable without a file system.
    ///
    /// Every component is best-effort: a read-only provider that can't
    /// supply `fileResourceIdentifierKey`/`volumeIdentifierKey` still gets a
    /// usable identity built from whatever did resolve, falling through to
    /// `rootFingerprint` alone — which `relationship(to:)` only ever treats
    /// as grounds to ask, never to auto-match.
    public static func resolve(
        url: URL,
        manifestLibraryID: LibraryID?,
        fileManager: FileManager = .default
    ) -> LibrarySourceIdentity {
        var resourceIdentifier: Data?
        var volumeIdentifier: Data?
        let resolvedURL = url
        if let values = try? resolvedURL.resourceValues(
            forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey]
        ) {
            resourceIdentifier = values.fileResourceIdentifier as? Data
            volumeIdentifier = values.volumeIdentifier as? Data
        }

        return LibrarySourceIdentity(
            manifestLibraryID: manifestLibraryID,
            resourceIdentifier: resourceIdentifier,
            volumeIdentifier: volumeIdentifier,
            rootFingerprint: try? boundedRootFingerprint(of: url, fileManager: fileManager),
            livePathComponents: url.standardizedFileURL.pathComponents
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
            manifestLibraryID: manifestLibraryID,
            resourceIdentifier: resourceIdentifier,
            volumeIdentifier: volumeIdentifier,
            rootFingerprint: rootFingerprint,
            livePathComponents: nil
        )
    }

    /// Decides how `self` (an existing known source) relates to `other` (a
    /// freshly resolved candidate).
    ///
    /// Priority follows spec §7: manifest `LibraryID` wins outright; a
    /// matching bookmark-resolved resource identifier is next; a shared
    /// volume plus live path containment catches parent/child overlap; a
    /// bounded fingerprint match with no stronger signal is `.ambiguous`,
    /// never auto-matched. Anything left over — including different
    /// volumes under the same display name — is `.distinct`.
    public func relationship(to other: LibrarySourceIdentity) -> SourceRelationship {
        if let mine = manifestLibraryID, let theirs = other.manifestLibraryID {
            return mine == theirs ? .same : containmentOrDistinct(with: other)
        }
        if let mine = resourceIdentifier, let theirs = other.resourceIdentifier {
            return mine == theirs ? .same : containmentOrDistinct(with: other)
        }
        if resourceIdentifier == nil || other.resourceIdentifier == nil,
           let mine = rootFingerprint, let theirs = other.rootFingerprint,
           sameVolume(as: other), mine == theirs {
            // Spec §7 step 3: no manifest ID and no resolvable resource
            // identifier on at least one side — a read-only or Files
            // provider source. The fingerprint match is only ever grounds
            // to ask the user, never to declare `.same` on its own.
            return .ambiguous
        }
        return containmentOrDistinct(with: other)
    }

    private func sameVolume(as other: LibrarySourceIdentity) -> Bool {
        guard let mine = volumeIdentifier, let theirs = other.volumeIdentifier else { return false }
        return mine == theirs
    }

    private func containmentOrDistinct(with other: LibrarySourceIdentity) -> SourceRelationship {
        guard sameVolume(as: other),
              let minePath = livePathComponents,
              let theirPath = other.livePathComponents else {
            return .distinct
        }
        if minePath == theirPath { return .same }
        if minePath.count < theirPath.count, Array(theirPath.prefix(minePath.count)) == minePath {
            return .ancestor
        }
        if theirPath.count < minePath.count, Array(minePath.prefix(theirPath.count)) == theirPath {
            return .descendant
        }
        return .distinct
    }
}
