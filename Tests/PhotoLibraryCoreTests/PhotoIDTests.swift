import XCTest
@testable import PhotoLibraryCore

final class PhotoIDTests: XCTestCase {
    func testPhotoIDEncodesAsABareUUIDString() throws {
        let id = PhotoID(UUID(uuidString: "6C6F1F1C-0000-4000-8000-00000000ABCD")!)
        let data = try JSONEncoder().encode(["photoID": id])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"6C6F1F1C-0000-4000-8000-00000000ABCD\""), json)
    }

    func testPhotoIDRoundTrips() throws {
        let id = PhotoID()
        let data = try JSONEncoder().encode([id])
        let decoded = try JSONDecoder().decode([PhotoID].self, from: data)
        XCTAssertEqual(decoded, [id])
    }

    func testDecodingRejectsMalformedIdentifier() {
        let data = Data(#"["not-a-uuid"]"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode([PhotoID].self, from: data))
    }

    func testSidecarFilenameUsesTheUUID() {
        let id = PhotoID(UUID(uuidString: "6C6F1F1C-0000-4000-8000-00000000ABCD")!)
        XCTAssertEqual(id.sidecarFilename, "6C6F1F1C-0000-4000-8000-00000000ABCD.json")
    }
}
