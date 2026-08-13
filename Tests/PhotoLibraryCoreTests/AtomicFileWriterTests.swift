import XCTest
@testable import PhotoLibraryCore

/// Spec §8.2: temp file in the same directory, flushed, then swapped in. A
/// failure must leave the previous file untouched and no debris behind.
final class AtomicFileWriterTests: TemporaryDirectoryTestCase {
    func testWritesANewFile() throws {
        let url = temporaryDirectory.appendingPathComponent("new.json")
        try AtomicFileWriter.write(Data("first".utf8), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("first".utf8))
    }

    func testCreatesMissingIntermediateDirectories() throws {
        let url = temporaryDirectory
            .appendingPathComponent(".lumaharbor/edits/photo.json")
        try AtomicFileWriter.write(Data("{}".utf8), to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testReplacesAnExistingFile() throws {
        let url = temporaryDirectory.appendingPathComponent("existing.json")
        try AtomicFileWriter.write(Data("first".utf8), to: url)
        try AtomicFileWriter.write(Data("second".utf8), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("second".utf8))
    }

    func testLeavesNoTemporaryFilesBehindOnSuccess() throws {
        let url = temporaryDirectory.appendingPathComponent("clean.json")
        try AtomicFileWriter.write(Data("payload".utf8), to: url)
        XCTAssertEqual(try leftoverTemporaryFiles(in: temporaryDirectory), [])
    }

    func testFailedWriteLeavesThePreviousContentIntact() throws {
        try XCTSkipUnless(canSimulateReadOnlyDirectory, "Test must not run as root")

        let directory = try makeSubdirectory("locked")
        let url = directory.appendingPathComponent("sidecar.json")
        try AtomicFileWriter.write(Data("good".utf8), to: url)

        try setPosixPermissions(0o555, at: directory)
        defer { try? setPosixPermissions(0o755, at: directory) }

        XCTAssertThrowsError(try AtomicFileWriter.write(Data("bad".utf8), to: url)) { error in
            guard case AtomicWriteError.destinationNotWritable = error else {
                return XCTFail("Expected .destinationNotWritable, got \(error)")
            }
        }
        // The whole point: the old edits survive a failed save.
        XCTAssertEqual(try Data(contentsOf: url), Data("good".utf8))
    }

    func testFailedWriteLeavesNoTemporaryFile() throws {
        try XCTSkipUnless(canSimulateReadOnlyDirectory, "Test must not run as root")

        let directory = try makeSubdirectory("locked2")
        let url = directory.appendingPathComponent("sidecar.json")
        try AtomicFileWriter.write(Data("good".utf8), to: url)

        try setPosixPermissions(0o555, at: directory)
        XCTAssertThrowsError(try AtomicFileWriter.write(Data("bad".utf8), to: url))
        try setPosixPermissions(0o755, at: directory)

        XCTAssertEqual(try leftoverTemporaryFiles(in: directory), [])
    }

    func testWritingIntoAMissingDirectoryTreeReportsSomethingActionable() {
        let url = URL(fileURLWithPath: "/Volumes/DefinitelyNotMounted-\(UUID().uuidString)/a.json")
        XCTAssertThrowsError(try AtomicFileWriter.write(Data("x".utf8), to: url)) { error in
            let localized = error as? LocalizedError
            XCTAssertNotNil(localized?.errorDescription)
            XCTAssertNotNil(localized?.recoverySuggestion)
        }
    }

    func testEveryWriteErrorOffersANextStep() {
        let errors: [AtomicWriteError] = [
            .destinationNotWritable(path: "/Volumes/SSD"),
            .volumeUnavailable(path: "/Volumes/SSD"),
            .insufficientDiskSpace,
            .writeFailed(path: "/Volumes/SSD/a.json", reason: "test")
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error)")
            XCTAssertNotNil(error.recoverySuggestion, "\(error)")
        }
    }

    func testLargePayloadRoundTrips() throws {
        let url = temporaryDirectory.appendingPathComponent("large.json")
        let payload = Data(repeating: 0x7A, count: 2_000_000)
        try AtomicFileWriter.write(payload, to: url)
        XCTAssertEqual(try Data(contentsOf: url), payload)
    }

    private func leftoverTemporaryFiles(in directory: URL) throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".tmp") }
    }
}
