import Foundation
import XCTest
@testable import RawProcessingCore

final class ReferenceImageLocatorTests: XCTestCase {
    func testResolveReturnsOnlyMatchingCandidate() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = directory.appendingPathComponent("reference.png")
        try Data([0]).write(to: expected)

        let resolved = try ReferenceImageLocator.resolve(identifier: "reference", in: directory)

        XCTAssertEqual(resolved, expected)
    }

    func testResolveRejectsMultipleExtensionsForSameIdentifier() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([0]).write(to: directory.appendingPathComponent("reference.png"))
        try Data([0]).write(to: directory.appendingPathComponent("reference.tif"))

        XCTAssertThrowsError(try ReferenceImageLocator.resolve(identifier: "reference", in: directory)) { error in
            XCTAssertEqual(error as? ReferenceImageLocatorError, .ambiguous)
        }
    }

    func testResolveReportsMissingCandidate() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try ReferenceImageLocator.resolve(identifier: "reference", in: directory)) { error in
            XCTAssertEqual(error as? ReferenceImageLocatorError, .notFound)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
