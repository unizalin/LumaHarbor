import XCTest
@testable import PhotoLibraryCore

/// Spec §8.1: a moved file with a unique fingerprint match keeps its record; a
/// tie is held for confirmation and never merged automatically.
final class RelinkResolverTests: XCTestCase {
    private let alpha = FileFingerprint.stub("alpha")
    private let beta = FileFingerprint.stub("beta")

    func testUnseenFileIsNew() {
        let decision = RelinkResolver.resolve(
            relativePath: "Trip/DSC0001.ARW",
            fingerprint: alpha,
            against: []
        )
        XCTAssertEqual(decision, .new)
    }

    func testSamePathSameBytesIsUnchanged() {
        let id = PhotoID()
        let records = [PhotoRecord.stub(photoID: id, relativePath: "Trip/A.ARW", fingerprint: alpha)]
        let decision = RelinkResolver.resolve(
            relativePath: "Trip/A.ARW", fingerprint: alpha, against: records
        )
        XCTAssertEqual(decision, .unchanged(id))
    }

    func testSamePathDifferentBytesKeepsTheIdentityButFlagsTheChange() {
        // Re-copied from the card: same photo slot, new bytes. Keeping the ID
        // means the user's edits survive.
        let id = PhotoID()
        let records = [PhotoRecord.stub(photoID: id, relativePath: "Trip/A.ARW", fingerprint: alpha)]
        let decision = RelinkResolver.resolve(
            relativePath: "Trip/A.ARW", fingerprint: beta, against: records
        )
        XCTAssertEqual(decision, .contentChanged(id))
    }

    func testMovedFileWithAUniqueMatchIsRelinked() {
        let id = PhotoID()
        let records = [PhotoRecord.stub(photoID: id, relativePath: "Old/A.ARW", fingerprint: alpha)]
        let decision = RelinkResolver.resolve(
            relativePath: "New/A.ARW", fingerprint: alpha, against: records
        )
        XCTAssertEqual(decision, .moved(id, previousRelativePath: "Old/A.ARW"))
    }

    func testRenamedFileWithAUniqueMatchIsRelinked() {
        let id = PhotoID()
        let records = [PhotoRecord.stub(photoID: id, relativePath: "Trip/A.ARW", fingerprint: alpha)]
        let decision = RelinkResolver.resolve(
            relativePath: "Trip/Renamed.ARW", fingerprint: alpha, against: records
        )
        XCTAssertEqual(decision, .moved(id, previousRelativePath: "Trip/A.ARW"))
    }

    func testDuplicateFingerprintsAreNeverMergedAutomatically() {
        // Two byte-identical copies already in the library: choosing one would
        // silently attach one photo's edits to another file.
        let first = PhotoID()
        let second = PhotoID()
        let records = [
            PhotoRecord.stub(photoID: first, relativePath: "Trip/A.ARW", fingerprint: alpha),
            PhotoRecord.stub(photoID: second, relativePath: "Trip/B.ARW", fingerprint: alpha)
        ]
        let decision = RelinkResolver.resolve(
            relativePath: "Trip/C.ARW", fingerprint: alpha, against: records
        )
        guard case .ambiguous(let candidates) = decision else {
            return XCTFail("Expected .ambiguous, got \(decision)")
        }
        XCTAssertEqual(Set(candidates), [first, second])
    }

    func testAmbiguousCandidatesAreOrderedDeterministically() {
        let ids = (0..<4).map { _ in PhotoID() }
        let records = ids.enumerated().map { index, id in
            PhotoRecord.stub(photoID: id, relativePath: "Trip/\(index).ARW", fingerprint: alpha)
        }
        let first = RelinkResolver.resolve(
            relativePath: "New.ARW", fingerprint: alpha, against: records
        )
        let second = RelinkResolver.resolve(
            relativePath: "New.ARW", fingerprint: alpha, against: records.reversed()
        )
        XCTAssertEqual(first, second, "The same inputs must produce the same decision")
    }

    func testPathMatchWinsOverAFingerprintTie() {
        // A file sitting where we last saw it is that photo, even if copies of
        // its bytes exist elsewhere.
        let atPath = PhotoID()
        let records = [
            PhotoRecord.stub(photoID: atPath, relativePath: "Trip/A.ARW", fingerprint: beta),
            PhotoRecord.stub(relativePath: "Trip/B.ARW", fingerprint: alpha),
            PhotoRecord.stub(relativePath: "Trip/C.ARW", fingerprint: alpha)
        ]
        let decision = RelinkResolver.resolve(
            relativePath: "Trip/A.ARW", fingerprint: alpha, against: records
        )
        XCTAssertEqual(decision, .contentChanged(atPath))
    }

    func testDifferentFingerprintAtANewPathIsNew() {
        let records = [PhotoRecord.stub(relativePath: "Trip/A.ARW", fingerprint: alpha)]
        let decision = RelinkResolver.resolve(
            relativePath: "Trip/B.ARW", fingerprint: beta, against: records
        )
        XCTAssertEqual(decision, .new)
    }

    func testSizeAloneDoesNotMakeAMatch() {
        let sameSizeDifferentDigest = FileFingerprint(fileSize: 1_024, edgeDigest: "different")
        let records = [PhotoRecord.stub(relativePath: "Trip/A.ARW", fingerprint: alpha)]
        let decision = RelinkResolver.resolve(
            relativePath: "Trip/B.ARW", fingerprint: sameSizeDifferentDigest, against: records
        )
        XCTAssertEqual(decision, .new)
    }
}
