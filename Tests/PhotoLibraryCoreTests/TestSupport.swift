import Foundation
import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Base class for tests that need a real directory.
///
/// These behaviours — atomic replace, read-only volumes, quarantine, relinking —
/// are precisely the ones a mocked file system would paper over, so they run
/// against the real thing in a throwaway folder.
class TemporaryDirectoryTestCase: XCTestCase {
    private(set) var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LumaHarborTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            // A test may have made something read-only on purpose; restore
            // permissions so cleanup can't leak temp data between runs.
            restoreWritePermissions(at: temporaryDirectory)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    @discardableResult
    func makeSubdirectory(_ name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func writeFile(_ contents: Data, at url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url)
        return url
    }

    func setPosixPermissions(_ permissions: Int, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }

    /// Some CI images run tests as root, where a 0o555 directory is still
    /// writable and the read-only assertions would be meaningless.
    var canSimulateReadOnlyDirectory: Bool {
        getuid() != 0
    }

    private func restoreWritePermissions(at root: URL) {
        let fileManager = FileManager.default
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: root.path
        )
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for case let url as URL in enumerator {
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: url.path
            )
        }
    }
}

extension PhotoRecord {
    static func stub(
        photoID: PhotoID = PhotoID(),
        relativePath: String,
        fingerprint: FileFingerprint
    ) -> PhotoRecord {
        PhotoRecord(
            photoID: photoID,
            relativePath: relativePath,
            fingerprint: fingerprint,
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

extension FileFingerprint {
    static func stub(_ digest: String, size: Int64 = 1_024) -> FileFingerprint {
        FileFingerprint(fileSize: size, edgeDigest: digest)
    }
}

extension PhotoAsset {
    static func stub(
        id: PhotoID = PhotoID(),
        libraryID: LibraryID,
        relativePath: String = "Trip/DSC0001.ARW",
        fingerprint: FileFingerprint = .stub("abc"),
        status: PhotoStatus = .ready
    ) -> PhotoAsset {
        PhotoAsset(
            id: id,
            libraryID: libraryID,
            relativePath: relativePath,
            fingerprint: fingerprint,
            metadata: RawMetadata(pixelWidth: 6_000, pixelHeight: 4_000),
            status: status,
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
