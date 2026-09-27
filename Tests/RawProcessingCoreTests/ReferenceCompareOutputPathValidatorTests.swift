import Foundation
import XCTest
@testable import RawProcessingCore

final class ReferenceCompareOutputPathValidatorTests: XCTestCase {
    func testRejectsMatrixPath() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let matrix = root.appendingPathComponent("matrix.json")
        try Data("matrix".utf8).write(to: matrix)

        XCTAssertThrowsError(try ReferenceCompareOutputPathValidator.validate(
            reportURL: matrix,
            matrixURL: matrix,
            referenceRootURL: root.appendingPathComponent("images", isDirectory: true)
        )) { error in
            XCTAssertEqual(error as? ReferenceCompareOutputPathError, .reportIsInput)
        }
    }

    func testRejectsExistingDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("report", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertThrowsError(try ReferenceCompareOutputPathValidator.validate(
            reportURL: directory,
            matrixURL: root.appendingPathComponent("matrix.json"),
            referenceRootURL: root.appendingPathComponent("images", isDirectory: true)
        )) { error in
            XCTAssertEqual(error as? ReferenceCompareOutputPathError, .reportIsDirectory)
        }
    }

    func testRejectsPathResolvedInsideReferenceRoot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let images = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)

        XCTAssertThrowsError(try ReferenceCompareOutputPathValidator.validate(
            reportURL: images.appendingPathComponent("nested/../report.json"),
            matrixURL: root.appendingPathComponent("matrix.json"),
            referenceRootURL: images
        )) { error in
            XCTAssertEqual(error as? ReferenceCompareOutputPathError, .reportInsideReferenceDirectory)
        }
    }

    func testRejectsSymlinkReport() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.json")
        let link = root.appendingPathComponent("report.json")
        try Data("sentinel".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try ReferenceCompareOutputPathValidator.validate(
            reportURL: link,
            matrixURL: root.appendingPathComponent("matrix.json"),
            referenceRootURL: root.appendingPathComponent("images", isDirectory: true)
        )) { error in
            XCTAssertEqual(error as? ReferenceCompareOutputPathError, .reportIsSymlink)
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
