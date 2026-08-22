import Localization
import PresetCore
import SwiftUI
import UniformTypeIdentifiers

/// Spec §9.3: pick one or more `.xmp` files, see a preview summary (native /
/// approximate / preserved counts, with approximate leaves the user can
/// uncheck), then confirm into a chosen scope. Nothing is written until
/// confirmed, and cancelling at any point writes nothing.
struct ImportPresetSheet: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isShowingFilePicker = false
    @State private var scope: PresetScopeKind = .mine

    private var presetLibrary: PresetLibraryViewModel { model.presetLibrary }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("Import Develop Presets"))
                .font(.title3.weight(.semibold))

            switch presetLibrary.importState {
            case .idle:
                emptyState
            case .loading:
                ProgressView(L10n.t("Reading files…"))
                    .frame(maxWidth: .infinity, minHeight: 120)
            case .preview:
                summaryList
            case .saving:
                ProgressView(L10n.t("Saving…"))
                    .frame(maxWidth: .infinity, minHeight: 120)
            case .partialResult(let succeeded, let failed):
                partialResultView(succeeded: succeeded, failed: failed)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }

            Divider()

            HStack {
                Button(L10n.t("Choose Files…")) { isShowingFilePicker = true }
                    .accessibilityLabel(L10n.t("Choose develop preset files to import"))

                Spacer()

                if presetLibrary.importState == .preview {
                    // The "This Library" segment only exists when there's a
                    // library scope to save into -- rather than disabling
                    // the whole picker after the fact (which used to trap
                    // `scope` on `.library` with no way back to `.mine` once
                    // `hasLibraryScope` was false), the invalid option is
                    // simply never selectable in the first place.
                    Picker(L10n.t("Save to"), selection: $scope) {
                        Text(PresetScopeKind.mine.title).tag(PresetScopeKind.mine)
                        if presetLibrary.hasLibraryScope {
                            Text(PresetScopeKind.library.title).tag(PresetScopeKind.library)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }

                Button(L10n.t("Cancel")) {
                    presetLibrary.cancelImport()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.t("Import")) {
                    Task { await presetLibrary.confirmImport(scope: scope) }
                }
                .keyboardShortcut(.defaultAction)
                // Second line of defense alongside the picker above and
                // `confirmImport`'s own guard: this must never be tappable
                // while pointed at a scope that doesn't actually exist.
                .disabled(presetLibrary.importState != .preview || (scope == .library && !presetLibrary.hasLibraryScope))
            }
        }
        .padding(20)
        .frame(width: 520)
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [.xml, .init(filenameExtension: "xmp") ?? .xml],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { await presetLibrary.previewImport(urls) }
            }
        }
        .onChange(of: presetLibrary.hasLibraryScope) { _, hasLibraryScope in
            // The library can close while this sheet is still open (e.g. the
            // user switches libraries mid-import) -- fall back to a scope
            // that's actually available rather than leaving `scope` pointed
            // at one that just disappeared.
            if !hasLibraryScope, scope == .library {
                scope = .mine
            }
        }
    }

    private var emptyState: some View {
        Text(L10n.t("Choose one or more .xmp develop preset files to see what LumaHarbor can import."))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func partialResultView(succeeded: Int, failed: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(String(format: L10n.t("Imported %d of %d files."), succeeded, succeeded + failed))
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private var summaryList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(presetLibrary.importItems) { item in
                    ImportItemSummaryRow(item: item, presetLibrary: presetLibrary)
                    Divider()
                }
            }
        }
        .frame(height: 320)
    }
}

private struct ImportItemSummaryRow: View {
    let item: PresetImportItem
    let presetLibrary: PresetLibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.preview.proposedPreset.name)
                .font(.callout.weight(.semibold))

            HStack(spacing: 12) {
                Label("\(item.preview.nativeFields.count)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help(L10n.t("Native: applies reliably"))
                Label("\(item.preview.approximateFields.count)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(L10n.t("Approximate: applies, but the algorithm differs from Adobe's"))
                Label("\(item.preview.preservedProperties.count)", systemImage: "archivebox.fill")
                    .foregroundStyle(.secondary)
                    .help(L10n.t("Preserved: kept but not applied"))
            }
            .font(.caption)

            if !item.preview.hasApplicableAdjustments {
                Text(L10n.t("This preset has no adjustments LumaHarbor can apply yet."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(item.preview.approximateFields, id: \.self) { field in
                Toggle(
                    field.rawValue,
                    isOn: Binding(
                        get: { !item.deselectedApproximateFields.contains(field) },
                        set: { included in
                            presetLibrary.setApproximateField(field, included: included, for: item.id)
                        }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.caption)
            }
        }
    }
}
