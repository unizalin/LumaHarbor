import Foundation
import RawProcessingCore

/// The exact migration state machine from
/// `docs/superpowers/plans/2026-09-10-curation-sidecar-v3-and-migration.md`
/// (gap G1). Pure and I/O-free by design: every branch here is fully
/// testable without a filesystem, and the one caller (`PhotoLibraryService`'s
/// scan hydration) is the only place that performs the actual sidecar write.
enum CurationMigrationDecision: Equatable {
    /// The sidecar is already schema v3 or newer; its own `curation` is
    /// authoritative regardless of what SQLite currently holds (spec §6.1
    /// rule 1). No write.
    case sidecarAuthoritative(PhotoCuration)
    /// Nothing worth migrating: either there is no sidecar and SQLite has no
    /// curation either, or the sidecar is legacy and SQLite's curation is
    /// already neutral. No write.
    case unchanged(PhotoCuration)
    /// SQLite holds non-neutral curation that a legacy or absent sidecar
    /// does not yet carry. The caller must attempt `repository.write(sidecar:)`;
    /// on failure it must keep the given `curation` values in memory without
    /// raising, so the next scan retries this exact decision from scratch.
    case migrate(sidecar: PhotoSidecar, curation: PhotoCuration)
}

enum CurationMigration {
    static func decide(
        existingSidecar: PhotoSidecar?,
        existingSQLiteCuration: PhotoCuration?,
        photoID: PhotoID,
        sourceRelativePath: String,
        sourceFingerprint: FileFingerprint,
        decoder: DecoderDescriptor,
        now: Date
    ) -> CurationMigrationDecision {
        if let sidecar = existingSidecar, sidecar.schemaVersion >= PhotoSidecar.currentSchemaVersion {
            return .sidecarAuthoritative(sidecar.curation)
        }

        let sqliteCuration = existingSQLiteCuration ?? .neutral
        guard !sqliteCuration.isNeutral else {
            return .unchanged(.neutral)
        }

        if let sidecar = existingSidecar {
            var migrated = sidecar
            migrated.schemaVersion = PhotoSidecar.currentSchemaVersion
            migrated.curation = sqliteCuration
            return .migrate(sidecar: migrated, curation: sqliteCuration)
        }

        let created = PhotoSidecar(
            photoID: photoID,
            sourceRelativePath: sourceRelativePath,
            sourceFingerprint: sourceFingerprint,
            decoder: decoder,
            adjustments: .neutral,
            curation: sqliteCuration,
            createdAt: now,
            modifiedAt: now
        )
        return .migrate(sidecar: created, curation: sqliteCuration)
    }
}
