import Foundation
import Localization

/// A portable bundle of every preset in one scope (Phase 3 Task 3.2: "Preset
/// backup/restore"). Distinct from `.lhpreset` (one preset, `SidecarCoding`
/// in `PhotoLibraryCore`) and `.xmp` (one Adobe-compatible preset,
/// `XMPExporter`) -- this is the whole-scope archive a user backs up and
/// later restores from, possibly on a different Mac. `documents` round-trips
/// every `PresetDocument` field verbatim, `xmpEnvelope` included, so an
/// Adobe-imported preset's original packet (and anything in it this build
/// doesn't map) survives a backup/restore cycle unchanged.
public struct PresetBackupArchive: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var createdAt: Date
    public var documents: [PresetDocument]

    public init(
        schemaVersion: Int = PresetBackupArchive.currentSchemaVersion,
        createdAt: Date = Date(),
        documents: [PresetDocument]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.documents = documents
    }
}

/// Errors specific to reading a `PresetBackupArchive` file -- distinct from
/// `PresetError` since these are about the *archive container*, not an
/// individual preset's own content (an individual document's own validation
/// still runs later, when each one is actually restored via `save`).
public enum PresetBackupError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case malformedJSON(String)
}

extension PresetBackupError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let found, let supported):
            return "\(L10n.t("This backup was saved by a newer version of LumaHarbor")) (format \(found); this version reads up to \(supported))."
        case .malformedJSON:
            return L10n.t("This backup file couldn't be read; its JSON is malformed.")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unsupportedSchemaVersion:
            return L10n.t("Update LumaHarbor, or restore this backup on the device that made it.")
        case .malformedJSON:
            return L10n.t("Nothing was restored. Choose a different file, then try again.")
        }
    }
}

/// The JSON dialect for `.lhpresetbackup` files. A small, deliberate
/// duplication of `PhotoLibraryCore.SidecarCoding`'s own conventions
/// (sorted keys, pretty-printed, ISO 8601 dates) rather than a dependency on
/// it -- `PresetCore` does not and should not depend on `PhotoLibraryCore`
/// (see `Package.swift`: the dependency runs the other way).
public enum PresetBackupCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ archive: PresetBackupArchive) throws -> Data {
        try makeEncoder().encode(archive)
    }

    public static func decode(_ data: Data) throws -> PresetBackupArchive {
        let archive: PresetBackupArchive
        do {
            archive = try makeDecoder().decode(PresetBackupArchive.self, from: data)
        } catch let error as PresetBackupError {
            throw error
        } catch {
            throw PresetBackupError.malformedJSON(String(describing: type(of: error)))
        }
        guard archive.schemaVersion <= PresetBackupArchive.currentSchemaVersion else {
            throw PresetBackupError.unsupportedSchemaVersion(
                found: archive.schemaVersion,
                supported: PresetBackupArchive.currentSchemaVersion
            )
        }
        return archive
    }
}
