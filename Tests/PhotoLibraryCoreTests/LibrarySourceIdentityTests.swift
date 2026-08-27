import XCTest
@testable import PhotoLibraryCore

/// Spec §7: pure coverage of `LibrarySourceIdentity.relationship(to:)`, built
/// entirely from hand-constructed values so the decision matrix is testable
/// without a file system or a second physical volume.
final class LibrarySourceIdentityTests: XCTestCase {
    private func identity(
        manifestLibraryID: LibraryID? = nil,
        resourceIdentifier: Data? = nil,
        volumeIdentifier: Data? = nil,
        rootFingerprint: RootFingerprint? = nil,
        livePathComponents: [String]? = nil
    ) -> LibrarySourceIdentity {
        LibrarySourceIdentity(
            manifestLibraryID: manifestLibraryID,
            resourceIdentifier: resourceIdentifier,
            volumeIdentifier: volumeIdentifier,
            rootFingerprint: rootFingerprint,
            livePathComponents: livePathComponents
        )
    }

    // MARK: - Manifest identity wins

    func testMatchingManifestLibraryIDIsSameEvenWithDifferentResourceIdentifiers() {
        let sharedID = LibraryID()
        let mine = identity(
            manifestLibraryID: sharedID,
            resourceIdentifier: Data([0x01]),
            volumeIdentifier: Data([0xAA])
        )
        let theirs = identity(
            manifestLibraryID: sharedID,
            resourceIdentifier: Data([0x02]),
            volumeIdentifier: Data([0xAA])
        )

        XCTAssertEqual(mine.relationship(to: theirs), .same)
    }

    func testDifferentManifestLibraryIDsAreNotAutomaticallySame() {
        let mine = identity(manifestLibraryID: LibraryID())
        let theirs = identity(manifestLibraryID: LibraryID())

        XCTAssertNotEqual(mine.relationship(to: theirs), .same)
    }

    // MARK: - Resource identifier

    func testMatchingResourceIdentifierIsSame() {
        let sharedResourceID = Data([0x01, 0x02, 0x03])
        let mine = identity(resourceIdentifier: sharedResourceID, volumeIdentifier: Data([0xAA]))
        let theirs = identity(resourceIdentifier: sharedResourceID, volumeIdentifier: Data([0xAA]))

        XCTAssertEqual(mine.relationship(to: theirs), .same)
    }

    // MARK: - Ancestor / descendant

    func testContainingPathOnTheSameVolumeIsAncestor() {
        let volume = Data([0xAA])
        let parent = identity(
            resourceIdentifier: Data([0x01]),
            volumeIdentifier: volume,
            livePathComponents: ["Volumes", "SSD", "Photos"]
        )
        let child = identity(
            resourceIdentifier: Data([0x02]),
            volumeIdentifier: volume,
            livePathComponents: ["Volumes", "SSD", "Photos", "Trip"]
        )

        XCTAssertEqual(parent.relationship(to: child), .ancestor)
        XCTAssertEqual(child.relationship(to: parent), .descendant)
    }

    func testSiblingFoldersOnTheSameVolumeAreDistinct() {
        let volume = Data([0xAA])
        let tripA = identity(
            resourceIdentifier: Data([0x01]),
            volumeIdentifier: volume,
            livePathComponents: ["Volumes", "SSD", "Photos", "TripA"]
        )
        let tripB = identity(
            resourceIdentifier: Data([0x02]),
            volumeIdentifier: volume,
            livePathComponents: ["Volumes", "SSD", "Photos", "TripB"]
        )

        XCTAssertEqual(tripA.relationship(to: tripB), .distinct)
    }

    // MARK: - Same display name, different volumes

    func testSameDisplayNameIrrelevantIdentityOnDifferentVolumesIsDistinct() {
        // Display name is never part of identity at all — these two would
        // carry the same user-facing label ("Photos") but live on different
        // drives with unrelated resource identifiers.
        let driveA = identity(
            resourceIdentifier: Data([0x01]),
            volumeIdentifier: Data([0xAA]),
            livePathComponents: ["Volumes", "DriveA", "Photos"]
        )
        let driveB = identity(
            resourceIdentifier: Data([0x02]),
            volumeIdentifier: Data([0xBB]),
            livePathComponents: ["Volumes", "DriveB", "Photos"]
        )

        XCTAssertEqual(driveA.relationship(to: driveB), .distinct)
    }

    // MARK: - Ambiguous fallback

    func testBoundedFingerprintMatchWithNoStrongerSignalIsAmbiguous() {
        let volume = Data([0xAA])
        let fingerprint = RootFingerprint(childCount: 3, sampleNames: ["a.ARW", "b.ARW", "c.ARW"])
        // Neither side has a resource identifier — the Files-provider case
        // spec §7 step 3 describes.
        let mine = identity(volumeIdentifier: volume, rootFingerprint: fingerprint)
        let theirs = identity(volumeIdentifier: volume, rootFingerprint: fingerprint)

        XCTAssertEqual(mine.relationship(to: theirs), .ambiguous)
    }

    func testAmbiguousFingerprintMatchNeverWinsOverAResourceIdentifierMismatch() {
        // Both sides do have a resource identifier, and they disagree — that
        // is a stronger, decisive signal, so a merely-matching fingerprint
        // must never escalate this back to `.ambiguous`.
        let volume = Data([0xAA])
        let fingerprint = RootFingerprint(childCount: 1, sampleNames: ["a.ARW"])
        let mine = identity(
            resourceIdentifier: Data([0x01]),
            volumeIdentifier: volume,
            rootFingerprint: fingerprint,
            livePathComponents: ["Volumes", "SSD", "PhotosA"]
        )
        let theirs = identity(
            resourceIdentifier: Data([0x02]),
            volumeIdentifier: volume,
            rootFingerprint: fingerprint,
            livePathComponents: ["Volumes", "SSD", "PhotosB"]
        )

        XCTAssertEqual(mine.relationship(to: theirs), .distinct)
    }

    func testDifferingFingerprintsWithNoResourceIdentifierAreDistinctNotAmbiguous() {
        let volume = Data([0xAA])
        let mine = identity(
            volumeIdentifier: volume,
            rootFingerprint: RootFingerprint(childCount: 1, sampleNames: ["a.ARW"])
        )
        let theirs = identity(
            volumeIdentifier: volume,
            rootFingerprint: RootFingerprint(childCount: 9, sampleNames: ["z.ARW"])
        )

        XCTAssertEqual(mine.relationship(to: theirs), .distinct)
    }

    // MARK: - Persistable projection

    func testPersistableDropsLivePathComponents() {
        let full = identity(
            manifestLibraryID: LibraryID(),
            resourceIdentifier: Data([0x01]),
            volumeIdentifier: Data([0xAA]),
            rootFingerprint: RootFingerprint(childCount: 1, sampleNames: ["a.ARW"]),
            livePathComponents: ["Volumes", "SSD", "Photos"]
        )

        let persisted = full.persistable

        XCTAssertNil(persisted.livePathComponents)
        XCTAssertEqual(persisted.manifestLibraryID, full.manifestLibraryID)
        XCTAssertEqual(persisted.resourceIdentifier, full.resourceIdentifier)
        XCTAssertEqual(persisted.volumeIdentifier, full.volumeIdentifier)
        XCTAssertEqual(persisted.rootFingerprint, full.rootFingerprint)
    }

    // MARK: - Live resolution

    func testResolveReadsRealResourceAndVolumeIdentifiersForAnExistingDirectory() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaHarborIdentityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let resolved = LibrarySourceIdentity.resolve(url: tempDirectory, manifestLibraryID: nil)

        XCTAssertNotNil(resolved.resourceIdentifier, "the test platform must expose a stable file resource identifier")
        XCTAssertNotNil(resolved.volumeIdentifier, "the test platform must expose a stable volume identifier")
        XCTAssertEqual(resolved.livePathComponents, tempDirectory.standardizedFileURL.pathComponents)
    }

    func testResolveDistinguishesTwoDifferentDirectoriesOnTheSameVolume() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaHarborIdentityTests-\(UUID().uuidString)", isDirectory: true)
        let first = base.appendingPathComponent("First", isDirectory: true)
        let second = base.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let firstIdentity = LibrarySourceIdentity.resolve(url: first, manifestLibraryID: nil)
        let secondIdentity = LibrarySourceIdentity.resolve(url: second, manifestLibraryID: nil)

        XCTAssertNotEqual(firstIdentity.resourceIdentifier, secondIdentity.resourceIdentifier)
        XCTAssertEqual(firstIdentity.volumeIdentifier, secondIdentity.volumeIdentifier)
        XCTAssertEqual(firstIdentity.relationship(to: secondIdentity), .distinct)
    }

    func testResolveRoundTripsThroughBookmarkResolutionWithTheSameResourceIdentifier() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaHarborIdentityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let original = LibrarySourceIdentity.resolve(url: tempDirectory, manifestLibraryID: nil)

        let bookmarkData = try tempDirectory.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        )
        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        let afterBookmarkRoundTrip = LibrarySourceIdentity.resolve(url: resolvedURL, manifestLibraryID: nil)

        XCTAssertEqual(original.resourceIdentifier, afterBookmarkRoundTrip.resourceIdentifier)
        XCTAssertEqual(original.volumeIdentifier, afterBookmarkRoundTrip.volumeIdentifier)
    }
}
