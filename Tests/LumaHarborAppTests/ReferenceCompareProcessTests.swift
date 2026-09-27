import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class ReferenceCompareProcessTests: XCTestCase {
    func testAllNeutralProcessReportsFourUniqueCasesAndSanitizedJSON() throws {
        let executable = try referenceCompareExecutable()
        let fixture = try makeFixture(rawIDs: ["raw-a", "raw-b", "raw-c", "raw-d"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try run(
            executable: executable,
            arguments: [
                "--all-neutral",
                "--matrix", fixture.matrix.path,
                "--images", fixture.images.path
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "PASS")
        let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 4)
        XCTAssertEqual(Set(cases.compactMap { $0["rawID"] as? String }), ["raw-a", "raw-b", "raw-c", "raw-d"])
        XCTAssertTrue(cases.allSatisfy { ($0["status"] as? String) == "PASS" })
        XCTAssertFalse(result.output.contains("/Users/"))
        XCTAssertFalse(result.output.contains(".tiff"))
    }

    func testAllNeutralProcessReturnsNonzeroNotRunForMissingReference() throws {
        let executable = try referenceCompareExecutable()
        let fixture = try makeFixture(rawIDs: ["raw-a"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try run(
            executable: executable,
            arguments: [
                "--all-neutral",
                "--matrix", fixture.matrix.path,
                "--images", fixture.images.path
            ]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "NOT RUN")
        let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 4)
        XCTAssertFalse(result.output.contains("/Users/"))
    }

    func testAllNeutralProcessWritesSanitizedReportAtomically() throws {
        let executable = try referenceCompareExecutable()
        let fixture = try makeFixture(rawIDs: ["raw-a", "raw-b", "raw-c", "raw-d"])
        let report = fixture.root.appendingPathComponent("report.json")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try run(
            executable: executable,
            arguments: [
                "--all-neutral",
                "--matrix", fixture.matrix.path,
                "--images", fixture.images.path,
                "--report", report.path
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        let reportData = try Data(contentsOf: report)
        let stdoutObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
        )
        let reportObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: reportData) as? [String: Any]
        )
        XCTAssertEqual(stdoutObject["status"] as? String, "PASS")
        XCTAssertEqual(reportObject["status"] as? String, "PASS")
        XCTAssertEqual((reportObject["cases"] as? [[String: Any]])?.count, 4)
        XCTAssertEqual((stdoutObject["cases"] as? [[String: Any]])?.count, 4)
        XCTAssertFalse(String(decoding: reportData, as: UTF8.self).contains(fixture.root.path))
        XCTAssertFalse(String(decoding: reportData, as: UTF8.self).contains(".tiff"))
    }

    func testReportCannotOverwriteMatrix() throws {
        let executable = try referenceCompareExecutable()
        let fixture = try makeFixture(rawIDs: ["raw-a", "raw-b", "raw-c", "raw-d"])
        let matrixBefore = try Data(contentsOf: fixture.matrix)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try run(
            executable: executable,
            arguments: [
                "--all-neutral",
                "--matrix", fixture.matrix.path,
                "--images", fixture.images.path,
                "--report", fixture.matrix.path
            ]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertEqual(try Data(contentsOf: fixture.matrix), matrixBefore)
    }

    func testReportCannotBeWrittenInsideReferenceDirectory() throws {
        let executable = try referenceCompareExecutable()
        let fixture = try makeFixture(rawIDs: ["raw-a", "raw-b", "raw-c", "raw-d"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try run(
            executable: executable,
            arguments: [
                "--all-neutral",
                "--matrix", fixture.matrix.path,
                "--images", fixture.images.path,
                "--report", fixture.images.appendingPathComponent("report.json").path
            ]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.images.appendingPathComponent("report.json").path))
    }

    func testReportCannotBeWrittenThroughSymlink() throws {
        let executable = try referenceCompareExecutable()
        let fixture = try makeFixture(rawIDs: ["raw-a", "raw-b", "raw-c", "raw-d"])
        let destination = fixture.root.appendingPathComponent("real-report.json")
        let symlink = fixture.root.appendingPathComponent("report-link.json")
        FileManager.default.createFile(atPath: destination.path, contents: Data("sentinel".utf8))
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: destination)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try run(
            executable: executable,
            arguments: [
                "--all-neutral",
                "--matrix", fixture.matrix.path,
                "--images", fixture.images.path,
                "--report", symlink.path
            ]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertEqual(try Data(contentsOf: destination), Data("sentinel".utf8))
    }

    func testReportCannotTraverseIntoReferenceDirectory() throws {
        let executable = try referenceCompareExecutable()
        let fixture = try makeFixture(rawIDs: ["raw-a", "raw-b", "raw-c", "raw-d"])
        let outside = fixture.root.appendingPathComponent("outside-report.json")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let traversalPath = fixture.images
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("outside-report.json")
        let result = try run(
            executable: executable,
            arguments: [
                "--all-neutral",
                "--matrix", fixture.matrix.path,
                "--images", fixture.images.path,
                "--report", traversalPath.path
            ]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testSingleNeutralProcessUsesTheTypedComparisonPath() throws {
        let executable = try referenceCompareExecutable()
        let fixture = try makeFixture(rawIDs: ["raw-a"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try run(
            executable: executable,
            arguments: [
                "--mode", "neutralDirect",
                "--case", "raw-a--fixture-a",
                "--lr-neutral", "raw-a-lr-neutral",
                "--lr-preset", "raw-a--fixture-a-lr-preset",
                "--lh-neutral", "raw-a-lh-neutral",
                "--lh-preset", "raw-a--fixture-a-lh-preset",
                "--matrix", fixture.matrix.path,
                "--images", fixture.images.path
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "PASS")
        XCTAssertEqual(object["caseID"] as? String, "raw-a--fixture-a")
        XCTAssertEqual(object["mode"] as? String, "neutralDirect")
        XCTAssertFalse(result.output.contains("/Users/"))
    }

    func testSingleNeutralProcessPreservesKnownSixteenBitErrorMagnitude() throws {
        let executable = try referenceCompareExecutable()
        let fixture = try makeFixture(rawIDs: ["raw-a"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sharedTail: [UInt16] = [0x2000, 0x3000, .max, 0x4000, 0x5000, 0x6000, .max]
        try writeReferenceTIFF(
            to: fixture.images.appendingPathComponent("raw-a-lr-neutral.tiff"),
            samples: [0x0100] + sharedTail
        )
        try writeReferenceTIFF(
            to: fixture.images.appendingPathComponent("raw-a-lh-neutral.tiff"),
            samples: [0x0200] + sharedTail
        )

        let result = try run(
            executable: executable,
            arguments: [
                "--mode", "neutralDirect",
                "--case", "raw-a--fixture-a",
                "--lr-neutral", "raw-a-lr-neutral",
                "--lr-preset", "raw-a--fixture-a-lr-preset",
                "--lh-neutral", "raw-a-lh-neutral",
                "--lh-preset", "raw-a--fixture-a-lh-preset",
                "--matrix", fixture.matrix.path,
                "--images", fixture.images.path
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        let metrics = try XCTUnwrap(object["metrics"] as? [String: Any])
        let channelError = Double(0x0100) / Double(UInt16.max)
        XCTAssertEqual(try XCTUnwrap(metrics["meanAbsoluteError"] as? Double), channelError / 6, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(metrics["p95AbsoluteError"] as? Double), channelError, accuracy: 1e-9)
    }

    private func referenceCompareExecutable() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let candidates: [URL]
        if let override = environment["LUMAHARBOR_REFERENCE_COMPARE_EXECUTABLE"] {
            candidates = [URL(fileURLWithPath: override)]
        } else {
            candidates = [
                Bundle(for: ReferenceCompareProcessTests.self).bundleURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("LumaHarborReferenceCompare"),
                repoRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/LumaHarborReferenceCompare"),
                repoRoot.appendingPathComponent(".build/debug/LumaHarborReferenceCompare")
            ]
        }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            XCTFail("LumaHarborReferenceCompare executable is unavailable")
            throw NSError(domain: "ReferenceCompareProcessTests", code: 1)
        }
        return executable
    }

    private func makeFixture(rawIDs: [String]) throws -> (root: URL, images: URL, matrix: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let images = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)

        var cases: [[String: Any]] = []
        let fixtureIDs = ["fixture-a", "fixture-b", "fixture-c", "fixture-d", "fixture-e"]
        for rawID in ["raw-a", "raw-b", "raw-c", "raw-d"] {
            for fixtureID in fixtureIDs {
                let caseID = "\(rawID)--\(fixtureID)"
                cases.append([
                    "caseID": caseID,
                    "fixtureID": fixtureID,
                    "rawID": rawID,
                    "lrNeutralID": "\(rawID)-lr-neutral",
                    "lrPresetID": "\(caseID)-lr-preset",
                    "lhNeutralID": "\(rawID)-lh-neutral",
                    "lhPresetID": "\(caseID)-lh-preset",
                    "profile": "sRGB",
                    "processVersion": "native-reference-v1",
                    "colorSpace": "sRGB",
                    "bitDepth": 16,
                    "width": 2,
                    "height": 1
                ])
            }
        }
        let matrix = root.appendingPathComponent("matrix.json")
        let matrixData = try JSONSerialization.data(
            withJSONObject: ["schemaVersion": 2, "cases": cases],
            options: [.sortedKeys]
        )
        try matrixData.write(to: matrix)

        for (index, rawID) in rawIDs.sorted().enumerated() {
            try writeReferenceTIFF(
                to: images.appendingPathComponent("\(rawID)-lr-neutral.tiff"),
                seed: index
            )
            try writeReferenceTIFF(
                to: images.appendingPathComponent("\(rawID)-lh-neutral.tiff"),
                seed: index
            )
        }
        return (root, images, matrix)
    }

    private func writeReferenceTIFF(to url: URL, seed: Int) throws {
        try writeReferenceTIFF(to: url, samples: [
            UInt16((seed * 257) % Int(UInt16.max)),
            UInt16((seed * 509 + 17) % Int(UInt16.max)),
            UInt16((seed * 761 + 31) % Int(UInt16.max)),
            UInt16.max,
            UInt16.max,
            UInt16((seed * 389 + 43) % Int(UInt16.max)),
            UInt16((seed * 613 + 59) % Int(UInt16.max)),
            UInt16.max
        ])
    }

    private func writeReferenceTIFF(to url: URL, samples inputSamples: [UInt16]) throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var samples = inputSamples
        XCTAssertEqual(samples.count, 8)
        let bitmapInfo = CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(CGContext(
            data: &samples,
            width: 2,
            height: 1,
            bitsPerComponent: 16,
            bytesPerRow: 2 * 4 * MemoryLayout<UInt16>.size,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.tiff.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func run(executable: URL, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (process.terminationStatus, output)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
