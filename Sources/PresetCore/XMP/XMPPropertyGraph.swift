import Foundation

/// Which RDF container an XMP array uses. Order matters for `Seq`, is
/// unordered for `Bag`, and `Alt` picks one alternative (commonly by
/// `xml:lang`) -- spec §6.1 requires the distinction to survive round-trips.
public enum XMPArrayKind: String, Codable, Equatable, Sendable {
    case bag
    case seq
    case alt
}

/// One RDF value in the parsed XMP graph. `indirect` because structures and
/// qualified values can nest arbitrarily (bounded at parse time by
/// `XMPCodec.Limits.maximumDepth`).
public indirect enum XMPValue: Equatable, Sendable {
    case text(String)
    case array(kind: XMPArrayKind, values: [XMPValue])
    case structure([XMPPropertyID: XMPValue])
    /// A value with RDF qualifiers attached -- in practice almost always
    /// `xml:lang` on a `rdf:Alt` alternative, but modelled generally so an
    /// unrecognised qualifier still round-trips (spec §6.1).
    case qualified(value: XMPValue, qualifiers: [XMPPropertyID: XMPValue])
}

/// The `xml:lang` qualifier's identity -- the one qualifier real-world XMP
/// (Lightroom/ACR) actually emits, on `dc:title`/`dc:description` Alt arrays.
public enum XMPQualifier {
    public static let xmlNamespace = "http://www.w3.org/XML/1998/namespace"
    public static let lang = XMPPropertyID(namespaceURI: xmlNamespace, localName: "lang")
}

/// The parsed form of one RDF/XML `rdf:Description` node: an optional
/// `rdf:about` subject and its properties, keyed by namespace-qualified ID.
///
/// Spec §6.1: this is the namespace-aware property graph a codec parses into
/// and serializes back out of -- `XMPEnvelope.originalPacketUTF8` remains the
/// literal round-trip source, this is what mapping/import/export code walks.
public struct XMPDocument: Equatable, Sendable {
    public var about: String?
    public var properties: [XMPPropertyID: XMPValue]

    public init(about: String? = nil, properties: [XMPPropertyID: XMPValue] = [:]) {
        self.about = about
        self.properties = properties
    }

    public func property(namespaceURI: String, localName: String) -> XMPValue? {
        properties[XMPPropertyID(namespaceURI: namespaceURI, localName: localName)]
    }
}
