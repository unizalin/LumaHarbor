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

    func testConfiguredBlackAndWhiteFixturesCarryTheirAdobeMonochromeState() throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtures: [LightroomXMPFixture]
        do {
            fixtures = try LightroomXMPFixtureSupport.load(environment: environment)
        } catch LightroomXMPFixtureSupportError.missingDirectory {
            throw XCTSkip("private Lightroom XMP corpus is not configured")
        }

        let importer = XMPImporter()
        let first = try importer.preview(data: fixtures[0].data, suggestedName: fixtures[0].id)
        let third = try importer.preview(data: fixtures[2].data, suggestedName: fixtures[2].id)
        XCTAssertEqual(first.proposedPreset.patch.monochrome?.isEnabled, true)
        XCTAssertEqual(third.proposedPreset.patch.monochrome?.isEnabled, true)
        XCTAssertTrue(first.nativeFields.contains(.monochrome))
        XCTAssertTrue(third.nativeFields.contains(.monochrome))
    }

    func testConfiguredCorpusCarriesVisualAdjustmentFieldsIntoPatch() throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtures: [LightroomXMPFixture]
        do {
            fixtures = try LightroomXMPFixtureSupport.load(environment: environment)
        } catch LightroomXMPFixtureSupportError.missingDirectory {
            throw XCTSkip("private Lightroom XMP corpus is not configured")
        }

        let importer = XMPImporter()
        let previews = try fixtures.map {
            try importer.preview(data: $0.data, suggestedName: $0.id)
        }

        let blackAndWhite = previews[0].proposedPreset.patch
        XCTAssertEqual(blackAndWhite.monochrome?.red, 5)
        XCTAssertEqual(blackAndWhite.noiseReduction?.luminanceAmount, 13)
        XCTAssertEqual(blackAndWhite.noiseReduction?.colorAmount, 25)
        XCTAssertEqual(blackAndWhite.lensCorrection?.mode, .automatic)

        let hideaki = previews[1].proposedPreset.patch
        XCTAssertEqual(hideaki.colorGrading?.midtones.hue, 174)
        XCTAssertEqual(hideaki.colorGrading?.blending, 100)
        XCTAssertEqual(hideaki.lensCorrection?.mode, .automatic)

        let color = previews[3].proposedPreset.patch
        XCTAssertEqual(color.basic?.temperature, 7656)
        XCTAssertEqual(color.basic?.tint, 12)
        XCTAssertEqual(color.lensCorrection?.mode, .off)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lr-xmp-fixture-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
