import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class LightroomReferenceMatrixContractTests: XCTestCase {
    func testCommittedReferenceMatrixTemplateIsSanitizedAndComplete() throws {
        let templateURL = repoRoot
            .appendingPathComponent("docs/testing/templates/lightroom-xmp-reference-matrix.json")
        let data = try Data(contentsOf: templateURL)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertNil(object["absolutePaths"])
        let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 20)

        let requiredKeys: Set<String> = [
            "caseID", "fixtureID", "rawID",
            "lrNeutralID", "lrPresetID", "lhNeutralID", "lhPresetID",
            "profile", "processVersion", "colorSpace", "bitDepth", "width", "height"
        ]
        for item in cases {
            XCTAssertEqual(Set(item.keys), requiredKeys)
            XCTAssertTrue(item.values.allSatisfy { value in
                guard let string = value as? String else { return true }
                return !string.contains("/Users/")
                    && !string.contains("/Volumes/")
                    && !string.contains("file://")
                    && !string.contains("<x:xmpmeta")
            })
        }
        XCTAssertEqual(Set(cases.compactMap { $0["fixtureID"] as? String }), [
            "fixture-a", "fixture-b", "fixture-c", "fixture-d", "fixture-e"
        ])
        XCTAssertEqual(Set(cases.compactMap { $0["rawID"] as? String }), [
            "raw-a", "raw-b", "raw-c", "raw-d"
        ])
        let expectedCaseIDs = Set(
            ["raw-a", "raw-b", "raw-c", "raw-d"].flatMap { rawID in
                ["fixture-a", "fixture-b", "fixture-c", "fixture-d", "fixture-e"].map {
                    "\(rawID)--\($0)"
                }
            }
        )
        XCTAssertEqual(Set(cases.compactMap { $0["caseID"] as? String }), expectedCaseIDs)
    }

    func testValidatorRejectsMultipleExtensionsForOneImageID() throws {
        let fixture = try makeValidatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let identifier = "raw-a--fixture-a-lr-neutral"
        try Data("stale".utf8).write(
            to: fixture.images.appendingPathComponent("\(identifier).tif")
        )

        let result = try runValidator(matrix: fixture.matrix, images: fixture.images)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("FAIL multiple reference image candidates"))
    }

    func testValidatorRejectsDuplicateContentAcrossDifferentCases() throws {
        let fixture = try makeValidatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let duplicate = try Data(contentsOf: fixture.images.appendingPathComponent("raw-a--fixture-a-lr-preset.tiff"))
        try duplicate.write(to: fixture.images.appendingPathComponent("raw-b--fixture-a-lr-preset.tiff"))

        let result = try runValidator(matrix: fixture.matrix, images: fixture.images)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("FAIL duplicate reference image content"))
    }

    func testValidatorAllowsExplicitNeutralSharingForSameRAW() throws {
        let fixture = try makeValidatorFixture(sharedNeutral: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runValidator(matrix: fixture.matrix, images: fixture.images)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("PASS reference matrix"))
    }

    private func makeValidatorFixture(sharedNeutral: Bool = false) throws -> (
        root: URL,
        matrix: URL,
        images: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let images = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)

        let rawIDs = ["raw-a", "raw-b", "raw-c", "raw-d"]
        let fixtureIDs = ["fixture-a", "fixture-b", "fixture-c", "fixture-d", "fixture-e"]
        var imageIDs = Set<String>()
        let cases: [[String: Any]] = rawIDs.flatMap { rawID in
            fixtureIDs.map { fixtureID in
            let caseID = "\(rawID)--\(fixtureID)"
            let lrNeutralID = sharedNeutral ? "\(rawID)-lr-neutral" : "\(caseID)-lr-neutral"
            let lhNeutralID = sharedNeutral ? "\(rawID)-lh-neutral" : "\(caseID)-lh-neutral"
            let values: [String: Any] = [
                "caseID": caseID,
                "fixtureID": fixtureID,
                "rawID": rawID,
                "lrNeutralID": lrNeutralID,
                "lrPresetID": "\(caseID)-lr-preset",
                "lhNeutralID": lhNeutralID,
                "lhPresetID": "\(caseID)-lh-preset",
                "profile": "test-profile",
                "processVersion": "test-process",
                "colorSpace": "sRGB",
                "bitDepth": 16,
                "width": 2,
                "height": 1
            ]
            imageIDs.formUnion([lrNeutralID, "\(caseID)-lr-preset", lhNeutralID, "\(caseID)-lh-preset"])
            return values
            }
        }

        let matrix = root.appendingPathComponent("matrix.json")
        let data = try JSONSerialization.data(
            withJSONObject: ["schemaVersion": 2, "cases": cases],
            options: [.sortedKeys]
        )
        try data.write(to: matrix)
        for (index, imageID) in imageIDs.sorted().enumerated() {
            try writeReferenceTIFF(
                to: images.appendingPathComponent("\(imageID).tiff"),
                seed: index
            )
        }
        return (root, matrix, images)
    }

    private func writeReferenceTIFF(to url: URL, seed: Int) throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var samples: [UInt16] = [
            UInt16((seed * 257) % Int(UInt16.max)),
            UInt16((seed * 509 + 17) % Int(UInt16.max)),
            UInt16((seed * 761 + 31) % Int(UInt16.max)),
            UInt16.max,
            UInt16.max,
            UInt16((seed * 389 + 43) % Int(UInt16.max)),
            UInt16((seed * 613 + 59) % Int(UInt16.max)),
            UInt16.max
        ]
        let bitmapInfo = CGBitmapInfo.byteOrder16Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
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

    private func runValidator(matrix: URL, images: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            repoRoot.appendingPathComponent("Scripts/validate-lr-reference-matrix.zsh").path,
            matrix.path,
            "--images",
            images.path
        ]
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
