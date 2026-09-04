import Foundation
import Localization
import PhotoLibraryCore
import PresetCore
import RawProcessingCore

/// Which of the two storage scopes a preset belongs to, or should be saved
/// into (spec §5.1: "我的 Preset" and "此照片庫的 Preset"). Distinct from
/// `PresetScope` (`PhotoLibraryCore`), which additionally carries the real
/// URL a repository reads and writes -- this is just the UI-facing tag used
/// to pick which already-constructed repository to call.
enum PresetScopeKind: Hashable, CaseIterable {
    case mine
    case library
    /// Shipped with the app, read-only (Phase 3 Task 3.1). Never a valid
    /// `save`/`delete` destination -- `BuiltInPresetRepository` always
    /// throws `PresetError.builtInPresetIsReadOnly` for both.
    case builtIn

    var title: String {
        switch self {
        case .mine: return L10n.t("My Presets")
        case .library: return L10n.t("This Library")
        case .builtIn: return L10n.t("Built-In")
        }
    }
}

/// One preset plus which scope it came from.
struct PresetListItem: Identifiable, Equatable {
    var document: PresetDocument
    var scope: PresetScopeKind
    var id: UUID { document.id }
}

/// One `.xmp` file queued for import, from preview through confirmation
/// (spec §9.3: preview first, nothing written until the user confirms).
struct PresetImportItem: Identifiable, Equatable {
    let id = UUID()
    var sourceURL: URL
    var preview: XMPImportPreview
    /// Approximate fields the user has unchecked for this file. Preserved
    /// fields are never in this set -- they never participate in the patch
    /// at all, so there's nothing to uncheck (spec §7).
    var deselectedApproximateFields: Set<AdjustmentFieldID> = []
}

/// Drives the Preset browser, creation sheet, and XMP import/export workflow
/// (spec §9). Talks only to `PresetRepository`/`XMPImporter`/`XMPExporter` --
/// never touches XML or the filesystem directly.
@MainActor
final class PresetLibraryViewModel: ObservableObject {
    enum ScopeFilter: Hashable, CaseIterable {
        case all
        case scope(PresetScopeKind)
        case favorites

        static var allCases: [ScopeFilter] { [.all, .scope(.mine), .scope(.library), .scope(.builtIn), .favorites] }

        var title: String {
            switch self {
            case .all: return L10n.t("All")
            case .scope(let kind): return kind.title
            case .favorites: return L10n.t("Favorites")
            }
        }
    }

    /// The import workflow's state machine (plan Task 7 step 3): every async
    /// completion updates published state exactly once, and a stale result
    /// (a second import started before the first's preview returned) is
    /// dropped rather than clobbering newer state.
    enum ImportState: Equatable {
        case idle
        case loading
        case preview
        case saving
        case partialResult(succeeded: Int, failed: Int)
        case failed(String)
    }

    @Published private(set) var items: [PresetListItem] = []
    @Published var searchText = ""
    @Published var scopeFilter: ScopeFilter = .all
    @Published private(set) var importState: ImportState = .idle
    @Published private(set) var importItems: [PresetImportItem] = []
    /// Set by rename/delete/copy/create/toggleFavorite on failure. Bound to
    /// `.alert(item:)` on `PresetBrowserView` (the stable container all of
    /// those actions run from) and, separately, on `CreatePresetSheet`
    /// itself -- a sheet showing over `PresetBrowserView` needs its own
    /// binding to the same property to actually present while it's up
    /// (round 2, finding #4: this property existed and was set correctly,
    /// but no View read it at all, so every one of those failures was
    /// invisible).
    @Published var alert: UserAlert?

    /// Optional, like `EditorViewModel.services`: this view model is
    /// constructed once, up front, before `AppServices` exists, and attached
    /// once startup provides them (see `LibraryViewModel.install(services:)`).
    private var myRepository: (any PresetRepository)?
    /// Rebuilt whenever the selected library changes -- rooted at that
    /// library's own `.lumaharbor/presets/`, so switching libraries switches
    /// which "this library" scope means (spec §8.1).
    private var libraryRepository: (any PresetRepository)?
    /// Never optional, unlike the two above: built-in presets don't depend
    /// on Application Support or a library being available, so there is
    /// nothing to `attach()` later (Phase 3 Task 3.1).
    private let builtInRepository: any PresetRepository
    private let importer: XMPImporter
    private let exporter: XMPExporter
    private var operationID = 0

    init(
        myRepository: (any PresetRepository)? = nil,
        libraryRepository: (any PresetRepository)? = nil,
        builtInRepository: any PresetRepository = BuiltInPresetRepository(),
        importer: XMPImporter = XMPImporter(),
        exporter: XMPExporter = XMPExporter()
    ) {
        self.myRepository = myRepository
        self.libraryRepository = libraryRepository
        self.builtInRepository = builtInRepository
        self.importer = importer
        self.exporter = exporter
    }

    func attach(myRepository: any PresetRepository) {
        guard self.myRepository == nil else { return }
        self.myRepository = myRepository
        Task { await load() }
    }

    /// Called on every library selection change, including to `nil` when no
    /// library is open.
    func updateLibraryRepository(_ repository: (any PresetRepository)?) {
        libraryRepository = repository
        Task { await load() }
    }

    /// Whether "This Library" is even an option right now -- `nil` when no
    /// library is open, or when the one that's open hasn't set up a
    /// `libraryRepository` (spec §8.1: library presets require an open,
    /// known library root).
    var hasLibraryScope: Bool { libraryRepository != nil }

    var filteredItems: [PresetListItem] {
        items
            .filter { item in
                switch scopeFilter {
                case .all: break
                case .scope(let kind): guard item.scope == kind else { return false }
                case .favorites: guard item.document.isFavorite else { return false }
                }
                guard !searchText.isEmpty else { return true }
                let haystack = ([item.document.name] + item.document.groupPath).joined(separator: " ")
                return haystack.range(of: searchText, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            .sorted { $0.document.name.localizedStandardCompare($1.document.name) == .orderedAscending }
    }

    // MARK: - Loading

    func load() async {
        operationID += 1
        let current = operationID
        var loaded: [PresetListItem] = []
        if let builtIn = try? await builtInRepository.list() {
            loaded += builtIn.map { PresetListItem(document: $0, scope: .builtIn) }
        }
        if let myRepository, let mine = try? await myRepository.list() {
            loaded += mine.map { PresetListItem(document: $0, scope: .mine) }
        }
        if let libraryRepository, let library = try? await libraryRepository.list() {
            loaded += library.map { PresetListItem(document: $0, scope: .library) }
        }
        guard current == operationID else { return } // a newer load() already landed
        items = loaded
    }

    private func repository(for kind: PresetScopeKind) -> (any PresetRepository)? {
        switch kind {
        case .mine: return myRepository
        case .library: return libraryRepository
        case .builtIn: return builtInRepository
        }
    }

    // MARK: - Create

    /// Spec §9.2: create only writes the preset; it never touches the
    /// photo's own adjustments or Undo history.
    /// Returns whether the preset was actually saved. `CreatePresetSheet`
    /// used to call `dismiss()` unconditionally right after awaiting this,
    /// regardless of outcome -- so a failure set `alert` (which nothing
    /// read either -- see the type-level doc comment on `alert`) and then
    /// the sheet closed anyway, hiding the one place that error could still
    /// have been shown before this fix (round 2, finding #4). The caller is
    /// now expected to keep the sheet open on `false` so its own `.alert`
    /// binding to this same `alert` property can actually present.
    @discardableResult
    func createPreset(
        name: String,
        groupPath: [String],
        isFavorite: Bool,
        scope: PresetScopeKind,
        selectedFields: Set<AdjustmentFieldID>,
        from adjustments: PhotoAdjustments
    ) async -> Bool {
        guard let destination = repository(for: scope) else {
            // Never a silent no-op: the UI must not be able to leave
            // `scope` pointing at a destination that doesn't exist (see
            // `CreatePresetSheet`), but this is the second, ViewModel-level
            // line of defense in case it ever does.
            alert = UserAlert(
                title: L10n.t("Couldn't create this preset"),
                message: L10n.t("That destination isn't available right now.")
            )
            return false
        }
        let document = PresetDocument(
            name: name,
            groupPath: groupPath,
            isFavorite: isFavorite,
            patch: AdjustmentPatch.extracting(selectedFields, from: adjustments)
        )
        do {
            let validated = try document.validated()
            _ = try await destination.save(validated, conflict: .keepBoth)
            await load()
            return true
        } catch {
            alert = UserAlert(title: L10n.t("Couldn't create this preset"), error: error)
            return false
        }
    }

    /// Edits an already-saved preset in place: same identity, same scope,
    /// same `createdAt` (spec-consistent with `rename`'s own "檔名不是身份"
    /// rule, extended to the whole document). `keptFields` is a subset of
    /// whatever fields the preset's own patch already has -- unlike
    /// `createPreset`, this never *adds* a field that wasn't already
    /// present, since there's no photo open to source a new field's value
    /// from. Any currently-present field left out of `keptFields` is
    /// dropped via `AdjustmentPatch.excluding(_:)`, the same sparse-removal
    /// primitive the XMP import flow already uses for deselected
    /// approximate fields (Phase 3 Task 3.1: "sparse patch edit/removal
    /// when value returns to inherited/default" -- a field absent from the
    /// patch is exactly that "returns to inherited/default" state).
    @discardableResult
    func updatePreset(
        _ item: PresetListItem,
        name: String,
        groupPath: [String],
        isFavorite: Bool,
        keptFields: Set<AdjustmentFieldID>
    ) async -> Bool {
        guard let repository = repository(for: item.scope) else {
            alert = UserAlert(
                title: L10n.t("Couldn't update this preset"),
                message: L10n.t("That destination isn't available right now.")
            )
            return false
        }
        var updated = item.document
        updated.name = name
        updated.groupPath = groupPath
        updated.isFavorite = isFavorite
        let presentFields = Set(AdjustmentFieldID.allCases.filter { item.document.patch.contains($0) })
        updated.patch = updated.patch.excluding(presentFields.subtracting(keptFields))
        updated.modifiedAt = Date()
        do {
            let validated = try updated.validated()
            _ = try await repository.save(validated, conflict: .replace)
            await load()
            return true
        } catch {
            alert = UserAlert(title: L10n.t("Couldn't update this preset"), error: error)
            return false
        }
    }

    // MARK: - Favorite / delete

    func toggleFavorite(_ item: PresetListItem) async {
        guard let repository = repository(for: item.scope) else { return }
        var updated = item.document
        updated.isFavorite.toggle()
        updated.modifiedAt = Date()
        do {
            _ = try await repository.save(updated, conflict: .replace)
            await load()
        } catch {
            // Consistent with rename/delete/copy/createPreset below -- a
            // failed save must never be silently swallowed just because it
            // was triggered from a single-click star rather than a form.
            alert = UserAlert(title: L10n.t("Couldn't update this favorite"), error: error)
        }
    }

    /// Renames in place: same UUID, same scope, same file -- identity never
    /// moves just because the display name changed (spec §8.2: "檔名不是身份").
    func rename(_ item: PresetListItem, to newName: String) async {
        guard let repository = repository(for: item.scope) else { return }
        var updated = item.document
        updated.name = newName
        updated.modifiedAt = Date()
        do {
            let validated = try updated.validated()
            _ = try await repository.save(validated, conflict: .replace)
            await load()
        } catch {
            alert = UserAlert(title: L10n.t("Couldn't rename this preset"), error: error)
        }
    }

    func delete(_ item: PresetListItem) async {
        guard let repository = repository(for: item.scope) else { return }
        do {
            try await repository.delete(id: item.document.id)
            await load()
        } catch {
            alert = UserAlert(title: L10n.t("Couldn't delete this preset"), error: error)
        }
    }

    /// Copies (not moves) a preset into the other scope -- distinct from the
    /// repository layer's `transferPreset`, which deletes the source (spec
    /// §2: "並可互相複製").
    func copy(_ item: PresetListItem, to scope: PresetScopeKind) async {
        guard let destination = repository(for: scope) else {
            alert = UserAlert(
                title: L10n.t("Couldn't copy this preset"),
                message: L10n.t("That destination isn't available right now.")
            )
            return
        }
        var document = item.document
        if item.scope == .builtIn {
            // Independent-review finding: BuiltInPresetRepository's
            // documents carry fixed UUIDs that are never file-backed
            // anywhere. Forwarding one verbatim into a real, file-backed
            // scope would give the still-present `.builtIn` row and the
            // newly-copied `.mine`/`.library` row the same
            // `PresetListItem.id` (unqualified by scope) -- permanently, on
            // disk, since the destination has never seen that UUID and so
            // never even consults `conflict`. A copy out of `.builtIn`
            // always mints a fresh identity, the same way `.xmp`/`.lhpreset`
            // import already does for the same underlying reason. This must
            // NOT apply to a copy between `.mine` and `.library` -- both are
            // real, file-backed scopes, and `presetDocumentsAreCanonicallyEqual`
            // /`.keepBoth`'s own duplicate detection at the repository layer
            // depends on identity staying stable across that copy (see
            // `testCopyingABetweenMineAndLibraryPreservesIdentity`).
            document.id = UUID()
            document.createdAt = Date()
            document.modifiedAt = Date()
        }
        do {
            _ = try await destination.save(document, conflict: .keepBoth)
            await load()
        } catch {
            alert = UserAlert(title: L10n.t("Couldn't copy this preset"), error: error)
        }
    }

    // MARK: - Import (spec §9.3)

    func previewImport(_ urls: [URL]) async {
        operationID += 1
        let current = operationID
        importState = .loading

        var newItems: [PresetImportItem] = []
        var failureCount = 0
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let suggestedName = url.deletingPathExtension().lastPathComponent
                // Task 3.2: import also accepts LumaHarbor's own `.lhpreset`
                // files, not just `.xmp` -- distinct from `.lhpresetbackup`
                // (a whole-scope archive, see `exportBackup`/`restoreBackup`
                // below), this is a single preset. Like the `.xmp` path, a
                // fresh identity is always minted (`PresetDocument.init`'s
                // own default `UUID()`) rather than reusing the file's own
                // `id` -- import always creates a new preset, it never
                // silently adopts another preset's identity; that's what
                // backup/restore is for.
                let preview: XMPImportPreview = url.pathExtension.lowercased() == "lhpreset"
                    ? try Self.previewLHPreset(data: data, suggestedName: suggestedName)
                    : try importer.preview(data: data, suggestedName: suggestedName)
                newItems.append(PresetImportItem(sourceURL: url, preview: preview))
            } catch {
                failureCount += 1
            }
        }

        guard current == operationID else { return }
        importItems = newItems
        if newItems.isEmpty {
            importState = .failed(
                failureCount > 0
                    ? L10n.t("None of the selected files could be read as develop presets.")
                    : L10n.t("No files were selected.")
            )
        } else {
            importState = .preview
        }
    }

    /// Zero writes -- the whole point of previewing first (spec §9.3).
    func cancelImport() {
        importItems = []
        importState = .idle
    }

    /// Only an `approximateFields` member can be toggled -- `native` fields
    /// always participate, and `preserved` properties never do (spec §7:
    /// "preserved 永不參與 patch"), so this is a no-op for either.
    func setApproximateField(_ field: AdjustmentFieldID, included: Bool, for itemID: PresetImportItem.ID) {
        guard let index = importItems.firstIndex(where: { $0.id == itemID }),
              importItems[index].preview.approximateFields.contains(field) else { return }
        if included {
            importItems[index].deselectedApproximateFields.remove(field)
        } else {
            importItems[index].deselectedApproximateFields.insert(field)
        }
    }

    func confirmImport(scope: PresetScopeKind) async {
        guard let destination = repository(for: scope) else {
            // Never a silent no-op: the UI must not be able to leave `scope`
            // pointing at a destination that doesn't exist (see
            // `ImportPresetSheet`), but this is the second, ViewModel-level
            // line of defense -- reported through the same state machine the
            // rest of import already uses, rather than a separate `alert`.
            importState = .failed(L10n.t("That destination isn't available right now."))
            return
        }

        importState = .saving
        var succeeded = 0
        var failed = 0
        for item in importItems {
            var document = item.preview.proposedPreset
            document.patch = document.patch.excluding(item.deselectedApproximateFields)
            do {
                _ = try await destination.save(try document.validated(), conflict: .keepBoth)
                succeeded += 1
            } catch {
                failed += 1
            }
        }

        importItems = []
        importState = failed > 0 ? .partialResult(succeeded: succeeded, failed: failed) : .idle
        await load()
    }

    // MARK: - Export (spec §9.4)

    struct ExportResult {
        var data: Data
        var diagnostics: [XMPDiagnostic]
    }

    /// - Parameter context: the open photo's white-balance baseline, if any
    ///   -- only meaningful for a native-sourced preset's temperature/tint
    ///   (see `XMPExporter.export`'s own parameter doc).
    func exportAsXMP(_ document: PresetDocument, context: PresetApplicationContext) throws -> ExportResult {
        let result = try exporter.export(document, context: context)
        return ExportResult(data: result.data, diagnostics: result.diagnostics)
    }

    func exportAsNativePreset(_ document: PresetDocument) throws -> Data {
        try SidecarCoding.encode(document)
    }

    /// Wraps an `.lhpreset` file's own decoded document into the same
    /// `XMPImportPreview` shape the XMP path already produces, so
    /// `ImportPresetSheet`'s summary UI works unchanged for either kind of
    /// file (Task 3.2: "Add UI for import/export `.lhpreset` and `.xmp`" --
    /// `.xmp` import already existed; `.lhpreset` import did not). A native
    /// preset has no approximate-vs-preserved distinction to make -- every
    /// field already present in its own `patch` is exactly as native as
    /// LumaHarbor's own patch format gets.
    private static func previewLHPreset(data: Data, suggestedName: String) throws -> XMPImportPreview {
        let decoded = try SidecarCoding.decode(PresetDocument.self, from: data)
        let nativeFields = AdjustmentFieldID.allCases.filter { decoded.patch.contains($0) }
        // Independent-review finding: a `.lhpreset` file that was itself
        // originally imported from Adobe XMP still carries `source:
        // .adobeXMP` and an `xmpEnvelope` preserving the full original
        // packet (Task 3.2's own "preserve unknown XMP fields"). Dropping
        // either here -- as an earlier version of this function did --
        // would silently turn it into a plain native preset on re-import:
        // losing the "Imported" source badge (Task 3.1), and permanently
        // losing every unmapped property `xmpEnvelope` was preserving the
        // next time it's re-exported to `.xmp` (`XMPExporter.baseDocument(for:)`
        // falls back to a blank envelope when `xmpEnvelope == nil`).
        let proposedPreset = PresetDocument(
            name: decoded.name.isEmpty ? suggestedName : decoded.name,
            groupPath: decoded.groupPath,
            source: decoded.source,
            patch: decoded.patch,
            xmpEnvelope: decoded.xmpEnvelope
        )
        return XMPImportPreview(
            proposedPreset: proposedPreset,
            nativeFields: nativeFields,
            approximateFields: [],
            preservedProperties: [],
            diagnostics: []
        )
    }

    // MARK: - Backup / restore (spec: "備份、還原 preset", Task 3.2)

    /// Bundles every preset currently in `scope` into one portable
    /// `PresetBackupArchive`, encoded the same way `.lhpreset` files are
    /// (`PresetBackupCoding`, `PresetCore`) -- distinct from a single-preset
    /// `.lhpreset`/`.xmp` export above. Throws rather than returning `nil`
    /// on an unavailable scope, matching `list()`'s own contract; the caller
    /// (a save panel action) has nothing useful to show for a partial
    /// backup, so there is no "best effort" version of this.
    func exportBackup(scope: PresetScopeKind) async throws -> Data {
        guard let source = repository(for: scope) else {
            throw PresetError.destinationUnavailable(scope.title)
        }
        let archive = PresetBackupArchive(documents: try await source.list())
        return try PresetBackupCoding.encode(archive)
    }

    /// Decodes `data` as a `PresetBackupArchive` and replays every document
    /// into `scope` via `restorePresets` (`PhotoLibraryCore`), one `save`
    /// per document under `conflict` -- the exact same per-document
    /// conflict machinery `save`/`PresetConflictResolution` already define
    /// and `PresetRestoreTests` already covers against a real repository.
    /// Returns `nil` (and sets `alert`) on a malformed archive or an
    /// unavailable destination scope; a per-document failure inside a
    /// otherwise-valid archive is instead tallied into the returned
    /// `PresetRestoreSummary.failed`, since one bad preset in a large backup
    /// must not hide what did restore.
    @discardableResult
    func restoreBackup(_ data: Data, into scope: PresetScopeKind, conflict: PresetConflictResolution) async -> PresetRestoreSummary? {
        guard let destination = repository(for: scope) else {
            alert = UserAlert(
                title: L10n.t("Couldn't restore this backup"),
                message: L10n.t("That destination isn't available right now.")
            )
            return nil
        }
        let archive: PresetBackupArchive
        do {
            archive = try PresetBackupCoding.decode(data)
        } catch {
            alert = UserAlert(title: L10n.t("Couldn't restore this backup"), error: error)
            return nil
        }
        let summary = await restorePresets(archive.documents, into: destination, conflict: conflict)
        await load()
        return summary
    }

    @discardableResult
    func restoreBackupAndPresentSummary(
        _ data: Data,
        into scope: PresetScopeKind,
        conflict: PresetConflictResolution
    ) async -> PresetRestoreSummary? {
        guard let summary = await restoreBackup(data, into: scope, conflict: conflict) else {
            return nil
        }
        alert = UserAlert(title: L10n.t("Restore complete"), message: Self.restoreSummaryMessage(summary))
        return summary
    }

    private static func restoreSummaryMessage(_ summary: PresetRestoreSummary) -> String {
        var parts: [String] = []
        if summary.created > 0 { parts.append("\(summary.created) \(L10n.t("added"))") }
        if summary.keptBoth > 0 { parts.append("\(summary.keptBoth) \(L10n.t("kept as a copy"))") }
        if summary.duplicateSkipped > 0 { parts.append("\(summary.duplicateSkipped) \(L10n.t("already present"))") }
        if summary.failed > 0 { parts.append("\(summary.failed) \(L10n.t("failed"))") }
        return parts.isEmpty ? L10n.t("Nothing to restore.") : parts.joined(separator: ", ")
    }
}
