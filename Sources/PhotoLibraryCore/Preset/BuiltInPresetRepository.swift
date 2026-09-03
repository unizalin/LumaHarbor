import Foundation
import PresetCore

/// A third, read-only `PresetRepository` scope, shipped with the app rather
/// than stored on disk (Phase 3 Task 3.1: "built-in vs user preset
/// precedence"). Distinct from `FilePresetRepository`'s two scopes, and
/// deliberately never file-backed, so it works identically whether or not
/// Application Support or the current library's volume is even available.
///
/// "Precedence" here means *coexistence*, not conflict: a built-in preset's
/// `id` is one of the fixed UUIDs below, guaranteed never to collide with a
/// freshly minted `UUID()` from `PresetDocument.init`'s own default, and
/// nothing in this scope can ever be renamed or deleted out from under a
/// user who built a workflow around its presence -- `save`/`delete` always
/// fail with `PresetError.builtInPresetIsReadOnly`, whose own recovery
/// suggestion is "duplicate it, then edit the copy"
/// (`PresetLibraryViewModel.copy(_:to:)` already handles that transfer;
/// this repository doesn't need its own copy logic).
public actor BuiltInPresetRepository: PresetRepository {
    private let documents: [PresetDocument]

    public init(documents: [PresetDocument] = BuiltInPresetRepository.defaultPresets) {
        self.documents = documents
    }

    public func list() async throws -> [PresetDocument] { documents }

    public func load(id: UUID) async throws -> PresetDocument? {
        documents.first { $0.id == id }
    }

    public func save(_ document: PresetDocument, conflict: PresetConflictResolution) async throws -> PresetStoreResult {
        throw PresetError.builtInPresetIsReadOnly
    }

    public func delete(id: UUID) async throws {
        throw PresetError.builtInPresetIsReadOnly
    }

    /// Two minimal, honestly-labeled *technical* presets that prove the
    /// built-in mechanism actually works end to end -- not a curated,
    /// creative preset library (a product/content decision explicitly out
    /// of scope for this foundation round; the user's own call, not an
    /// engineering one). Fixed UUIDs, not `UUID()`, so identity survives
    /// every app launch rather than being reminted -- a sidecar or another
    /// preset that referenced one of these by id must keep working.
    public static let defaultPresets: [PresetDocument] = [
        PresetDocument(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "High Contrast",
            groupPath: ["Built-In"],
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 0),
            patch: AdjustmentPatch(basic: BasicAdjustmentPatch(contrast: 30, saturation: 10))
        ),
        PresetDocument(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Flat (Low Contrast)",
            groupPath: ["Built-In"],
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 0),
            patch: AdjustmentPatch(basic: BasicAdjustmentPatch(contrast: -20))
        )
    ]
}
