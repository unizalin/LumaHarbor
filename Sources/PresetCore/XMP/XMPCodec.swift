import Foundation

/// A bounded, namespace-aware RDF/XML (XMP) parser and serializer.
///
/// Spec §6.2: this is the security boundary for anything that reaches this
/// codebase as an untrusted `.xmp`/`.lhpreset` file. Every limit below is
/// checked *during* parsing (not after a full DOM builds), and `DOCTYPE` is
/// rejected by scanning the raw bytes before any XML parser ever sees them —
/// so no internal or external entity can be declared, let alone resolved,
/// regardless of how the underlying parser would otherwise behave.
public struct XMPCodec: Sendable {
    public enum Limits {
        public static let maximumDocumentBytes = 10 * 1024 * 1024
        public static let maximumDepth = 64
        public static let maximumPropertyCount = 20_000
        public static let maximumValueBytes = 1 * 1024 * 1024
    }

    public init() {}

    // MARK: - Parse

    public func parse(_ data: Data) throws -> XMPDocument {
        guard data.count <= Limits.maximumDocumentBytes else {
            throw PresetError.documentTooLarge(limitBytes: Limits.maximumDocumentBytes)
        }
        // Checked on raw bytes, before any XML parser -- including internal
        // subset entity declarations means DOCTYPE alone is enough to forbid
        // every entity-expansion attack, without relying on parser-specific
        // entity-resolution behaviour.
        if data.range(of: Data("<!DOCTYPE".utf8)) != nil {
            throw PresetError.unsafeXMLConstruct("DOCTYPE")
        }

        let delegate = BoundedXMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        if #available(macOS 12, *) {
            parser.externalEntityResolvingPolicy = .never
        }

        let succeeded = parser.parse()
        if let error = delegate.capturedError {
            throw error
        }
        guard succeeded, let root = delegate.root else {
            throw PresetError.malformedXML("invalid XML")
        }

        return try XMPTreeInterpreter().interpretDocument(root)
    }

    // MARK: - Serialize

    public func serialize(_ document: XMPDocument) throws -> Data {
        try XMPSerializer().serialize(document)
    }

    // MARK: - Comparison

    /// Structural equality of the parsed graph: array order matters (RDF
    /// `Seq`/list semantics), dictionary/property ordering does not (`==` on
    /// `[XMPPropertyID: XMPValue]` already ignores insertion order). This is
    /// deliberately never a byte comparison of serialized XML -- spec §6.1:
    /// whitespace, attribute order, quote style and namespace prefixes are
    /// not part of "lossless".
    public func semanticallyEquivalent(_ a: XMPDocument, _ b: XMPDocument) -> Bool {
        a == b
    }
}

// MARK: - Bounded SAX tree builder

/// One element as parsed, before RDF interpretation.
private final class RawXMLElement {
    let namespaceURI: String
    let localName: String
    /// Attribute order from the source is not preserved -- RDF property
    /// attributes have no order semantics, so this doesn't affect losslessness.
    var attributes: [(XMPPropertyID, String)] = []
    var children: [RawXMLElement] = []
    var text: String = ""

    init(namespaceURI: String, localName: String) {
        self.namespaceURI = namespaceURI
        self.localName = localName
    }
}

/// Builds a `RawXMLElement` tree from `XMLParser`'s SAX callbacks, enforcing
/// every size/depth/count/value-length limit incrementally so a hostile
/// document is rejected during parsing rather than after fully materializing.
private final class BoundedXMLTreeBuilder: NSObject, XMLParserDelegate {
    private(set) var root: RawXMLElement?
    private(set) var capturedError: PresetError?

    private var stack: [RawXMLElement] = []
    private var depth = 0
    private var propertyCount = 0
    /// `xml` is predefined by the XML spec itself and always in scope, even
    /// without an explicit declaration.
    private var prefixToURI: [String: String] = ["xml": XMPQualifier.xmlNamespace]
    private var prefixStack: [(prefix: String, previousURI: String?)] = []

    private static let structuralElements: Set<XMPPropertyID> = [
        XMPPropertyID(namespaceURI: "adobe:ns:meta/", localName: "xmpmeta"),
        XMPPropertyID(namespaceURI: XMPNamespace.rdf, localName: "RDF"),
        XMPPropertyID(namespaceURI: XMPNamespace.rdf, localName: "Description")
    ]

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        prefixStack.append((prefix, prefixToURI[prefix]))
        prefixToURI[prefix] = namespaceURI
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        guard let last = prefixStack.popLast() else { return }
        if let previous = last.previousURI {
            prefixToURI[last.prefix] = previous
        } else {
            prefixToURI.removeValue(forKey: last.prefix)
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard capturedError == nil else { return }

        depth += 1
        guard depth <= XMPCodec.Limits.maximumDepth else {
            fail(.documentTooDeep(limit: XMPCodec.Limits.maximumDepth), on: parser)
            return
        }

        let resolvedNamespace = namespaceURI ?? ""
        let node = RawXMLElement(namespaceURI: resolvedNamespace, localName: elementName)

        if !Self.structuralElements.contains(XMPPropertyID(namespaceURI: resolvedNamespace, localName: elementName)) {
            propertyCount += 1
            guard propertyCount <= XMPCodec.Limits.maximumPropertyCount else {
                fail(.tooManyProperties(limit: XMPCodec.Limits.maximumPropertyCount), on: parser)
                return
            }
        }

        for (rawKey, value) in attributeDict {
            if rawKey == "xmlns" || rawKey.hasPrefix("xmlns:") { continue }
            guard value.utf8.count <= XMPCodec.Limits.maximumValueBytes else {
                fail(.valueTooLarge(limitBytes: XMPCodec.Limits.maximumValueBytes), on: parser)
                return
            }
            let id: XMPPropertyID
            if let colonIndex = rawKey.firstIndex(of: ":") {
                let prefix = String(rawKey[rawKey.startIndex..<colonIndex])
                let localName = String(rawKey[rawKey.index(after: colonIndex)...])
                id = XMPPropertyID(namespaceURI: prefixToURI[prefix] ?? "", localName: localName)
            } else {
                id = XMPPropertyID(namespaceURI: "", localName: rawKey)
            }
            node.attributes.append((id, value))
        }

        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturedError == nil, let current = stack.last else { return }
        guard current.text.utf8.count + string.utf8.count <= XMPCodec.Limits.maximumValueBytes else {
            fail(.valueTooLarge(limitBytes: XMPCodec.Limits.maximumValueBytes), on: parser)
            return
        }
        current.text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard capturedError == nil else { return }
        depth -= 1
        guard let node = stack.popLast() else { return }
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        guard capturedError == nil else { return }
        // A fixed, safe message -- never the parser's own description, which
        // can echo fragments of the input (spec §6.2: no raw XMP in errors).
        capturedError = .malformedXML("invalid XML")
    }

    private func fail(_ error: PresetError, on parser: XMLParser) {
        capturedError = error
        parser.abortParsing()
    }
}

// MARK: - RDF interpretation

/// Turns the generic element tree into the namespace-aware `XMPValue` graph
/// (spec §6.1): scalars, `rdf:Bag`/`Seq`/`Alt` arrays, nested `rdf:Description`
/// structures, and `xml:lang`-qualified values.
private struct XMPTreeInterpreter {
    func interpretDocument(_ root: RawXMLElement) throws -> XMPDocument {
        guard let rdfElement = findRDFElement(root) else {
            throw PresetError.unsupportedDocumentKind("no rdf:RDF element")
        }
        var about: String?
        var properties: [XMPPropertyID: XMPValue] = [:]
        for description in rdfElement.children
        where description.namespaceURI == XMPNamespace.rdf && description.localName == "Description" {
            let (nodeAbout, nodeProperties) = interpretDescription(description)
            if about == nil { about = nodeAbout }
            for (key, value) in nodeProperties {
                properties[key] = value
            }
        }
        return XMPDocument(about: about, properties: properties)
    }

    private func findRDFElement(_ node: RawXMLElement) -> RawXMLElement? {
        if node.namespaceURI == XMPNamespace.rdf && node.localName == "RDF" { return node }
        for child in node.children {
            if let found = findRDFElement(child) { return found }
        }
        return nil
    }

    private func interpretDescription(_ node: RawXMLElement) -> (about: String?, properties: [XMPPropertyID: XMPValue]) {
        var about: String?
        var properties: [XMPPropertyID: XMPValue] = [:]
        for (id, value) in node.attributes {
            if id.namespaceURI == XMPNamespace.rdf, id.localName == "about" {
                about = value
                continue
            }
            properties[id] = .text(value)
        }
        for child in node.children {
            let id = XMPPropertyID(namespaceURI: child.namespaceURI, localName: child.localName)
            properties[id] = interpretPropertyElement(child)
        }
        return (about, properties)
    }

    /// Interprets one namespaced property element: its shape (scalar / array /
    /// structure) from its children, and any non-`xml:lang` attributes plus
    /// `xml:lang` itself as qualifiers on the result.
    private func interpretPropertyElement(_ node: RawXMLElement) -> XMPValue {
        let langValue = node.attributes.first { $0.0 == XMPQualifier.lang }?.1
        let otherAttributes = node.attributes.filter { $0.0 != XMPQualifier.lang }

        let base: XMPValue
        if node.children.count == 1, let only = node.children.first,
           only.namespaceURI == XMPNamespace.rdf, let kind = arrayKind(for: only.localName) {
            base = .array(kind: kind, values: only.children.map { interpretPropertyElement($0) })
        } else if node.children.count == 1, let only = node.children.first,
                  only.namespaceURI == XMPNamespace.rdf, only.localName == "Description" {
            base = .structure(interpretDescription(only).properties)
        } else if node.children.isEmpty {
            base = .text(node.text)
        } else {
            // Mixed content this codec doesn't specifically model -- fold every
            // child in as a structure field rather than dropping it, so an
            // unrecognised shape stays lossless even if not idiomatically
            // reinterpreted (spec §6.1/§7: unknown data is preserved, not lost).
            var fields: [XMPPropertyID: XMPValue] = [:]
            for child in node.children {
                fields[XMPPropertyID(namespaceURI: child.namespaceURI, localName: child.localName)] =
                    interpretPropertyElement(child)
            }
            base = .structure(fields)
        }

        var qualifiers: [XMPPropertyID: XMPValue] = [:]
        if let langValue { qualifiers[XMPQualifier.lang] = .text(langValue) }
        for (id, value) in otherAttributes {
            qualifiers[id] = .text(value)
        }
        guard !qualifiers.isEmpty else { return base }
        return .qualified(value: base, qualifiers: qualifiers)
    }

    private func arrayKind(for localName: String) -> XMPArrayKind? {
        switch localName {
        case "Bag": return .bag
        case "Seq": return .seq
        case "Alt": return .alt
        default: return nil
        }
    }
}

// MARK: - Serialization

/// Serializes an `XMPDocument` back to RDF/XML. Always emits properties as
/// child elements (never Adobe's attribute shorthand) -- the two forms are
/// RDF-equivalent by definition, and always choosing one keeps the serializer
/// simple without affecting semantic round-trips (spec §6.1: byte-for-byte
/// form isn't part of "lossless").
private struct XMPSerializer {
    private static let wellKnownPrefixes: [String: String] = [
        XMPNamespace.rdf: "rdf",
        "adobe:ns:meta/": "x",
        XMPNamespace.cameraRaw: "crs",
        XMPNamespace.xmpBasic: "xmp",
        XMPNamespace.dublinCore: "dc",
        XMPNamespace.tiff: "tiff",
        XMPNamespace.exif: "exif",
        XMPQualifier.xmlNamespace: "xml"
    ]

    func serialize(_ document: XMPDocument) throws -> Data {
        var namespaces = Set<String>([XMPNamespace.rdf, "adobe:ns:meta/"])
        collectNamespaces(from: document.properties, into: &namespaces)
        let prefixes = assignPrefixes(namespaces)

        var body = ""
        let aboutAttribute = " rdf:about=\"\(escapeAttribute(document.about ?? ""))\""
        body += "<rdf:Description\(aboutAttribute)>"
        for (id, value) in document.properties.sorted(by: Self.byID) {
            body += serializeProperty(id: id, value: value, prefixes: prefixes)
        }
        body += "</rdf:Description>"

        var declarations = ""
        for uri in namespaces.sorted() {
            declarations += " xmlns:\(prefixes[uri]!)=\"\(escapeAttribute(uri))\""
        }

        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">\
        <rdf:RDF\(declarations)>\(body)</rdf:RDF>\
        </x:xmpmeta>
        """
        guard let data = xml.data(using: .utf8) else {
            throw PresetError.malformedXML("could not encode as UTF-8")
        }
        return data
    }

    private static func byID(_ lhs: (XMPPropertyID, XMPValue), _ rhs: (XMPPropertyID, XMPValue)) -> Bool {
        (lhs.0.namespaceURI, lhs.0.localName) < (rhs.0.namespaceURI, rhs.0.localName)
    }

    private func collectNamespaces(from properties: [XMPPropertyID: XMPValue], into set: inout Set<String>) {
        for (id, value) in properties {
            set.insert(id.namespaceURI)
            collectNamespaces(from: value, into: &set)
        }
    }

    private func collectNamespaces(from value: XMPValue, into set: inout Set<String>) {
        switch value {
        case .text:
            return
        case .array(_, let values):
            for value in values { collectNamespaces(from: value, into: &set) }
        case .structure(let properties):
            collectNamespaces(from: properties, into: &set)
        case .qualified(let inner, let qualifiers):
            collectNamespaces(from: inner, into: &set)
            for (id, value) in qualifiers {
                set.insert(id.namespaceURI)
                collectNamespaces(from: value, into: &set)
            }
        }
    }

    private func assignPrefixes(_ namespaces: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        var used = Set<String>()
        var next = 0
        for uri in namespaces.sorted() {
            if let wellKnown = Self.wellKnownPrefixes[uri], !used.contains(wellKnown) {
                result[uri] = wellKnown
                used.insert(wellKnown)
            } else {
                var candidate = "ns\(next)"
                while used.contains(candidate) {
                    next += 1
                    candidate = "ns\(next)"
                }
                next += 1
                result[uri] = candidate
                used.insert(candidate)
            }
        }
        return result
    }

    private func serializeProperty(id: XMPPropertyID, value: XMPValue, prefixes: [String: String]) -> String {
        let prefix = prefixes[id.namespaceURI] ?? "ns"
        let tag = "\(prefix):\(id.localName)"

        switch value {
        case .text(let text):
            return "<\(tag)>\(escapeText(text))</\(tag)>"
        case .array(let kind, let values):
            let containerTag = "rdf:\(containerName(for: kind))"
            let items = values.map { serializeListItem($0, prefixes: prefixes) }.joined()
            return "<\(tag)><\(containerTag)>\(items)</\(containerTag)></\(tag)>"
        case .structure(let properties):
            let inner = properties.sorted(by: Self.byID)
                .map { serializeProperty(id: $0.0, value: $0.1, prefixes: prefixes) }
                .joined()
            return "<\(tag)><rdf:Description>\(inner)</rdf:Description></\(tag)>"
        case .qualified(let inner, let qualifiers):
            var attrs = ""
            var remainingQualifiers: [(XMPPropertyID, XMPValue)] = []
            for (qid, qvalue) in qualifiers.sorted(by: Self.byID) {
                if case .text(let qtext) = qvalue {
                    let qprefix = prefixes[qid.namespaceURI] ?? "ns"
                    attrs += " \(qprefix):\(qid.localName)=\"\(escapeAttribute(qtext))\""
                } else {
                    remainingQualifiers.append((qid, qvalue))
                }
            }
            return serializeQualifiedProperty(
                tag: tag, inner: inner, attrs: attrs, extraQualifiers: remainingQualifiers, prefixes: prefixes
            )
        }
    }

    private func serializeQualifiedProperty(
        tag: String,
        inner: XMPValue,
        attrs: String,
        extraQualifiers: [(XMPPropertyID, XMPValue)],
        prefixes: [String: String]
    ) -> String {
        switch inner {
        case .text(let text):
            return "<\(tag)\(attrs)>\(escapeText(text))</\(tag)>"
        default:
            // A non-text qualified value (rare) -- keep the qualifiers as
            // sibling struct fields alongside the value under `rdf:value`
            // rather than dropping them, so nothing is lost.
            var fields: [(XMPPropertyID, XMPValue)] = [(XMPPropertyID(namespaceURI: XMPNamespace.rdf, localName: "value"), inner)]
            fields.append(contentsOf: extraQualifiers)
            let innerXML = fields.sorted(by: Self.byID)
                .map { serializeProperty(id: $0.0, value: $0.1, prefixes: prefixes) }
                .joined()
            return "<\(tag)\(attrs)><rdf:Description>\(innerXML)</rdf:Description></\(tag)>"
        }
    }

    private func serializeListItem(_ value: XMPValue, prefixes: [String: String]) -> String {
        switch value {
        case .text(let text):
            return "<rdf:li>\(escapeText(text))</rdf:li>"
        case .array, .structure:
            return serializeProperty(
                id: XMPPropertyID(namespaceURI: XMPNamespace.rdf, localName: "li"), value: value, prefixes: prefixes
            )
        case .qualified(let inner, let qualifiers):
            var attrs = ""
            for (qid, qvalue) in qualifiers.sorted(by: Self.byID) {
                if case .text(let qtext) = qvalue {
                    let qprefix = prefixes[qid.namespaceURI] ?? "ns"
                    attrs += " \(qprefix):\(qid.localName)=\"\(escapeAttribute(qtext))\""
                }
            }
            if case .text(let text) = inner {
                return "<rdf:li\(attrs)>\(escapeText(text))</rdf:li>"
            }
            return serializeProperty(
                id: XMPPropertyID(namespaceURI: XMPNamespace.rdf, localName: "li"), value: inner, prefixes: prefixes
            )
        }
    }

    private func containerName(for kind: XMPArrayKind) -> String {
        switch kind {
        case .bag: return "Bag"
        case .seq: return "Seq"
        case .alt: return "Alt"
        }
    }

    private func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func escapeAttribute(_ text: String) -> String {
        escapeText(text).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
