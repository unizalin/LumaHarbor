import Foundation

/// Identifies an XMP property by namespace URI and local name.
///
/// Spec §7: mapping keys must be namespace-aware, never a bare `crs:` prefix
/// (prefixes are declaration-local and not guaranteed stable across writers).
public struct XMPPropertyID: Hashable, Codable, Sendable {
    public var namespaceURI: String
    public var localName: String

    public init(namespaceURI: String, localName: String) {
        self.namespaceURI = namespaceURI
        self.localName = localName
    }
}

extension XMPPropertyID: CustomStringConvertible {
    public var description: String { "{\(namespaceURI)}\(localName)" }
}

extension XMPPropertyID {
    /// Convenience for building a `crs:` (Camera Raw settings) property ID
    /// without spelling the URI at every call site.
    public static func cameraRaw(_ localName: String) -> XMPPropertyID {
        XMPPropertyID(namespaceURI: XMPNamespace.cameraRaw, localName: localName)
    }
}

/// Well-known namespace URIs this codebase maps against.
public enum XMPNamespace {
    public static let cameraRaw = "http://ns.adobe.com/camera-raw-settings/1.0/"
    public static let xmpBasic = "http://ns.adobe.com/xap/1.0/"
    public static let dublinCore = "http://purl.org/dc/elements/1.1/"
    public static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    public static let tiff = "http://ns.adobe.com/tiff/1.0/"
    public static let exif = "http://ns.adobe.com/exif/1.0/"
}
