import Foundation

/// Stable identity for one photo, minted the first time it is discovered and
/// never derived from the path.
///
/// Spec §8.1: the fingerprint exists for relinking and change detection, it does
/// *not* replace this UUID. A file that moves keeps its `PhotoID`, so the edits
/// stored under `<photo-id>.json` follow it.
public struct PhotoID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = uuid
    }

    public var description: String { rawValue.uuidString }

    /// Filename used inside `.lumaharbor/edits/`.
    public var sidecarFilename: String { "\(rawValue.uuidString).json" }

    // Encoded as a bare string so the sidecar matches the documented shape in
    // spec §8.2 rather than nesting `{"rawValue": ...}`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let uuid = UUID(uuidString: string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "\"\(string)\" is not a valid photo identifier."
            )
        }
        self.rawValue = uuid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString)
    }
}

/// Identity for one photo folder the user has added.
public struct LibraryID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = uuid
    }

    public var description: String { rawValue.uuidString }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let uuid = UUID(uuidString: string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "\"\(string)\" is not a valid library identifier."
            )
        }
        self.rawValue = uuid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString)
    }
}
