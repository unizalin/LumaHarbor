import Foundation
import XCTest

final class LightroomReferenceMatrixContractTests: XCTestCase {
    func testCommittedReferenceMatrixTemplateIsSanitizedAndComplete() throws {
        let templateURL = repoRoot
            .appendingPathComponent("docs/testing/templates/lightroom-xmp-reference-matrix.json")
        let data = try Data(contentsOf: templateURL)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertNil(object["absolutePaths"])
        let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 5)

        let requiredKeys: Set<String> = [
            "fixtureID", "rawID", "lrNeutralID", "lrPresetID", "lhNeutralID", "lhPresetID",
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
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
