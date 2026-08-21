import XCTest
@testable import PresetCore

final class XMPSecurityTests: XCTestCase {
    private func wrap(_ innerRDFDescriptionAttributes: String, children: String = "") -> Data {
        Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" \(innerRDFDescriptionAttributes)>\(children)</rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        """.utf8)
    }

    // MARK: - DOCTYPE / entity rejection

    func testRejectsDoctypeBeforeEntityResolution() {
        let xml = Data("<!DOCTYPE x [<!ENTITY e SYSTEM 'file:///etc/passwd'>]><x>&e;</x>".utf8)
        XCTAssertThrowsError(try XMPCodec().parse(xml)) {
            XCTAssertEqual($0 as? PresetError, .unsafeXMLConstruct("DOCTYPE"))
        }
    }

    func testRejectsDoctypeEvenWithoutAnEntityDeclaration() {
        let xml = Data("<!DOCTYPE x><x/>".utf8)
        XCTAssertThrowsError(try XMPCodec().parse(xml)) {
            XCTAssertEqual($0 as? PresetError, .unsafeXMLConstruct("DOCTYPE"))
        }
    }

    func testUndeclaredEntityReferenceFailsAsMalformedRatherThanExpanding() {
        // No DOCTYPE at all, so `&undeclared;` has no definition -- this must
        // fail to parse, not silently resolve to something.
        let xml = wrap("crs:Exposure2012=\"0.5\"", children: "<crs:Note>&undeclared;</crs:Note>")
        XCTAssertThrowsError(try XMPCodec().parse(xml)) {
            guard case .malformedXML = $0 as? PresetError else {
                return XCTFail("Expected .malformedXML, got \($0)")
            }
        }
    }

    // MARK: - Size / depth / count / value-length boundaries

    /// Each chunk stays under `maximumValueBytes` on its own; only the *sum*
    /// approaches `maximumDocumentBytes`, so this isolates the document-size
    /// check from the per-value one.
    private func manyChunks(count: Int, chunkSize: Int = 900_000) -> String {
        let chunk = String(repeating: "a", count: chunkSize)
        var children = ""
        for index in 0..<count {
            children += "<crs:Note\(index)>\(chunk)</crs:Note\(index)>"
        }
        return children
    }

    func testAcceptsDocumentAtTheSizeLimit() throws {
        let xml = wrap("crs:Exposure2012=\"0.5\"", children: manyChunks(count: 10))
        XCTAssertLessThanOrEqual(xml.count, XMPCodec.Limits.maximumDocumentBytes)
        XCTAssertNoThrow(try XMPCodec().parse(xml))
    }

    func testRejectsDocumentOverTheSizeLimit() {
        let xml = wrap("crs:Exposure2012=\"0.5\"", children: manyChunks(count: 12))
        XCTAssertGreaterThan(xml.count, XMPCodec.Limits.maximumDocumentBytes)
        XCTAssertThrowsError(try XMPCodec().parse(xml)) {
            XCTAssertEqual($0 as? PresetError, .documentTooLarge(limitBytes: XMPCodec.Limits.maximumDocumentBytes))
        }
    }

    func testRejectsDepthOverTheLimit() {
        var children = "<crs:Leaf>1</crs:Leaf>"
        // One extra level of nesting per iteration via a struct wrapper.
        for _ in 0..<(XMPCodec.Limits.maximumDepth + 4) {
            children = "<rdf:Description xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\">\(children)</rdf:Description>"
        }
        let xml = wrap("crs:Exposure2012=\"0.5\"", children: "<crs:Deep>\(children)</crs:Deep>")
        XCTAssertThrowsError(try XMPCodec().parse(xml)) {
            XCTAssertEqual($0 as? PresetError, .documentTooDeep(limit: XMPCodec.Limits.maximumDepth))
        }
    }

    func testAcceptsPropertyCountAtTheLimit() throws {
        var children = ""
        for index in 0..<XMPCodec.Limits.maximumPropertyCount {
            children += "<crs:P\(index)>v</crs:P\(index)>"
        }
        let xml = wrap("crs:Exposure2012=\"0.5\"", children: children)
        XCTAssertNoThrow(try XMPCodec().parse(xml))
    }

    func testRejectsPropertyCountOverTheLimit() {
        var children = ""
        for index in 0..<(XMPCodec.Limits.maximumPropertyCount + 500) {
            children += "<crs:P\(index)>v</crs:P\(index)>"
        }
        let xml = wrap("crs:Exposure2012=\"0.5\"", children: children)
        XCTAssertThrowsError(try XMPCodec().parse(xml)) {
            XCTAssertEqual($0 as? PresetError, .tooManyProperties(limit: XMPCodec.Limits.maximumPropertyCount))
        }
    }

    func testRejectsSingleValueOverTheLengthLimit() {
        let huge = String(repeating: "a", count: XMPCodec.Limits.maximumValueBytes + 1)
        let xml = wrap("crs:Exposure2012=\"0.5\"", children: "<crs:Note>\(huge)</crs:Note>")
        XCTAssertThrowsError(try XMPCodec().parse(xml)) {
            XCTAssertEqual($0 as? PresetError, .valueTooLarge(limitBytes: XMPCodec.Limits.maximumValueBytes))
        }
    }

    // MARK: - No local / network resource access

    func testDoesNotTouchTheFilesystemForAnUnresolvableSystemPath() {
        // Even without a DOCTYPE, confirm a bogus local reference embedded as
        // plain text is never treated as something to fetch.
        let marker = "/nonexistent/lumaharbor-xmp-security-marker-\(UUID().uuidString)"
        let xml = wrap("crs:Exposure2012=\"0.5\"", children: "<crs:Note>\(marker)</crs:Note>")
        XCTAssertNoThrow(try XMPCodec().parse(xml))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    // MARK: - Non-finite / malformed values must not crash

    func testNonNumericAndNonFiniteLookingTextValuesParseAsPlainText() throws {
        // Values a naive `Double(string:)` conversion downstream could choke
        // on -- the codec itself must treat them as opaque text and never
        // attempt numeric interpretation or crash on them.
        let xml = wrap(
            "crs:Exposure2012=\"NaN\"",
            children: "<crs:Weird>Infinity, -Infinity, 🎞️, not-a-number</crs:Weird>"
        )
        let document = try XMPCodec().parse(xml)
        XCTAssertEqual(document.property(namespaceURI: XMPNamespace.cameraRaw, localName: "Exposure2012"), .text("NaN"))
        XCTAssertEqual(
            document.property(namespaceURI: XMPNamespace.cameraRaw, localName: "Weird"),
            .text("Infinity, -Infinity, 🎞️, not-a-number")
        )
    }

    func testRawControlCharacterInTextIsRejectedRatherThanCrashing() {
        // A literal NUL is not valid XML 1.0 character data; the parser must
        // reject it cleanly, not crash or silently truncate.
        var bytes = Array(
            "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\"><crs:Note>"
                .utf8
        )
        bytes.append(0x00)
        bytes.append(contentsOf: Array("masked</crs:Note></rdf:Description></rdf:RDF></x:xmpmeta>".utf8))
        XCTAssertThrowsError(try XMPCodec().parse(Data(bytes)))
    }

    func testInvalidUTF8DoesNotCrashAndThrowsMalformed() {
        var bytes = Array("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\">".utf8)
        bytes.append(contentsOf: [0xFF, 0xFE, 0xFD])
        bytes.append(contentsOf: Array("</rdf:Description></rdf:RDF></x:xmpmeta>".utf8))
        let data = Data(bytes)
        XCTAssertThrowsError(try XMPCodec().parse(data))
    }
}
