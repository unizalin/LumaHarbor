import XCTest
@testable import PresetCore

final class AdobeRGBTableCodecTests: XCTestCase {
    func testRoundTripsSyntheticDeltaEncodedTable() throws {
        let table = try syntheticTable(gridSize: 2)
        let codec = AdobeRGBTableCodec()

        let encoded = try codec.encode(table)
        let decoded = try codec.decode(encoded)

        XCTAssertEqual(decoded, table)
        XCTAssertEqual(try codec.encode(decoded), encoded)
    }

    func testNeutralRampSamplesAsOneDimensionalIdentity() throws {
        let table = try AdobeRGBTable(
            gridSize: 2,
            samples: identitySamples(gridSize: 2)
        )

        let sample = try table.sample(red: 0.5, green: 0.5, blue: 0.5)

        for (actual, expected) in zip(sample, [0.5, 0.5, 0.5]) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }
    }

    func testThreeDimensionalSamplingUsesBFastestStorageOrder() throws {
        let table = try AdobeRGBTable(
            gridSize: 2,
            samples: [
                .init(red: 0, green: 0, blue: 0),
                .init(red: 0, green: 0, blue: 65_535),
                .init(red: 0, green: 65_535, blue: 0),
                .init(red: 0, green: 65_535, blue: 65_535),
                .init(red: 65_535, green: 0, blue: 0),
                .init(red: 65_535, green: 0, blue: 65_535),
                .init(red: 65_535, green: 65_535, blue: 0),
                .init(red: 65_535, green: 65_535, blue: 65_535)
            ]
        )

        let sample = try table.sample(red: 1, green: 0, blue: 1)

        XCTAssertEqual(sample, [1, 0, 1])
    }

    func testRejectsMalformedAlphabet() throws {
        let encoded = try AdobeRGBTableCodec().encode(syntheticTable(gridSize: 2))

        XCTAssertThrowsError(try AdobeRGBTableCodec().decode(encoded + "~")) { error in
            XCTAssertEqual(error as? AdobeRGBTableCodecError, .invalidBase85)
        }
    }

    func testRejectsTruncatedCompressedBytes() throws {
        let encoded = try AdobeRGBTableCodec().encode(syntheticTable(gridSize: 2))

        XCTAssertThrowsError(try AdobeRGBTableCodec().decode(String(encoded.dropLast(5)))) { error in
            XCTAssertEqual(error as? AdobeRGBTableCodecError, .invalidCompressedPayload)
        }
    }

    func testRejectsUncompressedPayloadAboveConfiguredLimit() throws {
        let encoded = try AdobeRGBTableCodec().encode(syntheticTable(gridSize: 2))
        let codec = AdobeRGBTableCodec(limits: .init(maxUncompressedBytes: 16))

        XCTAssertThrowsError(try codec.decode(encoded)) { error in
            XCTAssertEqual(error as? AdobeRGBTableCodecError, .decompressionLimitExceeded)
        }
    }

    func testRejectsMalformedDimensionsAndUnsupportedVersion() throws {
        let codec = AdobeRGBTableCodec()

        XCTAssertThrowsError(try codec.decodeUncompressedPayload(makeUncompressedPayload(version: 2, gridSize: 2))) { error in
            XCTAssertEqual(error as? AdobeRGBTableCodecError, .unsupportedVersion)
        }
        XCTAssertThrowsError(try codec.decodeUncompressedPayload(makeUncompressedPayload(version: 1, gridSize: 0))) { error in
            XCTAssertEqual(error as? AdobeRGBTableCodecError, .invalidDimensions)
        }
    }

    func testValidImportIsPreservedAndImportOnlyUntilStageOrderIsProven() throws {
        let capability = XMPCapabilityManifest.default.capability(for: .cameraRaw("RGBTable"))
        XCTAssertEqual(capability?.level, .preserved)
        XCTAssertEqual(capability?.direction, .importOnly)

        let table = try syntheticTable(gridSize: 2)
        let encoded = try AdobeRGBTableCodec().encode(table)
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">
          <rdf:RDF><rdf:Description rdf:about="" crs:ProcessVersion="11.0" crs:RGBTable="SYNTHETIC" crs:Table_SYNTHETIC="\(encoded)" /></rdf:RDF>
        </x:xmpmeta>
        """

        let preview = try XMPImporter().preview(data: Data(xml.utf8), suggestedName: "synthetic")

        XCTAssertTrue(preview.nativeFields.isEmpty)
        XCTAssertTrue(preview.approximateFields.isEmpty)
        XCTAssertTrue(preview.preservedProperties.contains(.cameraRaw("RGBTable")))
    }

    private func identitySamples(gridSize: Int) -> [AdobeRGBTable.Sample] {
        (0..<(gridSize * gridSize * gridSize)).map { index in
            let red = index / (gridSize * gridSize)
            let green = (index / gridSize) % gridSize
            let blue = index % gridSize
            return AdobeRGBTable.Sample(
                red: UInt16(red * 65_535 / max(gridSize - 1, 1)),
                green: UInt16(green * 65_535 / max(gridSize - 1, 1)),
                blue: UInt16(blue * 65_535 / max(gridSize - 1, 1))
            )
        }
    }

    private func syntheticTable(gridSize: Int) throws -> AdobeRGBTable {
        let samples = identitySamples(gridSize: gridSize).enumerated().map { index, sample in
            guard index == 7 else { return sample }
            return AdobeRGBTable.Sample(
                red: sample.red / 2,
                green: sample.green,
                blue: sample.blue
            )
        }
        return try AdobeRGBTable(gridSize: gridSize, samples: samples)
    }

    private func makeUncompressedPayload(version: UInt32, gridSize: UInt32) -> Data {
        var data = Data()
        appendLittleEndian(version, to: &data)
        appendLittleEndian(UInt32(1), to: &data)
        appendLittleEndian(UInt32(3), to: &data)
        appendLittleEndian(gridSize, to: &data)
        return data
    }

    private func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
