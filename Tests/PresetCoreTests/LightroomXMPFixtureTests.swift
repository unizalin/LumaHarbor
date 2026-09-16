import Foundation
import XCTest
@testable import PresetCore

final class LightroomXMPFixtureTests: XCTestCase {
    func testLoaderReturnsOnlySortedXMPFixturesWithSanitizedIDs() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("<xmp/>".utf8).write(to: directory.appendingPathComponent("z-last.xmp"))
        try Data("<xmp/>".utf8).write(to: directory.appendingPathComponent("a-first.XMP"))
        try Data("ignore".utf8).write(to: directory.appendingPathComponent("not-xmp.txt"))

        let fixtures = try LightroomXMPFixtureSupport.load(environment: [
            "LUMAHARBOR_LR_XMP_FIXTURE_DIR": directory.path
        ])

        XCTAssertEqual(fixtures.map(\.id), ["fixture-01", "fixture-02"])
        XCTAssertEqual(fixtures.map(\.data.count), [6, 6])
        XCTAssertTrue(fixtures.allSatisfy { !$0.id.contains("first") && !$0.id.contains("last") })
    }

    func testMissingFixtureDirectoryIsAnExplicitSupportError() {
        XCTAssertThrowsError(try LightroomXMPFixtureSupport.load(environment: [:])) { error in
            XCTAssertEqual(error as? LightroomXMPFixtureSupportError, .missingDirectory)
        }
    }

    func testConfiguredPrivateCorpusPreviewsWithoutEchoingIdentity() throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtures: [LightroomXMPFixture]
        do {
            fixtures = try LightroomXMPFixtureSupport.load(environment: environment)
        } catch LightroomXMPFixtureSupportError.missingDirectory {
            throw XCTSkip("private Lightroom XMP corpus is not configured")
        }

        XCTAssertEqual(fixtures.count, 5)
        let importer = XMPImporter()
        for fixture in fixtures {
            let preview = try importer.preview(data: fixture.data, suggestedName: fixture.id)
            XCTAssertFalse(preview.proposedPreset.name.isEmpty)
            XCTAssertFalse(preview.diagnostics.contains { String(describing: $0).contains(fixture.id) })
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lr-xmp-fixture-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
