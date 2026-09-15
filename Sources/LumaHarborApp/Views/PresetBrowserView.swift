import AppKit
import Localization
import PhotoLibraryCore
import PresetCore
import SwiftUI
import UniformTypeIdentifiers

/// Which scope a preset in `scope` can be copied *to*, factored out of the
/// view so it's independently testable (Codex re-review, finding #3: copy
/// existed only in the ViewModel/repository, with nothing testing which
/// scope the UI should even offer). Mirrors the existing rule `CreatePresetSheet`/
/// `ImportPresetSheet` already use for their own scope pickers: "This
/// Library" is only ever offered when a library is actually open, never
/// shown and then left to fail.
enum PresetCopyDestination {
    static func destination(for scope: PresetScopeKind, hasLibraryScope: Bool) -> PresetScopeKind? {
        switch scope {
        case .mine: return hasLibraryScope ? .library : nil
        case .library: return .mine
        // A built-in preset can only ever be duplicated into "My Presets"
        // -- never "This Library", and nothing is ever copied *into*
        // .builtIn (BuiltInPresetRepository.save always throws).
        case .builtIn: return .mine
        }
    }
}

/// Configures the `NSSavePanel` used by `exportPreset`, factored out so its
/// file-type setup is unit-testable without driving a real modal panel
/// (XCTest can't drive `NSSavePanel.runModal()`).
///
/// Gate B smoke test (2026-08-24): `allowedContentTypes` only declared
/// `lhpreset`/`xml`, and `allowsOtherFileTypes` was left at its default
/// `false`. NSSavePanel silently rewrites any extension the user types that
/// isn't in `allowedContentTypes`, re-appending the first type's extension
/// instead -- so typing "MyPreset.xmp" actually saved as
/// "MyPreset.xmp.lhpreset", and `exportPreset`'s `pathExtension == "xmp"`
/// check was never true through this UI, no matter what the user named the
/// file. `exportAsXMP` was unreachable from Export... entirely, silently:
/// no error, no warning, just the wrong format on disk. Reproduced twice by
/// hand; `XMPImportExportTests` couldn't have caught this since those
/// exercise `exportAsXMP` directly, bypassing the panel.
enum PresetExportPanelFactory {
    static func allowedContentTypes() -> [UTType] {
        [
            .init(filenameExtension: "lhpreset") ?? .data,
            .init(filenameExtension: "xmp") ?? .xml
        ]
    }

    @MainActor
    static func configure(_ panel: NSSavePanel, presetName: String) {
        panel.title = L10n.t("Export Preset")
        panel.nameFieldStringValue = presetName
        panel.allowedContentTypes = allowedContentTypes()
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
    }
}

/// Who most recently asked to preview a preset: a real mouse hover, or
/// keyboard focus moving through the list. Whichever fired most recently
/// owns the current preview -- a stale hover-exit or focus-loss event from a
/// row that is no longer the owner must be a no-op, or it would cancel a
/// newer owner's still-active preview (spec: hover and keyboard focus must
/// not incorrectly cancel each other). Factored out as a pure, `Equatable`
/// value so the arbitration rules are unit-testable without driving actual
/// SwiftUI hover/focus events.
enum PresetPreviewOwner: Equatable {
    case none
    case hover(UUID)
    case keyboard(UUID)

    func shouldCancel(onHoverExit id: UUID) -> Bool { self == .hover(id) }
    func shouldCancel(onKeyboardExit id: UUID) -> Bool { self == .keyboard(id) }
}

/// Pure arrow-key index arithmetic behind `PresetBrowserView`'s `.onMoveCommand`
/// handler, factored out for the same reason as `PresetPreviewOwner` above.
enum PresetFocusNavigation {
    static func nextIndex(current: Int?, direction: MoveCommandDirection, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let base = current ?? -1
        let candidate: Int
        switch direction {
        case .up: candidate = base - 1
        case .down: candidate = base + 1
        default: return nil
        }
        guard candidate >= 0, candidate < count else { return nil }
        return candidate
    }
}

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
    /// Phase 3 Task 3.1: which preset (if any) the Edit… menu item opened.
    /// A separate sheet from `CreatePresetSheet` -- editing an existing
    /// document needs its identity, not a fresh one built from the open
    /// photo.
    @State private var editingItem: PresetListItem?
    @State private var exportError: UserAlert?
    /// Round 3: which of hover or keyboard focus currently owns the transient
    /// preview -- see `PresetPreviewOwner`.
    @State private var previewOwner: PresetPreviewOwner = .none
    @FocusState private var focusedPresetID: UUID?

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
        .sheet(item: $editingItem) { item in EditPresetSheet(item: item) }
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

                // Task 3.2: backup/restore a whole scope at once -- distinct
                // from Export…/Import above, which are one preset at a time.
                Menu {
                    Button(L10n.t("Backup My Presets…")) { backupPresets(scope: .mine) }
                    if presetLibrary.hasLibraryScope {
                        Button(L10n.t("Backup This Library's Presets…")) { backupPresets(scope: .library) }
                    }
                    Divider()
                    // Restore always targets "My Presets" -- the one scope
                    // guaranteed to exist, matching `confirmImport`'s own
                    // `.keepBoth` policy so a restore can never silently
                    // overwrite an existing preset.
                    Button(L10n.t("Restore Presets…")) { restorePresets() }
                } label: {
                    Image(systemName: "tray.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
                .help(L10n.t("Backup or restore presets"))
                .accessibilityLabel(L10n.t("Backup or restore presets"))
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
        // Round 3: a preview that genuinely changes the picture can also
        // fail to render (e.g. hovering it over a photo whose decode fails
        // outright). That failure is published separately from
        // `presetPreviewMessage` -- see `EditorViewModel.previewRenderFailureMessage`
        // -- specifically so it can sit *beside* the diagnostic instead of
        // the modal `alert` covering this whole section.
        if model.editor.presetPreviewMessage != nil || model.editor.previewRenderFailureMessage != nil {
            VStack(alignment: .leading, spacing: 2) {
                if let message = model.editor.presetPreviewMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(message)
                }
                if let failure = model.editor.previewRenderFailureMessage {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(failure)
                }
            }
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
                    copyDestination: PresetCopyDestination.destination(
                        for: item.scope, hasLibraryScope: presetLibrary.hasLibraryScope
                    ),
                    onRename: {
                        renameText = item.document.name
                        renamingItem = item
                    },
                    onEdit: { editingItem = item },
                    onExport: { exportPreset(item) },
                    onCopy: { destination in Task { await presetLibrary.copy(item, to: destination) } },
                    onHoverChanged: { isHovering in handleHover(item, isHovering: isHovering) }
                )
                .focusable()
                .focused($focusedPresetID, equals: item.id)
            }
        }
        // Round 3: arrow-key row-to-row navigation, so a preset's preview is
        // reachable without a mouse at all (spec §9.1: "hover *or* keyboard
        // selection"). `List`'s own selection would give this for free, but
        // `list` lives inside `InspectorView`'s own outer `ScrollView` --
        // nesting a second, independently-scrolling `List` in there is its
        // own can of layout problems, so this is a deliberately small,
        // local substitute: move `focusedPresetID` by one row per press.
        .onMoveCommand { direction in
            let items = presetLibrary.filteredItems
            let currentIndex = focusedPresetID.flatMap { id in items.firstIndex { $0.id == id } }
            guard let newIndex = PresetFocusNavigation.nextIndex(
                current: currentIndex, direction: direction, count: items.count
            ) else { return }
            focusedPresetID = items[newIndex].id
        }
        .onChange(of: focusedPresetID) { oldValue, newValue in
            if let id = newValue, let item = presetLibrary.filteredItems.first(where: { $0.id == id }) {
                previewOwner = .keyboard(id)
                model.editor.previewPreset(item.document, mode: applicationMode)
            } else if let old = oldValue, previewOwner.shouldCancel(onKeyboardExit: old) {
                previewOwner = .none
                model.editor.cancelPresetPreview()
            }
        }
    }

    /// Shared by every row's `.onHover`, so it can arbitrate against keyboard
    /// focus via `previewOwner` instead of each row deciding on its own
    /// (round 3: hover and keyboard focus must not cancel each other out).
    private func handleHover(_ item: PresetListItem, isHovering: Bool) {
        guard model.editor.photo != nil else { return }
        if isHovering {
            previewOwner = .hover(item.id)
            model.editor.previewPreset(item.document, mode: applicationMode)
        } else if previewOwner.shouldCancel(onHoverExit: item.id) {
            previewOwner = .none
            model.editor.cancelPresetPreview()
        }
    }

    private func exportPreset(_ item: PresetListItem) {
        let panel = NSSavePanel()
        PresetExportPanelFactory.configure(panel, presetName: item.document.name)

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

    /// Whole-scope backup, distinct from `exportPreset` above (one preset).
    /// `.lhpresetbackup`, `PresetCore.PresetBackupArchive`'s own file
    /// extension convention (Task 3.2).
    private func backupPresets(scope: PresetScopeKind) {
        let panel = NSSavePanel()
        panel.title = L10n.t("Backup Presets")
        panel.nameFieldStringValue = "\(scope.title) Backup"
        panel.allowedContentTypes = [.init(filenameExtension: "lhpresetbackup") ?? .data]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try await presetLibrary.exportBackup(scope: scope)
                try data.write(to: url, options: .atomic)
            } catch {
                exportError = UserAlert(title: L10n.t("Couldn't back up presets"), error: error)
            }
        }
    }

    /// Always restores into "My Presets" -- the one scope guaranteed to
    /// exist -- under `.keepBoth`, the same never-overwrite policy
    /// `confirmImport` already uses for `.xmp`/`.lhpreset` import. A picker
    /// for restore's destination scope or conflict policy is a documented
    /// scope boundary for this round, not an omission: `restorePresets`
    /// (`PhotoLibraryCore`) and `PresetRestoreTests` already support every
    /// policy, so widening this to a picker later needs no engine changes.
    private func restorePresets() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("Restore Presets")
        panel.allowedContentTypes = [.init(filenameExtension: "lhpresetbackup") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try PresetBackupCoding.read(from: url)
                await presetLibrary.restoreBackupAndPresentSummary(data, into: .mine, conflict: .keepBoth)
            } catch {
                exportError = UserAlert(
                    title: L10n.t("Couldn't restore this backup"),
                    error: error
                )
            }
        }
    }
}

private struct PresetRow: View {
    @EnvironmentObject private var model: LibraryViewModel
    let item: PresetListItem
    let applicationMode: PresetApplicationMode
    /// `nil` when there's no sensible destination to copy this item to right
    /// now (spec: only offer the *other* scope, and only when it actually
    /// exists) -- mirrors `CreatePresetSheet`/`ImportPresetSheet`'s own rule
    /// for their "This Library" segment.
    let copyDestination: PresetScopeKind?
    let onRename: () -> Void
    let onEdit: () -> Void
    let onExport: () -> Void
    let onCopy: (PresetScopeKind) -> Void
    let onHoverChanged: (Bool) -> Void

    private var presetLibrary: PresetLibraryViewModel { model.presetLibrary }

    private func copyMenuTitle(for destination: PresetScopeKind) -> String {
        switch destination {
        case .mine: return L10n.t("Copy to My Presets")
        case .library: return L10n.t("Copy to This Library")
        // Unreachable in practice: `PresetCopyDestination.destination(for:)`
        // never returns `.builtIn` (nothing can ever be copied *into* a
        // read-only scope) -- handled for exhaustiveness, not because a
        // menu item with this title can actually appear.
        case .builtIn: return L10n.t("Copy to Built-In")
        }
    }

    /// Spec §9.1 gap (identified in Task 3.1 research): a row previously
    /// showed nothing distinguishing a built-in preset (which can't be
    /// renamed, edited, or deleted) or an Adobe/XMP-imported one (whose
    /// approximate fields carry a wider tolerance than a native match) from
    /// an ordinary native user preset. `nil` for the common case -- a native
    /// preset in "My Presets" or "This Library" -- so this never clutters
    /// the row with a label that says nothing new.
    private var sourceBadge: String? {
        if item.scope == .builtIn { return L10n.t("Built-In") }
        if case .adobeXMP = item.document.source { return L10n.t("Imported") }
        return nil
    }

    var body: some View {
        HStack {
            Button {
                model.editor.commitPreset(item.document, mode: applicationMode)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(item.document.name)
                            .font(.callout)
                        if let sourceBadge {
                            Text(sourceBadge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                    }
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
                // Built-in presets can't be renamed, edited, or deleted --
                // `BuiltInPresetRepository.save`/`delete` always throw
                // `PresetError.builtInPresetIsReadOnly` -- so this menu
                // never even offers those actions for one; the only path
                // out is "Copy to My Presets" below, then edit the copy
                // (Phase 3 Task 3.1).
                if item.scope != .builtIn {
                    Button(L10n.t("Rename…"), action: onRename)
                    Button(L10n.t("Edit…"), action: onEdit)
                }
                Button(L10n.t("Export…"), action: onExport)
                // Round 3 (Codex re-review, finding #3): `PresetLibraryViewModel.copy(_:to:)`
                // existed and was tested end to end, but nothing in this view
                // ever called it -- there was no way to reach it without a
                // mouse, keyboard, or VoiceOver, from this menu or anywhere
                // else. This is that entry point; only the scope that isn't
                // already `item.scope` is ever offered, and only when it
                // exists at all (`copyDestination` is `nil` otherwise).
                if let destination = copyDestination {
                    Button(copyMenuTitle(for: destination)) { onCopy(destination) }
                        .help(copyMenuTitle(for: destination))
                        .accessibilityLabel(copyMenuTitle(for: destination))
                }
                if item.scope != .builtIn {
                    Divider()
                    Button(L10n.t("Delete"), role: .destructive) {
                        Task { await presetLibrary.delete(item) }
                    }
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
        .onHover(perform: onHoverChanged)
        .padding(.vertical, 2)
        .accessibilityHint(L10n.t("Use the up and down arrow keys to preview presets in this list"))
    }
}
