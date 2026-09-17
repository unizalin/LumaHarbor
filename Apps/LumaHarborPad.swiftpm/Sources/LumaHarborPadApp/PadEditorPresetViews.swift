import AdjustmentUI
import EditorCore
import Localization
import PresetCore
import RawProcessingCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Preset panel

/// The full Preset inspector: search, scope filter, apply-mode control, and
/// a scrollable list where a single tap previews and an explicit Apply button
/// commits via `editor.commitPreset(_:mode:)` — one undo step per apply.
///
/// Never holds a second copy of `PhotoAdjustments`. Preview is cancelled
/// automatically when the panel disappears so no stale preset render lingers.
struct PadPresetPanel: View {
    @ObservedObject var editor: EditorSession
    @ObservedObject var presetLibrary: PadPresetLibrary

    @State private var applicationMode: PresetApplicationMode = .merge
    @State private var previewingPresetID: UUID?
    @State private var isCreatingPreset = false
    @State private var editingPreset: PresetDocument?
    @State private var isImportingFiles = false
    @State private var isRestoringBackup = false
    @State private var isExportingFile = false
    @State private var exportDocument: PadPresetDataFileDocument?
    @State private var exportFilename = "preset.lhpreset"

    var body: some View {
        VStack(spacing: 0) {
            presetActionBar
            Divider()
            searchBar
            Divider()
            scopePicker
            Divider()
            applyModePicker
            Divider()
            presetList
        }
        .task { await presetLibrary.load() }
        .onDisappear {
            if previewingPresetID != nil {
                editor.cancelPresetPreview()
                previewingPresetID = nil
            }
        }
        .sheet(isPresented: $isCreatingPreset) {
            NavigationStack {
                PadPresetCreateSheet(
                    adjustments: editor.adjustments,
                    presetLibrary: presetLibrary
                ) {
                    isCreatingPreset = false
                }
            }
        }
        .sheet(item: $editingPreset) { preset in
            NavigationStack {
                PadPresetEditSheet(preset: preset, presetLibrary: presetLibrary) {
                    editingPreset = nil
                }
            }
        }
        .fileImporter(
            isPresented: $isImportingFiles,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task { await presetLibrary.importFiles(urls) }
        }
        .fileImporter(
            isPresented: $isRestoringBackup,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                guard let data = presetLibrary.readData(from: url) else {
                    presetLibrary.message = L10n.t("This backup could not be read.")
                    return
                }
                await presetLibrary.restoreBackup(data)
            }
        }
        .fileExporter(
            isPresented: $isExportingFile,
            document: exportDocument,
            contentType: .data,
            defaultFilename: exportFilename
        ) { result in
            if case .failure = result {
                presetLibrary.message = L10n.t("The preset file could not be saved.")
            }
            exportDocument = nil
        }
        .alert(
            L10n.t("Preset"),
            isPresented: Binding(
                get: { presetLibrary.message != nil },
                set: { if !$0 { presetLibrary.message = nil } }
            )
        ) {
            Button(L10n.t("OK"), role: .cancel) { presetLibrary.message = nil }
        } message: {
            Text(presetLibrary.message ?? "")
        }
    }

    /// Keeps Preset actions attached to the page instead of relying on the
    /// editor's root NavigationStack toolbar, whose many document actions can
    /// collapse page-specific controls into an overflow menu on iPad.
    private var presetActionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                favoritesButton
                createPresetButton
                presetActionsMenu
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    favoritesButton
                    createPresetButton
                    presetActionsMenu
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private var favoritesButton: some View {
        Button {
            presetLibrary.favoritesOnly.toggle()
        } label: {
            Image(systemName: presetLibrary.favoritesOnly ? "star.fill" : "star")
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel(Text(L10n.t("Favorites only")))
        .accessibilityAddTraits(presetLibrary.favoritesOnly ? .isSelected : [])
    }

    private var createPresetButton: some View {
        Button {
            isCreatingPreset = true
        } label: {
            Image(systemName: "plus")
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel(Text(L10n.t("Create preset")))
    }

    private var presetActionsMenu: some View {
        Menu {
            Button {
                isImportingFiles = true
            } label: {
                Label(L10n.t("Import preset files"), systemImage: "square.and.arrow.down")
            }
            Button {
                isRestoringBackup = true
            } label: {
                Label(L10n.t("Restore backup"), systemImage: "arrow.counterclockwise")
            }
            Button {
                exportBackup()
            } label: {
                Label(L10n.t("Export backup"), systemImage: "archivebox")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel(Text(L10n.t("Preset actions")))
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(L10n.t("Search Presets"), text: $presetLibrary.searchQuery)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
        }
        .padding(.horizontal)
        .frame(height: 44)
        .accessibilityLabel(Text(L10n.t("Search Presets")))
    }

    private var scopePicker: some View {
        ViewThatFits(in: .horizontal) {
            Picker(L10n.t("Scope"), selection: $presetLibrary.scope) {
                ForEach(PadPresetScope.allCases) { scope in
                    Text(L10n.t(scope.rawValue)).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)

            Picker(L10n.t("Scope"), selection: $presetLibrary.scope) {
                ForEach(PadPresetScope.allCases) { scope in
                    Text(L10n.t(scope.rawValue)).tag(scope)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .accessibilityLabel(Text(L10n.t("Preset scope")))
    }

    private var applyModePicker: some View {
        ViewThatFits(in: .horizontal) {
            Picker(L10n.t("Apply Mode"), selection: $applicationMode) {
                Text(L10n.t("Merge")).tag(PresetApplicationMode.merge)
                Text(L10n.t("Replace")).tag(PresetApplicationMode.replace)
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)

            Picker(L10n.t("Apply Mode"), selection: $applicationMode) {
                Text(L10n.t("Merge")).tag(PresetApplicationMode.merge)
                Text(L10n.t("Replace")).tag(PresetApplicationMode.replace)
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .accessibilityLabel(Text(L10n.t("Apply mode")))
    }

    @ViewBuilder
    private var presetList: some View {
        if presetLibrary.isLoading {
            Spacer()
            ProgressView()
                .frame(maxWidth: .infinity)
            Spacer()
        } else if presetLibrary.filteredPresets.isEmpty {
            Spacer()
            Text(presetLibrary.searchQuery.isEmpty
                 ? L10n.t("No presets.")
                 : L10n.t("No results."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(presetLibrary.filteredPresets) { preset in
                        presetRow(preset)
                        Divider()
                    }
                }
            }
        }
    }

    private func presetRow(_ preset: PresetDocument) -> some View {
        let isPreviewing = previewingPresetID == preset.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                presetSummary(preset)
                Spacer(minLength: 8)
                favoriteButton(for: preset)
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    Spacer(minLength: 0)
                    presetApplyButton(preset, isPreviewing: isPreviewing)
                    presetActionsMenu(for: preset)
                }

                VStack(alignment: .leading, spacing: 4) {
                    presetApplyButton(preset, isPreviewing: isPreviewing)
                    presetActionsMenu(for: preset)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(minHeight: 76)
        .background(
            isPreviewing ? Color.accentColor.opacity(0.10) : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isPreviewing {
                // Second tap on the same row commits, identical to the Apply button.
                editor.commitPreset(preset, mode: applicationMode)
                previewingPresetID = nil
            } else {
                if previewingPresetID != nil {
                    editor.cancelPresetPreview()
                }
                previewingPresetID = preset.id
                editor.previewPreset(preset, mode: applicationMode)
            }
        }
        .accessibilityLabel(Text(preset.name))
        .accessibilityHint(Text(isPreviewing
            ? L10n.t("Previewing. Tap again or use Apply button to commit.")
            : L10n.t("Tap to preview this preset.")))
        .accessibilityAddTraits(isPreviewing ? .isSelected : [])
    }

    private func presetSummary(_ preset: PresetDocument) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(preset.name)
                .font(.body)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            if !preset.groupPath.isEmpty {
                Text(preset.groupPath.joined(separator: " › "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if presetLibrary.isBuiltIn(preset) {
                Text(L10n.t("Built-In"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func favoriteButton(for preset: PresetDocument) -> some View {
        Button {
            Task { await presetLibrary.toggleFavorite(preset) }
        } label: {
            Image(systemName: preset.isFavorite ? "star.fill" : "star")
                .foregroundStyle(preset.isFavorite ? .yellow : .secondary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(presetLibrary.isBuiltIn(preset))
        .accessibilityLabel(Text(preset.isFavorite ? L10n.t("Remove favorite") : L10n.t("Add favorite")))
    }

    @ViewBuilder
    private func presetApplyButton(_ preset: PresetDocument, isPreviewing: Bool) -> some View {
        if isPreviewing {
            Button(L10n.t("Apply")) {
                editor.commitPreset(preset, mode: applicationMode)
                previewingPresetID = nil
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .frame(minHeight: 44)
            .accessibilityLabel(Text(L10n.t("Apply") + " " + preset.name))
        }
    }

    private func presetActionsMenu(for preset: PresetDocument) -> some View {
        Menu {
            if !presetLibrary.isBuiltIn(preset) {
                Button {
                    editingPreset = preset
                } label: {
                    Label(L10n.t("Edit preset"), systemImage: "pencil")
                }
                Button(role: .destructive) {
                    Task { await presetLibrary.delete(preset) }
                } label: {
                    Label(L10n.t("Delete preset"), systemImage: "trash")
                }
            }
            Button {
                exportPreset(preset, as: .native)
            } label: {
                Label(L10n.t("Export .lhpreset"), systemImage: "square.and.arrow.up")
            }
            Button {
                exportPreset(preset, as: .xmp)
            } label: {
                Label(L10n.t("Export XMP"), systemImage: "doc.text")
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 44, height: 44)
        }
        .menuOrder(.fixed)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(Text(L10n.t("Preset actions")))
    }

    private enum ExportKind { case native, xmp }

    private func exportPreset(_ preset: PresetDocument, as kind: ExportKind) {
        do {
            let data: Data
            switch kind {
            case .native:
                data = try presetLibrary.exportNative(preset)
                exportFilename = "\(preset.name).lhpreset"
            case .xmp:
                data = try presetLibrary.exportXMP(preset)
                exportFilename = "\(preset.name).xmp"
            }
            exportDocument = PadPresetDataFileDocument(data: data)
            isExportingFile = true
        } catch {
            presetLibrary.message = L10n.t("This preset could not be exported.")
        }
    }

    private func exportBackup() {
        Task {
            do {
                let data = try await presetLibrary.exportBackup()
                exportFilename = "LumaHarbor-Presets.lhpresetbackup"
                exportDocument = PadPresetDataFileDocument(data: data)
                isExportingFile = true
            } catch {
                presetLibrary.message = L10n.t("The preset backup could not be created.")
            }
        }
    }
}

/// Data-only FileDocument used by the iPad Files picker for native presets,
/// XMP and backup archives. The file extension is supplied by the caller; the
/// payload is never re-encoded by the picker.
struct PadPresetDataFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.data] }

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct PadPresetCreateSheet: View {
    let adjustments: PhotoAdjustments
    @ObservedObject var presetLibrary: PadPresetLibrary
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var groupPath = ""
    @State private var isFavorite = false
    @State private var selectedFields: Set<AdjustmentFieldID>
    @State private var isSaving = false

    init(adjustments: PhotoAdjustments, presetLibrary: PadPresetLibrary, onDismiss: @escaping () -> Void) {
        self.adjustments = adjustments
        self.presetLibrary = presetLibrary
        self.onDismiss = onDismiss
        _selectedFields = State(initialValue: AdjustmentPatch.modifiedFields(in: adjustments))
    }

    var body: some View {
        Form {
            Section(L10n.t("Preset details")) {
                TextField(L10n.t("Name"), text: $name)
                TextField(L10n.t("Group (optional)"), text: $groupPath)
                Toggle(L10n.t("Favorite"), isOn: $isFavorite)
            }
            PadPresetFieldSelection(selectedFields: $selectedFields)
        }
        .navigationTitle(L10n.t("Create preset"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.t("Cancel")) { dismissSheet() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.t("Save")) { save() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
    }

    private func save() {
        isSaving = true
        Task {
            let saved = await presetLibrary.createPreset(
                name: name,
                groupPath: groupPath.isEmpty ? [] : [groupPath],
                isFavorite: isFavorite,
                selectedFields: selectedFields,
                from: adjustments
            )
            isSaving = false
            if saved { dismissSheet() }
        }
    }

    private func dismissSheet() {
        onDismiss()
        dismiss()
    }
}

struct PadPresetEditSheet: View {
    let preset: PresetDocument
    @ObservedObject var presetLibrary: PadPresetLibrary
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var groupPath: String
    @State private var isFavorite: Bool
    @State private var selectedFields: Set<AdjustmentFieldID>
    @State private var isSaving = false

    init(preset: PresetDocument, presetLibrary: PadPresetLibrary, onDismiss: @escaping () -> Void) {
        self.preset = preset
        self.presetLibrary = presetLibrary
        self.onDismiss = onDismiss
        _name = State(initialValue: preset.name)
        _groupPath = State(initialValue: preset.groupPath.joined(separator: " / "))
        _isFavorite = State(initialValue: preset.isFavorite)
        _selectedFields = State(initialValue: Set(AdjustmentFieldID.allCases.filter { preset.patch.contains($0) }))
    }

    var body: some View {
        Form {
            Section(L10n.t("Preset details")) {
                TextField(L10n.t("Name"), text: $name)
                TextField(L10n.t("Group (optional)"), text: $groupPath)
                Toggle(L10n.t("Favorite"), isOn: $isFavorite)
            }
            PadPresetFieldSelection(selectedFields: $selectedFields)
        }
        .navigationTitle(L10n.t("Edit preset"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.t("Cancel")) { dismissSheet() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.t("Save")) { save() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
    }

    private func save() {
        isSaving = true
        Task {
            let saved = await presetLibrary.updatePreset(
                preset,
                name: name,
                groupPath: groupPath.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) },
                isFavorite: isFavorite,
                keptFields: selectedFields
            )
            isSaving = false
            if saved { dismissSheet() }
        }
    }

    private func dismissSheet() {
        onDismiss()
        dismiss()
    }
}

struct PadPresetFieldSelection: View {
    @Binding var selectedFields: Set<AdjustmentFieldID>

    var body: some View {
        Section(L10n.t("Included adjustments")) {
            ForEach(AdjustmentFieldID.allCases, id: \.self) { field in
                Toggle(isOn: binding(for: field)) {
                    Text(L10n.t(field.rawValue))
                }
            }
        }
    }

    private func binding(for field: AdjustmentFieldID) -> Binding<Bool> {
        Binding(
            get: { selectedFields.contains(field) },
            set: { included in
                if included { selectedFields.insert(field) }
                else { selectedFields.remove(field) }
            }
        )
    }
}

