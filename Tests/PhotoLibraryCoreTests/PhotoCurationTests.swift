import XCTest
@testable import PhotoLibraryCore

/// Spec §6.1: `PhotoCuration` is the portable rating/flag/keyword record a
/// sidecar carries. Keywords are unique by `normalized`, sorted by
/// `normalized` for a stable, diffable JSON encoding.
final class PhotoCurationTests: XCTestCase {
    func testNeutralIsRatingZeroFlagNoneNoKeywords() {
        XCTAssertEqual(PhotoCuration.neutral, PhotoCuration(rating: 0, flag: .none, keywords: []))
        XCTAssertTrue(PhotoCuration.neutral.isNeutral)
    }

    func testDefaultInitIsNeutral() {
        XCTAssertEqual(PhotoCuration(), .neutral)
    }

    func testInitClampsRatingToZeroThroughFive() {
        XCTAssertEqual(PhotoCuration(rating: 9).rating, 5)
        XCTAssertEqual(PhotoCuration(rating: -3).rating, 0)
        XCTAssertEqual(PhotoCuration(rating: 3).rating, 3)
    }

    func testKeywordsDeduplicateByNormalizedKeepingFirstDisplayValue() {
        let curation = PhotoCuration(keywords: [
            PhotoKeyword(normalized: "sunset", displayValue: "Sunset"),
            PhotoKeyword(normalized: "sunset", displayValue: "SUNSET")
        ])
        XCTAssertEqual(curation.keywords, [PhotoKeyword(normalized: "sunset", displayValue: "Sunset")])
    }

    func testKeywordsAreSortedByNormalizedForStableEncoding() {
        let curation = PhotoCuration(keywords: [
            PhotoKeyword(normalized: "sunset", displayValue: "Sunset"),
            PhotoKeyword(normalized: "beach", displayValue: "Beach")
        ])
        XCTAssertEqual(curation.keywords.map(\.normalized), ["beach", "sunset"])
    }

    func testNonNeutralValuesAreNotNeutral() {
        XCTAssertFalse(PhotoCuration(rating: 1).isNeutral)
        XCTAssertFalse(PhotoCuration(flag: .pick).isNeutral)
        XCTAssertFalse(PhotoCuration(keywords: [PhotoKeyword(normalized: "x", displayValue: "x")]).isNeutral)
    }

    func testCodableRoundTrip() throws {
        let curation = PhotoCuration(
            rating: 4,
            flag: .reject,
            keywords: [PhotoKeyword(normalized: "dog", displayValue: "Dog")]
        )
        let data = try JSONEncoder().encode(curation)
        let decoded = try JSONDecoder().decode(PhotoCuration.self, from: data)
        XCTAssertEqual(decoded, curation)
    }

    func testDecodingEnforcesRatingAndKeywordInvariants() throws {
        let json = """
        {
          "rating": 9,
          "flag": "pick",
          "keywords": [
            { "normalized": "sunset", "displayValue": "Sunset" },
            { "normalized": "beach", "displayValue": "Beach" },
            { "normalized": "sunset", "displayValue": "SUNSET" }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(PhotoCuration.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.rating, 5)
        XCTAssertEqual(decoded.flag, .pick)
        XCTAssertEqual(decoded.keywords.map(\.normalized), ["beach", "sunset"])
        XCTAssertEqual(decoded.keywords.last?.displayValue, "Sunset")
    }

    func testCodableUsesPlainFieldNames() throws {
        let curation = PhotoCuration(rating: 2, flag: .pick, keywords: [])
        let data = try JSONEncoder().encode(curation)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["rating"] as? Int, 2)
        XCTAssertEqual(object["flag"] as? String, "pick")
        XCTAssertNotNil(object["keywords"])
    }
}
