import XCTest
@testable import PhotoLibraryCore

/// Spec §7: pure coverage of `LibrarySourceIdentity.relationship(to:)`, built
/// entirely from hand-constructed values so the decision matrix is testable
/// without a file system or a second physical volume, plus `resolve(...)`
/// coverage against real directories (symlinks, case sensitivity, bookmark
/// round-trips) that a hand-constructed value can't stand in for.
final class LibrarySourceIdentityTests: XCTestCase {
    private func identity(
        confirmedManifestLibraryID: LibraryID? = nil,
        resourceIdentifier: Data? = nil,
        volumeIdentifier: String? = nil,
        rootFingerprint: RootFingerprint? = nil,
        canonicalLivePath: String? = nil,
        canonicalLivePathCaseSensitivity: PathCaseSensitivity = .unknown
    ) -> LibrarySourceIdentity {
        LibrarySourceIdentity(
            confirmedManifestLibraryID: confirmedManifestLibraryID,
            resourceIdentifier: resourceIdentifier,
            volumeIdentifier: volumeIdentifier,
            rootFingerprint: rootFingerprint,
            canonicalLivePath: canonicalLivePath,
            canonicalLivePathCaseSensitivity: canonicalLivePathCaseSensitivity
        )
    }

    // MARK: - Confirmed manifest ID is authoritative and terminal

    func testMatchingConfirmedManifestLibraryIDIsSameEvenWithDifferentResourceIdentifiers() {
        let sharedID = LibraryID()
        let mine = identity(
            confirmedManifestLibraryID: sharedID,
            resourceIdentifier: Data([0x01]),
            volumeIdentifier: "aa"
        )
        let theirs = identity(
            confirmedManifestLibraryID: sharedID,
            resourceIdentifier: Data([0x02]),
            volumeIdentifier: "aa"
        )

        XCTAssertEqual(mine.relationship(to: theirs), .same)
    }

    /// Review fix round 2, Critical 1: two ordinary, independently-manifested
    /// sources with no other relation to each other are simply `.distinct`
    /// — a manifest-ID disagreement alone is not `.conflict`. `.conflict` is
    /// reserved for when *physical* evidence (resource identifier or
    /// canonical live path) says the same folder while the manifests
    /// disagree — see `testDifferentConfirmedManifestLibraryIDsAreConflictEvenAtTheIdenticalLivePath`.
    func testDifferentConfirmedManifestLibraryIDsWithNoPhysicalRelationAreDistinctNotConflict() {
        let mine = identity(confirmedManifestLibraryID: LibraryID())
        let theirs = identity(confirmedManifestLibraryID: LibraryID())

        XCTAssertEqual(mine.relationship(to: theirs), .distinct)
    }

    func testDifferentConfirmedManifestLibraryIDsOnDifferentVolumesAreDistinct() {
        let mine = identity(
            confirmedManifestLibraryID: LibraryID(),
            volumeIdentifier: "aa",
            canonicalLivePath: "/volumes/drivea/photos",
            canonicalLivePathCaseSensitivity: .sensitive
        )
        let theirs = identity(
            confirmedManifestLibraryID: LibraryID(),
            volumeIdentifier: "bb",
            canonicalLivePath: "/volumes/driveb/photos",
            canonicalLivePathCaseSensitivity: .sensitive
        )

        XCTAssertEqual(mine.relationship(to: theirs), .distinct)
    }

    func testDifferentConfirmedManifestLibraryIDsOnTheSameVolumeAsSiblingsAreDistinct() {
        let volume = "aa"
        let mine = identity(
            confirmedManifestLibraryID: LibraryID(),
            resourceIdentifier: Data([0x01]),
            volumeIdentifier: volume,
            canonicalLivePath: "/volumes/ssd/photos/tripa",
            canonicalLivePathCaseSensitivity: .sensitive
        )
        let theirs = identity(
            confirmedManifestLibraryID: LibraryID(),
            resourceIdentifier: Data([0x02]),
            volumeIdentifier: volume,
            canonicalLivePath: "/volumes/ssd/photos/tripb",
            canonicalLivePathCaseSensitivity: .sensitive
        )

        XCTAssertEqual(mine.relationship(to: theirs), .distinct)
    }

    func testDifferentConfirmedManifestLibraryIDsWithAncestorLivePathIsOverlapNotConflict() {
        // Spec §7 requirement: an ancestor/descendant relationship must
        // still be reported as overlap (so the caller rejects it), even
        // when the manifest IDs disagree — not escalated to `.conflict`.
        let volume = "aa"
        let parent = identity(
            confirmedManifestLibraryID: LibraryID(),
            volumeIdentifier: volume,
            canonicalLivePath: "/volumes/ssd/photos",
            canonicalLivePathCaseSensitivity: .sensitive
        )
        let child = identity(
            confirmedManifestLibraryID: LibraryID(),
            volumeIdentifier: volume,
            canonicalLivePath: "/volumes/ssd/photos/trip",
            canonicalLivePathCaseSensitivity: .sensitive
        )

        XCTAssertEqual(parent.relationship(to: child), .ancestor)
        XCTAssertEqual(child.relationship(to: parent), .descendant)
    }

    func testDifferentConfirmedManifestLibraryIDsAreConflictEvenAtTheIdenticalLivePath() {
        // Spec §7 requirement: a manifest ID mismatch must never be
        // downgraded to `.same` by a matching path or resource identifier.
        let mine = identity(
            confirmedManifestLibraryID: LibraryID(),
            resourceIdentifier: Data([0x01]),
            volumeIdentifier: "aa",
            canonicalLivePath: "/volumes/ssd/photos"
        )
        let theirs = identity(
            confirmedManifestLibraryID: LibraryID(),
            resourceIdentifier: Data([0x01]),
            volumeIdentifier: "aa",
            canonicalLivePath: "/volumes/ssd/photos"
        )

        XCTAssertEqual(mine.relationship(to: theirs), .conflict)
    }

    // MARK: - Resource identifier requires a confirmed shared volume

    func testMatchingResourceIdentifierWithSharedVolumeIsSame() {
        let sharedResourceID = Data([0x01, 0x02, 0x03])
        let mine = identity(resourceIdentifier: sharedResourceID, volumeIdentifier: "aa")
        let theirs = identity(resourceIdentifier: sharedResourceID, volumeIdentifier: "aa")

        XCTAssertEqual(mine.relationship(to: theirs), .same)
    }

    func testMatchingResourceIdentifierWithDifferentVolumesIsDistinct() {
        let sharedResourceID = Data([0x01, 0x02, 0x03])
        let mine = identity(resourceIdentifier: sharedResourceID, volumeIdentifier: "aa")
        let theirs = identity(resourceIdentifier: sharedResourceID, volumeIdentifier: "bb")

        XCTAssertEqual(mine.relationship(to: theirs), .distinct)
    }

    func testMatchingResourceIdentifierWithAMissingVolumeOnEitherSideNeverAutoConfirmsSame() {
        let sharedResourceID = Data([0x01, 0x02, 0x03])
        let mineNoVolume = identity(resourceIdentifier: sharedResourceID, volumeIdentifier: nil)
        let theirsWithVolume = identity(resourceIdentifier: sharedResourceID, volumeIdentifier: "aa")

        XCTAssertNotEqual(mineNoVolume.relationship(to: theirsWithVolume), .same)
        XCTAssertNotEqual(theirsWithVolume.relationship(to: mineNoVolume), .same)

        let neitherHasVolume = identity(resourceIdentifier: sharedResourceID, volumeIdentifier: nil)
        XCTAssertEqual(mineNoVolume.relationship(to: neitherHasVolume), .ambiguous)
    }

    func testFailClosedPhysicalRelationshipMatrix() {
        let resourceID = Data([0xAA])
        let knownManifestID = LibraryID()
        let foreignManifestID = LibraryID()

        struct Case {
            let name: String
            let existing: LibrarySourceIdentity
            let candidate: LibrarySourceIdentity
            let expected: SourceRelationship
        }

        let cases: [Case] = [
            Case(
                name: "missing volume with matching resource ID",
                existing: identity(resourceIdentifier: resourceID),
                candidate: identity(resourceIdentifier: resourceID, volumeIdentifier: "volume"),
                expected: .ambiguous
            ),
            Case(
                name: "missing volume with exact canonical path",
                existing: identity(canonicalLivePath: "/Photos"),
                candidate: identity(volumeIdentifier: "volume", canonicalLivePath: "/Photos"),
                expected: .ambiguous
            ),
            Case(
                name: "missing volume with possible containment",
                existing: identity(canonicalLivePath: "/Photos"),
                candidate: identity(volumeIdentifier: "volume", canonicalLivePath: "/Photos/Child"),
                expected: .ambiguous
            ),
            Case(
                name: "case-insensitive containment",
                existing: identity(
                    volumeIdentifier: "volume", canonicalLivePath: "/Photos",
                    canonicalLivePathCaseSensitivity: .insensitive
                ),
                candidate: identity(
                    volumeIdentifier: "volume", canonicalLivePath: "/photos/Child",
                    canonicalLivePathCaseSensitivity: .insensitive
                ),
                expected: .ancestor
            ),
            Case(
                name: "case-sensitive variants stay distinct",
                existing: identity(
                    volumeIdentifier: "volume", canonicalLivePath: "/Photos",
                    canonicalLivePathCaseSensitivity: .sensitive
                ),
                candidate: identity(
                    volumeIdentifier: "volume", canonicalLivePath: "/photos/Child",
                    canonicalLivePathCaseSensitivity: .sensitive
                ),
                expected: .distinct
            ),
            Case(
                name: "unknown sensitivity natural containment",
                existing: identity(volumeIdentifier: "volume", canonicalLivePath: "/Photos"),
                candidate: identity(volumeIdentifier: "volume", canonicalLivePath: "/Photos/Child"),
                expected: .ancestor
            ),
            Case(
                name: "unknown sensitivity case-fold containment",
                existing: identity(volumeIdentifier: "volume", canonicalLivePath: "/Photos"),
                candidate: identity(volumeIdentifier: "volume", canonicalLivePath: "/photos/Child"),
                expected: .ambiguous
            ),
            Case(
                name: "root contains a child",
                existing: identity(volumeIdentifier: "volume", canonicalLivePath: "/"),
                candidate: identity(volumeIdentifier: "volume", canonicalLivePath: "/Photos"),
                expected: .ancestor
            ),
            Case(
                name: "component prefix is not containment",
                existing: identity(volumeIdentifier: "volume", canonicalLivePath: "/Photos"),
                candidate: identity(volumeIdentifier: "volume", canonicalLivePath: "/Photos2"),
                expected: .distinct
            ),
            Case(
                name: "manifest mismatch cannot upgrade ambiguous physical evidence",
                existing: identity(
                    confirmedManifestLibraryID: knownManifestID,
                    canonicalLivePath: "/Photos"
                ),
                candidate: identity(
                    confirmedManifestLibraryID: foreignManifestID,
                    volumeIdentifier: "volume",
                    canonicalLivePath: "/Photos"
                ),
                expected: .ambiguous
            )
        ]

        for testCase in cases {
            XCTAssertEqual(
                testCase.existing.relationship(to: testCase.candidate),
                testCase.expected,
                testCase.name
            )
        }
    }

    // MARK: - Ancestor / descendant (live containment, confirmed shared volume)

    func testContainingPathOnASharedVolumeIsAncestor() {
        let volume = "aa"
        let parent = identity(
            resourceIdentifier: Data([0x01]),
            volumeIdentifier: volume,
            canonicalLivePath: "/volumes/ssd/photos"
        )
        let child = identity(
            resourceIdentifier: Data([0x02]),
            volumeIdentifier: volume,
            canonicalLivePath: "/volumes/ssd/photos/trip"
        )

        XCTAssertEqual(parent.relationship(to: child), .ancestor)
        XCTAssertEqual(child.relationship(to: parent), .descendant)
    }

    func testSiblingFoldersOnASharedVolumeAreDistinct() {
        let volume = "aa"
        let tripA = identity(
            resourceIdentifier: Data([0x01]),
            volumeIdentifier: volume,
            canonicalLivePath: "/volumes/ssd/photos/tripa"
        )
        let tripB = identity(
            resourceIdentifier: Data([0x02]),
            volumeIdentifier: volume,
            canonicalLivePath: "/volumes/ssd/photos/tripb"
        )

        XCTAssertEqual(tripA.relationship(to: tripB), .distinct)
    }

    func testParentChildOverlapIsDetectedEvenWhenFingerprintsMatch() {
        // A matching fingerprint must never mask a live-path containment
        // result — containment is a stronger signal and decides first.
        let volume = "aa"
        let sharedFingerprint = RootFingerprint(childCount: 2, sampleNames: ["a", "b"])
        let parent = identity(
            volumeIdentifier: volume,
            rootFingerprint: sharedFingerprint,
            canonicalLivePath: "/volumes/ssd/photos"
        )
        let child = identity(
            volumeIdentifier: volume,
            rootFingerprint: sharedFingerprint,
            canonicalLivePath: "/volumes/ssd/photos/trip"
        )

        XCTAssertEqual(parent.relationship(to: child), .ancestor)
    }

    // MARK: - Same display name, different volumes

    func testSameDisplayNameIrrelevantIdentityOnDifferentVolumesIsDistinct() {
        // Display name is never part of identity at all — these two would
        // carry the same user-facing label ("Photos") but live on different
        // drives with unrelated resource identifiers.
        let driveA = identity(
            resourceIdentifier: Data([0x01]),
            volumeIdentifier: "aa",
            canonicalLivePath: "/volumes/drivea/photos"
        )
        let driveB = identity(
            resourceIdentifier: Data([0x02]),
            volumeIdentifier: "bb",
            canonicalLivePath: "/volumes/driveb/photos"
        )

        XCTAssertEqual(driveA.relationship(to: driveB), .distinct)
    }

    // MARK: - Ambiguous fallback (no volume known at all)

    func testBoundedFingerprintMatchWithNoVolumeKnownIsAmbiguous() {
        let fingerprint = RootFingerprint(childCount: 3, sampleNames: ["a.ARW", "b.ARW", "c.ARW"])
        // Neither side has a resource identifier or a volume identifier —
        // the Files-provider case spec §7 step 3 describes.
        let mine = identity(rootFingerprint: fingerprint)
        let theirs = identity(rootFingerprint: fingerprint)

        XCTAssertEqual(mine.relationship(to: theirs), .ambiguous)
    }

    func testDifferingFingerprintsWithNoVolumeKnownAreDistinctNotAmbiguous() {
        let mine = identity(rootFingerprint: RootFingerprint(childCount: 1, sampleNames: ["a.ARW"]))
        let theirs = identity(rootFingerprint: RootFingerprint(childCount: 9, sampleNames: ["z.ARW"]))

        XCTAssertEqual(mine.relationship(to: theirs), .distinct)
    }

    // MARK: - Fail-closed to ambiguous on a known-shared volume

    func testSharedVolumeWithNoLivePathOnEitherSideAndNoFingerprintMatchFailsClosedToAmbiguous() {
        // Known to be the same volume (e.g. read from a persisted bookmark
        // for an offline library), but neither side has a resolvable live
        // path and there's no fingerprint agreement either — must not guess
        // `.distinct` on a volume we know is shared.
        let mine = identity(volumeIdentifier: "aa")
        let theirs = identity(volumeIdentifier: "aa")

        XCTAssertEqual(mine.relationship(to: theirs), .ambiguous)
    }

    func testSharedVolumeWithLivePathOnlyOnOneSideFailsClosedToAmbiguousRatherThanDistinct() {
        // Offline known library (no live path) vs. a reachable candidate on
        // the same persisted volume: can't verify containment either way.
        let offlineExisting = identity(resourceIdentifier: Data([0x01]), volumeIdentifier: "aa")
        let onlineCandidate = identity(
            resourceIdentifier: Data([0x02]),
            volumeIdentifier: "aa",
            canonicalLivePath: "/volumes/ssd/photos/new"
        )

        XCTAssertEqual(offlineExisting.relationship(to: onlineCandidate), .ambiguous)
    }

    func testSharedVolumeFingerprintMatchWithNoLivePathIsAmbiguous() {
        let fingerprint = RootFingerprint(childCount: 4, sampleNames: ["a", "b", "c", "d"])
        let mine = identity(volumeIdentifier: "aa", rootFingerprint: fingerprint)
        let theirs = identity(volumeIdentifier: "aa", rootFingerprint: fingerprint)

        XCTAssertEqual(mine.relationship(to: theirs), .ambiguous)
    }

    // MARK: - Persistable projection

    func testPersistableDropsCanonicalLivePath() {
        let full = identity(
            confirmedManifestLibraryID: LibraryID(),
            resourceIdentifier: Data([0x01]),
            volumeIdentifier: "aa",
            rootFingerprint: RootFingerprint(childCount: 1, sampleNames: ["a.ARW"]),
            canonicalLivePath: "/volumes/ssd/photos"
        )

        let persisted = full.persistable

        XCTAssertNil(persisted.canonicalLivePath)
        XCTAssertEqual(persisted.confirmedManifestLibraryID, full.confirmedManifestLibraryID)
        XCTAssertEqual(persisted.resourceIdentifier, full.resourceIdentifier)
        XCTAssertEqual(persisted.volumeIdentifier, full.volumeIdentifier)
        XCTAssertEqual(persisted.rootFingerprint, full.rootFingerprint)
    }

    // MARK: - Live resolution

    private func makeTempDirectory(name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaHarborIdentityTests-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testResolveReadsRealResourceAndVolumeIdentifiersForAnExistingDirectory() throws {
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let resolved = LibrarySourceIdentity.resolve(url: tempDirectory, confirmedManifestLibraryID: nil)

        XCTAssertNotNil(resolved.resourceIdentifier, "the test platform must expose a stable file resource identifier")
        XCTAssertNotNil(resolved.volumeIdentifier, "the test platform must expose a stable volume identifier")
        XCTAssertNotNil(resolved.canonicalLivePath)
    }

    func testResolveDistinguishesTwoDifferentDirectoriesOnTheSameVolume() throws {
        let base = try makeTempDirectory()
        let first = base.appendingPathComponent("First", isDirectory: true)
        let second = base.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let firstIdentity = LibrarySourceIdentity.resolve(url: first, confirmedManifestLibraryID: nil)
        let secondIdentity = LibrarySourceIdentity.resolve(url: second, confirmedManifestLibraryID: nil)

        XCTAssertNotEqual(firstIdentity.resourceIdentifier, secondIdentity.resourceIdentifier)
        XCTAssertEqual(firstIdentity.volumeIdentifier, secondIdentity.volumeIdentifier)
        XCTAssertEqual(firstIdentity.relationship(to: secondIdentity), .distinct)
    }

    func testResolveRoundTripsThroughBookmarkResolutionWithTheSameResourceIdentifier() throws {
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let original = LibrarySourceIdentity.resolve(url: tempDirectory, confirmedManifestLibraryID: nil)

        let bookmarkData = try tempDirectory.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        )
        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        let afterBookmarkRoundTrip = LibrarySourceIdentity.resolve(
            url: resolvedURL, confirmedManifestLibraryID: nil
        )

        XCTAssertEqual(original.resourceIdentifier, afterBookmarkRoundTrip.resourceIdentifier)
        XCTAssertEqual(original.volumeIdentifier, afterBookmarkRoundTrip.volumeIdentifier)
    }

    /// Review fix round 2, Minor: canonicalization of the platform's opaque
    /// resource/volume identifiers must fail closed (`nil`, never a
    /// fabricated stand-in) when a provider can't supply `Data`-backed
    /// values — exercised through `resolve()`'s real injectable seam
    /// (`ResourceIdentityResolving`), not a hand-built `LibrarySourceIdentity`.
    private struct ProviderShapedResourceIdentityResolver: ResourceIdentityResolving {
        func resolvedIdentity(for url: URL) -> ResolvedResourceIdentity? {
            // A Files-provider-like lookup that resolves successfully but
            // has no stable, `Data`-backed identifier to offer at all — the
            // opposite of the real, `Data`-backed system resolver.
            ResolvedResourceIdentity(fileResourceIdentifier: nil, volumeIdentifier: nil, caseSensitivity: .unknown)
        }
    }

    func testResolveWithANonDataProviderShapedFixtureFailsClosedRatherThanFabricatingIdentity() throws {
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let resolved = LibrarySourceIdentity.resolve(
            url: tempDirectory,
            confirmedManifestLibraryID: nil,
            resourceIdentityResolver: ProviderShapedResourceIdentityResolver()
        )

        XCTAssertNil(resolved.resourceIdentifier, "No Data-backed identifier was available; must never be invented")
        XCTAssertNil(resolved.volumeIdentifier)
        // Best-effort from whatever *did* resolve — the live path and
        // bounded fingerprint are still populated from the real directory.
        XCTAssertNotNil(resolved.canonicalLivePath)
        XCTAssertNotNil(resolved.rootFingerprint)

        let other = LibrarySourceIdentity.resolve(
            url: tempDirectory,
            confirmedManifestLibraryID: nil,
            resourceIdentityResolver: ProviderShapedResourceIdentityResolver()
        )
        // Same fingerprint (the same real, empty directory), but no volume
        // at all: `.ambiguous`, never a fabricated `.same`.
        XCTAssertEqual(resolved.relationship(to: other), .ambiguous)
    }

    /// Item 7 of the required regression coverage: a `RootFingerprint`
    /// recovered from a real `StoredBookmark` JSON round-trip (not just a
    /// hand-built value) still functions in `relationship(to:)`, and two
    /// otherwise-unidentifiable (no volume) sources with matching bounded
    /// fingerprints land on `.ambiguous` — the restricted/provider scenario.
    func testRootFingerprintSurvivesAProductionBookmarkRoundTripAndStillProducesAmbiguous() throws {
        let tempDirectory = try makeTempDirectory()
        try Data("x".utf8).write(to: tempDirectory.appendingPathComponent("a.ARW"))
        try Data("y".utf8).write(to: tempDirectory.appendingPathComponent("b.ARW"))
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let resolved = LibrarySourceIdentity.resolve(url: tempDirectory, confirmedManifestLibraryID: nil)
        let fingerprint = try XCTUnwrap(resolved.rootFingerprint)

        let bookmark = StoredBookmark(
            libraryID: LibraryID(),
            displayName: "Provider Source",
            lastKnownPath: tempDirectory.path,
            bookmarkData: Data([0x01, 0x02, 0x03]),
            rootFingerprint: fingerprint
        )
        let data = try SidecarCoding.encode(bookmark)
        let decoded = try SidecarCoding.decode(StoredBookmark.self, from: data)

        XCTAssertEqual(decoded.rootFingerprint, fingerprint)

        // Simulate a Files-provider source that never exposes a volume or
        // resource identifier: only the restored fingerprint is available.
        let restoredAsProviderIdentity = identity(rootFingerprint: decoded.rootFingerprint)
        let candidateWithSameFingerprint = identity(rootFingerprint: fingerprint)

        XCTAssertEqual(
            restoredAsProviderIdentity.relationship(to: candidateWithSameFingerprint), .ambiguous
        )
    }

    // MARK: - Symlink aliasing (item 13)

    func testSymlinkAliasToAnExistingSourceRootResolvesToTheSameIdentity() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let alias = base.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        let realIdentity = LibrarySourceIdentity.resolve(url: real, confirmedManifestLibraryID: nil)
        let aliasIdentity = LibrarySourceIdentity.resolve(url: alias, confirmedManifestLibraryID: nil)

        XCTAssertEqual(realIdentity.resourceIdentifier, aliasIdentity.resourceIdentifier)
        XCTAssertEqual(realIdentity.canonicalLivePath, aliasIdentity.canonicalLivePath)
        XCTAssertEqual(realIdentity.relationship(to: aliasIdentity), .same)
    }

    func testSymlinkAliasIntoAnExistingSourceIsDetectedAsOverlap() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("Real", isDirectory: true)
        let child = real.appendingPathComponent("Trip", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        // An alias that lives OUTSIDE `real` but points AT `real`'s child —
        // a naive path-only comparison of the alias's own (unresolved)
        // location would miss the overlap entirely.
        let alias = base.appendingPathComponent("AliasIntoChild", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)

        let parentIdentity = LibrarySourceIdentity.resolve(url: real, confirmedManifestLibraryID: nil)
        let aliasIdentity = LibrarySourceIdentity.resolve(url: alias, confirmedManifestLibraryID: nil)

        XCTAssertEqual(parentIdentity.relationship(to: aliasIdentity), .ancestor)
    }

    // MARK: - Filesystem case sensitivity (item 14)

    func testCaseVariantPathOnACaseInsensitiveVolumeIsDetectedAsTheSameSource() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("CasedFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)

        let probe = real
        let values = try probe.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        try XCTSkipIf(
            values.volumeSupportsCaseSensitiveNames == true,
            "This host's temporary volume is case-sensitive; the alias case can't arise here."
        )

        let differentCaseVariant = base.appendingPathComponent("CASEDFOLDER", isDirectory: true)

        let realIdentity = LibrarySourceIdentity.resolve(url: real, confirmedManifestLibraryID: nil)
        let variantIdentity = LibrarySourceIdentity.resolve(
            url: differentCaseVariant, confirmedManifestLibraryID: nil
        )

        XCTAssertEqual(realIdentity.canonicalLivePath, variantIdentity.canonicalLivePath)
        XCTAssertEqual(realIdentity.relationship(to: variantIdentity), .same)
    }

    func testCaseVariantSiblingFoldersOnACaseSensitiveVolumeAreNotMergedByLowercasing() {
        // Pure unit-level guard for the case-sensitive branch, independent of
        // this host's actual volume: two genuinely distinct, differently-cased
        // canonical paths, both sides *confirmed* case-sensitive, must not
        // compare equal.
        let caseSensitiveVolume = "cs-volume"
        let lower = identity(
            resourceIdentifier: Data([0x01]),
            volumeIdentifier: caseSensitiveVolume,
            canonicalLivePath: "/Volumes/SSD/trip",
            canonicalLivePathCaseSensitivity: .sensitive
        )
        let upper = identity(
            resourceIdentifier: Data([0x02]),
            volumeIdentifier: caseSensitiveVolume,
            canonicalLivePath: "/Volumes/SSD/Trip",
            canonicalLivePathCaseSensitivity: .sensitive
        )

        XCTAssertEqual(lower.relationship(to: upper), .distinct)
    }

    /// Review fix round 2, Important 2: an *unknown* case sensitivity on
    /// either side must never be folded into "insensitive" and declared
    /// `.same` — that could silently merge two genuinely distinct folders on
    /// a case-sensitive volume this build simply couldn't get an answer
    /// from. It must also never be folded into "sensitive" and declared
    /// `.distinct` — that could miss a real alias. The only safe answer is
    /// `.ambiguous`.
    func testCaseVariantPathsWithUnknownSensitivityOnEitherSideAreAmbiguous() {
        let volume = "unknown-sensitivity-volume"
        let known = identity(
            resourceIdentifier: Data([0x01]),
            volumeIdentifier: volume,
            canonicalLivePath: "/Volumes/Provider/trip",
            canonicalLivePathCaseSensitivity: .insensitive
        )
        let unknown = identity(
            resourceIdentifier: Data([0x02]),
            volumeIdentifier: volume,
            canonicalLivePath: "/Volumes/Provider/Trip",
            canonicalLivePathCaseSensitivity: .unknown
        )

        XCTAssertEqual(known.relationship(to: unknown), .ambiguous)
        XCTAssertEqual(unknown.relationship(to: known), .ambiguous)

        let bothUnknown = identity(
            resourceIdentifier: Data([0x03]),
            volumeIdentifier: volume,
            canonicalLivePath: "/Volumes/Provider/TRIP",
            canonicalLivePathCaseSensitivity: .unknown
        )
        XCTAssertEqual(unknown.relationship(to: bothUnknown), .ambiguous)
    }

    /// A case-varied parent/child pair on a confirmed case-insensitive
    /// volume is still a real overlap. It must not fall through to
    /// `.distinct` just because the raw strings differ in case.
    func testCaseVariantParentChildOnACaseInsensitiveVolumeIsAncestorDescendant() {
        let volume = "case-insensitive-volume"
        let parent = identity(
            resourceIdentifier: Data([0x01]),
            volumeIdentifier: volume,
            canonicalLivePath: "/Volumes/SSD/Photos",
            canonicalLivePathCaseSensitivity: .insensitive
        )
        let child = identity(
            resourceIdentifier: Data([0x02]),
            volumeIdentifier: volume,
            canonicalLivePath: "/Volumes/SSD/photos/Trip",
            canonicalLivePathCaseSensitivity: .insensitive
        )

        XCTAssertEqual(parent.relationship(to: child), .ancestor)
        XCTAssertEqual(child.relationship(to: parent), .descendant)
    }

    /// If either side cannot prove the volume's case behavior, a case-varied
    /// parent/child match must fail closed to `.ambiguous` instead of
    /// guessing overlap or distinctness.
    func testCaseVariantParentChildWithUnknownSensitivityIsAmbiguous() {
        let volume = "unknown-sensitivity-volume"
        let parent = identity(
            resourceIdentifier: Data([0x01]),
            volumeIdentifier: volume,
            canonicalLivePath: "/Volumes/SSD/Photos",
            canonicalLivePathCaseSensitivity: .unknown
        )
        let child = identity(
            resourceIdentifier: Data([0x02]),
            volumeIdentifier: volume,
            canonicalLivePath: "/Volumes/SSD/photos/Trip",
            canonicalLivePathCaseSensitivity: .insensitive
        )

        XCTAssertEqual(parent.relationship(to: child), .ambiguous)
        XCTAssertEqual(child.relationship(to: parent), .ambiguous)
    }

    /// On a confirmed case-sensitive volume, differently-cased path
    /// components describe genuinely different directories, so folded
    /// parent/child strings must not invent an overlap.
    func testCaseVariantParentChildOnACaseSensitiveVolumeIsDistinct() {
        let volume = "case-sensitive-volume"
        let parent = identity(
            resourceIdentifier: Data([0x01]),
            volumeIdentifier: volume,
            canonicalLivePath: "/Volumes/SSD/Photos",
            canonicalLivePathCaseSensitivity: .sensitive
        )
        let child = identity(
            resourceIdentifier: Data([0x02]),
            volumeIdentifier: volume,
            canonicalLivePath: "/Volumes/SSD/photos/Trip",
            canonicalLivePathCaseSensitivity: .sensitive
        )

        XCTAssertEqual(parent.relationship(to: child), .distinct)
        XCTAssertEqual(child.relationship(to: parent), .distinct)
    }
}
