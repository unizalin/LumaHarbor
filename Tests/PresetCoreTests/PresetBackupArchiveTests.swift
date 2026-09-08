import XCTest
@testable import PresetCore

/// Phase 3 Task 3.2: "Add backup archive tests." A `PresetBackupArchive`
/// bundles every preset in a scope into one portable file -- distinct from
/// `.lhpreset` (one preset) and `.xmp` (one Adobe-compatible preset). Pure
/// model/coding tests only; restoring an archive into a real repository
/// (with conflict resolution) is covered separately by
/// `PhotoLibraryCoreTests/PresetRestoreTests.swift`, since that needs a real
/// `PresetRepository`.
final class PresetBackupArchiveTests: XCTestCase {
    private func makeDocument(
        name: String = "My Preset",
        source: PresetSource = .native,
        xmpEnvelope: XMPEnvelope? = nil
    ) -> PresetDocument {
        PresetDocument(
            id: UUID(),
            name: name,
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 0),
            source: source,
            patch: AdjustmentPatch(basic: .init(exposure: 1)),
            xmpEnvelope: xmpEnvelope
        )
    }

    // MARK: - Round trip

    func testEncodeDecodeRoundTripsEveryDocumentExactly() throws {
        let documents = [makeDocument(name: "A"), makeDocument(name: "B"), makeDocument(name: "C")]
        let archive = PresetBackupArchive(createdAt: Date(timeIntervalSince1970: 1_000), documents: documents)

        let data = try PresetBackupCoding.encode(archive)
        let decoded = try PresetBackupCoding.decode(data)

        XCTAssertEqual(decoded, archive)
        XCTAssertEqual(decoded.documents, documents)
    }

    func testAnEmptyArchiveRoundTripsWithoutError() throws {
        let archive = PresetBackupArchive(createdAt: Date(timeIntervalSince1970: 0), documents: [])
        let decoded = try PresetBackupCoding.decode(try PresetBackupCoding.encode(archive))
        XCTAssertEqual(decoded.documents, [])
    }

    func testArchiveRecordsItsSchemaVersionAndCreationDate() throws {
        let archive = PresetBackupArchive(createdAt: Date(timeIntervalSince1970: 42), documents: [])
        XCTAssertEqual(archive.schemaVersion, PresetBackupArchive.currentSchemaVersion)
        XCTAssertEqual(archive.createdAt, Date(timeIntervalSince1970: 42))
    }

    // MARK: - Preserve unknown XMP fields (Task 3.2: "Preserve unknown XMP fields")

    /// `XMPEnvelope.originalPacketUTF8` is the single source of truth for
    /// everything the original packet contained, including properties this
    /// build has no mapping for -- a backup/restore round trip must not
    /// truncate, re-serialize, or otherwise touch that string.
    func testRoundTripPreservesTheFullOriginalXMPPacketByteForByte() throws {
        let unmappedPacket = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:ProcessVersion="15.4" crs:Exposure2012="+0.50"
          crs:SomeFutureLightroomOnlyProperty2099="totally-unmapped-value"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let envelope = XMPEnvelope(
            originalPacketUTF8: unmappedPacket,
            documentKind: .developPreset,
            processVersion: "15.4",
            mappedProperties: [.cameraRaw("Exposure2012")],
            diagnostics: [XMPDiagnostic(severity: .info, code: "unmapped-property", detail: "SomeFutureLightroomOnlyProperty2099")]
        )
        let document = makeDocument(
            name: "Imported",
            source: .adobeXMP(tool: "Lightroom", version: "15.4"),
            xmpEnvelope: envelope
        )
        let archive = PresetBackupArchive(createdAt: Date(timeIntervalSince1970: 0), documents: [document])

        let decoded = try PresetBackupCoding.decode(try PresetBackupCoding.encode(archive))

        XCTAssertEqual(decoded.documents.first?.xmpEnvelope?.originalPacketUTF8, unmappedPacket)
        XCTAssertEqual(decoded.documents.first?.xmpEnvelope, envelope)
    }

    // MARK: - Errors

    func testDecodingRejectsAFutureSchemaVersion() throws {
        struct FutureArchive: Encodable {
            let schemaVersion = PresetBackupArchive.currentSchemaVersion + 1
            let createdAt = Date(timeIntervalSince1970: 0)
            let documents: [PresetDocument] = []
        }
        let data = try PresetBackupCoding.makeEncoder().encode(FutureArchive())

        XCTAssertThrowsError(try PresetBackupCoding.decode(data)) { error in
            XCTAssertEqual(
                error as? PresetBackupError,
                .unsupportedSchemaVersion(found: PresetBackupArchive.currentSchemaVersion + 1, supported: PresetBackupArchive.currentSchemaVersion)
            )
        }
    }

    func testDecodingRejectsMalformedJSON() {
        let data = Data("not json at all".utf8)
        XCTAssertThrowsError(try PresetBackupCoding.decode(data))
    }

    func testReadingRejectsAnOversizedArchiveBeforeJSONDecoding() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaHarbor-\(UUID().uuidString).lhpresetbackup")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data(repeating: 0, count: PresetBackupArchive.maximumEncodedBytes + 1)
        try data.write(to: url)

        XCTAssertThrowsError(try PresetBackupCoding.read(from: url)) { error in
            XCTAssertEqual(
                error as? PresetError,
                .documentTooLarge(limitBytes: PresetBackupArchive.maximumEncodedBytes)
            )
        }
    }
}
