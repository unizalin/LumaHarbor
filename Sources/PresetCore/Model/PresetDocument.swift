import Foundation

/// Where a preset originated. Round-tripped through `.lhpreset` and used to
/// decide whether "export as .xmp" has an original packet to build on.
public enum PresetSource: Codable, Equatable, Sendable {
    case native
    case adobeXMP(tool: String?, version: String?)

    private enum CodingKeys: String, CodingKey { case native, adobeXMP }
    private enum AdobeXMPCodingKeys: String, CodingKey { case tool, version }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.native) {
            self = .native
        } else if container.contains(.adobeXMP) {
            let nested = try container.nestedContainer(keyedBy: AdobeXMPCodingKeys.self, forKey: .adobeXMP)
            self = .adobeXMP(
                tool: try nested.decodeIfPresent(String.self, forKey: .tool),
                version: try nested.decodeIfPresent(String.self, forKey: .version)
            )
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown PresetSource case")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .native:
            _ = container.nestedContainer(keyedBy: AdobeXMPCodingKeys.self, forKey: .native)
        case .adobeXMP(let tool, let version):
            var nested = container.nestedContainer(keyedBy: AdobeXMPCodingKeys.self, forKey: .adobeXMP)
            try nested.encodeIfPresent(tool, forKey: .tool)
            try nested.encodeIfPresent(version, forKey: .version)
        }
    }
}

/// LumaHarbor's native preset document (spec §5.1). File extension `.lhpreset`,
/// UTF-8 JSON. UUID is identity; `name` is display-only.
public struct PresetDocument: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1
    /// Display name after `.trimmingCharacters(in: .whitespacesAndNewlines)`
    /// may not exceed this many extended grapheme clusters.
    public static let maximumNameLength = 120
    /// `groupPath` may not exceed this many levels.
    public static let maximumGroupPathDepth = 8

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var groupPath: [String]
    public var isFavorite: Bool
    public var createdAt: Date
    public var modifiedAt: Date
    public var source: PresetSource
    public var patch: AdjustmentPatch
    public var xmpEnvelope: XMPEnvelope?

    public init(
        schemaVersion: Int = PresetDocument.currentSchemaVersion,
        id: UUID = UUID(),
        name: String,
        groupPath: [String] = [],
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        source: PresetSource = .native,
        patch: AdjustmentPatch,
        xmpEnvelope: XMPEnvelope? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.groupPath = groupPath
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.source = source
        self.patch = patch
        self.xmpEnvelope = xmpEnvelope
    }

    /// Trims name/group segments and rejects anything that violates the
    /// invariants a caller must not persist (spec §5.1, §8.2). Does not mutate
    /// `self` -- callers persist the returned, normalised copy.
    public func validated() throws -> PresetDocument {
        guard schemaVersion >= 1, schemaVersion <= Self.currentSchemaVersion else {
            throw PresetError.unsupportedSchemaVersion(found: schemaVersion, supported: Self.currentSchemaVersion)
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= Self.maximumNameLength else {
            throw PresetError.invalidName
        }

        guard groupPath.count <= Self.maximumGroupPathDepth else {
            throw PresetError.invalidGroupPath
        }
        var trimmedGroupPath: [String] = []
        trimmedGroupPath.reserveCapacity(groupPath.count)
        for segment in groupPath {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= Self.maximumNameLength else {
                throw PresetError.invalidGroupPath
            }
            trimmedGroupPath.append(trimmed)
        }

        var copy = self
        copy.name = trimmedName
        copy.groupPath = trimmedGroupPath
        return copy
    }
}
