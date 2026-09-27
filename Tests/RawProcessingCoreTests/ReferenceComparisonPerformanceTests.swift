import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RawProcessingCore

final class ReferenceComparisonPerformanceTests: XCTestCase {
    func testFullResolutionProcessStaysWithinMemoryBudget() throws {
        guard ProcessInfo.processInfo.environment["LUMAHARBOR_RUN_FULL_RES_REFERENCE_PERF"] == "1" else {
            throw XCTSkip("full-resolution performance gate is opt-in")
        }
        guard let executablePath = ProcessInfo.processInfo.environment["LUMAHARBOR_REFERENCE_COMPARE_EXECUTABLE"],
              !executablePath.isEmpty else {
            XCTFail("LumaHarborReferenceCompare executable is unavailable")
            return
        }

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageDirectory = directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let seedURL = imageDirectory.appendingPathComponent("seed.tiff")
        try writeSixteenBitSRGBTiff(to: seedURL, width: 6_000, height: 4_000)

        let rawIDs = ["raw-a", "raw-b", "raw-c", "raw-d"]
        let fixtureIDs = ["fixture-a", "fixture-b", "fixture-c", "fixture-d", "fixture-e"]
        var cases: [[String: Any]] = []
        for rawID in rawIDs {
            let lrID = "\(rawID)-lr-neutral"
            let lhID = "\(rawID)-lh-neutral"
            for imageID in [lrID, lhID] {
                let destination = imageDirectory.appendingPathComponent("\(imageID).tiff")
                try FileManager.default.linkItem(at: seedURL, to: destination)
            }
            for fixtureID in fixtureIDs {
                cases.append([
                    "caseID": "\(rawID)--\(fixtureID)",
                    "fixtureID": fixtureID,
                    "rawID": rawID,
                    "lrNeutralID": lrID,
                    "lrPresetID": lrID,
                    "lhNeutralID": lhID,
                    "lhPresetID": lhID,
                    "profile": "neutral-reference",
                    "processVersion": "Process 2012",
                    "colorSpace": "sRGB",
                    "bitDepth": 16,
                    "width": 6_000,
                    "height": 4_000
                ])
            }
        }
        let matrixURL = directory.appendingPathComponent("matrix.json")
        let matrix: [String: Any] = ["schemaVersion": 2, "cases": cases]
        let matrixData = try JSONSerialization.data(withJSONObject: matrix, options: [.sortedKeys])
        try matrixData.write(to: matrixURL, options: .atomic)

        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/time")
        process.arguments = [
            "-l",
            executablePath,
            "--all-neutral",
            "--matrix", matrixURL.path,
            "--images", imageDirectory.path
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let elapsed = Date().timeIntervalSince(started)
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let diagnostics = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "reference compare process failed")
        XCTAssertTrue(output.contains("\"status\":\"PASS\""))
        let peakRSS = try XCTUnwrap(parseMaximumResidentSetSize(from: diagnostics))
        XCTAssertLessThanOrEqual(peakRSS, 1_500_000_000)
        print(String(format: "full-resolution aggregate: wall_seconds=%.3f peak_rss_bytes=%llu", elapsed, peakRSS))
    }

    private func parseMaximumResidentSetSize(from output: String) -> UInt64? {
        for line in output.split(separator: "\n") {
            guard line.contains("maximum resident set size") else { continue }
            let digits = line.filter(\.isNumber)
            return UInt64(digits)
        }
        return nil
    }

    private func writeSixteenBitSRGBTiff(to url: URL, width: Int, height: Int) throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var samples = [UInt16](repeating: 0x8000, count: width * height * 4)
        for index in stride(from: 3, to: samples.count, by: 4) {
            samples[index] = UInt16.max
        }
        let bitmapInfo = CGBitmapInfo.byteOrder16Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(CGContext(
            data: &samples,
            width: width,
            height: height,
            bitsPerComponent: 16,
            bytesPerRow: width * 4 * MemoryLayout<UInt16>.size,
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

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
