import Foundation

/// Which kind of Adobe document an XMP packet parsed as.
public enum XMPDocumentKind: String, Codable, Equatable, Sendable {
    /// A standalone Camera Raw / Lightroom develop preset (`.xmp` exported
    /// from the Develop Presets panel).
    case developPreset
    /// A photo-adjacent sidecar (`crs:` settings alongside `photoshop:`,
    /// `exif:`, etc.) -- Phase 2's input shape, parsed the same way.
    case photoSidecar
    /// Recognisable as RDF/XMP but not a shape this build assigns meaning to.
    case unknown
}

/// Severity of one parse/mapping/application diagnostic. Shared by XMP-parse
/// diagnostics and by `PresetApplicator`'s white-balance diagnostics so both
/// layers report through one vocabulary.
public enum PresetDiagnosticSeverity: String, Codable, Equatable, Sendable {
    case info
    case warning
    case error
}

/// One thing worth telling the user about while importing or exporting XMP:
/// an unknown process version, a value that had to be clamped, a property
/// with no reverse mapping, etc. (spec §7, §9.3).
public struct XMPDiagnostic: Codable, Equatable, Sendable {
    public var severity: PresetDiagnosticSeverity
    /// Stable, non-localized identifier for tests and telemetry -- never the
    /// user-facing string itself (spec §6.2: debug data must stay safe to log).
    public var code: String
    /// The property this diagnostic is about, if any.
    public var propertyID: XMPPropertyID?
    /// Extra detail safe to log: property local names, numeric values -- never
    /// full XMP content or absolute file paths (spec §6.2).
    public var detail: String?

    public init(
        severity: PresetDiagnosticSeverity,
        code: String,
        propertyID: XMPPropertyID? = nil,
        detail: String? = nil
    ) {
        self.severity = severity
        self.code = code
        self.propertyID = propertyID
        self.detail = detail
    }
}

/// The parsed, retained form of one XMP packet (spec §6.1).
///
/// `originalPacketUTF8` is the round-trip and future-upgrade source of truth;
/// `mappedProperties` and `diagnostics` describe what this build did with it,
/// not what the packet itself contains -- that lives in the property graph
/// built alongside this envelope by `XMPCodec`/`XMPImporter`.
public struct XMPEnvelope: Codable, Equatable, Sendable {
    public var originalPacketUTF8: String
    public var documentKind: XMPDocumentKind
    public var processVersion: String?
    public var mappedProperties: Set<XMPPropertyID>
    public var diagnostics: [XMPDiagnostic]

    public init(
        originalPacketUTF8: String,
        documentKind: XMPDocumentKind,
        processVersion: String? = nil,
        mappedProperties: Set<XMPPropertyID> = [],
        diagnostics: [XMPDiagnostic] = []
    ) {
        self.originalPacketUTF8 = originalPacketUTF8
        self.documentKind = documentKind
        self.processVersion = processVersion
        self.mappedProperties = mappedProperties
        self.diagnostics = diagnostics
    }
}
