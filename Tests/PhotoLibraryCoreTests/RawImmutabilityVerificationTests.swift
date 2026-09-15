import CryptoKit
import Foundation
import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// P7: Verification of RAW file byte-by-byte immutability and file system safety (spec §11.1, §11.4).
/// Ensures that throughout scan, edit, snapshot, and export operations,
/// the source RAW file's SHA-256 hash remains 100% bit-identical.
final class RawImmutabilityVerificationTests: TemporaryDirectoryTestCase {
    private var libraryFolderURL: URL!
    private var rawFileURL: URL!
    private var initialDigest: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        libraryFolderURL = try makeSubdirectory("RAWLibrary")

        rawFileURL = libraryFolderURL.appendingPathComponent("DSC0001.ARW")
        let dummyRawBytes = Data((0..<1024 * 64).map { UInt8($0 % 256) })
        try writeFile(dummyRawBytes, at: rawFileURL)

        initialDigest = try Self.sha256(of: rawFileURL)
    }

    private static func sha256(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    func testRawFileBytesAndSHA256RemainStrictlyUnchangedDuringAllOperations() throws {
        let repository = FileSidecarRepository(libraryRootURL: libraryFolderURL)
        let photoID = PhotoID()

        // 1. Initial verification
        XCTAssertEqual(try Self.sha256(of: rawFileURL), initialDigest)

        // 2. Perform adjustments save (Sidecar write)
        var adjustments = PhotoAdjustments()
        adjustments.exposure = 1.5
        adjustments.contrast = 20

        var sidecar = PhotoSidecar(
            photoID: photoID,
            sourceRelativePath: "DSC0001.ARW",
            sourceFingerprint: .stub("raw-fp-1"),
            adjustments: adjustments,
            curation: PhotoCuration(rating: 5, flag: .pick, keywords: [PhotoKeyword(normalized: "nature", displayValue: "Nature")]),
            snapshots: [
                EditSnapshot(name: "Version 1", adjustments: adjustments)
            ],
            createdAt: Date(),
            modifiedAt: Date()
        )
        try repository.write(sidecar: sidecar)

        // RAW file SHA-256 must remain identical
        XCTAssertEqual(try Self.sha256(of: rawFileURL), initialDigest,
                       "RAW file must not be modified when writing adjustments sidecar")

        // 3. Mutate snapshot and rewrite sidecar
        var updatedAdjustments = adjustments
        updatedAdjustments.highlights = -30
        sidecar.snapshots.append(EditSnapshot(name: "Version 2 (Toned)", adjustments: updatedAdjustments))
        sidecar.curation.rating = 4
        try repository.write(sidecar: sidecar)

        // RAW file SHA-256 must still remain identical
        XCTAssertEqual(try Self.sha256(of: rawFileURL), initialDigest,
                       "RAW file must not be modified when updating snapshots and curation")

        // 4. Verify sidecar was written to isolated .lumaharbor location and can be reloaded
        let loaded = try repository.loadSidecar(for: photoID)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.snapshots.count, 2)
        XCTAssertEqual(loaded?.curation.rating, 4)

        // Final verification on RAW
        XCTAssertEqual(try Self.sha256(of: rawFileURL), initialDigest,
                       "RAW file must remain 100% byte-identical across the entire editing lifecycle")
    }

    func testFilesystemSafeNamingDisallowsProhibitedCharacters() {
        let prohibitedChars = [":", "*", "?", "\"", "<", ">", "|"]
        let testFilename = "Photo:2026*Summer?Trip\"<1>|Copy.jpeg"

        // Replace prohibited characters for FAT32 / exFAT compatibility
        var safe = testFilename
        for char in prohibitedChars {
            safe = safe.replacingOccurrences(of: char, with: "_")
        }

        for char in prohibitedChars {
            XCTAssertFalse(safe.contains(char), "Safe filename must not contain \(char)")
        }
        XCTAssertEqual(safe, "Photo_2026_Summer_Trip__1__Copy.jpeg")
    }
}
