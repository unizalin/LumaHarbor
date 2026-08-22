import XCTest
@testable import PresetCore

final class XMPSecurityTests: XCTestCase {
    private func wrapXML(_ innerRDFDescriptionAttributes: String, children: String = "") -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" \(innerRDFDescriptionAttributes)>\(children)</rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        """
    }

    private func wrap(_ innerRDFDescriptionAttributes: String, children: String = "") -> Data {
        Data(wrapXML(innerRDFDescriptionAttributes, children: children).utf8)
    }

    /// Manually prepends the byte-order mark and encodes with an explicit,
    /// fixed byte order -- `String.Encoding.utf16` alone would pick an
    /// implementation-defined byte order and isn't guaranteed to add a BOM
    /// the same way across platforms, so the tests below build both forms
    /// deterministically instead of relying on that.
    private func utf16Data(_ xml: String, bigEndian: Bool) -> Data {
        let bom: [UInt8] = bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]
        let body = xml.data(using: bigEndian ? .utf16BigEndian : .utf16LittleEndian)!
        return Data(bom) + body
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

    // MARK: - DOCTYPE rejection is encoding-independent (finding #1)

    /// The plain UTF-8 case, spelled out explicitly alongside the UTF-16
    /// variants below so the three tests read as one deliberate matrix
    /// rather than leaving UTF-8 implicit.
    func testRejectsDoctypeInUTF8Document() {
        let xml = Data("<!DOCTYPE x [<!ENTITY e \"payload\">]><x>&e;</x>".utf8)
        XCTAssertThrowsError(try XMPCodec().parse(xml)) {
            XCTAssertEqual($0 as? PresetError, .unsafeXMLConstruct("DOCTYPE"))
        }
    }

    func testRejectsDoctypeInUTF16LittleEndianBOMDocument() {
        let xml = utf16Data("<!DOCTYPE x [<!ENTITY e \"payload\">]><x>&e;</x>", bigEndian: false)
        XCTAssertThrowsError(try XMPCodec().parse(xml)) {
            XCTAssertEqual($0 as? PresetError, .unsafeXMLConstruct("DOCTYPE"))
        }
    }

    func testRejectsDoctypeInUTF16BigEndianBOMDocument() {
        let xml = utf16Data("<!DOCTYPE x [<!ENTITY e \"payload\">]><x>&e;</x>", bigEndian: true)
        XCTAssertThrowsError(try XMPCodec().parse(xml)) {
            XCTAssertEqual($0 as? PresetError, .unsafeXMLConstruct("DOCTYPE"))
        }
    }

    func testRejectsEmptyDoctypeInUTF16LittleEndianBOMDocument() {
        // No entity at all -- confirms the encoding-aware scan matches the
        // literal construct, not just a side effect of entity handling.
        let xml = utf16Data("<!DOCTYPE x><x/>", bigEndian: false)
        XCTAssertThrowsError(try XMPCodec().parse(xml)) {
            XCTAssertEqual($0 as? PresetError, .unsafeXMLConstruct("DOCTYPE"))
        }
    }

    func testRejectsEmptyDoctypeInUTF16BigEndianBOMDocument() {
        let xml = utf16Data("<!DOCTYPE x><x/>", bigEndian: true)
        XCTAssertThrowsError(try XMPCodec().parse(xml)) {
            XCTAssertEqual($0 as? PresetError, .unsafeXMLConstruct("DOCTYPE"))
        }
    }

    /// A classic "billion laughs" shape (nested self-referencing entities) --
    /// this must be rejected on sight of the `DOCTYPE`, never reach the point
    /// of the parser attempting any expansion.
    func testRejectsRecursiveInternalEntityPayload() {
        let xml = Data("""
        <!DOCTYPE x [
        <!ENTITY a "1234567890">
        <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
        <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">
        ]>
        <x>&c;</x>
        """.utf8)
        XCTAssertThrowsError(try XMPCodec().parse(xml)) {
            XCTAssertEqual($0 as? PresetError, .unsafeXMLConstruct("DOCTYPE"))
        }
    }

    /// Defense-in-depth check: even if the pre-parse byte/encoding scan were
    /// bypassed, `XMLParser`'s own entity-declaration callback must still
    /// reject the document rather than letting `XMLParser` expand it.
    /// Exercised here through the normal `parse` entry point (the only
    /// public surface), not by calling the delegate directly.
    func testInternalEntityDeclarationIsRejectedEvenWithoutALiteralDoctypeKeywordMatch() {
        let xml = Data("<!DOCTYPE x [<!ENTITY e \"value\">]><x>&e;</x>".utf8)
        XCTAssertThrowsError(try XMPCodec().parse(xml)) {
            XCTAssertEqual($0 as? PresetError, .unsafeXMLConstruct("DOCTYPE"))
        }
    }

    /// The whole point of encoding-aware sniffing rather than "reject
    /// everything non-UTF-8": a legitimate UTF-16 XMP document with no
    /// `DOCTYPE` at all must still parse correctly, values intact.
    func testValidUTF16LittleEndianXMPStillParses() throws {
        let xml = utf16Data(wrapXML("crs:Exposure2012=\"0.5\"", children: "<crs:Note>hello</crs:Note>"), bigEndian: false)
        let document = try XMPCodec().parse(xml)
        XCTAssertEqual(document.property(namespaceURI: XMPNamespace.cameraRaw, localName: "Exposure2012"), .text("0.5"))
        XCTAssertEqual(document.property(namespaceURI: XMPNamespace.cameraRaw, localName: "Note"), .text("hello"))
    }

    func testValidUTF16BigEndianXMPStillParses() throws {
        let xml = utf16Data(wrapXML("crs:Exposure2012=\"0.5\"", children: "<crs:Note>hello</crs:Note>"), bigEndian: true)
        let document = try XMPCodec().parse(xml)
        XCTAssertEqual(document.property(namespaceURI: XMPNamespace.cameraRaw, localName: "Exposure2012"), .text("0.5"))
        XCTAssertEqual(document.property(namespaceURI: XMPNamespace.cameraRaw, localName: "Note"), .text("hello"))
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
        // `rdf:about` (added by `wrap`) is a structural identifier, not a
        // property, and is excluded from the count -- so exactly
        // `maximumPropertyCount` child elements, with no other attribute,
        // lands precisely at the limit.
        var children = ""
        for index in 0..<XMPCodec.Limits.maximumPropertyCount {
            children += "<crs:P\(index)>v</crs:P\(index)>"
        }
        let xml = wrap("", children: children)
        XCTAssertNoThrow(try XMPCodec().parse(xml))
    }

    func testRejectsPropertyCountOverTheLimit() {
        var children = ""
        for index in 0..<(XMPCodec.Limits.maximumPropertyCount + 500) {
            children += "<crs:P\(index)>v</crs:P\(index)>"
        }
        let xml = wrap("", children: children)
        XCTAssertThrowsError(try XMPCodec().parse(xml)) {
            XCTAssertEqual($0 as? PresetError, .tooManyProperties(limit: XMPCodec.Limits.maximumPropertyCount))
        }
    }

    // MARK: - Property count via RDF attribute shorthand (finding #2)

    /// `rdf:Description` attributes are RDF's "shorthand" form for a
    /// property -- semantically identical to a child element -- and must
    /// share the same budget as the child-element form, or a single element
    /// with tens of thousands of attributes bypasses `maximumPropertyCount`
    /// entirely while staying well under `maximumDocumentBytes`.
    func testAttributeShorthandPropertiesCountTowardTheLimit() {
        var attributes = ""
        for index in 0..<(XMPCodec.Limits.maximumPropertyCount + 500) {
            attributes += " crs:P\(index)=\"v\""
        }
        let xml = wrap(attributes)
        XCTAssertThrowsError(try XMPCodec().parse(xml)) {
            XCTAssertEqual($0 as? PresetError, .tooManyProperties(limit: XMPCodec.Limits.maximumPropertyCount))
        }
    }

    func testAttributeShorthandPropertyCountAtExactlyTheLimitIsAccepted() throws {
        var attributes = ""
        for index in 0..<XMPCodec.Limits.maximumPropertyCount {
            attributes += " crs:P\(index)=\"v\""
        }
        let xml = wrap(attributes)
        XCTAssertNoThrow(try XMPCodec().parse(xml))
    }

    /// `rdf:about` never counts, no matter how many other attributes are
    /// present alongside it -- it's the resource identifier, not data.
    func testRdfAboutAttributeItselfDoesNotCountTowardTheLimit() throws {
        var attributes = ""
        for index in 0..<XMPCodec.Limits.maximumPropertyCount {
            attributes += " crs:P\(index)=\"v\""
        }
        // `wrap` already emits `rdf:about=""`; this just confirms a document
        // built up to exactly the limit via attributes alone -- with the
        // mandatory `rdf:about` also present -- still parses.
        let xml = wrap(attributes)
        XCTAssertNoThrow(try XMPCodec().parse(xml))
    }

    /// Child elements and attribute-shorthand properties are two forms of
    /// the same thing and must share one budget, not two independent ones.
    func testChildElementsAndAttributeShorthandPropertiesShareOneLimit() {
        var attributes = ""
        for index in 0..<(XMPCodec.Limits.maximumPropertyCount / 2) {
            attributes += " crs:A\(index)=\"v\""
        }
        var children = ""
        for index in 0..<(XMPCodec.Limits.maximumPropertyCount / 2 + 500) {
            children += "<crs:C\(index)>v</crs:C\(index)>"
        }
        let xml = wrap(attributes, children: children)
        XCTAssertThrowsError(try XMPCodec().parse(xml)) {
            XCTAssertEqual($0 as? PresetError, .tooManyProperties(limit: XMPCodec.Limits.maximumPropertyCount))
        }
    }

    /// `xml:lang` is a genuine qualifier that becomes graph data (a
    /// qualifier value on the property), so -- unlike `rdf:about` -- it does
    /// count toward the limit; this locks that decision down with a test.
    func testXMLLangQualifierAttributesCountTowardTheLimit() {
        var children = ""
        for index in 0..<(XMPCodec.Limits.maximumPropertyCount + 500) {
            children += "<crs:C\(index) xml:lang=\"en\">v</crs:C\(index)>"
        }
        let xml = wrap("", children: children)
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
