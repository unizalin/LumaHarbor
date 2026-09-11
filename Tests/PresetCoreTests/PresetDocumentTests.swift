import XCTest
@testable import PresetCore

final class PresetDocumentTests: XCTestCase {
    private func makeDocument(
        name: String = "My Preset",
        groupPath: [String] = [],
        schemaVersion: Int = PresetDocument.currentSchemaVersion
    ) -> PresetDocument {
        PresetDocument(
            schemaVersion: schemaVersion,
            id: UUID(),
            name: name,
            groupPath: groupPath,
            isFavorite: false,
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 0),
            source: .native,
            patch: AdjustmentPatch(basic: .init(exposure: 1)),
            xmpEnvelope: nil
        )
    }

    // MARK: - Schema version (P3: per-channel tone curves bump v1 -> v2)

    func testCurrentSchemaVersionIsTwo() {
        XCTAssertEqual(PresetDocument.currentSchemaVersion, 2)
    }

    func testNewlyCreatedDocumentDefaultsToCurrentSchemaVersion() {
        let document = makeDocument()
        XCTAssertEqual(document.schemaVersion, 2)
    }

    func testLegacySchemaVersionOneDocumentStillValidates() throws {
        // A v1 preset (no per-channel curve keys ever existed in its JSON)
        // must keep validating after the v2 bump -- `AdvancedToneCurve`
        // itself, not `PresetDocument.validated()`, is what makes the
        // missing `redPoints`/`greenPoints`/`bluePoints` keys degrade to
        // identity (spec §11.1 item 2).
        let document = makeDocument(schemaVersion: 1)
        let validated = try document.validated()
        XCTAssertEqual(validated.schemaVersion, 1)
        XCTAssertTrue(validated.patch.advancedToneCurve?.isIdentity(for: .red) ?? true)
    }

    func testValidatedTrimsNameWhitespace() throws {
        let document = makeDocument(name: "  Moody Film  ")
        let validated = try document.validated()
        XCTAssertEqual(validated.name, "Moody Film")
    }

    func testValidatedRejectsEmptyName() {
        let document = makeDocument(name: "   ")
        XCTAssertThrowsError(try document.validated()) {
            XCTAssertEqual($0 as? PresetError, .invalidName)
        }
    }

    func testValidatedRejectsNameOverGraphemeLimit() {
        let document = makeDocument(name: String(repeating: "a", count: 121))
        XCTAssertThrowsError(try document.validated()) {
            XCTAssertEqual($0 as? PresetError, .invalidName)
        }
    }

    func testValidatedAcceptsNameAtGraphemeLimit() throws {
        let document = makeDocument(name: String(repeating: "a", count: 120))
        XCTAssertNoThrow(try document.validated())
    }

    func testValidatedRejectsGroupPathOverEightLevels() {
        let document = makeDocument(groupPath: (1...9).map { "L\($0)" })
        XCTAssertThrowsError(try document.validated()) {
            XCTAssertEqual($0 as? PresetError, .invalidGroupPath)
        }
    }

    func testValidatedAcceptsGroupPathAtEightLevels() throws {
        let document = makeDocument(groupPath: (1...8).map { "L\($0)" })
        XCTAssertNoThrow(try document.validated())
    }

    func testValidatedRejectsBlankGroupPathSegment() {
        let document = makeDocument(groupPath: ["Film", "  "])
        XCTAssertThrowsError(try document.validated()) {
            XCTAssertEqual($0 as? PresetError, .invalidGroupPath)
        }
    }

    func testValidatedTrimsGroupPathSegments() throws {
        let document = makeDocument(groupPath: [" Film ", " B&W "])
        let validated = try document.validated()
        XCTAssertEqual(validated.groupPath, ["Film", "B&W"])
    }

    func testValidatedRejectsFutureSchemaVersion() {
        let document = makeDocument(schemaVersion: PresetDocument.currentSchemaVersion + 1)
        XCTAssertThrowsError(try document.validated()) {
            XCTAssertEqual(
                $0 as? PresetError,
                .unsupportedSchemaVersion(
                    found: PresetDocument.currentSchemaVersion + 1,
                    supported: PresetDocument.currentSchemaVersion
                )
            )
        }
    }

    func testValidatedRejectsSchemaVersionBelowOne() {
        let document = makeDocument(schemaVersion: 0)
        XCTAssertThrowsError(try document.validated()) {
            XCTAssertEqual(
                $0 as? PresetError,
                .unsupportedSchemaVersion(found: 0, supported: PresetDocument.currentSchemaVersion)
            )
        }
    }

    func testPresetDocumentRoundTripsThroughJSON() throws {
        let document = makeDocument(name: "Kodachrome", groupPath: ["Film", "Warm"])
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(PresetDocument.self, from: data)
        XCTAssertEqual(document, decoded)
    }

    func testPresetSourceRoundTripsThroughJSON() throws {
        let source = PresetSource.adobeXMP(tool: "Lightroom Classic", version: "13.2")
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(PresetSource.self, from: data)
        XCTAssertEqual(source, decoded)
    }

    func testMissingSchemaVersionKeyFailsToDecode() {
        // Every field is required in v1's JSON -- a hand-truncated file should
        // fail cleanly rather than silently defaulting to a nonsense document.
        let json = """
        {"id":"\(UUID().uuidString)","name":"x","groupPath":[],"isFavorite":false,
        "createdAt":0,"modifiedAt":0,"source":{"native":{}},"patch":{}}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(PresetDocument.self, from: Data(json.utf8)))
    }
}
