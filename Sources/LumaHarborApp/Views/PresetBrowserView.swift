import AppKit
import Localization
import PresetCore
import SwiftUI
import UniformTypeIdentifiers

/// Spec §9.1: a collapsible Preset section in the editor inspector, with
/// search, scope/favorite filtering, hover/keyboard preview, click-to-apply,
/// and entry points for create/import/export.
struct PresetBrowserView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @AppStorage("preset.applicationMode") private var applicationModeRaw = PresetApplicationMode.merge.rawValue
    @State private var isExpanded = true
    @State private var isShowingCreateSheet = false
    @State private var isShowingImportSheet = false
    @State private var renamingItem: PresetListItem?
    @State private var renameText = ""
    @State private var exportError: UserAlert?

    private var presetLibrary: PresetLibraryViewModel { model.presetLibrary }
    private var applicationMode: PresetApplicationMode {
        PresetApplicationMode(rawValue: applicationModeRaw) ?? .merge
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                controls
                previewDiagnostic
                list
            }
            .padding(.top, 8)
        } label: {
            Text(L10n.t("Presets"))
                .font(.headline)
        }
        .task { await presetLibrary.load() }
        .sheet(isPresented: $isShowingCreateSheet) { CreatePresetSheet() }
        .sheet(isPresented: $isShowingImportSheet) { ImportPresetSheet() }
        .alert(
            L10n.t("Rename Preset"),
            isPresented: Binding(get: { renamingItem != nil }, set: { if !$0 { renamingItem = nil } })
        ) {
            TextField(L10n.t("Name"), text: $renameText)
            Button(L10n.t("Cancel"), role: .cancel) { renamingItem = nil }
            Button(L10n.t("Save")) {
                if let item = renamingItem {
                    Task { await presetLibrary.rename(item, to: renameText) }
                }
                renamingItem = nil
            }
        }
        .alert(item: $exportError) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        // `PresetLibraryViewModel.alert` -- set on a failed rename, delete,
        // copy or toggleFavorite (all of which act directly on rows in
        // `list` below, never behind a sheet) -- was never bound to any
        // View at all (round 2, finding #4): every one of those failures
        // was invisible. `CreatePresetSheet` binds this same property
        // separately, since its own sheet would otherwise cover this alert
        // and keep it from presenting while open.
        .alert(item: Binding(
            get: { presetLibrary.alert },
            set: { presetLibrary.alert = $0 }
        )) { alert in
            Alert(
                title: Text(alert.title),
                message: Text([alert.message, alert.nextStep].compactMap { $0 }.joined(separator: "\n\n")),
                dismissButton: .default(Text(L10n.t("OK")))
            )
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(
                    L10n.t("Search presets"),
                    text: Binding(get: { presetLibrary.searchText }, set: { presetLibrary.searchText = $0 })
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.t("Search presets by name or group"))

                Menu {
                    ForEach(PresetLibraryViewModel.ScopeFilter.allCases, id: \.self) { filter in
                        Button(filter.title) { presetLibrary.scopeFilter = filter }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .help(L10n.t("Filter presets"))
                .accessibilityLabel(L10n.t("Filter presets"))
            }

            HStack {
                Picker(L10n.t("Apply mode"), selection: $applicationModeRaw) {
                    Text(L10n.t("Merge")).tag(PresetApplicationMode.merge.rawValue)
                    Text(L10n.t("Replace")).tag(PresetApplicationMode.replace.rawValue)
                }
                .pickerStyle(.segmented)
                .help(L10n.t("Merge keeps fields the preset doesn't set; Replace starts from neutral"))

                Spacer()

                Button {
                    isShowingCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help(L10n.t("Create a preset from this photo"))
                .accessibilityLabel(L10n.t("Create a preset from this photo"))
                .disabled(model.editor.photo == nil)

                Button {
                    isShowingImportSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help(L10n.t("Import develop presets"))
                .accessibilityLabel(L10n.t("Import develop presets"))
            }
        }
    }

    /// Non-modal, hover-driven notice for the *currently previewed* preset
    /// (spec §9.1: "hover or keyboard selection only does transient
    /// preview"). Round 2, finding #3: `EditorViewModel.presetPreviewMessage`
    /// was published from Phase 1's original fix but no View ever read it,
    /// so a skipped contextual leaf (e.g. white balance with no baseline
    /// yet) was invisible while hovering. Entirely absent -- not an empty
    /// reserved row -- when there's nothing to say, so it never leaves a
    /// stale message on screen after the pointer moves off a row (the
    /// message is recomputed from live diagnostics on every hover change,
    /// per `EditorViewModel.presetPreviewMessage`'s doc comment).
    @ViewBuilder
    private var previewDiagnostic: some View {
        if let message = model.editor.presetPreviewMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(message)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            if presetLibrary.filteredItems.isEmpty {
                Text(L10n.t("No presets yet"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(presetLibrary.filteredItems) { item in
                PresetRow(
                    item: item,
                    applicationMode: applicationMode,
                    onRename: {
                        renameText = item.document.name
                        renamingItem = item
                    },
                    onExport: { exportPreset(item) }
                )
            }
        }
    }

    private func exportPreset(_ item: PresetListItem) {
        let panel = NSSavePanel()
        panel.title = L10n.t("Export Preset")
        panel.nameFieldStringValue = item.document.name
        panel.allowedContentTypes = [.init(filenameExtension: "lhpreset") ?? .data, .xml]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            if url.pathExtension.lowercased() == "xmp" {
                data = try presetLibrary.exportAsXMP(item.document, context: .none).data
            } else {
                data = try presetLibrary.exportAsNativePreset(item.document)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            exportError = UserAlert(title: L10n.t("Couldn't export this preset"), error: error)
        }
    }
}

private struct PresetRow: View {
    @EnvironmentObject private var model: LibraryViewModel
    let item: PresetListItem
    let applicationMode: PresetApplicationMode
    let onRename: () -> Void
    let onExport: () -> Void

    private var presetLibrary: PresetLibraryViewModel { model.presetLibrary }

    var body: some View {
        HStack {
            Button {
                model.editor.commitPreset(item.document, mode: applicationMode)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.document.name)
                        .font(.callout)
                    if !item.document.groupPath.isEmpty {
                        Text(item.document.groupPath.joined(separator: " / "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(L10n.t("Apply preset")) \(item.document.name)")
            .accessibilityHint(L10n.t("Applies this preset using the current merge or replace mode"))

            Spacer()

            Button {
                Task { await presetLibrary.toggleFavorite(item) }
            } label: {
                Image(systemName: item.document.isFavorite ? "star.fill" : "star")
            }
            .buttonStyle(.plain)
            .foregroundStyle(item.document.isFavorite ? .yellow : .secondary)
            .help(L10n.t("Favorite"))
            .accessibilityLabel(L10n.t("Toggle favorite"))

            Menu {
                Button(L10n.t("Rename…"), action: onRename)
                Button(L10n.t("Export…"), action: onExport)
                Divider()
                Button(L10n.t("Delete"), role: .destructive) {
                    Task { await presetLibrary.delete(item) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
            .help(L10n.t("More preset actions"))
            .accessibilityLabel(L10n.t("More preset actions"))
        }
        .contentShape(Rectangle())
        .onHover { isHovering in
            if isHovering, model.editor.photo != nil {
                model.editor.previewPreset(item.document, mode: applicationMode)
            } else if !isHovering {
                model.editor.cancelPresetPreview()
            }
        }
        .padding(.vertical, 2)
    }
}
