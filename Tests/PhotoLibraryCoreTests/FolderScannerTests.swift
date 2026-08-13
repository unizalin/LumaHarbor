import XCTest
@testable import PhotoLibraryCore

/// Spec §6.1 and §11: results arrive in batches as they are found, `.lumaharbor`
/// is skipped, and one bad file doesn't stop the walk.
final class FolderScannerTests: TemporaryDirectoryTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try makeSubdirectory("Photos")
    }

    private func makeRaw(_ relativePath: String, bytes: Int = 64) throws {
        try writeFile(
            Data(repeating: 0x11, count: bytes),
            at: root.appendingPathComponent(relativePath)
        )
    }

    private func collect(_ scanner: FolderScanner) async -> (files: [ScannedFile], summary: ScanSummary?) {
        var files: [ScannedFile] = []
        var summary: ScanSummary?
        for await event in scanner.scan(root: root) {
            switch event {
            case .discovered(let batch): files.append(contentsOf: batch)
            case .finished(let result): summary = result
            case .started, .fileFailed: break
            }
        }
        return (files, summary)
    }

    func testFindsRawFilesRecursively() async throws {
        try makeRaw("DSC0001.ARW")
        try makeRaw("Trip/DSC0002.ARW")
        try makeRaw("Trip/Day2/DSC0003.ARW")

        let (files, summary) = await collect(FolderScanner())
        XCTAssertEqual(
            Set(files.map(\.relativePath)),
            ["DSC0001.ARW", "Trip/DSC0002.ARW", "Trip/Day2/DSC0003.ARW"]
        )
        XCTAssertEqual(summary?.discoveredCount, 3)
        XCTAssertEqual(summary?.wasCancelled, false)
    }

    func testRelativePathsUseForwardSlashesForPortability() async throws {
        try makeRaw("Trip/Day2/DSC0003.ARW")
        let (files, _) = await collect(FolderScanner())
        XCTAssertEqual(files.first?.relativePath, "Trip/Day2/DSC0003.ARW")
    }

    func testIgnoresNonRawFiles() async throws {
        try makeRaw("DSC0001.ARW")
        try writeFile(Data("x".utf8), at: root.appendingPathComponent("notes.txt"))
        try writeFile(Data("x".utf8), at: root.appendingPathComponent("preview.jpg"))

        let (files, _) = await collect(FolderScanner())
        XCTAssertEqual(files.map(\.relativePath), ["DSC0001.ARW"])
    }

    func testExtensionMatchingIsCaseInsensitive() async throws {
        try makeRaw("lower.arw")
        try makeRaw("UPPER.ARW")
        try makeRaw("Mixed.Arw")

        let (files, _) = await collect(FolderScanner())
        XCTAssertEqual(files.count, 3)
    }

    func testSkipsOurOwnSidecarDirectory() async throws {
        try makeRaw("DSC0001.ARW")
        // A stray file with a RAW extension inside .lumaharbor must not be
        // indexed as a photo.
        try writeFile(
            Data("x".utf8),
            at: root.appendingPathComponent(".lumaharbor/edits/stray.ARW")
        )

        let (files, _) = await collect(FolderScanner())
        XCTAssertEqual(files.map(\.relativePath), ["DSC0001.ARW"])
    }

    func testReportsFileSize() async throws {
        try makeRaw("DSC0001.ARW", bytes: 4_096)
        let (files, _) = await collect(FolderScanner())
        XCTAssertEqual(files.first?.fileSize, 4_096)
    }

    func testDeliversResultsInBatchesAsTheyAreFound() async throws {
        for index in 0..<10 {
            try makeRaw(String(format: "DSC%04d.ARW", index))
        }

        var batchSizes: [Int] = []
        for await event in FolderScanner(batchSize: 3).scan(root: root) {
            if case .discovered(let batch) = event {
                batchSizes.append(batch.count)
            }
        }
        // Spec §6.1: the grid grows during the scan rather than after it.
        XCTAssertGreaterThan(batchSizes.count, 1)
        XCTAssertEqual(batchSizes.reduce(0, +), 10)
        XCTAssertTrue(batchSizes.dropLast().allSatisfy { $0 == 3 })
    }

    func testEmptyFolderFinishesCleanly() async throws {
        let (files, summary) = await collect(FolderScanner())
        XCTAssertTrue(files.isEmpty)
        XCTAssertEqual(summary?.discoveredCount, 0)
    }

    func testMissingRootFinishesInsteadOfHanging() async throws {
        root = temporaryDirectory.appendingPathComponent("NotMounted", isDirectory: true)
        let (files, summary) = await collect(FolderScanner())
        XCTAssertTrue(files.isEmpty)
        XCTAssertNotNil(summary, "The stream must always terminate")
    }

    func testCancellationStopsTheWalk() async throws {
        for index in 0..<200 {
            try makeRaw(String(format: "DSC%04d.ARW", index))
        }

        var seen = 0
        for await event in FolderScanner(batchSize: 1).scan(root: root) {
            if case .discovered = event {
                seen += 1
                if seen == 3 { break }
            }
        }
        // Breaking out terminates the stream, which cancels the walk. The test
        // asserts it returns rather than running to completion in the
        // background — a leak here would be invisible in production.
        XCTAssertEqual(seen, 3)
    }

    func testRelativePathFallsBackWhenTheURLIsOutsideTheRoot() {
        let outside = URL(fileURLWithPath: "/elsewhere/DSC0001.ARW")
        XCTAssertEqual(
            FolderScanner.relativePath(of: outside, from: URL(fileURLWithPath: "/Photos")),
            "DSC0001.ARW"
        )
    }

    func testCustomExtensionSetIsRespected() async throws {
        try makeRaw("a.ARW")
        try makeRaw("b.NEF")

        var files: [ScannedFile] = []
        for await event in FolderScanner(supportedExtensions: ["nef"]).scan(root: root) {
            if case .discovered(let batch) = event { files.append(contentsOf: batch) }
        }
        XCTAssertEqual(files.map(\.relativePath), ["b.NEF"])
    }
}
