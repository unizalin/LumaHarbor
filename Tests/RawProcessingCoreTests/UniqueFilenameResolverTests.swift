import XCTest
@testable import RawProcessingCore

/// Spec §6.3: an existing file gets a serial suffix; overwriting silently is
/// forbidden.
final class UniqueFilenameResolverTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/tmp/exports", isDirectory: true)

    func testUsesThePlainNameWhenNothingExists() throws {
        let url = try XCTUnwrap(UniqueFilenameResolver.resolve(
            baseName: "DSC0001",
            fileExtension: "jpg",
            in: directory,
            exists: { _ in false }
        ))
        XCTAssertEqual(url.lastPathComponent, "DSC0001.jpg")
    }

    func testAddsASerialSuffixOnCollision() throws {
        let taken: Set<String> = ["DSC0001.jpg"]
        let url = try XCTUnwrap(UniqueFilenameResolver.resolve(
            baseName: "DSC0001",
            fileExtension: "jpg",
            in: directory,
            exists: { taken.contains($0.lastPathComponent) }
        ))
        XCTAssertEqual(url.lastPathComponent, "DSC0001-1.jpg")
    }

    func testKeepsCountingPastTheFirstSuffix() throws {
        let taken: Set<String> = ["DSC0001.jpg", "DSC0001-1.jpg", "DSC0001-2.jpg"]
        let url = try XCTUnwrap(UniqueFilenameResolver.resolve(
            baseName: "DSC0001",
            fileExtension: "jpg",
            in: directory,
            exists: { taken.contains($0.lastPathComponent) }
        ))
        XCTAssertEqual(url.lastPathComponent, "DSC0001-3.jpg")
    }

    func testGivesUpRatherThanLoopingForever() {
        let url = UniqueFilenameResolver.resolve(
            baseName: "DSC0001",
            fileExtension: "jpg",
            in: directory,
            maximumAttempts: 5,
            exists: { _ in true }
        )
        XCTAssertNil(url)
    }

    func testSanitisesNamesThatCouldEscapeTheDirectory() {
        XCTAssertEqual(UniqueFilenameResolver.sanitize("../../etc/passwd"), "..-..-etc-passwd")
        XCTAssertEqual(UniqueFilenameResolver.sanitize("a/b"), "a-b")
        XCTAssertEqual(UniqueFilenameResolver.sanitize("   "), "Untitled")
        XCTAssertEqual(UniqueFilenameResolver.sanitize(""), "Untitled")
    }

    func testSanitisedNameStaysInsideTheChosenDirectory() throws {
        let url = try XCTUnwrap(UniqueFilenameResolver.resolve(
            baseName: "../escape",
            fileExtension: "jpg",
            in: directory,
            exists: { _ in false }
        ))
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
    }
}
