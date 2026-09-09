import Foundation
import Localization
import PhotoLibraryCore
import PresetCore
import RawProcessingCore

/// Which storage scope to browse in the Preset inspector.
enum PadPresetScope: String, CaseIterable, Identifiable {
    case all = "All"
    case builtIn = "Built-In"
    case myPresets = "My Presets"
    var id: String { rawValue }
}

/// Platform-neutral ObservableObject that loads presets from the built-in
/// catalogue and the user's "My Presets" FilePresetRepository, and exposes a
/// filtered view driven by search query and scope selection.
///
/// Owned once by PadAppServices. Never re-constructed inside a View body.
/// Errors from repositories are surfaced as an empty list, never as
/// absolute-path messages (spec §10 / §15 privacy rule).
@MainActor
final class PadPresetLibrary: ObservableObject {
    @Published private(set) var allPresets: [PresetDocument] = []
    @Published var searchQuery: String = ""
    @Published var scope: PadPresetScope = .all
    @Published var favoritesOnly = false
    @Published private(set) var isLoading = false
    @Published var message: String?

    let myPresetsRepository: FilePresetRepository
    private let builtInRepository: BuiltInPresetRepository

    init(
        builtInRepository: BuiltInPresetRepository,
        myPresetsRepository: FilePresetRepository
    ) {
        self.builtInRepository = builtInRepository
        self.myPresetsRepository = myPresetsRepository
    }

    /// Presets visible after applying scope filter and search query.
    var filteredPresets: [PresetDocument] {
        let builtInIDs = Set(BuiltInPresetRepository.defaultPresets.map(\.id))
        var result = allPresets
        switch scope {
        case .all:
            break
        case .builtIn:
            result = result.filter { builtInIDs.contains($0.id) }
        case .myPresets:
            result = result.filter { !builtInIDs.contains($0.id) }
        }
        if !searchQuery.isEmpty {
            let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty {
                result = result.filter { preset in
                    ([preset.name] + preset.groupPath).joined(separator: " ")
                        .range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
        }
        if favoritesOnly {
            result = result.filter(\.isFavorite)
        }
        return result
    }

    func isBuiltIn(_ preset: PresetDocument) -> Bool {
        let builtInIDs = Set(BuiltInPresetRepository.defaultPresets.map(\.id))
        return builtInIDs.contains(preset.id)
    }

    /// Loads both repositories. Safe to call repeatedly; skips if already loading.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        async let builtIn = (try? await builtInRepository.list()) ?? []
        async let user = (try? await myPresetsRepository.list()) ?? []
        let combined = await builtIn + user
        allPresets = combined.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        isLoading = false
    }

    // MARK: - Editing

    /// Creates a sparse preset from the current editor state. Geometry and
    /// local fields are opt-in at the UI layer; the repository only receives
    /// the selected patch and never touches the open photo.
    @discardableResult
    func createPreset(
        name: String,
        groupPath: [String],
        isFavorite: Bool,
        selectedFields: Set<AdjustmentFieldID>,
        from adjustments: PhotoAdjustments
    ) async -> Bool {
        let document = PresetDocument(
            name: name,
            groupPath: groupPath,
            isFavorite: isFavorite,
            patch: AdjustmentPatch.extracting(selectedFields, from: adjustments)
        )
        do {
            _ = try await myPresetsRepository.save(try document.validated(), conflict: .keepBoth)
            await load()
            return true
        } catch {
            message = L10n.t("Couldn't create this preset. Check the name and try again.")
            return false
        }
    }

    @discardableResult
    func updatePreset(
        _ preset: PresetDocument,
        name: String,
        groupPath: [String],
        isFavorite: Bool,
        keptFields: Set<AdjustmentFieldID>
    ) async -> Bool {
        guard !isBuiltIn(preset) else {
            message = L10n.t("Built-in presets are read-only.")
            return false
        }
        var updated = preset
        updated.name = name
        updated.groupPath = groupPath
        updated.isFavorite = isFavorite
        let presentFields = Set(AdjustmentFieldID.allCases.filter { preset.patch.contains($0) })
        updated.patch = updated.patch.excluding(presentFields.subtracting(keptFields))
        updated.modifiedAt = Date()
        do {
            _ = try await myPresetsRepository.save(try updated.validated(), conflict: .replace)
            await load()
            return true
        } catch {
            message = L10n.t("Couldn't update this preset. Try again.")
            return false
        }
    }

    func toggleFavorite(_ preset: PresetDocument) async {
        guard !isBuiltIn(preset) else {
            message = L10n.t("Built-in presets are read-only.")
            return
        }
        var updated = preset
        updated.isFavorite.toggle()
        updated.modifiedAt = Date()
        do {
            _ = try await myPresetsRepository.save(updated, conflict: .replace)
            await load()
        } catch {
            message = L10n.t("Couldn't update this favorite. Try again.")
        }
    }

    func delete(_ preset: PresetDocument) async {
        guard !isBuiltIn(preset) else {
            message = L10n.t("Built-in presets are read-only.")
            return
        }
        do {
            try await myPresetsRepository.delete(id: preset.id)
            await load()
        } catch {
            message = L10n.t("Couldn't delete this preset. Try again.")
        }
    }

    // MARK: - Files interchange

    func exportNative(_ preset: PresetDocument) throws -> Data {
        try SidecarCoding.encode(preset)
    }

    func exportXMP(_ preset: PresetDocument) throws -> Data {
        try XMPExporter().export(preset, context: .none).data
    }

    func exportBackup() async throws -> Data {
        let archive = PresetBackupArchive(documents: try await myPresetsRepository.list())
        return try PresetBackupCoding.encode(archive)
    }

    func restoreBackup(_ data: Data, conflict: PresetConflictResolution = .keepBoth) async {
        do {
            let archive = try PresetBackupCoding.decode(data)
            _ = await restorePresets(archive.documents, into: myPresetsRepository, conflict: conflict)
            await load()
        } catch {
            message = L10n.t("This backup could not be restored.")
        }
    }

    /// Imports one or more `.lhpreset` or Adobe `.xmp` files. Import always
    /// mints a new identity; backups are intentionally handled by
    /// `restoreBackup` so users never confuse the two flows.
    func importFiles(_ urls: [URL]) async {
        var imported = 0
        for url in urls {
            do {
                let data = try boundedData(from: url)
                let proposed: PresetDocument
                if url.pathExtension.caseInsensitiveCompare("lhpreset") == .orderedSame {
                    let decoded = try SidecarCoding.decode(PresetDocument.self, from: data)
                    proposed = PresetDocument(
                        name: decoded.name,
                        groupPath: decoded.groupPath,
                        isFavorite: decoded.isFavorite,
                        source: decoded.source,
                        patch: decoded.patch,
                        xmpEnvelope: decoded.xmpEnvelope
                    )
                } else if url.pathExtension.caseInsensitiveCompare("xmp") == .orderedSame {
                    proposed = try XMPImporter().preview(
                        data: data,
                        suggestedName: url.deletingPathExtension().lastPathComponent
                    ).proposedPreset
                } else {
                    continue
                }
                _ = try await myPresetsRepository.save(try proposed.validated(), conflict: .keepBoth)
                imported += 1
            } catch {
                continue
            }
        }
        await load()
        if imported == 0, !urls.isEmpty {
            message = L10n.t("No supported preset files were imported.")
        } else if imported > 0 {
            message = String(format: L10n.t("Imported %d presets."), imported)
        }
    }

    /// Reads a Files-picker URL while its security scope is held. The caller
    /// only receives bytes, so no scoped URL escapes the operation lifetime.
    func readData(from url: URL) -> Data? {
        try? boundedData(from: url)
    }

    private func boundedData(from url: URL) throws -> Data {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { url.stopAccessingSecurityScopedResource() }
        }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > PresetDocument.maximumEncodedBytes {
            throw PresetError.documentTooLarge(limitBytes: PresetDocument.maximumEncodedBytes)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= PresetDocument.maximumEncodedBytes else {
            throw PresetError.documentTooLarge(limitBytes: PresetDocument.maximumEncodedBytes)
        }
        return data
    }
}
