import XCTest
@testable import PresetCore

final class XMPCodecTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "XMP")
        )
        return try Data(contentsOf: url)
    }

    // MARK: - Scalars, attributes and simple documents

    func testParsesAttributeFormScalarProperties() throws {
        let data = try fixture("subset-basic.xmp")
        let document = try XMPCodec().parse(data)
        XCTAssertEqual(document.property(namespaceURI: XMPNamespace.cameraRaw, localName: "Temperature"), .text("5500"))
        XCTAssertEqual(document.property(namespaceURI: XMPNamespace.cameraRaw, localName: "Exposure2012"), .text("+0.50"))
        XCTAssertEqual(document.property(namespaceURI: XMPNamespace.cameraRaw, localName: "ProcessVersion"), .text("15.4"))
    }

    func testParsesChildElementAltArrayWithLanguageQualifier() throws {
        let data = try fixture("subset-basic.xmp")
        let document = try XMPCodec().parse(data)
        guard case .array(let kind, let values)? = document.property(namespaceURI: XMPNamespace.cameraRaw, localName: "Name") else {
            return XCTFail("Expected crs:Name to parse as an array")
        }
        XCTAssertEqual(kind, .alt)
        guard case .qualified(let value, let qualifiers) = values.first else {
            return XCTFail("Expected the rdf:li to carry an xml:lang qualifier")
        }
        XCTAssertEqual(value, .text("LumaHarbor Fixture Subset"))
        XCTAssertEqual(qualifiers[XMPQualifier.lang], .text("x-default"))
    }

    // MARK: - Unknown namespace / nested structure round-trip

    func testUnknownNamespaceStructureSurvivesSemanticRoundTrip() throws {
        let input = try fixture("unknown-nested-rdf.xmp")
        let document = try XMPCodec().parse(input)
        let output = try XMPCodec().serialize(document)
        let reparsed = try XMPCodec().parse(output)
        XCTAssertTrue(XMPCodec().semanticallyEquivalent(document, reparsed))
        XCTAssertNotNil(reparsed.property(namespaceURI: "urn:test:future", localName: "MaskTree"))
    }

    func testUnknownNestedSeqOfStructuresRoundTrips() throws {
        let document = try XMPCodec().parse(try fixture("unknown-nested-rdf.xmp"))
        guard case .structure(let maskTree)? = document.property(namespaceURI: "urn:test:future", localName: "MaskTree") else {
            return XCTFail("Expected future:MaskTree to parse as a structure")
        }
        XCTAssertEqual(maskTree[XMPPropertyID(namespaceURI: "urn:test:future", localName: "kind")], .text("radial"))
        guard case .array(let kind, let layers)? = maskTree[XMPPropertyID(namespaceURI: "urn:test:future", localName: "Layers")] else {
            return XCTFail("Expected future:Layers to parse as an array")
        }
        XCTAssertEqual(kind, .seq)
        XCTAssertEqual(layers.count, 2)
        guard case .structure(let firstLayer)? = layers.first else {
            return XCTFail("Expected each rdf:li to hold a nested structure")
        }
        XCTAssertEqual(
            firstLayer[XMPPropertyID(namespaceURI: "urn:test:future", localName: "layerName")],
            .text("Layer 1")
        )
    }

    func testUnknownBagPreservesUnorderedMembership() throws {
        let document = try XMPCodec().parse(try fixture("unknown-nested-rdf.xmp"))
        guard case .array(let kind, let values)? = document.property(namespaceURI: "urn:test:future", localName: "Tags") else {
            return XCTFail("Expected future:Tags to parse as an array")
        }
        XCTAssertEqual(kind, .bag)
        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(values.contains(.text("portrait")))
        XCTAssertTrue(values.contains(.text("studio")))
    }

    // MARK: - Malformed input

    func testMalformedXMLThrows() throws {
        let data = try fixture("corrupt.xmp")
        XCTAssertThrowsError(try XMPCodec().parse(data)) {
            guard case .malformedXML = $0 as? PresetError else {
                return XCTFail("Expected .malformedXML, got \($0)")
            }
        }
    }

    // MARK: - Semantic comparator

    func testSemanticEquivalenceIgnoresPropertyOrderingAndPrefixChoice() throws {
        let a = XMPDocument(properties: [
            XMPPropertyID.cameraRaw("Exposure2012"): .text("0.5"),
            XMPPropertyID.cameraRaw("Contrast2012"): .text("10")
        ])
        let b = XMPDocument(properties: [
            XMPPropertyID.cameraRaw("Contrast2012"): .text("10"),
            XMPPropertyID.cameraRaw("Exposure2012"): .text("0.5")
        ])
        XCTAssertTrue(XMPCodec().semanticallyEquivalent(a, b))
    }

    func testSemanticEquivalenceDetectsDifferingArrayOrder() throws {
        let a = XMPDocument(properties: [
            XMPPropertyID.cameraRaw("ToneCurve"): .array(kind: .seq, values: [.text("0,0"), .text("255,255")])
        ])
        let b = XMPDocument(properties: [
            XMPPropertyID.cameraRaw("ToneCurve"): .array(kind: .seq, values: [.text("255,255"), .text("0,0")])
        ])
        XCTAssertFalse(XMPCodec().semanticallyEquivalent(a, b))
    }

    func testSemanticEquivalenceDetectsMissingProperty() throws {
        let a = XMPDocument(properties: [XMPPropertyID.cameraRaw("Exposure2012"): .text("0.5")])
        let b = XMPDocument(properties: [:])
        XCTAssertFalse(XMPCodec().semanticallyEquivalent(a, b))
    }

    // MARK: - Serialize / re-parse fidelity for every value shape

    func testSerializeThenParseRoundTripsEveryValueShape() throws {
        let original = XMPDocument(
            about: "",
            properties: [
                XMPPropertyID.cameraRaw("Exposure2012"): .text("0.5"),
                XMPPropertyID(namespaceURI: "urn:test:x", localName: "Bag"): .array(
                    kind: .bag, values: [.text("a"), .text("b")]
                ),
                XMPPropertyID(namespaceURI: "urn:test:x", localName: "Seq"): .array(
                    kind: .seq, values: [.text("1"), .text("2"), .text("3")]
                ),
                XMPPropertyID(namespaceURI: "urn:test:x", localName: "Struct"): .structure([
                    XMPPropertyID(namespaceURI: "urn:test:x", localName: "inner"): .text("value")
                ]),
                XMPPropertyID(namespaceURI: "urn:test:x", localName: "Qualified"): .qualified(
                    value: .text("hello \"world\" & <friends>"),
                    qualifiers: [XMPQualifier.lang: .text("en")]
                )
            ]
        )
        let data = try XMPCodec().serialize(original)
        let reparsed = try XMPCodec().parse(data)
        XCTAssertTrue(XMPCodec().semanticallyEquivalent(original, reparsed))
    }
}
